// 白盒：HEVC 编码器 4:4:4（chroma_format_idc=3，Range Extensions profile）。
// 判据仍是「编码器局部重建 == 自家解码器输出」。4:4:4 与 4:2:0/4:2:2 的差别：
//   * hshift/vshift 全为 0，色度平面与 luma 同尺寸；
//   * 每个 luma TU 对应一个同尺寸的色度 TU（n_chroma_blocks=1）；
//   * 色度可以有自己的 intra 模式（每 PU 一个 bin），DM 模式不再重映射；
//   * 4x4 色度 TU 也参与编码（chroma_format_idc==3 才允许 log2_trafo_size<=2）。

///|
fn hevc_enc_444_plane(
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
fn hevc_enc_444_roundtrip(
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  qp : Int32,
  bit_depth : Int32,
) -> Unit raise {
  let frame = match
    hevc_encode_intra_frame(
      y,
      u,
      v,
      width=w,
      height=h,
      qp~,
      bit_depth~,
      chroma_format_idc=3,
    ) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  let pic = match ff_hevc_decode_intra_frame(frame.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("decode: \{e}")
  }
  let pw = frame.width
  let ph = frame.height
  if pic.cw != pw || pic.ch != ph {
    fail("decoder chroma dims \{pic.cw}x\{pic.ch}, expected \{pw}x\{ph}")
  }
  if frame.cstride != pw {
    fail("cstride=\{frame.cstride}, expected \{pw}")
  }
  for i in 0..<(pw * ph) {
    if pic.y[i] != frame.recon_y[i] {
      fail(
        "y mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{pic.y[i]} enc=\{frame.recon_y[i]}",
      )
    }
    if pic.cb[i] != frame.recon_u[i] {
      fail(
        "u mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{pic.cb[i]} enc=\{frame.recon_u[i]}",
      )
    }
    if pic.cr[i] != frame.recon_v[i] {
      fail(
        "v mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{pic.cr[i]} enc=\{frame.recon_v[i]}",
      )
    }
  }
}

///|
test "hevc enc 444: 64x64 gradient qp26 round-trip" {
  let y = hevc_enc_444_plane(64, 64, fn(i, j) { i * 3 + j * 2 + 128 })
  let u = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 2 + j * 3) & 255 })
  let v = hevc_enc_444_plane(64, 64, fn(_, j) { (128 + j * 2) & 255 })
  hevc_enc_444_roundtrip(y, u, v, 64, 64, 26, 8)
}

///|
test "hevc enc 444: non-CTB-aligned 48x40" {
  let y = hevc_enc_444_plane(48, 40, fn(i, j) { (i * 5 + j * 7) & 255 })
  let u = hevc_enc_444_plane(48, 40, fn(i, j) { (64 + i * 4 - j * 2) & 255 })
  let v = hevc_enc_444_plane(48, 40, fn(_, j) { (200 - j) & 255 })
  hevc_enc_444_roundtrip(y, u, v, 48, 40, 32, 8)
}

///|
test "hevc enc 444: qp sweep" {
  let y = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 4 + j * 3) & 255 })
  let u = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 6 + j) & 255 })
  let v = hevc_enc_444_plane(64, 64, fn(i, j) { (j * 2 + i) & 255 })
  for qp in [12, 26, 40, 51] {
    hevc_enc_444_roundtrip(y, u, v, 64, 64, qp, 8)
  }
}

///|
test "hevc enc 444: 10-bit round-trip" {
  let y = hevc_enc_444_plane(64, 64, fn(i, j) { 512 + i * 5 + j * 3 })
  let u = hevc_enc_444_plane(64, 64, fn(i, j) { 512 + i * 7 - j * 2 })
  let v = hevc_enc_444_plane(64, 64, fn(i, j) { 500 + (i + j) * 3 })
  hevc_enc_444_roundtrip(y, u, v, 64, 64, 26, 10)
}

