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

///|
test "refmvs temporal projection scales both axes and feeds find" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let ref_poc : FixedArray[Int] = [3, 0, 0, 4, 0, 0, 0]
  let ref_has : FixedArray[Bool] = [true, false, false, false, false, false, false]
  let ref_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  ref_ref_poc[0][0] = 2
  let init = @libavcodec.av1_refmvs_init_frame(
    4, 5, true, ref_poc, ref_has, ref_ref_poc,
  )
  inspect(init.mfmv_ref2cur[0], content="2")
  inspect(init.mfmv_ref2ref[0][0], content="1")
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  // Last's motion points toward its own past; last-to-current projection
  // moves this sample from (6, 3) to (2, 9) in the current frame.
  refs[0][6 * 32 + 3] = { mv: (128, -192), ref_: 1 }
  let state = @libavcodec.av1_refmvs_frame_state_new(
    rf, init, refs, 32, 32, 32, 16,
  )
  state.begin_sbrow(0, 0, 16, 0, 8)
  assert_eq(state.tile.rp_proj[2 * 32 + 9].mv, (128, -192))
  inspect(state.tile.rp_proj[2 * 32 + 9].ref_, content="1")
  let result = state.find(0, 32, 0, 32, 1, -1, 17, false, 4, 18)
  assert_eq(result.candidate(0).0, (256, -384))
}

///|
test "refmvs forward reference projection and superblock boundaries" {
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 32, 32, 32)
  let ref_poc : FixedArray[Int] = [0, 0, 0, 0, 7, 0, 0]
  let ref_has : FixedArray[Bool] = [false, false, false, false, true, false, false]
  let ref_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  ref_ref_poc[4][0] = 6
  let init = @libavcodec.av1_refmvs_init_frame(
    4, 5, true, ref_poc, ref_has, ref_ref_poc,
  )
  inspect(init.mfmv_ref[0], content="4")
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  // A forward reference reverses the sign relative to LAST: (2, 9)
  // projects to (6, 3) with a distance ratio of 2:1.
  refs[4][2 * 32 + 9] = { mv: (128, -192), ref_: 1 }
  state.load_tmvs(init, refs, 0, 16, 0, 8)
  assert_eq(state.rp_proj[6 * 32 + 3].mv, (128, -192))
  inspect(state.rp_proj[6 * 32 + 3].ref_, content="1")
  // Motion cannot project across the 8x8 temporal superblock boundary.
  refs[4][7 * 32 + 10] = { mv: (128, 0), ref_: 1 }
  state.load_tmvs(init, refs, 0, 16, 0, 16)
  assert_eq(state.rp_proj[11 * 32 + 10].mv, (32768, 32768))

  let block : @libavcodec.Av1Rb = {
    ref0: 1, ref1: -1, bs: 17, mf: 0,
    mv0: (64, -80), mv1: (0, 0),
  }
  state.init_sbrow(0)
  state.splat_mv(block, 4, 31, 2, 1)
  state.init_sbrow(1)
  assert_eq(state.rows[4][4].mv0, (64, -80))
  state.splat_mv(block, 6, 32, 2, 1)
  assert_eq(state.rows[5][6].mv0, (64, -80))
}

///|
test "refmvs saved temporal map propagates into the next frame" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let empty_refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  let first_poc : FixedArray[Int] = [2, 0, 0, 0, 0, 0, 0]
  let no_tmvs : FixedArray[Bool] = FixedArray::make(7, false)
  let first_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let first_init = @libavcodec.av1_refmvs_init_frame(
    4, 3, false, first_poc, no_tmvs, first_ref_poc,
  )
  let first = @libavcodec.av1_refmvs_frame_state_new(
    rf, first_init, empty_refs, 32, 32, 32, 16,
  )
  first.begin_sbrow(0, 0, 16, 0, 8)
  let block : @libavcodec.Av1Rb = {
    ref0: 1, ref1: -1, bs: 17, mf: 0,
    mv0: (128, -192), mv1: (0, 0),
  }
  first.splat(block, 6, 12, 2, 2)
  first.finish_sbrow(0, 16, 0, 8)
  assert_eq(first.rp[6 * 32 + 3].mv, (128, -192))

  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7, i => if i == 0 { first.rp } else { empty_refs[i] },
  )
  let second_poc : FixedArray[Int] = [3, 0, 0, 4, 0, 0, 0]
  let has_tmvs : FixedArray[Bool] = [true, false, false, false, false, false, false]
  let second_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  second_ref_poc[0][0] = 2
  let second_init = @libavcodec.av1_refmvs_init_frame(
    4, 5, true, second_poc, has_tmvs, second_ref_poc,
  )
  let second = @libavcodec.av1_refmvs_frame_state_new(
    rf, second_init, refs, 32, 32, 32, 16,
  )
  second.begin_sbrow(0, 0, 16, 0, 8)
  assert_eq(second.tile.rp_proj[2 * 32 + 9].mv, (128, -192))
  let result = second.find(0, 32, 0, 32, 1, -1, 17, false, 4, 18)
  assert_eq(result.candidate(0).0, (256, -384))
}

///|
test "refmvs block publishers retain dav1d reference and mode flags" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let ref_poc : FixedArray[Int] = FixedArray::make(7, 0)
  let ref_has : FixedArray[Bool] = FixedArray::make(7, false)
  let ref_ref_poc : FixedArray[FixedArray[Int]] = FixedArray::makei(
    7, _ => FixedArray::make(7, 0),
  )
  let init = @libavcodec.av1_refmvs_init_frame(
    4, 1, false, ref_poc, ref_has, ref_ref_poc,
  )
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(
    7,
    _ => FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0 }),
  )
  let state = @libavcodec.av1_refmvs_frame_state_new(
    rf, init, refs, 32, 32, 32, 16,
  )
  state.begin_sbrow(0, 0, 16, 0, 8)
  state.splat_intra(17, 0, 0, 2, 2)
  inspect(state.tile.rows[5][0].ref0, content="0")
  assert_eq(state.tile.rows[5][0].mv0, (32768, 32768))

  state.splat_single(0, 2, (12, 20), false, 17, 2, 0, 2, 2)
  inspect(state.tile.rows[5][2].mf, content="1")
  state.splat_single(0, 2, (12, 20), false, 17, 4, 0, 1, 1)
  inspect(state.tile.rows[5][4].mf, content="0")
  state.splat_single(1, 3, (24, -16), true, 17, 6, 0, 2, 2)
  inspect(state.tile.rows[5][6].ref0, content="2")
  inspect(state.tile.rows[5][6].ref1, content="0")
  inspect(state.tile.rows[5][6].mf, content="2")

  for mode in 0..<8 {
    state.splat_compound(
      0, 4, mode, (40, 8), (-24, 16), 17,
      mode * 2, 2, 2, 2,
    )
    let block = state.tile.rows[7][mode * 2]
    inspect(block.ref0, content="1")
    inspect(block.ref1, content="5")
    let expected = if mode == 6 { 1 } else if mode >= 2 && mode != 6 { 2 } else { 0 }
    assert_eq(block.mf, expected)
    assert_eq(block.mv1, (-24, 16))
  }
}
