///|
/// Unit tests for the P-slice port: motion compensation (`h264_mc.mbt`),
/// motion vector prediction (`h264_mvpred.mbt`) and the reference-picture
/// bookkeeping exercised through the real-vector decoder test in
/// `h264_decode_wbtest.mbt`.
///
/// The half-pel/quarter-pel/chroma expectations are computed in the test
/// with an independent transcription of the filter formulas (ISO/IEC
/// 14496-10 eq. 8-236/8-237 and the 6-tap filter of 8.4.8.2), not by calling
/// the decoder functions.

///|
/// 4x4 luma half-pel reference: independent 6-tap implementation. */
fn hpel6_ref(p : Array[Int32], stride : Int32, x : Int32, y : Int32) -> Int32 {
  fn px(xx : Int32, yy : Int32) -> Int32 {
    p[yy * stride + xx]
  }
  let v = px(x - 2, y) -
    5 * px(x - 1, y) +
    20 * px(x, y) +
    20 * px(x + 1, y) -
    5 * px(x + 2, y) +
    px(x + 3, y) +
    16
  let t = v >> 5
  if t < 0 {
    0
  } else if t > 255 {
    255
  } else {
    t
  }
}

///|
test "h264 mc: integer-pel luma copy with border replication" {
  // 12x9 plane with a gradient; fetch a 4x4 block at a negative full-pel
  // offset so rows/cols come from the replicated border.
  let w = 12
  let h = 9
  let src : Array[Int32] = Array::make(w * h, 0)
  for y = 0; y < h; y = y + 1 {
    for x = 0; x < w; x = x + 1 {
      src[y * w + x] = (x * 7 + y * 13) % 251
    }
  }
  let dst : Array[Int32] = Array::make(16, 0)
  h264_mc_luma(dst, 0, 4, src, -2, -3, w, 4, 4, 0, 0, w, h)
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      let sx = if x - 2 < 0 { 0 } else if x - 2 >= w { w - 1 } else { x - 2 }
      let sy = if y - 3 < 0 { 0 } else if y - 3 >= h { h - 1 } else { y - 3 }
      assert_eq(dst[y * 4 + x], src[sy * w + sx])
    }
  }
}

///|
test "h264 mc: half-pel horizontal luma filter" {
  let w = 16
  let h = 8
  let src : Array[Int32] = Array::make(w * h, 0)
  for i = 0; i < w * h; i = i + 1 {
    src[i] = (i * 31 + i / 3) % 256
  }
  let dst : Array[Int32] = Array::make(16, 0)
  h264_mc_luma(dst, 0, 4, src, 4, 2, w, 4, 4, 2, 0, w, h)
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      assert_eq(dst[y * 4 + x], hpel6_ref(src, w, 4 + x, 2 + y))
    }
  }
}

///|
test "h264 mc: quarter-pel luma is the average of full and half" {
  let w = 16
  let h = 8
  let src : Array[Int32] = Array::make(w * h, 0)
  for i = 0; i < w * h; i = i + 1 {
    src[i] = (i * 17 + i * i) % 256
  }
  let dst : Array[Int32] = Array::make(16, 0)
  h264_mc_luma(dst, 0, 4, src, 4, 2, w, 4, 4, 1, 0, w, h)
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      let full = src[(2 + y) * w + 4 + x]
      let half = hpel6_ref(src, w, 4 + x, 2 + y)
      assert_eq(dst[y * 4 + x], (full + half + 1) >> 1)
    }
  }
}

///|
test "h264 mc: chroma eighth-pel bilinear" {
  let w = 12
  let h = 8
  let src : Array[Int32] = Array::make(w * h, 0)
  for i = 0; i < w * h; i = i + 1 {
    src[i] = (i * 11 + 5) % 250
  }
  let dst : Array[Int32] = Array::make(16, 0)
  // luma mv (5, 3) quarter-pel → chroma full (0, 0), fractions (5, 3);
  // the block's chroma base is (2, 1) so the taps come from src (2, 1).
  h264_mc_chroma(dst, 0, 4, src, 2, 1, 5, 3, w, 4, 4, w, h)
  let dx = 5
  let dy = 3
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      let a = src[(y + 1) * w + x + 2]
      let b = src[(y + 1) * w + x + 3]
      let c = src[(y + 2) * w + x + 2]
      let d = src[(y + 2) * w + x + 3]
      let v = a * (8 - dx) * (8 - dy) +
        b * dx * (8 - dy) +
        c * (8 - dx) * dy +
        d * dx * dy +
        32
      assert_eq(dst[y * 4 + x], v >> 6)
    }
  }
}

