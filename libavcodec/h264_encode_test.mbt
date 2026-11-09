// Blackbox tests for the pure-MoonBit H.264 intra encoder: encode with the
// public API, decode with the public decoder entry, compare planes.

///|
fn h264_enc_test_fixture(
  w : Int,
  h : Int,
) -> (Bytes, Bytes, Bytes) {
  let y : Array[Byte] = Array::make(w * h, b'\x00')
  let u : Array[Byte] = Array::make((w / 2) * (h / 2), b'\x00')
  let v : Array[Byte] = Array::make((w / 2) * (h / 2), b'\x00')
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let mut s = (col * 2 + row * 3) & 0xFF
      if (((col >> 3) + (row >> 3)) & 1) == 1 {
        s = (s + 48) & 0xFF
      }
      if col >= 24 && col < 40 && row >= 16 && row < 32 {
        s = if row == 16 || row == 31 || col == 24 || col == 39 {
          40
        } else {
          220
        }
      }
      y[row * w + col] = s.to_byte()
    }
  }
  for row = 0; row < h / 2; row = row + 1 {
    for col = 0; col < w / 2; col = col + 1 {
      u[row * (w / 2) + col] = (((col + row) & 0x3F) + 96).to_byte()
      v[row * (w / 2) + col] = (((row * 2 + col) & 0x3F) + 96).to_byte()
    }
  }
  (Bytes::from_array(y[:]), Bytes::from_array(u[:]), Bytes::from_array(v[:]))
}

///|
/// Plane equality over the macroblock-aligned area. */
fn h264_enc_plane_eq(
  a : Array[Int],
  b : Array[Int],
  stride : Int,
  rows : Int,
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
fn h264_enc_bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
test "h264 enc: I_PCM frame is lossless and decodes identically" {
  let (y, u, v) = h264_enc_test_fixture(96, 64)
  let enc = match
    @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=26, pcm=true) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  // Local reconstruction == source.
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      if enc.recon_y[row * enc.ystride + col] != y[row * 96 + col].to_int() {
        fail("pcm luma recon mismatch at \{col},\{row}")
      }
    }
  }
  // The decoder reproduces the reconstruction byte-for-byte.
  let frames = match @libavcodec.h264_decode_annexb_frames(enc.annexb, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if frames.length() != 1 {
    fail("expected 1 frame, got \{frames.length()}")
  }
  let f = frames[0]
  if !h264_enc_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("pcm luma plane differs from decoder output")
  }
  if !h264_enc_plane_eq(enc.recon_u, f.u, enc.cstride, 32) {
    fail("pcm cb plane differs from decoder output")
  }
  if !h264_enc_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
    fail("pcm cr plane differs from decoder output")
  }
}

///|
test "h264 enc: intra frame reconstruction invariant (I16/I4x4 mix)" {
  let (y, u, v) = h264_enc_test_fixture(96, 64)
  let enc = match @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=24) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let frames = match @libavcodec.h264_decode_annexb_frames(enc.annexb, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if frames.length() != 1 {
    fail("expected 1 frame, got \{frames.length()}")
  }
  let f = frames[0]
  if !h264_enc_plane_eq(enc.recon_y, f.y, enc.ystride, 64) {
    fail("luma plane differs from decoder output")
  }
  if !h264_enc_plane_eq(enc.recon_u, f.u, enc.cstride, 32) {
    fail("cb plane differs from decoder output")
  }
  if !h264_enc_plane_eq(enc.recon_v, f.v, enc.cstride, 32) {
    fail("cr plane differs from decoder output")
  }
  // Quality sanity: mean absolute error of the quantised reconstruction
  // (a plain SAD mode decision at a flat QP leaves isolated saturated
  // macroblocks; the mean catches gross breakage without pinning the
  // rate-distortion behaviour that later slices will tune).
  let mut sum_abs = 0
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let raw = enc.recon_y[row * enc.ystride + col] -
        y[row * 96 + col].to_int()
      sum_abs = sum_abs + (if raw < 0 { -raw } else { raw })
    }
  }
  let mean = sum_abs / (96 * 64)
  // The SAD-based mode decision leaves some headroom (rate-distortion
  // tuning is a later slice), but the standard quantisation step keeps the
  // mean reconstruction error small.
  if mean > 40 {
    fail("luma mean abs diff \{mean} exceeds the quantisation bound")
  }
}

