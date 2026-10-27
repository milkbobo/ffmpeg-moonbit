///|
// HEVC persistent Rice parameter adaptation
// (`persistent_rice_adaptation_enabled_flag`). Streams come from HM 16.8 with
// the tool enabled (see scripts/generate_hevc_persistent_rice_vectors.mbtx);
// references are FFmpeg 9.0.2 single-thread framemd5s.

///|
fn hevc_check_persistent_rice(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  bitdepth~ : Int32 = 8,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let mut saw_persistent = false
  for sps in ps.sps_list {
    if sps is Some(s) && s.persistent_rice_adaptation_enabled != 0 {
      saw_persistent = true
    }
  }
  assert_true(saw_persistent, msg="SPS does not enable persistent rice")
  for filtered in [false, true] {
    let frames = ff_hevc_decode_frames_ex(data, false, 0, filtered).unwrap()
    let sorted = hevc_sorted_by_poc(frames)
    let expected = if filtered { refs } else { unfiltered }
    assert_eq(sorted.length(), expected.length())
    for i in 0..<sorted.length() {
      let hash = if bitdepth == 8 {
        hevc_yuv_md5(sorted[i].pic)
      } else {
        hevc_yuv16_md5(sorted[i].pic)
      }
      assert_eq(
        hash,
        expected[i],
        msg="filtered=\{filtered} frame=\{i} POC=\{sorted[i].poc} got=\{hash} want=\{expected[i]}",
      )
    }
  }
}

///|
test "HEVC persistent rice: 4:4:4 10-bit hierarchical B" {
  hevc_check_persistent_rice(
    rice_b444_10_b64,
    rice_b444_10_refs,
    rice_b444_10_unfiltered_refs,
    bitdepth=10,
  )
}

///|
test "HEVC persistent rice: 4:2:2 12-bit WPP state save and load" {
  let data = @libavutil.av_base64_decode(rice_b422_12_wpp_b64, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let mut wpp = false
  for pps in ps.pps_list {
    if pps is Some(p) && p.entropy_coding_sync_enabled_flag != 0 {
      wpp = true
    }
  }
  assert_true(wpp, msg="stream does not enable WPP")
  hevc_check_persistent_rice(
    rice_b422_12_wpp_b64,
    rice_b422_12_wpp_refs,
    rice_b422_12_wpp_unfiltered_refs,
    bitdepth=12,
  )
}

///|
test "HEVC persistent rice: 4:2:0 8-bit" {
  hevc_check_persistent_rice(
    rice_p420_8_b64, rice_p420_8_refs, rice_p420_8_unfiltered_refs,
  )
}

///|
test "HEVC persistent rice: stat_coeff grows, shrinks and holds" {
  let cabac = hevc_cabac_new(b"\x00\x00\x00\x00", 0, Array::make(1, 0)).unwrap()
  // init = 0: a remaining of 3 or more grows the state.
  hevc_persistent_rice_update(cabac, 0, 3)
  assert_eq(cabac.stat_coeff[0], 1)
  // remaining small for init = 0 (2 * 0 < 1 << 0) shrinks it again.
  hevc_persistent_rice_update(cabac, 0, 0)
  assert_eq(cabac.stat_coeff[0], 0)
  // 1 < 3 and 2 * 1 is not below 1: unchanged.
  hevc_persistent_rice_update(cabac, 0, 1)
  assert_eq(cabac.stat_coeff[0], 0)
  // Stat is per sb_type.
  hevc_persistent_rice_update(cabac, 3, 3)
  assert_eq(cabac.stat_coeff[3], 1)
  assert_eq(cabac.stat_coeff[0], 0)
}