///|
test "hevc enc 444: SPS advertises Range Extensions and 4:4:4" {
  let y = hevc_enc_444_plane(64, 64, fn(i, j) { 100 + i + j })
  let c = hevc_enc_444_plane(64, 64, fn(_, _) { 128 })
  let frame = match
    hevc_encode_intra_frame(
      y,
      c,
      c,
      width=64,
      height=64,
      qp=26,
      chroma_format_idc=3,
    ) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  let ps = new_hevc_param_sets()
  match ff_hevc_decode_extradata(frame.annexb, ps, true) {
    Ok(_) => ()
    Err(e) => fail("extradata: \{e}")
  }
  let sps = match ps.sps_list[0] {
    Some(s) => s
    None => fail("no SPS")
  }
  if sps.chroma_format_idc != 3 {
    fail("chroma_format_idc=\{sps.chroma_format_idc}, expected 3")
  }
  if sps.hshift[1] != 0 || sps.vshift[1] != 0 {
    fail("shifts (\{sps.hshift[1]},\{sps.vshift[1]}), expected (0,0)")
  }
  if sps.pix_fmt != "yuv444p" {
    fail("pix_fmt=\{sps.pix_fmt}, expected yuv444p")
  }
  if sps.ptl.general_ptl.profile_idc != 4 {
    fail("profile_idc=\{sps.ptl.general_ptl.profile_idc}, expected 4 (Rext)")
  }
}

///|
/// I/P round-trip in 4:4:4: exercises the inter chroma MC and residual paths
/// at full chroma resolution.
fn hevc_enc_444_p_roundtrip(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  w : Int32,
  h : Int32,
  qp : Int32,
  bit_depth : Int32,
) -> Unit raise {
  let seq = match
    hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      qp~,
      bit_depth~,
      chroma_format_idc=3,
    ) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let decoded = match ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  if decoded.length() != seq.frames.length() {
    fail("frame count \{decoded.length()} != \{seq.frames.length()}")
  }
  for k in 0..<seq.frames.length() {
    let enc = seq.frames[k]
    let dec = decoded[k].pic
    let pw = enc.width
    let ph = enc.height
    for i in 0..<(pw * ph) {
      if dec.y[i] != enc.recon_y[i] {
        fail("frame \{k} y mismatch at \{i}")
      }
      if dec.cb[i] != enc.recon_u[i] {
        fail("frame \{k} u mismatch at \{i}")
      }
      if dec.cr[i] != enc.recon_v[i] {
        fail("frame \{k} v mismatch at \{i}")
      }
    }
  }
}

///|
test "hevc enc 444: I/P static picture round-trip" {
  let y = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let u = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_444_plane(64, 64, fn(i, j) { (i * 5 + j * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
  ]
  frames.push((y.copy(), u.copy(), v.copy()))
  hevc_enc_444_p_roundtrip(frames, 64, 64, 26, 8)
}

///|
test "hevc enc 444: I/P translation (chroma MC) round-trip" {
  let w = 64
  let h = 64
  let y0 = hevc_enc_444_plane(w, h, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let u0 = hevc_enc_444_plane(w, h, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v0 = hevc_enc_444_plane(w, h, fn(i, j) { (i * 5 + j * 11) & 255 })
  for off in [(4, 0), (0, 4), (8, -4)] {
    let (dx, dy) = off
    let clamp = fn(v : Int32, n : Int32) -> Int32 {
      if v < 0 {
        0
      } else if v >= n {
        n - 1
      } else {
        v
      }
    }
    let y1 = hevc_enc_444_plane(w, h, fn(i, j) {
      y0[clamp(j + dy, h) * w + clamp(i + dx, w)]
    })
    let u1 = hevc_enc_444_plane(w, h, fn(i, j) {
      u0[clamp(j + dy, h) * w + clamp(i + dx, w)]
    })
    let v1 = hevc_enc_444_plane(w, h, fn(i, j) {
      v0[clamp(j + dy, h) * w + clamp(i + dx, w)]
    })
    let frames : Array[
      (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
    ] = [(y0, u0, v0), (y1, u1, v1)]
    hevc_enc_444_p_roundtrip(frames, w, h, 26, 8)
  }
}
