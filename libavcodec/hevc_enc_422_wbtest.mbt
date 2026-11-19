// 白盒：HEVC 编码器 4:2:2（chroma_format_idc=2，Range Extensions profile）。
// 判据与 4:2:0 的 §452/§455 一致——编码器局部重建必须与自家解码器逐字节
// 相等，这说明两边的色度几何、色度模式映射、cbf 语义完全对齐。
//
// 4:2:2 的关键差别：
//   * hshift[1]=1、vshift[1]=0，色度平面是 (w/2) x h；
//   * 每个 luma TU 对应两个上下堆叠的色度 TU（n_chroma_blocks=2），
//     第二个色度块的预测要用到第一个块残差叠加后的邻居；
//   * 每个色度块各自编码一个 cbf_cb/cbf_cr bin；
//   * 色度 DM 模式要经 hevc_tab_mode_idx 重映射。

///|
fn hevc_enc_422_plane(
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
/// Encode one 4:2:2 intra frame, decode it with the in-loop filters on, and
/// compare every plane sample against the encoder's local reconstruction.
fn hevc_enc_422_roundtrip(
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
      chroma_format_idc=2,
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
  for i in 0..<(pw * ph) {
    if pic.y[i] != frame.recon_y[i] {
      fail(
        "y mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{pic.y[i]} enc=\{frame.recon_y[i]}",
      )
    }
  }
  // 4:2:2: horizontally halved, vertically full resolution.
  let cw = pw / 2
  let ch = ph
  if frame.cstride != cw {
    fail("cstride=\{frame.cstride}, expected \{cw}")
  }
  if pic.cw != cw || pic.ch != ch {
    fail("decoder chroma dims \{pic.cw}x\{pic.ch}, expected \{cw}x\{ch}")
  }
  for i in 0..<(cw * ch) {
    if pic.cb[i] != frame.recon_u[i] {
      fail(
        "u mismatch at (\{i % cw},\{i / cw}) qp=\{qp}: dec=\{pic.cb[i]} enc=\{frame.recon_u[i]}",
      )
    }
    if pic.cr[i] != frame.recon_v[i] {
      fail(
        "v mismatch at (\{i % cw},\{i / cw}) qp=\{qp}: dec=\{pic.cr[i]} enc=\{frame.recon_v[i]}",
      )
    }
  }
}

///|
test "hevc enc 422: 64x64 gradient qp26 round-trip" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { i * 3 + j * 2 + 128 })
  let u = hevc_enc_422_plane(32, 64, fn(i, j) { (i * 2 + j * 3) & 255 })
  let v = hevc_enc_422_plane(32, 64, fn(_, j) { (128 + j) & 255 })
  hevc_enc_422_roundtrip(y, u, v, 64, 64, 26, 8)
}

///|
test "hevc enc 422: non-CTB-aligned 48x40" {
  let y = hevc_enc_422_plane(48, 40, fn(i, j) { (i * 5 + j * 7) & 255 })
  let u = hevc_enc_422_plane(24, 40, fn(i, j) { (64 + i * 4 - j * 2) & 255 })
  let v = hevc_enc_422_plane(24, 40, fn(_, _) { 200 })
  hevc_enc_422_roundtrip(y, u, v, 48, 40, 32, 8)
}

///|
test "hevc enc 422: flat chroma exercises zero-cbf path" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { 128 + i / 8 * 4 - j / 8 * 4 })
  let u = hevc_enc_422_plane(32, 64, fn(_, _) { 128 })
  let v = hevc_enc_422_plane(32, 64, fn(_, _) { 128 })
  hevc_enc_422_roundtrip(y, u, v, 64, 64, 22, 8)
}

///|
test "hevc enc 422: qp sweep" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { (i * 4 + j * 3) & 255 })
  let u = hevc_enc_422_plane(32, 64, fn(i, j) { (i * 6 + j) & 255 })
  let v = hevc_enc_422_plane(32, 64, fn(i, j) { (j * 2 + i) & 255 })
  for qp in [12, 26, 40, 51] {
    hevc_enc_422_roundtrip(y, u, v, 64, 64, qp, 8)
  }
}

