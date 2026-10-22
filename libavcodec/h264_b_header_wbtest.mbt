///|
/// Header expectations transcribed from original FFmpeg 9.0.2 trace_headers.
/// Real source: testsrc2 96x64@5, 7 frames, x264 high qp22, bframes2,
/// b-adapt0:cabac1:8x8dct1:weightp0:weightb1:ref3:keyint999:scenecut0.
/// Explicit B source: generate_h264_marking_vectors.mbtx --weighted-b;
/// original FFmpeg verifies it with -err_detect explode and trace_headers.
fn h264_b_headers(data : Bytes) -> Array[(H264SliceHeader, Int32)] {
  let ps = new_h264_param_sets()
  let headers : Array[(H264SliceHeader, Int32)] = []
  for nal in ff_h2645_packet_split(data, 4, H264, false).unwrap().nals {
    let gb = BitReader::with_size(nal.data, nal.size_bits); gb.skip(8)
    if nal.nal_type == 7 { ff_h264_decode_seq_parameter_set(gb, ps, false).unwrap() }
    else if nal.nal_type == 8 { ff_h264_decode_picture_parameter_set(gb, ps, gb.size_bits()).unwrap() }
    else if nal.nal_type == 1 || nal.nal_type == 5 {
      let header = ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, ps).unwrap()
      headers.push((header, gb.count()))
    }
  }
  headers
}

///|
test "h264: real B header lists, direct flag and bit positions match FFmpeg trace" {
  let headers = h264_b_headers(@libavutil.av_base64_decode(h264_b_header_b64, 100000).unwrap())
  let expected = [
    [7, 0, 0, -3, 38], [5, 1, 6, 0, 34], [6, 2, 2, 1, 39],
    [6, 3, 4, 2, 42], [5, 3, 12, 0, 50], [6, 4, 8, 1, 52], [6, 5, 10, 2, 42],
  ]
  assert_eq(headers.length(), 7)
  for i, (h, bits) in headers {
    assert_eq([h.slice_type, h.frame_num, h.pic_order_cnt_lsb, h.slice_qp_delta, bits], expected[i])
    assert_eq(h.cabac_init_flag, 0)
    assert_eq(h.disable_deblocking_filter_idc, 0)
    if h.slice_type_nos == 1 {
      assert_true(h.direct_spatial_mv_pred)
      assert_eq(h.num_ref_idx_l0_active, if i == 2 { 1 } else if i == 5 { 3 } else { 2 })
      assert_eq(h.num_ref_idx_l1_active, 1)
      assert_eq(h.ref_mod_l1_ops, [])
    }
  }
  assert_eq(headers[4].0.ref_mod_l0_ops, [0, 1, 0])
  assert_eq(headers[4].0.ref_mod_l0_vals, [1, 0, 1])
}

///|
test "h264: explicit B weights for both lists match FFmpeg trace" {
  let data = @libavutil.av_base64_decode(h264_b_weighted_b64, 10000).unwrap()
  let headers = h264_b_headers(data)
  assert_eq(headers.length(), 3)
  let (header, bits) = headers[2]
  assert_eq(bits, 87)
  assert_eq(header.slice_type_nos, 1)
  assert_eq(header.num_ref_idx_l0_active, 1)
  assert_eq(header.num_ref_idx_l1_active, 1)
  let weights = header.pwt
  assert_eq([weights.luma_log2_weight_denom, weights.chroma_log2_weight_denom], [1, 1])
  assert_eq([weights.luma_weight_l0[0], weights.luma_offset_l0[0]], [3, 2])
  assert_eq([weights.luma_weight_l1[0], weights.luma_offset_l1[0]], [1, -2])
  assert_eq(weights.chroma_weight_l0[0], [2, 1])
  assert_eq(weights.chroma_offset_l0[0], [1, -1])
  assert_eq(weights.chroma_weight_l1[0], [2, 3])
  assert_eq(weights.chroma_offset_l1[0], [0, 2])
  assert_eq(h264_decode_annexb_frames(data, false).unwrap().length(), 3)
}
