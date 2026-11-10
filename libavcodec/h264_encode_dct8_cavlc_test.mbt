// Blackbox tests for the High-profile transform_8x8 (8x8DCT) CAVLC write
// path: I-frame I8x8 and P-frame inter 8x8 residuals under entropy_coding_
// mode 0. Opt-in (`dct8x8=true`); the default Baseline chain stays
// byte-for-byte. Pinned against this repository's decoder, the encoder's
// own reconstruction, and docker ffmpeg's framemd5.

///|
/// Textured fixture (same shape as the CABAC suite's): diagonal ramps + a
/// per-8x8-grid offset pattern + a roaming box.
fn h264_dct8c_fixture(w : Int32, h : Int32) -> Array[(Bytes, Bytes, Bytes)] {
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
fn h264_dct8c_md5(data : Bytes) -> String {
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
fn h264_dct8c_plane_eq(
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
test "h264 enc: cavlc 8x8dct I frame round-trips through own decoder" {
  let frames = h264_dct8c_fixture(96, 64)
  let (y, u, v) = frames[0]
  let stats = @libavcodec.H264EncStats::new()
  let enc = match
    @libavcodec.h264_encode_intra_frame(
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
  // SPS is High profile (CAVLC High is legal: 8x8dct requires High, the
  // entropy mode does not).
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
  let f = dec[0]
  if !h264_dct8c_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("encoder luma reconstruction != decoder reconstruction")
  }
  if !h264_dct8c_plane_eq(enc.recon_u, f.u, enc.cstride, 32) {
    fail("encoder u reconstruction != decoder reconstruction")
  }
  if !h264_dct8c_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
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
  // The plain (4x4-only, Baseline) stream must differ.
  let plain_stats = @libavcodec.H264EncStats::new()
  let plain = match
    @libavcodec.h264_encode_intra_frame(
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
test "h264 enc: cavlc 8x8dct P frames round-trip" {
  let frames = h264_dct8c_fixture(96, 64)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
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
    fail("no macroblock used the 8x8 transform")
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
    if h264_dct8c_md5(r) != h264_dct8c_md5(dec[i + 1].yuvp()) {
      fail("P frame \{i + 1}: encoder reconstruction != decoder reconstruction")
    }
  }
  // The plain stream (Baseline, no 8x8) must be a different byte sequence.
  let plain = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
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
  // The pixels equal the CABAC suite's pins by construction: both entropy
  // coders share one plan decision and one residual chain, so only the
  // bitstream bytes differ (the `plain == stream` check above and the
  // ffmpeg arbitration cover the CAVLC syntax itself).
  let pins = [
    "5e000f9f8f4751c735c9595853041e9c", "5956be95a23f9b1804bcbc30dd0c2fd2", "50c176cb9f9245dbb6e4b2c222fcda55",
  ]
  for i, f in filtered {
    inspect(h264_dct8c_md5(f.yuvp()), content=pins[i])
  }
  // Replayable Annex B dump for the external ffmpeg arbitration.
  let mut d = ""
  for i = 0; i < stream.length(); i = i + 1 {
    d = d + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("DCT8CARB:\{d}")
}

///|
/// Busy fixture: gradient + 4x4 checkerboard + a roaming bordered box, the
/// content class that fills many sub-lists and leaves others empty.
fn h264_dct8c_busy_fixture(
  w : Int32,
  h : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<3 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 6 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f * 7) & 0xFF
        if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
          s = (s + 48) & 0xFF
        }
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        let border = col == bx || col == bx + 15 || row == by || row == by + 15
        if inbox && border {
          s = 40
        } else if inbox {
          s = 220
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f) & 0x3F) + 96).to_byte())
        v.push((((row + f * 2) & 0x3F) + 96).to_byte())
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
/// The nC mirror is the fragile part of the CAVLC 8x8 path (per-sub-list
/// counts, the leader sum, zeroed uncoded quadrants, neighbours across
/// macroblocks): any slip desynchronises the VLC tables and the decode
/// either fails or reconstructs garbage. Sweep the QP range on busy content
/// and require the full reconstruction invariant for the I picture and
/// both P pictures, on two geometries (the odd one adds the crop path and
/// right/bottom edge macroblocks).
test "h264 enc: cavlc 8x8dct reconstruction invariant across qp ladder" {
  for geom in [(96, 64), (80, 48)] {
    let (w, h) = geom
    let frames = h264_dct8c_busy_fixture(w, h)
    for qp in [14, 22, 30, 38] {
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let stream = match
        @libavcodec.h264_encode_frames(
          frames,
          width=w,
          height=h,
          qp~,
          dct8x8=true,
          stats~,
          recon~,
        ) {
        Ok(s) => s
        Err(e) => fail("qp \{qp} \{w}x\{h}: \{e}")
      }
      if stats.i8_mbs <= 0 {
        fail("qp \{qp} \{w}x\{h}: 8x8 transform never used")
      }
      let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(f) => f
        Err(e) => fail("qp \{qp} \{w}x\{h}: decode failed: \{e}")
      }
      if dec.length() != 3 {
        fail("qp \{qp} \{w}x\{h}: expected 3 frames, got \{dec.length()}")
      }
      for i, r in recon {
        if h264_dct8c_md5(r) != h264_dct8c_md5(dec[i + 1].yuvp()) {
          fail(
            "qp \{qp} \{w}x\{h} P frame \{i + 1}: encoder reconstruction != decoder reconstruction",
          )
        }
      }
      // I picture: compare against a standalone encode of frame 0 (the
      // GOP entry reuses the same intra encoder).
      let (y0, u0, v0) = frames[0]
      let intra = match
        @libavcodec.h264_encode_intra_frame(
          y0,
          u0,
          v0,
          width=w,
          height=h,
          qp~,
          dct8x8=true,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let f0 = dec[0]
      let rows = (h + 15) / 16 * 16
      if !h264_dct8c_plane_eq(intra.recon_y, f0.y, intra.ystride, rows) {
        fail("qp \{qp} \{w}x\{h}: I picture luma reconstruction mismatch")
      }
      if !h264_dct8c_plane_eq(intra.recon_u, f0.u, intra.cstride, rows / 2) {
        fail("qp \{qp} \{w}x\{h}: I picture u reconstruction mismatch")
      }
      if !h264_dct8c_plane_eq(intra.recon_v, f0.v, intra.cstride, rows / 2) {
        fail("qp \{qp} \{w}x\{h}: I picture v reconstruction mismatch")
      }
    }
  }
}
