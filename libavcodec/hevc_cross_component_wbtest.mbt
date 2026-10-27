///|
test "HEVC CCP: upstream spatial residual kernel all scales wraparound" {
  let mut case_idx = 0
  for log2_size in 2..<6 {
    for scale in [0, 1, -1, 2, -2, 4, -4, 8, -8] {
      for seed in 0..<16 {
        let luma = Array::make(1 << (2 * log2_size), 0)
        let chroma = Array::make(luma.length(), 0)
        let mut rng = (seed + 1).reinterpret_as_uint()
        for i in 0..<luma.length() {
          rng = rng ^ (rng << 13)
          rng = rng ^ (rng >> 17)
          rng = rng ^ (rng << 5)
          luma[i] = (((rng & 65535U).reinterpret_as_int() + 32768) & 65535) -
            32768
          rng = rng ^ (rng << 13)
          rng = rng ^ (rng >> 17)
          rng = rng ^ (rng << 5)
          if (seed & 1) == 0 {
            chroma[i] = (((rng & 65535U).reinterpret_as_int() + 32768) & 65535) -
              32768
          }
        }
        hevc_cross_component_residual(chroma, luma, scale)
        let mut hash = 2166136261U
        for value in chroma {
          hash = (hash ^ (value.reinterpret_as_uint() & 65535U)) * 16777619U
        }
        assert_eq(
          hash,
          hevc_ccp_reference[case_idx],
          msg="CCP kernel case=\{case_idx}",
        )
        case_idx += 1
      }
    }
  }
}

///|
fn hevc_check_ccp(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  depth : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let pps = ps.pps_list[headers[0].pps_id].unwrap()
  let sps = ps.sps_list[pps.sps_id].unwrap()
  assert_eq(pps.cross_component_prediction_enabled_flag, 1)
  assert_eq((sps.bit_depth, sps.chroma_format_idc), (depth, 3))
  assert_eq(refs.length(), 5)
  assert_eq(unfiltered.length(), 5)
  for filtered in [false, true] {
    let frames = hevc_sorted_by_poc(
      ff_hevc_decode_frames_ex(data, false, 0, filtered).unwrap(),
    )
    let expected = if filtered { refs } else { unfiltered }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      let hash = if depth == 8 {
        hevc_yuv_md5(frames[i].pic)
      } else {
        hevc_yuv16_md5(frames[i].pic)
      }
      assert_eq(
        hash,
        expected[i],
        msg="CCP depth=\{depth} frame=\{i} filtered=\{filtered} got=\{hash} want=\{expected[i]}",
      )
    }
  }
}

///|
test "HEVC CCP: 8-bit inter correlated chroma" {
  hevc_check_ccp(ccp8_b64, ccp8_refs, ccp8_unfiltered_refs, 8)
}

///|
test "HEVC CCP: 10-bit intra fractional scale" {
  hevc_check_ccp(
    ccp10_intra_b64, ccp10_intra_refs, ccp10_intra_unfiltered_refs, 10,
  )
}

///|
test "HEVC CCP: 12-bit transform skip RDPCM rotation" {
  hevc_check_ccp(
    ccp12_skip_b64, ccp12_skip_refs, ccp12_skip_unfiltered_refs, 12,
  )
}

///|
test "HEVC CCP: 12-bit transquant bypass" {
  hevc_check_ccp(
    ccp12_bypass_b64, ccp12_bypass_refs, ccp12_bypass_unfiltered_refs, 12,
  )
}

///|
test "HEVC CCP: 8-bit constant and correlated chroma" {
  hevc_check_ccp(ccp8_zero_b64, ccp8_zero_refs, ccp8_zero_unfiltered_refs, 8)
}

///|
test "HEVC CCP: 10-bit split intra transforms" {
  hevc_check_ccp(
    ccp10_split_b64, ccp10_split_refs, ccp10_split_unfiltered_refs, 10,
  )
}
