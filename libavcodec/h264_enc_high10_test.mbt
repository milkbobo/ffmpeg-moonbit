// Blackbox tests for the High 10 encoder path (`§412`): 9/10-bit input
// arrives as planar little-endian 16-bit samples (`yuv420p10le`), the
// parameter sets switch to profile_idc 110 with the matching
// `bit_depth_*_minus8`, and every picture must satisfy the same
// reconstruction invariant the 8-bit families pin — the encoder's local
// recon equals this repository's decoder output (skip_lf) point for point.

///|
/// Luma content that makes the CABAC intra encoder actually pick I8x8 (the
/// shape `h264_encode_dct8_test` uses at 8-bit: per-8x8-grid offset pattern
/// plus one bright 16x16 box), scaled to `bd` bits.
fn h264h10_dct8_y(w : Int32, h : Int32, bd : Int32) -> Bytes {
  let scale = 1 << (bd - 8)
  let out : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let mut s = ((col + row) * 2) & 0xFF
      if (col / 8 + row / 8) % 2 == 1 {
        s = (s + 5) & 0xFF
      }
      if col >= 8 && col < 24 && row >= 8 && row < 24 {
        s = (s + 90) & 0xFF
      }
      h264h10_push(out, s * scale, bd)
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Pack one 9/10-bit plane sample pair (little-endian low byte first).
fn h264h10_push(buf : Array[Byte], v : Int32, bd : Int32) -> Unit {
  buf.push((v & 0xFF).to_byte())
  if bd > 8 {
    buf.push(((v >> 8) & 0xFF).to_byte())
  }
}

///|
/// One synthetic 9/10-bit sequence: an 8-bit pattern scaled by `2^(bd-8)`
/// (so 9-bit stays inside 0..510 and 10-bit inside 0..1020) plus the same
/// moving box the 8-bit P fixtures use, packed little-endian.
fn h264h10_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
  bd : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let scale = 1 << (bd - 8)
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 3 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f) & 0xFF
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 40
        } else if inbox {
          s = 220
        }
        let s16 = s * scale
        y.push((s16 & 0xFF).to_byte())
        y.push(((s16 >> 8) & 0xFF).to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let cu = (((col + f) & 0x3F) + 96) * scale
        let cv = (((row + f * 2) & 0x3F) + 96) * scale
        u.push((cu & 0xFF).to_byte())
        u.push(((cu >> 8) & 0xFF).to_byte())
        v.push((cv & 0xFF).to_byte())
        v.push(((cv >> 8) & 0xFF).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
fn h264h10_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
/// Plane equality over the macroblock-aligned area (`stride * rows`).
fn h264h10_plane_eq(
  a : Array[Int32],
  b : Array[Int32],
  stride : Int32,
  rows : Int32,
) -> Bool {
  for row = 0; row < rows; row = row + 1 {
    for col = 0; col < stride; col = col + 1 {
      if a[row * stride + col] != b[row * stride + col] {
        return false
      }
    }
  }
  true
}

///|
/// The SPS NAL's `profile_idc` byte: the first `nal_unit_header` (0x67) sits
/// inside the first eight bytes of the stream, and the profile follows it.
fn h264h10_sps_profile(annexb : Bytes) -> Int32 {
  for i = 0; i < 8; i = i + 1 {
    if annexb[i].to_int() == 0x67 {
      return annexb[i + 1].to_int()
    }
  }
  -1
}

///|
test "h264 enc: high10 CAVLC intra frame round-trips" {
  let frames = h264h10_fixture(96, 64, 1, 10)
  let (y, u, v) = frames[0]
  let enc = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      bit_depth=10,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  if h264h10_sps_profile(enc.annexb) != 110 {
    fail("High 10 SPS profile_idc \{h264h10_sps_profile(enc.annexb)} != 110")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 1 {
    fail("expected 1 frame, got \{dec.length()}")
  }
  let f = dec[0]
  if f.bit_depth != 10 {
    fail("decoder saw bit_depth \{f.bit_depth}, expected 10")
  }
  if !h264h10_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("high10 luma recon differs from decoder output")
  }
  if !h264h10_plane_eq(enc.recon_u, f.u, enc.cstride, 32) {
    fail("high10 cb recon differs from decoder output")
  }
  if !h264h10_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
    fail("high10 cr recon differs from decoder output")
  }
  // Quality sanity in the 10-bit sample domain: the same quantiser step as
  // the 8-bit fixtures, so the mean absolute error scales by 2^(bd-8).
  let mut sum_abs = 0
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let idx = 2 * (row * 96 + col)
      let src = y[idx].to_int() | (y[idx + 1].to_int() << 8)
      let d = enc.recon_y[row * enc.ystride + col] - src
      sum_abs = sum_abs + (if d < 0 { -d } else { d })
    }
  }
  if sum_abs / (96 * 64) > 160 {
    fail(
      "high10 luma mean abs error \{sum_abs / (96 * 64)} exceeds 4x the 8-bit bound",
    )
  }
}

