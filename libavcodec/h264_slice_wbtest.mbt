///|
/// White-box test for the I-slice header parser against FFmpeg's
/// `trace_headers` output for the real baseline stream in
/// `h264_slice_realdata.mbt`.
///
/// Trace: first_mb_in_slice=0, slice_type=7 (I), pps_id=0, frame_num=0,
/// idr_pic_id=0, slice_qp_delta=3, disable_deblocking_filter_idc=0,
/// alpha/beta offsets 0. PPS pic_init_qp_minus26=-3 → init_qp 23, so the
/// slice QP is 26.

///| Parse one Annex B NAL (start code included) into its RBSP reader. */
fn h264_slice_reader(nal_bytes : Bytes) -> Result[(BitReader, Int, Int), String] {
  let pkt = match ff_h2645_packet_split(nal_bytes, 4, H264, false) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if pkt.nals.length() != 1 {
    return Err("EINVAL")
  }
  let nal = pkt.nals[0]
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  Ok((gb, nal.nal_type, nal.ref_idc))
}

test "h264: real baseline I-slice header matches FFmpeg trace" {
  let sps_bytes = @libavutil.av_base64_decode(h264_slice_sps_b64, 256).unwrap()
  let pps_bytes = @libavutil.av_base64_decode(h264_slice_pps_b64, 256).unwrap()
  let idr_bytes = @libavutil.av_base64_decode(h264_slice_idr_b64, 4096).unwrap()
  let ps = new_h264_param_sets()

  let (sps_gb, sps_type, _) = h264_slice_reader(sps_bytes).unwrap()
  assert_eq(sps_type, h264_nal_sps)
  sps_gb.skip(8)
  ff_h264_decode_seq_parameter_set(sps_gb, ps, false).unwrap()
  let sps = ps.sps_list[0].unwrap()
  assert_eq(sps.profile_idc, 66) // Baseline
  assert_eq(sps.level_idc, 30)
  assert_eq(sps.mb_width, 4)
  assert_eq(sps.mb_height, 3)
  assert_eq(sps.log2_max_frame_num, 4)
  assert_eq(sps.poc_type, 2)

  let (pps_gb, pps_type, _) = h264_slice_reader(pps_bytes).unwrap()
  assert_eq(pps_type, h264_nal_pps)
  pps_gb.skip(8)
  ff_h264_decode_picture_parameter_set(pps_gb, ps, pps_gb.size_bits()).unwrap()
  let pps = ps.pps_list[0].unwrap()
  assert_eq(pps.init_qp, 23)
  assert_eq(pps.deblocking_filter_parameters_present, 1)

  let (idr_gb, idr_type, idr_ref) = h264_slice_reader(idr_bytes).unwrap()
  assert_eq(idr_type, h264_nal_idr_slice)
  assert_eq(idr_ref, 3)
  idr_gb.skip(8)
  let sh = ff_h264_decode_slice_header(idr_gb, idr_type, idr_ref, ps).unwrap()
  assert_eq(sh.first_mb_in_slice, 0)
  assert_eq(sh.slice_type, 7)
  assert_eq(sh.slice_type_nos, 2)
  assert_eq(sh.pps_id, 0)
  assert_eq(sh.sps_id, 0)
  assert_eq(sh.frame_num, 0)
  assert_eq(sh.idr_pic_id, 0)
  assert_eq(sh.field_pic_flag, 0)
  assert_eq(sh.pic_order_cnt_lsb, -1) // POC type 2
  assert_eq(sh.slice_qp_delta, 3)
  assert_eq(sh.qscale, 26)
  assert_eq(sh.disable_deblocking_filter_idc, 0)
  assert_eq(sh.slice_alpha_c0_offset, 0)
  assert_eq(sh.slice_beta_offset, 0)
}
