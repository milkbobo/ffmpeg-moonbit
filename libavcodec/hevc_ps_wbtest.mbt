///|
/// White-box tests for the HEVC parameter set parser.
///
/// Authoritative vectors come from real files produced by
/// `linuxserver/ffmpeg:9.0.2` with libx265:
///
///   ffmpeg -f lavfi -i "testsrc2=size=64x48:rate=5:duration=0.6" \
///          -c:v libx265 -pix_fmt yuv420p \
///          -x265-params "log-level=none:keyint=5:min-keyint=5:bframes=0" \
///          -tag:v hvc1 hevc.mp4
///
/// and the same command with `-pix_fmt yuv420p10le -profile:v main10`.
/// The hvcC payloads below are rebuilt from the real MP4 records with only
/// the VPS/SPS/PPS arrays kept (the x265 version-string SEI is dropped; the
/// header bytes, lengths and NAL bytes are unchanged), which keeps the test
/// vector small without altering any parsed syntax.
///
/// Expected values are FFmpeg's own `trace_headers` output: Main profile
/// (profile_idc 1), level 30, 64x48 4:2:0 8-bit, POC LSB 8, CTB 32x32,
/// VUI SAR 1:1 + timing 1/5; PPS with sign hiding, ref 1/1, init QP 0,
/// CU-QP-delta, weighted prediction. The 10-bit file additionally asserts
/// profile_idc 2 / bit depth 10 / yuv420p10.

///| hvcC with the real 8-bit VPS/SPS/PPS arrays (108 bytes).
let hevc8_hvcc_b64 : Bytes =
  b"AQFgAAAAkAAAAAAAHvAA/P34+AAADwOgAAEAGEABDAH//wFgAAADAJAAAAMAAAMAHpKAkKEAAQAoQgEBAWAAAAMAkAAAAwAAAwAeoCCDFlkq5MrwFoCAAAADAIAAAAMChKIAAQAGRAHBc9CJ"

///| hvcC with the real Main10 VPS/SPS/PPS arrays (109 bytes).
let hevc10_hvcc_b64 : Bytes =
  b"AQIgAAAAkAAAAAAAHvAA/P36+gAADwOgAAEAGEABDAH//wIgAAADAJAAAAMAAAMAHpKAkKEAAQApQgEBAiAAAAMAkAAAAwAAAwAeoCCDE2WSrkyvAWgIAAADAAgAAAMAKECiAAEABkQBwXPQiQ=="

///| Annex B VPS+SPS+PPS from the same x265 stream (82 bytes).
let hevc8_annexb_b64 : Bytes =
  b"AAAAAUABDAH//wFgAAADAJAAAAMAAAMAHpKAkAAAAAFCAQEBYAAAAwCQAAADAAADAB6gIIMWWSrkyvAWgIAAAAMAgAAAAwKEAAAAAUQBwXPQiQ=="