///|
test "h264 enc: high10 I_PCM is lossless" {
  let frames = h264h10_fixture(96, 64, 1, 10)
  let (y, u, v) = frames[0]
  let enc = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      pcm=true,
      bit_depth=10,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 1 {
    fail("expected 1 frame, got \{dec.length()}")
  }
  let f = dec[0]
  if f.bit_depth != 10 {
    fail("PCM picture decoded at bit_depth \{f.bit_depth}")
  }
  if !h264h10_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("PCM luma differs from decoder output")
  }
  // PCM bypasses the transform: every sample equals the source.
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let idx = 2 * (row * 96 + col)
      let src = y[idx].to_int() | (y[idx + 1].to_int() << 8)
      if enc.recon_y[row * enc.ystride + col] != src {
        fail("PCM sample mismatch at \{col},\{row}")
      }
    }
  }
}

///|
test "h264 enc: high10 CABAC 8x8 DCT intra frame round-trips" {
  let frames = h264h10_fixture(96, 64, 1, 10)
  let (_, u, v) = frames[0]
  let y = h264h10_dct8_y(96, 64, 10)
  let stats = @libavcodec.H264EncStats::new()
  let enc = match
    @libavcodec.h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=24,
      dct8x8=true,
      stats~,
      bit_depth=10,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  if stats.i8_mbs <= 0 {
    fail("high10 CABAC intra never selected the 8x8 transform")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let f = dec[0]
  if f.bit_depth != 10 {
    fail("decoder saw bit_depth \{f.bit_depth}, expected 10")
  }
  if !h264h10_plane_eq(enc.recon_y, f.y, enc.ystride, 64) ||
    !h264h10_plane_eq(enc.recon_u, f.u, enc.cstride, 32) ||
    !h264h10_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
    fail("high10 CABAC intra reconstruction differs from decoder output")
  }
}

///|
test "h264 enc: high10 CAVLC P/B sequence round-trips" {
  let frames = h264h10_fixture(96, 64, 3, 10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      recon~,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  for f in dec {
    if f.bit_depth != 10 {
      fail("decoded frame bit_depth \{f.bit_depth}, expected 10")
    }
  }
  if recon.length() != 2 {
    fail("expected 2 P reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264h10_md5(r) != h264h10_md5(dec[i + 1].yuvp()) {
      fail("P frame \{i + 1}: recon != decoder reconstruction")
    }
  }
}

///|
test "h264 enc: high10 CABAC P/B sequence round-trips" {
  let frames = h264h10_fixture(96, 64, 3, 10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      recon~,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  for f in dec {
    if f.bit_depth != 10 {
      fail("decoded CABAC frame bit_depth \{f.bit_depth}, expected 10")
    }
  }
  if recon.length() != 2 {
    fail("expected 2 P reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264h10_md5(r) != h264h10_md5(dec[i + 1].yuvp()) {
      fail("CABAC P frame \{i + 1}: recon != decoder reconstruction")
    }
  }
}

///|
test "h264 enc: high10 AQ and weighted P prediction round-trip" {
  let frames = h264h10_fixture(96, 64, 3, 10)
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      aq=true,
      aq_strength=2,
      weightp=true,
      recon~,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  for i, r in recon {
    if h264h10_md5(r) != h264h10_md5(dec[i + 1].yuvp()) {
      fail("AQ/weightp P frame \{i + 1}: recon != decoder reconstruction")
    }
  }
}

///|
test "h264 enc: high10 stream encoder matches the batch entry" {
  let frames = h264h10_fixture(96, 64, 4, 10)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      bit_depth=10,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      bit_depth=10,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let aus = match enc.finish() {
    Ok(a) => a
    Err(e) => fail(e)
  }
  let mut streamed = ""
  let out : Array[Byte] = []
  for au in aus {
    for b in au {
      out.push(b)
    }
  }
  let joined = Bytes::from_array(out[:])
  if h264h10_md5(joined) != h264h10_md5(batch) {
    streamed = "sizes \{joined.length()} vs \{batch.length()}"
    fail("high10 stream encoder != batch entry (\{streamed})")
  }
}

///|
test "h264 enc: 9-bit round-trips and other depths are rejected" {
  let frames = h264h10_fixture(96, 64, 1, 9)
  let (y, u, v) = frames[0]
  let enc = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      bit_depth=9,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec[0].bit_depth != 9 {
    fail("9-bit frame decoded at bit_depth \{dec[0].bit_depth}")
  }
  if !h264h10_plane_eq(enc.recon_y, dec[0].y, enc.ystride, 64) {
    fail("9-bit luma recon differs from decoder output")
  }
  match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      bit_depth=11,
    ) {
    Ok(_) => fail("bit_depth 11 should be rejected")
    Err(_) => ()
  }
}