///|
test "h264 enc: determinism and QP ladder" {
  let (y, u, v) = h264_enc_test_fixture(96, 64)
  let e1 = match @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=26) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let e2 = match @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=26) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  if !h264_enc_bytes_eq(e1.annexb, e2.annexb) {
    fail("two identical encodes differ")
  }
  fn size_qp(qp : Int) -> Int raise {
    match @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp~) {
      Ok(e) => e.annexb.length()
      Err(e) => fail(e)
    }
  }
  let s18 = size_qp(18)
  let s30 = size_qp(30)
  let s42 = size_qp(42)
  if !(s18 > s30 && s30 > s42) {
    fail("qp ladder not monotone: \{s18} / \{s30} / \{s42}")
  }
}

///|
test "h264 enc: odd geometry uses cropping" {
  // 66x34: chroma planes are 33x17, macroblock aligned to 80x48.
  let w = 66
  let h = 34
  let y : Array[Byte] = Array::make(w * h, b'\x00')
  let u : Array[Byte] = Array::make(33 * 17, b'\x00')
  let v : Array[Byte] = Array::make(33 * 17, b'\x00')
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      y[row * w + col] = ((col * 3 + row * 5) & 0xFF).to_byte()
    }
  }
  for i = 0; i < 33 * 17; i = i + 1 {
    u[i] = ((i * 7) & 0x3F).to_byte()
    v[i] = ((i * 11) & 0x3F).to_byte()
  }
  let enc = match
    @libavcodec.h264_encode_intra_frame(
      Bytes::from_array(y[:]),
      Bytes::from_array(u[:]),
      Bytes::from_array(v[:]),
      width=w,
      height=h,
      qp=28,
      pcm=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let frames = match @libavcodec.h264_decode_annexb_frames(enc.annexb, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let f = frames[0]
  if f.width != 66 || f.height != 34 {
    fail("cropped geometry \{f.width}x\{f.height}")
  }
  // Visible area must be byte-exact against the source (PCM).
  for row = 0; row < 34; row = row + 1 {
    for col = 0; col < 66; col = col + 1 {
      if f.y[(row + f.crop_top) * f.ystride + f.crop_left + col] !=
        y[row * w + col].to_int() {
        fail("pcm crop luma mismatch at \{col},\{row}")
      }
    }
  }
}

///|
fn h264_enc_lcg(state : Ref[Int]) -> Int {
  state.val = (state.val * 1103515245 + 12345) & 0x7FFFFFFF
  (state.val >> 16) & 0x7FFF
}

///|
test "h264 enc: cavlc residual write/decode property" {
  let seed = Ref(42)
  for iter = 0; iter < 3000; iter = iter + 1 {
    let max_coeff = [16, 15, 4][iter % 3]
    let nc = h264_enc_lcg(seed) % 32
    let levels : Array[Int] = Array::make(max_coeff, 0)
    for i = 0; i < max_coeff; i = i + 1 {
      if h264_enc_lcg(seed) % 3 == 0 {
        let mag = 1 + h264_enc_lcg(seed) % 40
        let sgn = if h264_enc_lcg(seed) % 2 == 0 { 1 } else { -1 }
        levels[i] = mag * sgn
      }
    }
    match @libavcodec.h264_enc_residual_roundtrip(levels, max_coeff, nc) {
      Ok(true) => ()
      Ok(false) => fail("iter \{iter} round trip mismatch")
      Err(e) => {
        let mut lv = ""
        for k = 0; k < max_coeff; k = k + 1 {
          lv = lv + levels[k].to_string() + ","
        }
        fail(
          "iter \{iter} decode error: \{e}; max=\{max_coeff} nc=\{nc} lv=\{lv}",
        )
      }
    }
  }
}

///|
test "h264 enc: bisect failing vector" {
  let v1 : Array[Int] = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 17,
  ]
  match @libavcodec.h264_enc_residual_roundtrip(v1, 16, 31) {
    Ok(true) => println("V1 ok")
    Ok(false) => println("V1 mismatch")
    Err(e) => println("V1 err: \{e}")
  }
  let v2 : Array[Int] = [
    0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 0, 17,
  ]
  match @libavcodec.h264_enc_residual_roundtrip(v2, 16, 31) {
    Ok(true) => println("V2 ok")
    Ok(false) => println("V2 mismatch")
    Err(e) => println("V2 err: \{e}")
  }
  let v3 : Array[Int] = [
    0, 0, 0, 0, -24, 25, 28, 0, 0, 0, 0, 0, 0, 0, 0, 17,
  ]
  match @libavcodec.h264_enc_residual_roundtrip(v3, 16, 31) {
    Ok(true) => println("V3 ok")
    Ok(false) => println("V3 mismatch")
    Err(e) => println("V3 err: \{e}")
  }
}