///|
test "h264 mvpred: median of three" {
  assert_eq(h264_mid3(3, 1, 2), 2)
  assert_eq(h264_mid3(5, 9, 7), 7)
  assert_eq(h264_mid3(-4, 0, -1), -1)
  assert_eq(h264_mid3(2, 2, 8), 2)
}

///|
/// A default Baseline PPS for the direct `H264DecCtx` tests. */
fn inter_test_pps() -> H264Pps {
  {
    pps_id: 0,
    sps_id: 0,
    cabac: 0,
    pic_order_present: 0,
    slice_group_count: 1,
    mb_slice_group_map_type: 0,
    ref_count_l0: 1,
    ref_count_l1: 0,
    weighted_pred: 0,
    weighted_bipred_idc: 0,
    init_qp: 26,
    init_qs: 26,
    chroma_qp_index_offset0: 0,
    chroma_qp_index_offset1: 0,
    deblocking_filter_parameters_present: 0,
    constrained_intra_pred: 0,
    redundant_pic_cnt_present: 0,
    transform_8x8_mode: 0,
    transform_bypass: 0,
    profile_idc: 100,
    pic_scaling_matrix_present_flag: 0,
    pic_scaling_matrix_present_mask: 0,
    scaling_matrix4: [],
    scaling_matrix8: [],
    chroma_qp_diff: 0,
    data: b"",
    data_size: 0,
  }
}

///|
test "h264 mvpred: 16x16 median prediction from neighbours" {
  // 2x2 macroblock frame; MB 3 has left MB 2 and top MB 1 as inter with
  // reference 0 and different MVs: the prediction is the componentwise
  // median of A, B and C (the top-right macroblock is unavailable, so C
  // falls back to the top-left macroblock 0, also inter).
  let ystride = 32
  let infos : Array[H264MbInfo] = []
  for i = 0; i < 4; i = i + 1 {
    infos.push({
      nz: Array::make(48, 0),
      modes: Array::make(16, 0),
      intra4x4: false,
      field_mb: false,
      qp: 0,
      mb_type_bits: h264_mb_type_16x16 | h264_mb_type_p0l0,
      cbp_all: 0,
      chroma_mode: 0,
      mv: Array::make(32, 0),
      mv1: Array::make(32, 0),
      ref_idx1: Array::make(16, -1),
      mvd1: Array::make(32, 0),
      ref_identity1: Array::make(16, -1),
      direct: Array::make(16, false),
      ref_idx: Array::make(16, h264_ref_not_avail),
      mvd: Array::make(32, 0),
      transform_8x8: false,
      slice_num: 0,
      deblock_idc: 0,
      alpha_offset: 52,
      beta_offset: 52,
      ref_identity: Array::make(16, -1),
    })
  }
  // MB0 (top-left): mv (8, 4); MB1 (top-right): mv (12, -4);
  // MB2 (bottom-left): mv (16, 8).
  for i = 0; i < 16; i = i + 1 {
    infos[0].mv[2 * i] = 8
    infos[0].mv[2 * i + 1] = 4
    infos[1].mv[2 * i] = 12
    infos[1].mv[2 * i + 1] = -4
    infos[2].mv[2 * i] = 16
    infos[2].mv[2 * i + 1] = 8
    infos[0].ref_idx[i] = 0
    infos[1].ref_idx[i] = 0
    infos[2].ref_idx[i] = 0
  }
  let ctx : H264DecCtx = {
    bit_depth: 8,
    chroma_format: 1,
    chroma_hshift: 1,
    chroma_vshift: 1,
    si_slice: false,
    slice_num: 0,
    active_list: 0,
    ref_list1: [],
    ref_count1: 1,
    direct_spatial: true,
    direct_8x8: true,
    colocated: [],
    reference_buffers: Map([]),
    colocated_mbaff: false,
    colocated_field_picture: false,
    poc: 0,
    poc_top: 0,
    poc_bottom: 0,
    long_pocs: [],
    pps: inter_test_pps(),
    mb_width: 2,
    field_picture: false,
    bottom_field: false,
    mb_height: 2,
    mb_aff: false,
    mb_field: false,
    prev_mb_skipped: false,
    next_mb_skipped: false,
    y: Array::make(ystride * 32, 0),
    u: Array::make(16 * 16, 0),
    v: Array::make(16 * 16, 0),
    ystride,
    cstride: 16,
    infos,
    qscale: 26,
    last_qscale_diff: 0,
    slice_type_nos: 0,
    cur_mb_is_intra: false,
    ref_count0: 1,
    ref_list0: [],
    mb_skip_run: 0,
    pwt: new_h264_pred_weight(),
  }
  // MB3 = (1, 1): A = MB2 block (3, 0) = (16, 8), B = MB1 block (1, 3) =
  // (12, -4), C: top-right of the partition is outside → top-left MB0
  // block (3, 3) = (8, 4). medians: x = median(16, 12, 8) = 12,
  // y = median(8, -4, 4) = 4.
  let (mx, my) = h264_pred_motion(ctx, 3, 1, 1, 0, 0, 4, 0)
  assert_eq(mx, 12)
  assert_eq(my, 4)
}

