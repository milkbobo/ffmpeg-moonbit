///|
/// Black-box tests for HEVC dependent slice segments with the remaining RExt
/// combinations (4:4:4 10-bit and 4:2:2 8/12-bit). Each stream decodes both
/// with and without the in-loop filters and is compared per frame against
/// FFmpeg 9.0.2 single-thread framemd5s. Fixtures live in
/// `hevc_dependent_rext_vectors_test.mbt`; the 4:4:4 8/12-bit and 4:2:2
/// 10-bit combinations stay in the white-box harness.

///|
fn hevc_dependent_rext_md5(
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
fn hevc_dependent_rext_check(
  b64 : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  depth : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 1000000).unwrap()
  for filtered in [false, true] {
    let frames = match
      @libavcodec.ff_hevc_decode_frames_ex(data, false, 0, filtered) {
      Ok(frames) => frames
      Err(e) => fail("dependent RExt decode failed: \{e}")
    }
    let sorted = frames.copy()
    sorted.sort_by((a, b) => a.poc().compare(b.poc()))
    let expected = if filtered { refs } else { unfiltered }
    if sorted.length() != expected.length() {
      fail(
        "dependent RExt frame count \{sorted.length()} != \{expected.length()}",
      )
    }
    for i = 0; i < expected.length(); i = i + 1 {
      let got = hevc_dependent_rext_md5(sorted[i], depth)
      if got != expected[i] {
        fail(
          "dependent RExt depth=\{depth} frame=\{i} filtered=\{filtered}: \{got} != \{expected[i]}",
        )
      }
    }
  }
}

///|
test "HEVC dependent RExt: 4:4:4 10-bit" {
  hevc_dependent_rext_check(
    dep44410_b64, dep44410_refs, dep44410_unfiltered_refs, 10,
  )
}

///|
test "HEVC dependent RExt: 4:2:2 8-bit" {
  hevc_dependent_rext_check(
    dep4228_b64, dep4228_refs, dep4228_unfiltered_refs, 8,
  )
}

///|
test "HEVC dependent RExt: 4:2:2 12-bit" {
  hevc_dependent_rext_check(
    dep42212_b64, dep42212_refs, dep42212_unfiltered_refs, 12,
  )
}
