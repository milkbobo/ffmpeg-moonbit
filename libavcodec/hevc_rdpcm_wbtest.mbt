///|
test "HEVC RDPCM: upstream kernel wraparound both directions all sizes" {
  let mut case_idx = 0
  for log2_size in 2..<6 {
    for direction in 0..<2 {
      for seed in 0..<16 {
        let coeffs = Array::make(1 << (2 * log2_size), 0)
        let mut rng = (seed + 1).reinterpret_as_uint()
        for i in 0..<coeffs.length() {
          rng = rng ^ (rng << 13)
          rng = rng ^ (rng >> 17)
          rng = rng ^ (rng << 5)
          coeffs[i] = (((rng & 65535U).reinterpret_as_int() + 32768) & 65535) -
            32768
        }
        hevc_transform_rdpcm(coeffs, log2_size, direction != 0)
        let mut hash = 2166136261U
        for value in coeffs {
          hash = (hash ^ (value.reinterpret_as_uint() & 65535U)) * 16777619U
        }
        assert_eq(
          hash,
          hevc_rdpcm_reference[case_idx],
          msg="RDPCM kernel case=\{case_idx}",
        )
        case_idx += 1
      }
    }
  }
}

///|
fn hevc_check_rdpcm(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  depth : Int32,
  chroma : Int32,
  implicit : Int32,
  explicit : Int32,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let pps = ps.pps_list[headers[0].pps_id].unwrap()
  let sps = ps.sps_list[pps.sps_id].unwrap()
  assert_eq((sps.bit_depth, sps.chroma_format_idc), (depth, chroma))
  assert_eq(
    (sps.implicit_rdpcm_enabled, sps.explicit_rdpcm_enabled),
    (implicit, explicit),
  )
  for filtered in [false, true] {
    let frames = match ff_hevc_decode_frames_ex(data, false, 0, filtered) {
      Ok(frames) => hevc_sorted_by_poc(frames)
      Err(e) => fail("RDPCM \{depth}-bit chroma=\{chroma}: \{e}")
    }
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
        msg="RDPCM \{depth}-bit chroma=\{chroma} frame=\{i} filtered=\{filtered} got=\{hash} want=\{expected[i]}",
      )
    }
  }
}

///|
test "HEVC RDPCM: implicit 8-bit 444 bypass" {
  hevc_check_rdpcm(
    rdpcm_implicit8_b64, rdpcm_implicit8_refs, rdpcm_implicit8_unfiltered_refs, 8,
    3, 1, 0,
  )
}

///|
test "HEVC RDPCM: implicit 10-bit 422 transform skip rotation" {
  hevc_check_rdpcm(
    rdpcm_implicit10_b64, rdpcm_implicit10_refs, rdpcm_implicit10_unfiltered_refs,
    10, 2, 1, 0,
  )
}

///|
test "HEVC RDPCM: explicit 8-bit 420 bypass significance contexts" {
  hevc_check_rdpcm(
    rdpcm_explicit8_b64, rdpcm_explicit8_refs, rdpcm_explicit8_unfiltered_refs, 8,
    1, 0, 1,
  )
}

///|
test "HEVC RDPCM: explicit 12-bit 444 transform skip" {
  hevc_check_rdpcm(
    rdpcm_explicit12_b64, rdpcm_explicit12_refs, rdpcm_explicit12_unfiltered_refs,
    12, 3, 0, 1,
  )
}

///|
test "HEVC RDPCM: combined implicit explicit 12-bit bypass" {
  hevc_check_rdpcm(
    rdpcm_both12_b64, rdpcm_both12_refs, rdpcm_both12_unfiltered_refs, 12, 3, 1,
    1,
  )
}

///|
test "HEVC RDPCM: implicit 10-bit monochrome bypass" {
  hevc_check_rdpcm(
    rdpcm_mono10_b64, rdpcm_mono10_refs, rdpcm_mono10_unfiltered_refs, 10, 0, 1,
    0,
  )
}
