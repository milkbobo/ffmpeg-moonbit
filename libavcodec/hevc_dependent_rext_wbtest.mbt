///|
// HEVC dependent slice segments with RExt chroma formats (4:4:4/4:2:2).
// Streams come from HM 16.8 (`SliceSegmentMode=1`, one CTB per segment);
// references are FFmpeg 9.0.2 single-thread framemd5s.

///|
fn hevc_check_dependent_rext(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  bitdepth : Int32,
  chroma : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let mut saw_chroma = false
  for sps in ps.sps_list {
    if sps is Some(s) {
      assert_eq(s.chroma_format_idc, chroma)
      assert_eq(s.bit_depth, bitdepth)
      saw_chroma = true
    }
  }
  assert_true(saw_chroma, msg="missing SPS")
  hevc_check_dependent(encoded, refs, unfiltered, bitdepth~)
}

///|
test "HEVC dependent RExt: 4:4:4 8-bit" {
  hevc_check_dependent_rext(
    dep4448_b64, dep4448_refs, dep4448_unfiltered_refs, 8, 3,
  )
}

///|
test "HEVC dependent RExt: 4:2:2 10-bit" {
  hevc_check_dependent_rext(
    dep42210_b64, dep42210_refs, dep42210_unfiltered_refs, 10, 2,
  )
}

///|
test "HEVC dependent RExt: 4:4:4 12-bit" {
  hevc_check_dependent_rext(
    dep44412_b64, dep44412_refs, dep44412_unfiltered_refs, 12, 3,
  )
}