test "hevc_ps: hvcC extradata decodes real Main profile sets" {
  let hvcc = @libavutil.av_base64_decode(hevc8_hvcc_b64, 1024).unwrap()
  assert_eq(hvcc.length(), 108)
  let ps = new_hevc_param_sets()
  let info = ff_hevc_decode_extradata(hvcc, ps, true).unwrap()
  assert_true(info.is_nalff)
  assert_eq(info.nal_length_size, 4)

  let vps = ps.vps_list[0].unwrap()
  assert_eq(vps.vps_id, 0)
  assert_eq(vps.vps_max_layers, 1)
  assert_eq(vps.vps_max_sub_layers, 1)
  assert_eq(vps.vps_temporal_id_nesting_flag, 1)
  assert_eq(vps.ptl.general_ptl.profile_idc, 1) // Main
  assert_eq(vps.ptl.general_ptl.tier_flag, 0)
  assert_eq(vps.ptl.general_ptl.level_idc, 30)
  assert_eq(vps.ptl.general_ptl.profile_compatibility_flag[1], 1)
  assert_eq(vps.ptl.general_ptl.profile_compatibility_flag[2], 1)
  assert_eq(vps.vps_sub_layer_ordering_info_present_flag, 1)
  assert_eq(vps.vps_max_dec_pic_buffering[0], 4)
  assert_eq(vps.vps_num_reorder_pics[0], 0)
  assert_eq(vps.vps_max_latency_increase[0], 0)
  assert_eq(vps.vps_max_layer_id, 0)
  assert_eq(vps.vps_num_layer_sets, 1)
  assert_eq(vps.vps_timing_info_present_flag, 0)

  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.vps_id, 0)
  assert_eq(sps.max_sub_layers, 1)
  assert_eq(sps.temporal_id_nesting, 1)
  assert_eq(sps.ptl.general_ptl.profile_idc, 1)
  assert_eq(sps.ptl.general_ptl.level_idc, 30)
  assert_eq(sps.chroma_format_idc, 1) // 4:2:0
  assert_eq(sps.width, 64)
  assert_eq(sps.height, 48)
  assert_eq(sps.conformance_window, 0)
  assert_eq(sps.bit_depth, 8)
  assert_eq(sps.bit_depth_chroma, 8)
  assert_eq(sps.pix_fmt, "yuv420p")
  assert_eq(sps.log2_max_poc_lsb, 8)
  assert_eq(sps.max_dec_pic_buffering[0], 4)
  assert_eq(sps.num_reorder_pics[0], 0)
  assert_eq(sps.log2_min_cb_size, 3)
  assert_eq(sps.log2_diff_max_min_coding_block_size, 2)
  assert_eq(sps.log2_ctb_size, 5)
  assert_eq(sps.ctb_width, 2)
  assert_eq(sps.ctb_height, 2)
  assert_eq(sps.ctb_size, 4)
  assert_eq(sps.min_cb_width, 8)
  assert_eq(sps.min_cb_height, 6)
  assert_eq(sps.log2_min_tb_size, 2)
  assert_eq(sps.log2_max_trafo_size, 5)
  assert_eq(sps.min_tb_width, 16)
  assert_eq(sps.min_tb_height, 12)
  assert_eq(sps.min_pu_width, 16) // width >> (log2_min_cb_size - 1)
  assert_eq(sps.min_pu_height, 12)
  assert_eq(sps.tb_mask, 7)
  assert_eq(sps.qp_bd_offset, 0)
  assert_eq(sps.scaling_list_enabled, 0)
  assert_eq(sps.amp_enabled, 0)
  assert_eq(sps.sao_enabled, 1)
  assert_eq(sps.pcm_enabled, 0)
  assert_eq(sps.nb_st_rps, 0)
  assert_eq(sps.long_term_ref_pics_present, 0)
  assert_eq(sps.temporal_mvp_enabled, 1)
  assert_eq(sps.strong_intra_smoothing_enabled, 1)
  assert_eq(sps.extension_present, 0)
  assert_eq(sps.hshift[1], 1)
  assert_eq(sps.vshift[1], 1)
  assert_eq(sps.pixel_shift, false)
  // VUI: SAR 1:1, video_format 5, no colour description, timing 1/5.
  assert_eq(sps.vui_present, 1)
  assert_eq(sps.vui.common.aspect_ratio_idc, 1)
  assert_eq(sps.vui.common.sar_num, 1)
  assert_eq(sps.vui.common.sar_den, 1)
  assert_eq(sps.vui.common.video_signal_type_present_flag, 1)
  assert_eq(sps.vui.common.video_format, 5)
  assert_eq(sps.vui.common.video_full_range_flag, 0)
  assert_eq(sps.vui.common.colour_description_present_flag, 0)
  assert_eq(sps.vui.common.chroma_location, 1)
  assert_eq(sps.vui.vui_timing_info_present_flag, 1)
  assert_eq(sps.vui.vui_num_units_in_tick, 1)
  assert_eq(sps.vui.vui_time_scale, 5)
  assert_eq(sps.vui.bitstream_restriction_flag, 0)

  let pps = ps.pps_list[0].unwrap()
  assert_eq(pps.pps_id, 0)
  assert_eq(pps.sps_id, 0)
  assert_eq(pps.sign_data_hiding_flag, 1)
  assert_eq(pps.cabac_init_present_flag, 0)
  assert_eq(pps.num_ref_idx_l0_default_active, 1)
  assert_eq(pps.num_ref_idx_l1_default_active, 1)
  assert_eq(pps.pic_init_qp_minus26, 0)
  assert_eq(pps.constrained_intra_pred_flag, 0)
  assert_eq(pps.transform_skip_enabled_flag, 0)
  assert_eq(pps.cu_qp_delta_enabled_flag, 1)
  assert_eq(pps.diff_cu_qp_delta_depth, 0)
  assert_eq(pps.cb_qp_offset, 0)
  assert_eq(pps.cr_qp_offset, 0)
  assert_eq(pps.weighted_pred_flag, 1)
  assert_eq(pps.weighted_bipred_flag, 0)
  assert_eq(pps.tiles_enabled_flag, 0)
  assert_eq(pps.num_tile_columns, 1)
  assert_eq(pps.num_tile_rows, 1)
  assert_eq(pps.uniform_spacing_flag, 1)
  assert_eq(pps.seq_loop_filter_across_slices_enabled_flag, 1)
  assert_eq(pps.deblocking_filter_control_present_flag, 0)
  assert_eq(pps.log2_parallel_merge_level, 2)
  assert_eq(pps.pps_extension_present_flag, 0)
}

