///|
test "refmvs sbrow ring retains the previous row and splat writes each cell" {
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 32, 32, 16)
  state.init_sbrow(0)
  let block : @libavcodec.Av1Rb = {
    ref0: 1, ref1: -1, bs: 17, mf: 2, mv0: (12, -24), mv1: (0, 0),
  }
  state.splat_mv(block, 4, 14, 2, 2)
  assert_eq(state.rows[19][4].mv0, (12, -24))
  inspect(state.rows[20][5].ref0, content="1")
  state.init_sbrow(1)
  assert_eq(state.rows[19][4].mv0, (12, -24))
  inspect(state.rows[20][5].ref0, content="1")
  let next : @libavcodec.Av1Rb = {
    ref0: 4, ref1: -1, bs: 17, mf: 0, mv0: (50, 60), mv1: (0, 0),
  }
  state.splat_mv(next, 4, 16, 2, 2)
  assert_eq(state.rows[21][4].mv0, (50, 60))
  inspect(state.rows[22][5].ref0, content="4")
}

///|
test "refmvs save picks signed second reference and rejects large motion" {
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 32, 32, 16)
  state.init_sbrow(0)
  let first : @libavcodec.Av1Rb = {
    ref0: 1, ref1: 2, bs: 17, mf: 0,
    mv0: (10, 20), mv1: (-30, 40),
  }
  let second : @libavcodec.Av1Rb = {
    ref0: 1, ref1: 2, bs: 17, mf: 0,
    mv0: (11, 22), mv1: (4096, 0),
  }
  state.splat_mv(first, 0, 0, 2, 2)
  state.splat_mv(second, 2, 0, 2, 2)
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    32 * 32, _ => { mv: (0, 0), ref_: 0 },
  )
  state.save_tmvs(rp, [1, 1, 0, 0, 0, 0, 0], 0, 2, 0, 1)
  assert_eq(rp[0].mv, (-30, 40))
  inspect(rp[0].ref_, content="2")
  assert_eq(rp[1].mv, (11, 22))
  inspect(rp[1].ref_, content="1")
}

///|
test "refmvs temporal projection keeps valid source vectors" {
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 32, 32, 16)
  let ref_poc : FixedArray[Int] = [1, 0, 0, 2, 0, 0, 0]
  let ref_has : FixedArray[Bool] = [true, false, false, false, false, false, false]
  let ref_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let init = @libavcodec.av1_refmvs_init_frame(
    3, 2, true, ref_poc, ref_has, ref_ref_poc,
  )
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  refs[0][3 * 32 + 4] = { mv: (0, 0), ref_: 1 }
  state.load_tmvs(init, refs, 0, 16, 0, 8)
  assert_eq(state.rp_proj[3 * 32 + 4].mv, (0, 0))
  inspect(state.rp_proj[3 * 32 + 4].ref_, content="1")
  assert_eq(state.rp_proj[3 * 32 + 5].mv, (32768, 32768))
}

///|
test "refmvs frame state loads prior motion and saves current motion" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let ref_poc : FixedArray[Int] = [1, 0, 0, 2, 0, 0, 0]
  let ref_has : FixedArray[Bool] = [true, false, false, false, false, false, false]
  let ref_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let init = @libavcodec.av1_refmvs_init_frame(
    3, 2, true, ref_poc, ref_has, ref_ref_poc,
  )
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  refs[0][3 * 32 + 4] = { mv: (0, 0), ref_: 1 }
  let state = @libavcodec.av1_refmvs_frame_state_new(
    rf, init, refs, 32, 32, 32, 16,
  )
  state.begin_sbrow(0, 0, 16, 0, 8)
  inspect(state.tile.rp_proj[3 * 32 + 4].ref_, content="1")
  let block : @libavcodec.Av1Rb = {
    ref0: 1, ref1: -1, bs: 17, mf: 0,
    mv0: (24, -40), mv1: (0, 0),
  }
  state.splat(block, 0, 0, 2, 2)
  let stack = state.find(0, 32, 0, 32, 1, -1, 17, true, 0, 2)
  assert_true(stack.candidate(0).0 != (32768, 32768))
  state.finish_sbrow(0, 16, 0, 8)
  assert_eq(state.rp[0].mv, (24, -40))
  inspect(state.rp[0].ref_, content="1")
}
