///|
/// Generate pure-MoonBit HEVC Range Extensions streams for black-box
/// arbitration against FFmpeg.
/// Usage: moon run cmd/generate-hevc-422 <existing scratch dir>
///
/// Writes:
///   * `hevc422_i.265`   — one IDR I frame, 8-bit 4:2:2;
///   * `hevc422_ip.265`  — I + P, 8-bit 4:2:2;
///   * `hevc422_i10.265` — one IDR I frame, 10-bit 4:2:2 (yuv422p10le);
///   * `hevc444_i.265`   — one IDR I frame, 8-bit 4:4:4;
///   * `hevc444_ip.265`  — I + P, 8-bit 4:4:4.
///
/// Decode each with FFmpeg 9.0.2 and `-f framemd5 -` to regenerate the
/// reference hashes in `libavcodec/hevc_enc_422_test.mbt` /
/// `libavcodec/hevc_enc_444_test.mbt`.

///|
fn plane(
  w : Int32,
  h : Int32,
  f : (Int32, Int32) -> Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for j in 0..<h {
    for i in 0..<w {
      out[j * w + i] = f(i, j)
    }
  }
  out
}

///|
fn clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn main raise {
  let args = @env.args()
  guard args.length() == 2 else {
    fail("usage: generate-hevc-422 <existing scratch dir>")
  }
  let dir = args[1]
  let w = 64
  let h = 64
  let cw = w / 2
  let ch = h
  // 8-bit 4:2:2: chroma is horizontally halved, vertically full resolution.
  let y = plane(w, h, fn(i, j) { (i * 5 + j * 3 + 40) & 255 })
  let u = plane(cw, ch, fn(i, j) { (i * 9 + j * 5 + 20) & 255 })
  let v = plane(cw, ch, fn(i, j) { (i * 3 + j * 11 + 90) & 255 })
  match
    @libavcodec.hevc_encode_intra_frame(
      y,
      u,
      v,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=2,
    ) {
    Ok(f) => {
      let p = dir + "/hevc422_i.265"
      @fs.write_bytes_to_file(p, f.annexb)
      println("wrote \{p} (\{f.annexb.length()} bytes)")
    }
    Err(e) => fail("encode i: \{e}")
  }
  // I + P with a pure translation, so the chroma MC path carries a real MV.
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
  ]
  for k in 1..<2 {
    let dx = k * 4
    let dy = k * 2
    let yk = plane(w, h, fn(i, j) { y[clamp(j + dy, h) * w + clamp(i + dx, w)] })
    let uk = plane(cw, ch, fn(i, j) {
      u[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
    })
    let vk = plane(cw, ch, fn(i, j) {
      v[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
    })
    frames.push((yk, uk, vk))
  }
  match
    @libavcodec.hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=2,
    ) {
    Ok(s) => {
      let p = dir + "/hevc422_ip.265"
      @fs.write_bytes_to_file(p, s.annexb)
      println("wrote \{p} (\{s.annexb.length()} bytes)")
    }
    Err(e) => fail("encode ip: \{e}")
  }
  // 10-bit 4:2:2.
  let y10 = plane(w, h, fn(i, j) { (i * 21 + j * 13 + 512) & 1023 })
  let u10 = plane(cw, ch, fn(i, j) { (i * 11 + j * 17 + 300) & 1023 })
  let v10 = plane(cw, ch, fn(i, j) { (i * 7 + j * 19 + 700) & 1023 })
  match
    @libavcodec.hevc_encode_intra_frame(
      y10,
      u10,
      v10,
      width=w,
      height=h,
      qp=26,
      bit_depth=10,
      chroma_format_idc=2,
    ) {
    Ok(f) => {
      let p = dir + "/hevc422_i10.265"
      @fs.write_bytes_to_file(p, f.annexb)
      println("wrote \{p} (\{f.annexb.length()} bytes)")
    }
    Err(e) => fail("encode i10: \{e}")
  }
  // 8-bit 4:4:4: chroma planes are the full luma size.
  let y444 = plane(w, h, fn(i, j) { (i * 6 + j * 4 + 30) & 255 })
  let u444 = plane(w, h, fn(i, j) { (i * 8 + j * 6 + 70) & 255 })
  let v444 = plane(w, h, fn(i, j) { (i * 4 + j * 12 + 150) & 255 })
  match
    @libavcodec.hevc_encode_intra_frame(
      y444,
      u444,
      v444,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=3,
    ) {
    Ok(f) => {
      let p = dir + "/hevc444_i.265"
      @fs.write_bytes_to_file(p, f.annexb)
      println("wrote \{p} (\{f.annexb.length()} bytes)")
    }
    Err(e) => fail("encode 444 i: \{e}")
  }
  let frames444 : Array[
    (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
  ] = [(y444, u444, v444)]
  let dx = 4
  let dy = 2
  let yk = plane(w, h, fn(i, j) {
    y444[clamp(j + dy, h) * w + clamp(i + dx, w)]
  })
  let uk = plane(w, h, fn(i, j) {
    u444[clamp(j + dy, h) * w + clamp(i + dx, w)]
  })
  let vk = plane(w, h, fn(i, j) {
    v444[clamp(j + dy, h) * w + clamp(i + dx, w)]
  })
  frames444.push((yk, uk, vk))
  match
    @libavcodec.hevc_encode_sequence(
      frames444,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=3,
    ) {
    Ok(s) => {
      let p = dir + "/hevc444_ip.265"
      @fs.write_bytes_to_file(p, s.annexb)
      println("wrote \{p} (\{s.annexb.length()} bytes)")
    }
    Err(e) => fail("encode 444 ip: \{e}")
  }
}
