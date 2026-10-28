///|
/// Black-box tests for HEVC cross-component prediction combined with
/// dependent slice segments and PCM: four HM 16.8 4:4:4 streams decoded both
/// with and without the in-loop filters and compared per frame against
/// FFmpeg 9.0.2 single-thread references. Fixtures and reference MD5s live in
/// `hevc_ccp_combo_vectors_test.mbt`.

///|
fn hevc_ccp_combo_md5(
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
fn hevc_ccp_combo_check(
  b64 : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  depth : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 2000000).unwrap()
  for filtered in [false, true] {
    let frames = match
      @libavcodec.ff_hevc_decode_frames_ex(data, false, 0, filtered) {
      Ok(frames) => frames
      Err(e) => fail("CCP combo decode failed: \{e}")
    }
    let sorted = frames.copy()
    sorted.sort_by((a, b) => a.poc().compare(b.poc()))
    let expected = if filtered { refs } else { unfiltered }
    if sorted.length() != expected.length() {
      fail("CCP combo frame count \{sorted.length()} != \{expected.length()}")
    }
    for i = 0; i < expected.length(); i = i + 1 {
      let got = hevc_ccp_combo_md5(sorted[i], depth)
      if got != expected[i] {
        fail(
          "CCP combo depth=\{depth} frame=\{i} filtered=\{filtered}: \{got} != \{expected[i]}",
        )
      }
    }
  }
}

///|
test "HEVC CCP + dependent slice segments: 8-bit 4:4:4" {
  hevc_ccp_combo_check(ccp_dep8_b64, ccp_dep8_refs, ccp_dep8_unfiltered_refs, 8)
}

///|
test "HEVC CCP + dependent slice segments: 10-bit 4:4:4" {
  hevc_ccp_combo_check(
    ccp_dep10_b64, ccp_dep10_refs, ccp_dep10_unfiltered_refs, 10,
  )
}

///|
test "HEVC CCP + PCM: 8-bit 4:4:4 forced bypass" {
  hevc_ccp_combo_check(ccp_pcm8_b64, ccp_pcm8_refs, ccp_pcm8_unfiltered_refs, 8)
}

///|
test "HEVC CCP + PCM + dependent slice segments: 10-bit 4:4:4 forced bypass" {
  hevc_ccp_combo_check(
    ccp_dep_pcm10_b64, ccp_dep_pcm10_refs, ccp_dep_pcm10_unfiltered_refs, 10,
  )
}
