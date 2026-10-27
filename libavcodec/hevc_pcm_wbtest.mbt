///|
fn hevc_check_pcm(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  bitdepth : Int32,
  chroma : Int32,
  bypass~ : Bool = false,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let pps = ps.pps_list[headers[0].pps_id].unwrap()
  let sps = ps.sps_list[pps.sps_id].unwrap()
  if bypass {
    assert_eq(pps.transquant_bypass_enable_flag, 1)
    assert_eq(refs, unfiltered)
  } else {
    assert_eq(sps.pcm_enabled, 1)
  }
  assert_eq((sps.bit_depth, sps.chroma_format_idc), (bitdepth, chroma))
  for filtered in [false, true] {
    let decoded = match ff_hevc_decode_frames_ex(data, false, 0, filtered) {
      Ok(frames) => frames
      Err(e) => fail("PCM \{bitdepth}-bit chroma=\{chroma}: \{e}")
    }
    let frames = hevc_sorted_by_poc(decoded)
    let expected = if filtered { refs } else { unfiltered }
    assert_eq(frames.length(), expected.length())
    for i in 0..<frames.length() {
      let hash = if bitdepth == 8 {
        hevc_yuv_md5(frames[i].pic)
      } else {
        hevc_yuv16_md5(frames[i].pic)
      }
      assert_eq(
        hash,
        expected[i],
        msg="PCM \{bitdepth}-bit chroma=\{chroma} filtered=\{filtered} got=\{hash} want=\{expected[i]}",
      )
    }
  }
}

///|
test "HEVC PCM: 8-bit 420 conformance A" {
  hevc_check_pcm(pcm_a_b64, pcm_a_refs, pcm_a_unfiltered_refs, 8, 1)
}

///|
test "HEVC PCM: 8-bit 420 conformance B" {
  hevc_check_pcm(pcm_b_b64, pcm_b_refs, pcm_b_unfiltered_refs, 8, 1)
}

///|
test "HEVC PCM: per-side deblock and SAO protection" {
  hevc_check_pcm(pcm_c_b64, pcm_c_refs, pcm_c_unfiltered_refs, 8, 1)
}

///|
test "HEVC PCM: mixed coded and raw blocks" {
  hevc_check_pcm(pcm_d_b64, pcm_d_refs, pcm_d_unfiltered_refs, 8, 1)
}

///|
test "HEVC PCM: independent luma and chroma PCM precision" {
  hevc_check_pcm(pcm_e_b64, pcm_e_refs, pcm_e_unfiltered_refs, 8, 1)
}

///|
test "HEVC PCM: raw sample payload checks available bytes" {
  let cabac = ff_init_cabac_decoder(b"\x00\x00\x10\x20", 0).unwrap()
  let before = (cabac.low, cabac.range, cabac.pos)
  assert_true(cabac.skip_bytes(8) is Err("cabac: truncated raw payload"))
  assert_eq((cabac.low, cabac.range, cabac.pos), before)
}

///|
test "HEVC PCM: 10-bit 422 conformance" {
  hevc_check_pcm(
    pcm_42210_b64, pcm_42210_refs, pcm_42210_unfiltered_refs, 10, 2,
  )
}

///|
test "HEVC PCM: 12-bit 444 conformance" {
  hevc_check_pcm(
    pcm_44412_b64, pcm_44412_refs, pcm_44412_unfiltered_refs, 12, 3,
  )
}

///|
test "HEVC lossless: 8-bit 420 I P B transquant bypass" {
  hevc_check_pcm(
    lossless8_b64,
    lossless8_refs,
    lossless8_unfiltered_refs,
    8,
    1,
    bypass=true,
  )
}

///|
test "HEVC lossless: 10-bit 422 I P B transquant bypass" {
  hevc_check_pcm(
    lossless10_b64,
    lossless10_refs,
    lossless10_unfiltered_refs,
    10,
    2,
    bypass=true,
  )
}

///|
test "HEVC lossless: 12-bit 444 I P B transquant bypass" {
  hevc_check_pcm(
    lossless12_b64,
    lossless12_refs,
    lossless12_unfiltered_refs,
    12,
    3,
    bypass=true,
  )
}

///|
test "HEVC lossless: monochrome I P B transquant bypass" {
  hevc_check_pcm(
    lossless_mono_b64,
    lossless_mono_refs,
    lossless_mono_unfiltered_refs,
    8,
    0,
    bypass=true,
  )
}