test "hevc_ps: Annex B extradata decodes the same Main profile sets" {
  let blob = @libavutil.av_base64_decode(hevc8_annexb_b64, 1024).unwrap()
  let ps = new_hevc_param_sets()
  let info = ff_hevc_decode_extradata(blob, ps, true).unwrap()
  assert_true(!info.is_nalff)
  assert_eq(info.nal_length_size, 0)
  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.width, 64)
  assert_eq(sps.height, 48)
  assert_eq(sps.ptl.general_ptl.profile_idc, 1)
  assert_eq(sps.vui.vui_time_scale, 5)
  let pps = ps.pps_list[0].unwrap()
  assert_eq(pps.sign_data_hiding_flag, 1)
}

test "hevc_ps: Main10 hvcC parses 10-bit format" {
  let hvcc = @libavutil.av_base64_decode(hevc10_hvcc_b64, 1024).unwrap()
  let ps = new_hevc_param_sets()
  let info = ff_hevc_decode_extradata(hvcc, ps, true).unwrap()
  assert_true(info.is_nalff)
  assert_eq(info.nal_length_size, 4)
  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.ptl.general_ptl.profile_idc, 2) // Main 10
  assert_eq(sps.bit_depth, 10)
  assert_eq(sps.bit_depth_chroma, 10)
  assert_eq(sps.pix_fmt, "yuv420p10le")
  assert_eq(sps.pixel_shift, true)
  assert_eq(sps.qp_bd_offset, 12)
  assert_eq(sps.width, 64)
  assert_eq(sps.height, 48)
  let vps = ps.vps_list[0].unwrap()
  assert_eq(vps.ptl.general_ptl.profile_idc, 2)
}

test "hevc_ps: non-predictive short-term RPS" {
  // 010 (num_negative 1) 010 (num_positive 1) 1 1 (delta -1, used)
  // 1 1 (ue 0 -> delta +1, used) = 0100101111
  let gb = BitReader::with_size(b"\x4B\xC0", 10)
  let st_rps : Array[HevcStRps] = []
  let rps = new_hevc_st_rps()
  ff_hevc_decode_short_term_rps(gb, rps, st_rps, 0, 0, false).unwrap()
  assert_eq(rps.num_negative_pics, 1)
  assert_eq(rps.num_delta_pocs, 2)
  assert_eq(rps.delta_poc[0], -1)
  assert_eq(rps.delta_poc[1], 1)
  assert_eq(rps.used, 3U)
}

test "hevc_ps: compute_poc2 wrap and BLA reset" {
  assert_eq(ff_hevc_compute_poc2(8, 250, 10, 1), 266)
  assert_eq(ff_hevc_compute_poc2(8, 250, 200, 1), 200)
  assert_eq(ff_hevc_compute_poc2(8, 10, 250, 1), -6)
  // BLA_W_LP (16) resets the MSB part to zero.
  assert_eq(ff_hevc_compute_poc2(8, 250, 10, 16), 10)
}
