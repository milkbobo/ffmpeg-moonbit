///|
/// Black-box tests for HEVC tiles + WPP (High Throughput Intra 4:4:4). The
/// three HM 16.8 streams are decoded with the in-loop filters and compared
/// per frame against HM decoder output: FFmpeg 9.0.2 cannot decode this
/// combination (its single-thread cabac_init uses the tile-scan index modulo
/// the picture CTB width), so it cannot supply the reference. Fixtures and
/// reference MD5s live in `hevc_tiles_wpp_vectors_test.mbt`.

///|
fn hevc_tiles_wpp_md5(
  frame : @libavcodec.HevcDecodedFrame,
  depth : Int32,
) -> String {
  let yuv = frame.yuvp(depth)
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
fn hevc_tiles_wpp_check(
  b64 : Bytes,
  refs : Array[String],
  depth : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 4000000).unwrap()
  let frames = match
    @libavcodec.ff_hevc_decode_frames_ex(data, false, 0, true) {
    Ok(frames) => frames
    Err(e) => fail("tiles+WPP decode failed: \{e}")
  }
  let sorted = frames.copy()
  sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  if sorted.length() != refs.length() {
    fail("tiles+WPP frame count \{sorted.length()} != \{refs.length()}")
  }
  for i = 0; i < refs.length(); i = i + 1 {
    let got = hevc_tiles_wpp_md5(sorted[i], depth)
    if got != refs[i] {
      fail("tiles+WPP depth=\{depth} frame=\{i}: \{got} != \{refs[i]}")
    }
  }
}

///|
test "HEVC tiles + WPP: 8-bit 4:4:4 2x2 tiles" {
  hevc_tiles_wpp_check(htw8_b64, htw8_refs, 8)
}

///|
test "HEVC tiles + WPP: 10-bit 4:4:4 2x2 tiles" {
  hevc_tiles_wpp_check(htw10_b64, htw10_refs, 10)
}

///|
test "HEVC tiles + WPP: 8-bit wide 3x2 CTUs with non-square tiles" {
  hevc_tiles_wpp_check(htw_wide8_b64, htw_wide8_refs, 8)
}

///|
test "HEVC tiles + WPP + dependent slice segments: 8-bit 64x64" {
  hevc_tiles_wpp_check(htw_dep8_b64, htw_dep8_refs, 8)
}

///|
test "HEVC tiles + WPP + dependent slice segments: 8-bit 128x128" {
  hevc_tiles_wpp_check(htw_dep_wide8_b64, htw_dep_wide8_refs, 8)
}