///|
test "hevc enc 422: 10-bit round-trip" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { 512 + i * 5 + j * 3 })
  let u = hevc_enc_422_plane(32, 64, fn(i, j) { 512 + i * 7 - j * 2 })
  let v = hevc_enc_422_plane(32, 64, fn(i, j) { 500 + (i + j) * 3 })
  hevc_enc_422_roundtrip(y, u, v, 64, 64, 26, 10)
}

///|
test "hevc enc 422: SPS advertises Range Extensions and 4:2:2" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { 100 + i + j })
  let u = hevc_enc_422_plane(32, 64, fn(_, _) { 128 })
  let v = hevc_enc_422_plane(32, 64, fn(_, _) { 128 })
  let frame = match
    hevc_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=64,
      qp=26,
      chroma_format_idc=2,
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
  if sps.chroma_format_idc != 2 {
    fail("chroma_format_idc=\{sps.chroma_format_idc}, expected 2")
  }
  if sps.hshift[1] != 1 || sps.vshift[1] != 0 {
    fail("shifts (\{sps.hshift[1]},\{sps.vshift[1]}), expected (1,0)")
  }
  if sps.pix_fmt != "yuv422p" {
    fail("pix_fmt=\{sps.pix_fmt}, expected yuv422p")
  }
  if sps.ptl.general_ptl.profile_idc != 4 {
    fail("profile_idc=\{sps.ptl.general_ptl.profile_idc}, expected 4 (Rext)")
  }
  if sps.ptl.general_ptl.profile_compatibility_flag[4] == 0 {
    fail("Rext compatibility flag not set")
  }
}

///|
test "hevc enc 422: 10-bit SPS reports yuv422p10le" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { 512 + i + j })
  let u = hevc_enc_422_plane(32, 64, fn(_, _) { 512 })
  let v = hevc_enc_422_plane(32, 64, fn(_, _) { 512 })
  let frame = match
    hevc_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=64,
      qp=26,
      bit_depth=10,
      chroma_format_idc=2,
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
  if sps.bit_depth != 10 {
    fail("bit_depth=\{sps.bit_depth}, expected 10")
  }
  if sps.pix_fmt != "yuv422p10le" {
    fail("pix_fmt=\{sps.pix_fmt}, expected yuv422p10le")
  }
  if sps.qp_bd_offset != 12 {
    fail("qp_bd_offset=\{sps.qp_bd_offset}, expected 12")
  }
}

///|
test "hevc enc 422: plane size guard uses 4:2:2 chroma geometry" {
  let y = hevc_enc_422_plane(64, 64, fn(_, _) { 128 })
  // A 4:2:0-sized chroma plane (32x32) is too small for 4:2:2 (needs 32x64).
  let small = hevc_enc_422_plane(32, 32, fn(_, _) { 128 })
  match
    hevc_encode_intra_frame(
      y,
      small,
      small,
      width=64,
      height=64,
      chroma_format_idc=2,
    ) {
    Ok(_) => fail("expected plane-too-small error")
    Err(e) =>
      if !e.contains("plane too small") {
        fail("unexpected error: \{e}")
      }
  }
  // The same planes are exactly right for 4:2:0.
  match
    hevc_encode_intra_frame(
      y,
      small,
      small,
      width=64,
      height=64,
      chroma_format_idc=1,
    ) {
    Ok(_) => ()
    Err(e) => fail("4:2:0 should accept 32x32 chroma: \{e}")
  }
}

///|
test "hevc enc 422: chroma_format_idc 0 and 4 are rejected" {
  let y = hevc_enc_422_plane(64, 64, fn(_, _) { 128 })
  let c = hevc_enc_422_plane(32, 32, fn(_, _) { 128 })
  for cf in [0, 4, -1] {
    match
      hevc_encode_intra_frame(
        y,
        c,
        c,
        width=64,
        height=64,
        chroma_format_idc=cf,
      ) {
      Ok(_) => fail("chroma_format_idc=\{cf} should be rejected")
      Err(_) => ()
    }
  }
}

