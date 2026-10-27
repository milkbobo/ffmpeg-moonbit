///|
fn hevc_check_dependent(
  encoded : Bytes,
  refs : Array[String],
  unfiltered : Array[String],
  bitdepth~ : Int32 = 8,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let pps = ps.pps_list[headers[0].pps_id].unwrap()
  assert_eq(ps.sps_list[pps.sps_id].unwrap().bit_depth, bitdepth)
  assert_true(headers.any(h => h.dependent_slice_segment_flag))
  let units = ff_hevc_split_access_units(data, false, 0).unwrap()
  assert_eq(units.length(), refs.length())
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
test "HEVC dependent slices: DSLICE A CABAC and QP inheritance" {
  hevc_check_dependent(dep_a_b64, dep_a_refs, dep_a_unfiltered_refs)
}

///|
test "HEVC dependent slices: DSLICE B WPP continuation" {
  hevc_check_dependent(dep_b_b64, dep_b_refs, dep_b_unfiltered_refs)
}

///|
test "HEVC dependent slices: DSLICE C tile continuation" {
  hevc_check_dependent(dep_c_b64, dep_c_refs, dep_c_unfiltered_refs)
}

///|
test "HEVC dependent slices: 10-bit DSLICE A" {
  hevc_check_dependent(
    dep_a_10_b64,
    dep_a_10_refs,
    dep_a_10_unfiltered_refs,
    bitdepth=10,
  )
}

///|
test "HEVC dependent slices: 12-bit DSLICE A" {
  hevc_check_dependent(
    dep_a_12_b64,
    dep_a_12_refs,
    dep_a_12_unfiltered_refs,
    bitdepth=12,
  )
}

///|
test "HEVC dependent slices: 10-bit DSLICE B WPP" {
  hevc_check_dependent(
    dep_b_10_b64,
    dep_b_10_refs,
    dep_b_10_unfiltered_refs,
    bitdepth=10,
  )
}

///|
test "HEVC dependent slices: 12-bit DSLICE B WPP" {
  hevc_check_dependent(
    dep_b_12_b64,
    dep_b_12_refs,
    dep_b_12_unfiltered_refs,
    bitdepth=12,
  )
}

///|
test "HEVC dependent slices: 10-bit DSLICE C tiles" {
  hevc_check_dependent(
    dep_c_10_b64,
    dep_c_10_refs,
    dep_c_10_unfiltered_refs,
    bitdepth=10,
  )
}

///|
test "HEVC dependent slices: 12-bit DSLICE C tiles" {
  hevc_check_dependent(
    dep_c_12_b64,
    dep_c_12_refs,
    dep_c_12_unfiltered_refs,
    bitdepth=12,
  )
}

///|
test "HEVC dependent slices: headers inherit the current independent slice" {
  let data = @libavutil.av_base64_decode(dep_a_b64, 1048576).unwrap()
  let headers = ff_hevc_parse_slice_headers(data, false, 0).unwrap()
  let mut independent = headers[0]
  let mut count = 0
  for h in headers {
    if !h.dependent_slice_segment_flag {
      independent = h
    } else {
      assert_eq(h.pps_id, independent.pps_id)
      assert_eq(h.slice_type, independent.slice_type)
      assert_eq(h.poc, independent.poc)
      assert_eq(h.slice_qp_delta, independent.slice_qp_delta)
      assert_eq(h.num_ref_idx_l0_active, independent.num_ref_idx_l0_active)
      assert_eq(h.num_ref_idx_l1_active, independent.num_ref_idx_l1_active)
      assert_eq(h.slice_sao_luma_flag, independent.slice_sao_luma_flag)
      assert_eq(
        h.slice_loop_filter_across_slices_enabled_flag,
        independent.slice_loop_filter_across_slices_enabled_flag,
      )
      assert_true(h.slice_segment_address > independent.slice_segment_address)
      count += 1
    }
  }
  assert_true(count > 30)
}

///|
test "HEVC dependent slices: missing independent and missing preceding CTBs fail" {
  let data = @libavutil.av_base64_decode(dep_a_b64, 1048576).unwrap()
  let dec = hevc_decoder_new()
  let _ = ff_hevc_decode_extradata(data, dec.ps, true).unwrap()
  let packet = ff_h2645_packet_split(data, 0, Hevc, false).unwrap()
  let picture : Array[H2645Nal] = []
  for nal in packet.nals {
    if nal.nal_type > 31 {
      continue
    }
    if picture.length() > 0 && hevc_nal_is_first_slice(nal) {
      break
    }
    picture.push(nal)
  }
  assert_true(picture.length() > 3)
  let gb = BitReader::with_size(picture[1].data, picture[1].size_bits)
  gb.skip(16)
  assert_true(
    ff_hevc_decode_slice_header(gb, picture[1].nal_type, dec.ps, 0)
    is Err("hevc: independent slice segment missing"),
  )
  let skipped : Array[H2645Nal] = [picture[0]]
  for i in 2..<picture.length() {
    skipped.push(picture[i])
  }
  assert_eq(
    hevc_decode_picture(dec, skipped, false),
    Err("hevc: previous slice segment missing"),
  )
}

///|
test "HEVC dependent slices: zero address and truncated header fail" {
  let data = @libavutil.av_base64_decode(dep_a_b64, 1048576).unwrap()
  let ps = new_hevc_param_sets()
  let _ = ff_hevc_decode_extradata(data, ps, true).unwrap()
  let packet = ff_h2645_packet_split(data, 0, Hevc, false).unwrap()
  let vcl = packet.nals.filter(n => n.nal_type <= 31)
  let first_gb = BitReader::with_size(vcl[0].data, vcl[0].size_bits)
  first_gb.skip(16)
  let first = ff_hevc_decode_slice_header(first_gb, vcl[0].nal_type, ps, 0).unwrap()
  assert_eq(first.pps_id, 0)
  // IDR: first=0, no_output=0, ue(pps_id=0)=1, dependent=1,
  // followed by nine zero address bits (30x17 CTBs).
  let writer = BitWriter::new()
  writer.put(3U, 4)
  writer.put(0U, 9)
  let impossible = BitReader::new(writer.finish())
  assert_true(
    ff_hevc_decode_slice_header(
      impossible,
      vcl[1].nal_type,
      ps,
      0,
      previous=first,
    )
    is Err("hevc: impossible dependent slice segment"),
  )
  let dep_gb = BitReader::with_size(vcl[1].data, vcl[1].size_bits)
  dep_gb.skip(16)
  let dep = ff_hevc_decode_slice_header(
    dep_gb,
    vcl[1].nal_type,
    ps,
    0,
    previous=first,
  ).unwrap()
  let truncated = BitReader::with_size(vcl[1].data, dep.header_bits - 1)
  truncated.skip(16)
  assert_true(
    ff_hevc_decode_slice_header(
      truncated,
      vcl[1].nal_type,
      ps,
      0,
      previous=first,
    )
    is Err("hevc: truncated slice header"),
  )
}