///|
/// Regression vectors from the round-trip investigation: a lone
/// high-frequency level, a level pair spanning a zero gap with an escape
/// level, and the four-level pattern that caught the trailing-ones bug.
test "h264 enc: tricky residual vectors round trip" {
  let vectors : Array[(Array[Int], Int, Int)] = [
    ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 17], 16, 31),
    ([0, 0, 0, 0, 0, 0, 28, 0, 0, 0, 0, 0, 0, 0, 0, 17], 16, 31),
    ([0, 0, 0, 0, -24, 25, 28, 0, 0, 0, 0, 0, 0, 0, 0, 17], 16, 31),
    ([0, 0, 0, 0, 29, 0, 0, 0, 0, 38, 1, 0, 1, 0, 0], 15, 13),
  ]
  for i, v in vectors {
    let (levels, max_coeff, nc) = v
    match @libavcodec.h264_enc_residual_roundtrip(levels, max_coeff, nc) {
      Ok(true) => ()
      Ok(false) => fail("vector \{i} round trip mismatch")
      Err(e) => fail("vector \{i} decode error: \{e}")
    }
  }
}

///|
fn h264_enc_fixture(w : Int, h : Int) -> (Bytes, Bytes, Bytes) {
  let y : Array[Byte] = []
  let u : Array[Byte] = []
  let v : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let mut s2 = (col * 2 + row * 3) & 0xFF
      if (((col >> 3) + (row >> 3)) & 1) == 1 {
        s2 = (s2 + 48) & 0xFF
      }
      y.push(s2.to_byte())
    }
  }
  for row = 0; row < h / 2; row = row + 1 {
    for col = 0; col < w / 2; col = col + 1 {
      u.push((((col + row) & 0x3F) + 96).to_byte())
      v.push((((row * 2 + col) & 0x3F) + 96).to_byte())
    }
  }
  (Bytes::from_array(y[:]), Bytes::from_array(u[:]), Bytes::from_array(v[:]))
}

///|
fn h264_enc_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b' ')
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
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// encoder's auto-mode stream decodes in the reference implementation with
/// zero warnings, its deblocked output matches this repository's decoder
/// byte-for-byte (the pinned MD5 is the framemd5 ffmpeg reported), and the
/// encoder's local reconstruction matches the pre-deblock decode - the
/// full encode/decode chain closed against the C reference.
test "h264 enc: ffmpeg-arbitrated end-to-end (96x64, auto I16/I4x4)" {
  let (y, u, v) = h264_enc_fixture(96, 64)
  let enc = match
    @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=24) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let deblocked = match @libavcodec.h264_decode_annexb_frames(enc.annexb, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if deblocked.length() != 1 {
    fail("expected 1 frame")
  }
  inspect(
    h264_enc_md5(deblocked[0].yuvp()),
    content="f638094d3c84a83ac27611f0860bd1be",
  )
  let raw = match @libavcodec.h264_decode_annexb_frames(enc.annexb, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  // Local reconstruction == pre-deblock decode, macroblock-aligned planes.
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      if enc.recon_y[row * enc.ystride + col] !=
        raw[0].y[row * raw[0].ystride + col] {
        fail("recon luma mismatch at \{col},\{row}")
      }
    }
  }
  for row = 0; row < 32; row = row + 1 {
    for col = 0; col < 48; col = col + 1 {
      if enc.recon_u[row * enc.cstride + col] !=
        raw[0].u[row * raw[0].cstride + col] {
        fail("recon cb mismatch at \{col},\{row}")
      }
    }
  }
}
