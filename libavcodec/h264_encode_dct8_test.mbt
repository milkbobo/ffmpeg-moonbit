// Blackbox tests for the High-profile transform_8x8 (8x8DCT) CABAC write
// path: I-frame I8x8 (I_NxN + transform_size_8x8_flag) and P-frame inter
// 8x8 residuals. Opt-in (`dct8x8=true`); the default chain stays Main
// profile byte-for-byte. Pinned against this repository's decoder, the
// encoder's own reconstruction, and docker ffmpeg's framemd5.

///|
/// Textured fixture: diagonal ramps + per-8x8-grid offset pattern - the
/// low-frequency ramps favour the 8x8 transform's compaction while the
/// grid keeps enough detail for a mix of I4/I8x16/I8x8 decisions.
fn h264_dct8_fixture(w : Int32, h : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<3 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 6 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = ((col + row) * 2) & 0xFF
        if (col / 8 + row / 8 + f) % 2 == 1 {
          s = (s + 24) & 0xFF
        }
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox {
          s = (s + 90) & 0xFF
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((96 + ((col + f) & 0x1F)).to_byte())
        v.push((160 - ((row + 2 * f) & 0x1F)).to_byte())
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
fn h264_dct8_md5(data : Bytes) -> String {
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
fn h264_dct8_plane_eq(
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
test "h264 enc: cabac 8x8dct I frame round-trips through own decoder" {
  let frames = h264_dct8_fixture(96, 64)
  let (y, u, v) = frames[0]
  let stats = @libavcodec.H264EncStats::new()
  let enc = match
    @libavcodec.h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=22,
      dct8x8=true,
      stats~,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  if stats.i8_mbs <= 0 {
    fail("no macroblock chose I8x8 (decision never fires?)")
  }
  // SPS is High profile and the PPS carries transform_8x8_mode_flag: the
  // second NAL's first RBSP byte of each set is the id, the SPS payload
  // starts after the 5-byte Annex B prefix + header.
  let annexb = enc.annexb
  if annexb[5] != 100 {
    fail("SPS profile_idc \{annexb[5].to_int()} != 100 (High)")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(annexb, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 1 {
    fail("expected 1 frame, got \{dec.length()}")
  }
  // Reconstruction invariant: the decoder's unfiltered output equals the
  // encoder's own reconstruction pixel-for-pixel.
  let f = dec[0]
  if !h264_dct8_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("encoder luma reconstruction != decoder reconstruction")
  }
  if !h264_dct8_plane_eq(enc.recon_u, f.u, enc.cstride, 32) {
    fail("encoder u reconstruction != decoder reconstruction")
  }
  if !h264_dct8_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
    fail("encoder v reconstruction != decoder reconstruction")
  }
  // Quality floor: the textured fixture survives the round trip.
  let mut sum = 0
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let d = y[row * 96 + col].to_int() - f.y[row * f.ystride + col]
      sum = sum + (if d < 0 { -d } else { d })
    }
  }
  if sum / (96 * 64) > 12 {
    fail("textured luma mean abs error \{sum / (96 * 64)} too high")
  }
  // The plain (4x4-only) stream must differ: the mode surface changed.
  let plain_stats = @libavcodec.H264EncStats::new()
  let plain = match
    @libavcodec.h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=22,
      stats~,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  if plain_stats.i8_mbs != 0 {
    fail("dct8x8 off must not select I8x8")
  }
  if plain.annexb.length() == annexb.length() {
    fail("8x8 stream identical in size to the 4x4 stream")
  }
}

///|
test "h264 enc: cabac 8x8dct P frames round-trip" {
  let frames = h264_dct8_fixture(96, 64)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      dct8x8=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i8_mbs <= 0 {
    fail("no inter macroblock used the 8x8 transform")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  if recon.length() != 2 {
    fail("expected 2 P-frame reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264_dct8_md5(r) != h264_dct8_md5(dec[i + 1].yuvp()) {
      fail("P frame \{i + 1}: encoder reconstruction != decoder reconstruction")
    }
  }
  // The plain stream (no 8x8) must be a different byte sequence.
  let plain = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if plain == stream {
    fail("8x8 stream identical to the default stream")
  }
  // Pinned against docker ffmpeg 9.0.2 (`nine-x264`) framemd5: zero
  // warnings, every frame byte-identical to this decoder's filtered output.
  let filtered = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins = [
    "5e000f9f8f4751c735c9595853041e9c", "b765d76e71eff64313c6355e8bfcc8af", "2070b0ecc8fee0af012416d7456d5468",
  ]
  for i, f in filtered {
    inspect(h264_dct8_md5(f.yuvp()), content=pins[i])
  }
  // Replayable Annex B dump for the external ffmpeg arbitration.
  let mut d = ""
  for i = 0; i < stream.length(); i = i + 1 {
    d = d + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("DCT8ARB:\{d}")
}
