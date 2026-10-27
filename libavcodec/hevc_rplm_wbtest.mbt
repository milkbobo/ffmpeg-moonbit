///|
// HEVC reference-list modification (`ref_pic_list_modification`) decoding.
// Streams come from HM 16.8 patched to reverse every active list; references
// are FFmpeg 9.0.2 single-thread framemd5s (see
// scripts/generate_hevc_rplm_vectors.mbtx for the exact commands).

///|
fn hevc_check_rplm(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  bitdepth~ : Int32 = 8,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let mut modified_l0 = 0
  let mut modified_l1 = 0
  for h in headers {
    if h.rpl_modification_flag_l0 {
      modified_l0 = modified_l0 + 1
      // The generator reverses each list, so entry i must be n - 1 - i.
      for i in 0..<h.num_ref_idx_l0_active {
        assert_eq(
          h.list_entry_l0[i],
          h.num_ref_idx_l0_active - 1 - i,
          msg="l0 entry \{i} of POC \{h.poc}",
        )
      }
    }
    if h.rpl_modification_flag_l1 {
      modified_l1 = modified_l1 + 1
      for i in 0..<h.num_ref_idx_l1_active {
        assert_eq(
          h.list_entry_l1[i],
          h.num_ref_idx_l1_active - 1 - i,
          msg="l1 entry \{i} of POC \{h.poc}",
        )
      }
    }
  }
  assert_true(modified_l0 > 0, msg="no L0 modification parsed")
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
test "HEVC RPLM: P low-delay 4:2:0 reordered L0" {
  hevc_check_rplm(rplm_p8_b64, rplm_p8_refs, rplm_p8_unfiltered_refs)
  let data = @libavutil.av_base64_decode(rplm_p8_b64, 1048576).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let widest = headers.fold(init=0, (best, h) => {
    if h.rpl_modification_flag_l0 && h.num_ref_idx_l0_active > best {
      h.num_ref_idx_l0_active
    } else {
      best
    }
  })
  assert_true(widest >= 3, msg="expected at least three active L0 refs")
}

///|
test "HEVC RPLM: hierarchical B 4:2:0 reordered L0 and L1" {
  hevc_check_rplm(rplm_b8_b64, rplm_b8_refs, rplm_b8_unfiltered_refs)
  let data = @libavutil.av_base64_decode(rplm_b8_b64, 1048576).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let both = headers.any(h => {
    h.rpl_modification_flag_l0 && h.rpl_modification_flag_l1
  })
  assert_true(both, msg="expected a B slice modifying both lists")
}

///|
test "HEVC RPLM: hierarchical B 4:4:4 10-bit reordered lists" {
  hevc_check_rplm(
    rplm_b444_10_b64,
    rplm_b444_10_refs,
    rplm_b444_10_unfiltered_refs,
    bitdepth=10,
  )
}

///|
test "HEVC RPLM: hierarchical B 4:2:2 12-bit reordered lists" {
  hevc_check_rplm(
    rplm_b422_12_b64,
    rplm_b422_12_refs,
    rplm_b422_12_unfiltered_refs,
    bitdepth=12,
  )
}

///|
test "HEVC RPLM: out-of-range list entry is rejected" {
  let data = @libavutil.av_base64_decode(rplm_p8_b64, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let mut target : HevcSliceHeader? = None
  for h in headers {
    if target is None &&
      h.rpl_modification_flag_l0 &&
      h.num_ref_idx_l0_active >= 2 {
      let pps = ps.pps_list[h.pps_id].unwrap()
      let sps = ps.sps_list[pps.sps_id].unwrap()
      let cw = if sps.chroma_format_idc == 0 {
        0
      } else {
        sps.width >> sps.hshift[1]
      }
      let ch = if sps.chroma_format_idc == 0 {
        0
      } else {
        sps.height >> sps.vshift[1]
      }
      let dpb = hevc_dpb_new(
        sps.width,
        sps.height,
        cw,
        ch,
        sps.min_pu_width,
        sps.min_pu_height,
      )
      let cur = dpb.set_new_ref(h.poc).unwrap()
      hevc_frame_rps(dpb, h, sps.log2_max_poc_lsb)
      h.list_entry_l0[0] = 99
      match hevc_slice_rpl(dpb, cur, h) {
        Err(_) => target = Some(h)
        Ok(_) => fail("out-of-range list entry was accepted")
      }
    }
  }
  assert_true(target is Some(_), msg="no modifiable L0 slice found")
}
