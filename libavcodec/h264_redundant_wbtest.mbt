///|
/// A one-MB I_PCM picture with a PPS that signals redundant_pic_cnt.
fn h264_redundant_test_nals() -> (
  Array[Byte],
  Array[Byte],
  Array[Byte],
  Array[Byte],
) {
  let sps = BitWriter::new()
  psyn_put_u(sps, 8, 66)
  psyn_put_u(sps, 8, 0)
  psyn_put_u(sps, 8, 30)
  psyn_put_ue(sps, 0)
  psyn_put_ue(sps, 0) // frame_num width = 4
  psyn_put_ue(sps, 0) // POC type 0
  psyn_put_ue(sps, 0) // POC LSB width = 4
  psyn_put_ue(sps, 1) // one reference
  sps.put_bit(0) // frame_num gaps
  psyn_put_ue(sps, 0) // one MB wide
  psyn_put_ue(sps, 0) // one MB high
  sps.put_bit(1) // frame_mbs_only
  sps.put_bit(1) // direct_8x8_inference
  sps.put_bit(0) // crop
  sps.put_bit(0) // VUI
  let sps_rbsp = psyn_align(sps)

  let pps = BitWriter::new()
  psyn_put_ue(pps, 0) // pps_id
  psyn_put_ue(pps, 0) // sps_id
  pps.put_bit(0) // CAVLC
  pps.put_bit(0) // pic_order_present
  psyn_put_ue(pps, 0) // one slice group
  psyn_put_ue(pps, 0) // L0 count minus one
  psyn_put_ue(pps, 0) // L1 count minus one
  pps.put_bit(0) // weighted prediction
  psyn_put_u(pps, 2, 0) // weighted bipred
  psyn_put_se(pps, 0) // init QP
  psyn_put_se(pps, 0) // init QS
  psyn_put_se(pps, 0) // chroma offset
  pps.put_bit(1) // deblocking fields present
  pps.put_bit(0) // constrained intra
  pps.put_bit(1) // redundant_pic_cnt_present_flag
  let pps_rbsp = psyn_align(pps)

  let primary = BitWriter::new()
  psyn_put_ue(primary, 0) // first MB
  psyn_put_ue(primary, 7) // all-I slice
  psyn_put_ue(primary, 0) // PPS
  psyn_put_u(primary, 4, 0) // frame_num
  psyn_put_ue(primary, 0) // idr_pic_id
  psyn_put_u(primary, 4, 0) // POC LSB
  psyn_put_ue(primary, 0) // primary slice
  primary.put_bit(0) // no_output_of_prior_pics
  primary.put_bit(0) // long_term_reference
  psyn_put_se(primary, 0) // QP delta
  psyn_put_ue(primary, 1) // deblocking disabled
  psyn_put_ue(primary, 25) // I_PCM
  while primary.nbits != 0 {
    primary.put_bit(0)
  }
  for _ in 0..<384 {
    psyn_put_u(primary, 8, 128)
  }
  let primary_rbsp = psyn_align(primary)

  let redundant = BitWriter::new()
  psyn_put_ue(redundant, 0)
  psyn_put_ue(redundant, 7)
  psyn_put_ue(redundant, 0)
  psyn_put_u(redundant, 4, 0)
  psyn_put_ue(redundant, 0)
  psyn_put_u(redundant, 4, 0)
  psyn_put_ue(redundant, 1) // redundant slice, no MB payload required
  redundant.put_bit(0)
  redundant.put_bit(0)
  psyn_put_se(redundant, 0)
  psyn_put_ue(redundant, 1)
  let redundant_rbsp = psyn_align(redundant)
  (sps_rbsp, pps_rbsp, primary_rbsp, redundant_rbsp)
}

///|
test "h264: redundant picture does not replace its primary picture" {
  let (sps, pps, primary, redundant) = h264_redundant_test_nals()
  let data = psyn_stream([
    (7, 3, sps),
    (8, 3, pps),
    (5, 3, primary),
    (5, 3, redundant),
  ])
  let frames = h264_decode_annexb_frames(data, false).unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(frames[0].yuvp().length(), 384)
  assert_eq(frames[0].y[0], 128)
  let before = psyn_stream([
    (7, 3, sps),
    (8, 3, pps),
    (5, 3, redundant),
    (5, 3, primary),
  ])
  let reordered = h264_decode_annexb_frames(before, false).unwrap()
  assert_eq(reordered.length(), 1)
  assert_eq(reordered[0].yuvp(), frames[0].yuvp())
}

///|
test "h264: SI is explicitly rejected before pixel reconstruction" {
  let (sps, pps, _, _) = h264_redundant_test_nals()
  let si = BitWriter::new()
  psyn_put_ue(si, 0) // first MB
  psyn_put_ue(si, 9) // all-SI slice
  psyn_put_ue(si, 0) // PPS
  psyn_put_u(si, 4, 0) // frame_num
  psyn_put_u(si, 4, 0) // POC LSB
  psyn_put_ue(si, 0) // primary slice
  psyn_put_se(si, 0) // QP delta
  psyn_put_se(si, 0) // QS delta
  psyn_put_ue(si, 1) // deblocking disabled
  let data = psyn_stream([(7, 3, sps), (8, 3, pps), (1, 0, psyn_align(si))])
  match h264_decode_annexb_frames(data, false) {
    Err(error) => assert_eq(error, "SP/SI reconstruction is not supported")
    Ok(_) => abort("SI slice was accepted")
  }
}

///|
test "h264: data partition NAL is explicitly unsupported" {
  let data = psyn_stream([(2, 3, [b'\x80'])])
  match h264_decode_annexb_frames(data, false) {
    Err(error) => assert_eq(error, "H.264 data partitioning is not supported")
    Ok(_) => abort("data partition NAL was silently ignored")
  }
}