///|
/// Encode an I/P sequence in 4:2:2 and compare every reconstruction with the
/// frame-level decoder's output. This is the path that exercises 4:2:2 chroma
/// motion compensation and the per-block inter residual coding.
fn hevc_enc_422_p_roundtrip(
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
      chroma_format_idc=2,
    ) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  assert_true(seq.frames.length() == frames.length())
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
        fail(
          "frame \{k} y mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{dec.y[i]} enc=\{enc.recon_y[i]}",
        )
      }
    }
    let cw = pw / 2
    let ch = ph
    for i in 0..<(cw * ch) {
      if dec.cb[i] != enc.recon_u[i] {
        fail(
          "frame \{k} u mismatch at \{i}: dec=\{dec.cb[i]} enc=\{enc.recon_u[i]}",
        )
      }
      if dec.cr[i] != enc.recon_v[i] {
        fail(
          "frame \{k} v mismatch at \{i}: dec=\{dec.cr[i]} enc=\{enc.recon_v[i]}",
        )
      }
    }
  }
}

///|
/// A two-frame 4:2:2 pair where the second frame is the first shifted by
/// `(dx, dy)` chroma samples (edge-replicated), so the motion search finds a
/// pure translation and the chroma MC path is taken with a non-zero MV.
fn hevc_enc_422_shift_pair(
  w : Int32,
  h : Int32,
  dx : Int32,
  dy : Int32,
) -> Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] {
  let y0 = hevc_enc_422_plane(w, h, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let cw = w / 2
  let ch = h
  let u0 = hevc_enc_422_plane(cw, ch, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v0 = hevc_enc_422_plane(cw, ch, fn(i, j) { (i * 5 + j * 11) & 255 })
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  let y1 = hevc_enc_422_plane(w, h, fn(i, j) {
    y0[clamp(j + dy, h) * w + clamp(i + dx, w)]
  })
  let u1 = hevc_enc_422_plane(cw, ch, fn(i, j) {
    u0[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
  })
  let v1 = hevc_enc_422_plane(cw, ch, fn(i, j) {
    v0[clamp(j + dy, ch) * cw + clamp(i + dx, cw)]
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y0, u0, v0))
  frames.push((y1, u1, v1))
  frames
}

///|
test "hevc enc 422: I/P static picture round-trip" {
  let y = hevc_enc_422_plane(64, 64, fn(i, j) { (i * 3 + j * 5 + 40) & 255 })
  let u = hevc_enc_422_plane(32, 64, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v = hevc_enc_422_plane(32, 64, fn(i, j) { (i * 5 + j * 11) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y, u, v))
  frames.push((y.copy(), u.copy(), v.copy()))
  hevc_enc_422_p_roundtrip(frames, 64, 64, 26, 8)
}

///|
test "hevc enc 422: I/P pure translation (chroma MC) round-trip" {
  for off in [(4, 0), (0, 4), (8, -4)] {
    let (dx, dy) = off
    hevc_enc_422_p_roundtrip(
      hevc_enc_422_shift_pair(64, 64, dx, dy),
      64,
      64,
      26,
      8,
    )
  }
}

///|
test "hevc enc 422: 10-bit I/P round-trip" {
  let y0 = hevc_enc_422_plane(64, 64, fn(i, j) { 512 + i * 3 + j * 2 })
  let u0 = hevc_enc_422_plane(32, 64, fn(i, j) { 512 + i * 5 - j })
  let v0 = hevc_enc_422_plane(32, 64, fn(i, j) { 500 + (i + j) * 2 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y0, u0, v0))
  frames.push((y0.copy(), u0.copy(), v0.copy()))
  hevc_enc_422_p_roundtrip(frames, 64, 64, 26, 10)
}
