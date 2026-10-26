///|
test "AV1 skip-mode motion uses refmvs stack without consuming symbols" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let poc : FixedArray[Int] = FixedArray::make(7, 0)
  let has : FixedArray[Bool] = FixedArray::make(7, false)
  let history : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let init = @libavcodec.av1_refmvs_init_frame(4, 1, false, poc, has, history)
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  let state = @libavcodec.av1_refmvs_frame_state_new(
    rf, init, refs, 32, 32, 32, 16,
  )
  state.begin_sbrow(0, 0, 16, 0, 8)
  let data : Array[Byte] = []
  for _ in 0..<64 {
    data.push(b'\x55')
  }
  let msac = @libavcodec.Av1Msac::init(Bytes::from_array(data), false)
  let cdf = @libavcodec.av1_cdf_copy_defaults(100)
  let rng = msac.rng
  let cnt = msac.cnt
  let pos = msac.pos
  let params : @libavcodec.Av1InterMotionParams = {
    bs: 17, bx4: 0, by4: 0,
    tile_col_start4: 0, tile_col_end4: 32,
    tile_row_start4: 0, tile_row_end4: 32,
    top_has_right: false, switchable_comp_refs: true,
    skip_mode: true, skip_ref0: 0, skip_ref1: 4,
    seg_present: false, seg_ref: -1, seg_globalmv: false, seg_skip: false,
  }
  let motion = @libavcodec.av1_inter_read_block_motion(
    msac, cdf, state, None, None, params,
  )
  assert_eq((motion.ref0, motion.ref1), (0, 4))
  assert_eq(motion.mode, 0)
  assert_eq(motion.drl_idx, 0)
  assert_true(motion.skip_mode)
  assert_true(!motion.has_subpel_filter)
  assert_eq(msac.rng, rng)
  assert_eq(msac.cnt, cnt)
  assert_eq(msac.pos, pos)
  state.splat_compound(
    motion.ref0, motion.ref1, motion.mode,
    motion.mv0, motion.mv1, params.bs,
    params.bx4, params.by4, 2, 2,
  )
  assert_eq(state.tile.rows[5][0].mv0, motion.mv0)
  assert_eq(state.tile.rows[5][0].mv1, motion.mv1)
}

///|
test "AV1 forced-reference motion selects its declared reference" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let poc : FixedArray[Int] = FixedArray::make(7, 0)
  let has : FixedArray[Bool] = FixedArray::make(7, false)
  let history : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let init = @libavcodec.av1_refmvs_init_frame(4, 1, false, poc, has, history)
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  let state = @libavcodec.av1_refmvs_frame_state_new(
    rf, init, refs, 32, 32, 32, 16,
  )
  state.begin_sbrow(0, 0, 16, 0, 8)
  let data : Array[Byte] = []
  for _ in 0..<64 {
    data.push(b'\xff')
  }
  let msac = @libavcodec.Av1Msac::init(Bytes::from_array(data), false)
  let cdf = @libavcodec.av1_cdf_copy_defaults(100)
  let params : @libavcodec.Av1InterMotionParams = {
    bs: 17, bx4: 0, by4: 0,
    tile_col_start4: 0, tile_col_end4: 32,
    tile_row_start4: 0, tile_row_end4: 32,
    top_has_right: false, switchable_comp_refs: true,
    skip_mode: false, skip_ref0: 0, skip_ref1: 4,
    seg_present: true, seg_ref: 4, seg_globalmv: true, seg_skip: false,
  }
  let motion = @libavcodec.av1_inter_read_block_motion(
    msac, cdf, state, None, None, params,
  )
  assert_eq((motion.ref0, motion.ref1), (3, -1))
  assert_eq(motion.mode, 2)
  assert_eq(motion.mv0, (4, -2))
}
