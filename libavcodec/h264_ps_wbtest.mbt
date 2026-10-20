///|
/// White-box tests for the H.264 parameter set parser.
///
/// The authoritative vector is the avcC record of a real MP4 produced by
/// `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.6" \
///          -c:v libx264 -profile:v high -level:v 3.0 -pix_fmt yuv420p \
///          -g 5 -bf 0 -movflags +faststart h264.mp4
///
/// Expected SPS/PPS values are FFmpeg's own `trace_headers` output for the
/// stream (profile High, level 30, chroma 4:2:0 8-bit, POC type 2, 3 refs,
/// 4x3 MBs, VUI SAR 1:1 + timing 1/10; PPS CABAC, ref 3/1, QP 23/26, chroma
/// offsets -2/-2, weighted pred, 8x8 transform). The same parameter sets are
/// also parsed through an Annex B extradata blob to cover that entry path.

///| avcC box payload extracted from the MP4 above (44 bytes).
let h264_real_avcc_b64 : Bytes =
  b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

test "h264_ps: avcC extradata decodes real High-profile parameter sets" {
  let avcc = @libavutil.av_base64_decode(h264_real_avcc_b64, 1024).unwrap()
  assert_eq(avcc.length(), 44)
  let ps = new_h264_param_sets()
  let info = ff_h264_decode_extradata(avcc, ps).unwrap()
  assert_true(info.is_avc)
  assert_eq(info.nal_length_size, 4)

  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.sps_id, 0)
  assert_eq(sps.profile_idc, 100) // High
  assert_eq(sps.level_idc, 30)
  assert_eq(sps.chroma_format_idc, 1) // 4:2:0
  assert_eq(sps.bit_depth_luma, 8)
  assert_eq(sps.bit_depth_chroma, 8)
  assert_eq(sps.log2_max_frame_num, 4)
  assert_eq(sps.poc_type, 2)
  assert_eq(sps.ref_frame_count, 3)
  assert_eq(sps.mb_width, 4) // 64 px
  assert_eq(sps.mb_height, 3) // 48 px
  assert_eq(sps.frame_mbs_only_flag, 1)
  assert_eq(sps.crop, 0)
  assert_eq(sps.direct_8x8_inference_flag, 1)
  assert_eq(sps.constraint_set_flags, 0)
  assert_eq(sps.scaling_matrix_present, 0)
  // VUI bitstream_restriction carries the real values (x264 writes them):
  assert_eq(sps.bitstream_restriction_flag, 1)
  assert_eq(sps.num_reorder_frames, 0)
  assert_eq(sps.max_dec_frame_buffering, 3)
  // VUI: aspect_ratio_idc 1 (1:1), no video signal type, timing 1/10.
  assert_eq(sps.vui_parameters_present_flag, 1)
  assert_eq(sps.vui.aspect_ratio_idc, 1)
  assert_eq(sps.vui.sar_num, 1)
  assert_eq(sps.vui.sar_den, 1)
  assert_eq(sps.vui.video_signal_type_present_flag, 0)
  assert_eq(sps.vui.video_full_range_flag, -1)
  assert_eq(sps.vui.matrix_coeffs, 2) // unspecified, set before VUI
  assert_eq(sps.vui.chroma_location, 1) // left
  assert_eq(sps.timing_info_present_flag, 1)
  assert_eq(sps.num_units_in_tick, 1)
  assert_eq(sps.time_scale, 10) // 5 fps: time_scale / (2*num_units)
  assert_eq(sps.fixed_frame_rate_flag, 0)

  let pps = ps.pps_list[0].unwrap()
  assert_eq(pps.pps_id, 0)
  assert_eq(pps.sps_id, 0)
  assert_eq(pps.cabac, 1)
  assert_eq(pps.pic_order_present, 0)
  assert_eq(pps.slice_group_count, 1)
  assert_eq(pps.ref_count_l0, 3)
  assert_eq(pps.ref_count_l1, 1)
  assert_eq(pps.weighted_pred, 1)
  assert_eq(pps.weighted_bipred_idc, 0)
  assert_eq(pps.init_qp, 23) // -3 + 26
  assert_eq(pps.init_qs, 26)
  assert_eq(pps.chroma_qp_index_offset0, -2)
  assert_eq(pps.chroma_qp_index_offset1, -2)
  assert_eq(pps.chroma_qp_diff, 0)
  assert_eq(pps.deblocking_filter_parameters_present, 1)
  assert_eq(pps.constrained_intra_pred, 0)
  assert_eq(pps.redundant_pic_cnt_present, 0)
  assert_eq(pps.transform_8x8_mode, 1)
  assert_eq(pps.pic_scaling_matrix_present_flag, 0)
  assert_eq(pps.scaling_matrix4[0][0], 16) // inherited all-16 SPS matrix
}

test "h264_ps: Annex B extradata decodes the same parameter sets" {
  // Start-code separated SPS/PPS carried in the avcC record above.
  let blob = b"\x00\x00\x00\x01\x67\x64\x00\x1e\xAC\xB2\x08\xF6\x02\x20\x00" +
    b"\x00\x03\x00\x20\x00\x00\x03\x01\x41\xE2\xC5\xC9" +
    b"\x00\x00\x00\x01\x68\xEB\xC3\xCB\x22\xC0"
  let ps = new_h264_param_sets()
  let info = ff_h264_decode_extradata(blob, ps).unwrap()
  assert_true(!info.is_avc)
  assert_eq(info.nal_length_size, 0)
  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.profile_idc, 100)
  assert_eq(sps.mb_width, 4)
  assert_eq(sps.mb_height, 3)
  assert_eq(sps.time_scale, 10)
  let pps = ps.pps_list[0].unwrap()
  assert_eq(pps.transform_8x8_mode, 1)
  assert_eq(pps.chroma_qp_index_offset1, -2)
}

test "h264_ps: direct SPS parse after the NAL header" {
  let nal = b"\x67\x64\x00\x1e\xAC\xB2\x08\xF6\x02\x20\x00\x00\x03\x00\x20\x00" +
    b"\x00\x03\x01\x41\xE2\xC5\xC9"
  let pkt = ff_h2645_packet_split(b"\x00\x00\x00\x01" + nal, 4, H264, false).unwrap()
  assert_eq(pkt.nals.length(), 1)
  let gb = BitReader::with_size(pkt.nals[0].data, pkt.nals[0].size_bits)
  gb.skip(8)
  let ps = new_h264_param_sets()
  ff_h264_decode_seq_parameter_set(gb, ps, false).unwrap()
  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.profile_idc, 100)
  assert_eq(sps.ref_frame_count, 3)
  assert_eq(sps.vui.sar_num, 1)
}

test "h264_ps: truncated SPS is rejected" {
  let gb = BitReader::with_size(b"\x67\x64\x00", 24)
  gb.skip(8)
  let ps = new_h264_param_sets()
  match ff_h264_decode_seq_parameter_set(gb, ps, false) {
    Err(_) => assert_true(true)
    Ok(_) => assert_true(false)
  }
}

test "h264_ps: PPS referring to a missing SPS is rejected" {
  let gb = BitReader::with_size(b"\x68\xEB\xC3\xCB\x22\xC0", 40)
  gb.skip(8)
  let ps = new_h264_param_sets()
  match ff_h264_decode_picture_parameter_set(gb, ps, 40) {
    Err(e) => assert_eq(e, "EINVAL")
    Ok(_) => assert_true(false)
  }
}