///|
test "h264 mvpred: P skip zero shortcut" {
  // A left inter neighbour with reference 0 and a zero MV gives a zero
  // prediction (`pred_pskip_motion`'s early out).
  let infos : Array[H264MbInfo] = []
  for _i = 0; _i < 4; _i = _i + 1 {
    infos.push({
      nz: Array::make(48, 0),
      modes: Array::make(16, 0),
      intra4x4: false,
      field_mb: false,
      qp: 0,
      mb_type_bits: h264_mb_type_16x16 | h264_mb_type_p0l0,
      cbp_all: 0,
      chroma_mode: 0,
      mv: Array::make(32, 0),
      mv1: Array::make(32, 0),
      ref_idx1: Array::make(16, -1),
      mvd1: Array::make(32, 0),
      ref_identity1: Array::make(16, -1),
      direct: Array::make(16, false),
      ref_idx: Array::make(16, h264_ref_not_avail),
      mvd: Array::make(32, 0),
      transform_8x8: false,
      slice_num: 0,
      deblock_idc: 0,
      alpha_offset: 52,
      beta_offset: 52,
      ref_identity: Array::make(16, -1),
    })
  }
  for i = 0; i < 16; i = i + 1 {
    infos[2].ref_idx[i] = 0
  }
  let ctx : H264DecCtx = {
    bit_depth: 8,
    chroma_format: 1,
    chroma_hshift: 1,
    chroma_vshift: 1,
    si_slice: false,
    slice_num: 0,
    active_list: 0,
    ref_list1: [],
    ref_count1: 1,
    direct_spatial: true,
    direct_8x8: true,
    colocated: [],
    reference_buffers: Map([]),
    colocated_mbaff: false,
    colocated_field_picture: false,
    poc: 0,
    poc_top: 0,
    poc_bottom: 0,
    long_pocs: [],
    pps: inter_test_pps(),
    mb_width: 2,
    field_picture: false,
    bottom_field: false,
    mb_height: 2,
    mb_aff: false,
    mb_field: false,
    prev_mb_skipped: false,
    next_mb_skipped: false,
    y: Array::make(32 * 32, 0),
    u: Array::make(16 * 16, 0),
    v: Array::make(16 * 16, 0),
    ystride: 32,
    cstride: 16,
    infos,
    qscale: 26,
    last_qscale_diff: 0,
    slice_type_nos: 0,
    cur_mb_is_intra: false,
    ref_count0: 1,
    ref_list0: [
      {
        y: Array::make(32 * 32, 0),
        u: Array::make(16 * 16, 0),
        v: Array::make(16 * 16, 0),
        ystride: 32,
        cstride: 16,
        width: 32,
        height: 32,
        cwidth: 16,
        cheight: 16,
        poc: 0,
        field_poc_top: 0,
        field_poc_bottom: 0,
        identity: 1,
        base_y: 0,
        base_u: 0,
        base_v: 0,
        parity: 0,
      },
    ],
    mb_skip_run: 0,
    pwt: new_h264_pred_weight(),
  }
  let (mx, my) = h264_pred_pskip_motion(ctx, 3, 1, 1)
  assert_eq(mx, 0)
  assert_eq(my, 0)
}
