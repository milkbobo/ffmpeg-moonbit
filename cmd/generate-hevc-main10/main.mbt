///|
/// Generate the pure-MoonBit HEVC Main10 I/P/B stream for black-box arbitration.
/// Usage: moon run cmd/generate-hevc-main10 <existing scratch dir>
///
/// Writes `main10_ipb.265` (display order I0, B1, P2, P3; coding order I0, P2,
/// B1, P3). Decode it with FFmpeg 9.0.2 and `-f framemd5 -` to regenerate the
/// reference hashes in `libavcodec/hevc_enc_main10_test.mbt`.

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
    fail("usage: generate-hevc-main10 <existing scratch dir>")
  }
  let dir = args[1]
  let w = 64
  let h = 64
  let y0 = plane(w, h, fn(i, j) { (i * 13 + j * 9 + 512) & 1023 })
  let u0 = plane(w >> 1, h >> 1, fn(i, j) { (i * 17 + j * 11 + 300) & 1023 })
  let v0 = plane(w >> 1, h >> 1, fn(i, j) { (i * 7 + j * 19 + 700) & 1023 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = plane(w, h, fn(i, j) {
      y0[clamp(j + dy, h) * w + clamp(i + dx, w)]
    })
    let uk = plane(w >> 1, h >> 1, fn(i, j) {
      u0[clamp(j + dy, h >> 1) * (w >> 1) + clamp(i + dx, w >> 1)]
    })
    let vk = plane(w >> 1, h >> 1, fn(i, j) {
      v0[clamp(j + dy, h >> 1) * (w >> 1) + clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  let seq = match
    @libavcodec.hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=true,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail("encode: \{e}")
  }
  let stream_path = dir + "/main10_ipb.265"
  @fs.write_bytes_to_file(stream_path, seq.annexb)
  println("wrote \{stream_path} (\{seq.annexb.length()} bytes)")
  for f in seq.frames {
    println(
      "frame poc=\{f.poc} slice=\{f.slice_type} bytes=\{f.annexb.length()}",
    )
  }
}
