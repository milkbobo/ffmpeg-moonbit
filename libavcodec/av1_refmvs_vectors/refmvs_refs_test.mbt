///|
test "refmvs reference slots preserve a temporal map across refreshes" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let slots = @libavcodec.av1_refmvs_reference_store_new()
  let all_refs : Array[Int] = [0, 1, 2, 3, 4, 5, 6]
  let missing = slots.prepare_frame(
    all_refs, 4, 3, 128, 128, false, rf, 16,
  )
  assert_true(missing is Err(_))

  // Key picture A (POC 2) refreshes all eight slots without a motion map.
  slots.refresh_without_mvs(2, 128, 128, 255)
  let first = match slots.prepare_frame(
    all_refs, 4, 3, 128, 128, false, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_true(!first.state.init.use_ref_frame_mvs)
  assert_eq(first.state.tile.rp_stride, 16)
  first.state.begin_sbrow(0, 0, 16, 0, 8)
  first.state.splat_single(
    0, 3, (128, -192), false, 17, 6, 12, 2, 2,
  )
  first.state.finish_sbrow(0, 16, 0, 8)
  assert_eq(first.state.rp[6 * 16 + 3].mv, (128, -192))
  slots.refresh(first, 1)
  assert_true(slots.slots[0] is Some(_))
  assert_true(slots.slots[1] is Some(_))

  // A different golden picture makes LAST eligible for temporal projection.
  slots.refresh_without_mvs(1, 128, 128, 1 << 3)
  let second = match slots.prepare_frame(
    all_refs, 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  inspect(second.state.init.mfmv_ref[0], content="0")
  inspect(second.state.init.mfmv_ref2cur[0], content="2")
  inspect(second.state.init.mfmv_ref2ref[0][0], content="1")
  second.state.begin_sbrow(0, 0, 16, 0, 8)
  assert_eq(second.state.tile.rp_proj[2 * 16 + 9].mv, (128, -192))
  let candidate = second.state.find(0, 32, 0, 32, 1, -1, 17, false, 4, 18)
  assert_eq(candidate.candidate(0).0, (256, -384))
}

///|
test "refmvs reference slots gate temporal maps by rounded upscaled size" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let slots = @libavcodec.av1_refmvs_reference_store_new()
  let temporal : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 16, _ => { mv: (0, 0), ref_: 0 },
  )
  temporal[6 * 16 + 3] = { mv: (128, -192), ref_: 1 }
  let history : FixedArray[Int] = FixedArray::make(7, 2)
  // Superres-coded width 127 still has a 128-pixel upscaled grid, the
  // 16 8x8 columns refmvs stores motion on.
  slots.slots[0] = Some({
    poc: 3, upscaled_width: 127, height: 128,
    ref_poc: history, rp: Some(temporal),
  })
  // Upscaled width 119 rounds to 15 columns and must be excluded.
  slots.slots[1] = Some({
    poc: 3, upscaled_width: 119, height: 128,
    ref_poc: history, rp: Some(temporal),
  })
  slots.refresh_without_mvs(1, 128, 128, 252)
  let matched : Array[Int] = [0, 2, 2, 3, 4, 5, 6]
  let frame = match slots.prepare_frame(
    matched, 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_true(frame.state.init.use_ref_frame_mvs)
  inspect(frame.state.init.mfmv_ref[0], content="0")

  let mismatched : Array[Int] = [1, 2, 2, 3, 4, 5, 6]
  let no_projection = match slots.prepare_frame(
    mismatched, 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_true(!no_projection.state.init.use_ref_frame_mvs)
}

///|
test "refmvs spatial ring and temporal saves survive four SB rows" {
  let tile = @libavcodec.av1_refmvs_tile_state_new(16, 16, 32, 16)
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 32, _ => { mv: (0, 0), ref_: 0 },
  )
  let sign : FixedArray[Int] = [1, 0, 0, 0, 0, 0, 0]
  for sby in 0..<4 {
    tile.init_sbrow(sby)
    if sby > 0 {
      let top = ((sby * 16) & 31) + 4
      assert_eq(tile.rows[top][2].mv0, (sby, -sby))
    }
    let block : @libavcodec.Av1Rb = {
      ref0: 1, ref1: -1, bs: 17, mf: 2,
      mv0: (sby + 1, -(sby + 1)), mv1: (0, 0),
    }
    tile.splat_mv(block, 2, sby * 16 + 15, 2, 1)
    let row8 = sby * 8 + 7
    tile.save_tmvs(rp, sign, 1, 2, row8, row8 + 1)
    assert_eq(rp[row8 * 16 + 1].mv, (sby + 1, -(sby + 1)))
  }
}

///|
test "refmvs later temporal reference replaces earlier projection" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let slots = @libavcodec.av1_refmvs_reference_store_new()
  slots.refresh_without_mvs(1, 128, 128, 255)
  let last_map : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 16, _ => { mv: (0, 0), ref_: 0 },
  )
  let bwd_map : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 16, _ => { mv: (0, 0), ref_: 0 },
  )
  last_map[4 * 16 + 4] = { mv: (8, 0), ref_: 1 }
  bwd_map[4 * 16 + 4] = { mv: (16, 0), ref_: 1 }
  let last_history : FixedArray[Int] = FixedArray::make(7, 2)
  let bwd_history : FixedArray[Int] = FixedArray::make(7, 6)
  slots.slots[0] = Some({
    poc: 3, upscaled_width: 128, height: 128,
    ref_poc: last_history, rp: Some(last_map),
  })
  slots.slots[4] = Some({
    poc: 7, upscaled_width: 128, height: 128,
    ref_poc: bwd_history, rp: Some(bwd_map),
  })
  let refs : Array[Int] = [0, 1, 2, 3, 4, 5, 6]
  let frame = match slots.prepare_frame(
    refs, 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_eq(frame.state.init.n_mfmvs, 2)
  assert_eq(frame.state.init.mfmv_ref[0], 0)
  assert_eq(frame.state.init.mfmv_ref[1], 4)
  frame.state.begin_sbrow(0, 0, 16, 0, 8)
  assert_eq(frame.state.tile.rp_proj[4 * 16 + 4].mv, (16, 0))
}

///|
test "refmvs superres frames share temporal maps on the upscaled grid" {
  let (rf, _, _, _) = av1_refmvs_test_build(1)
  let slots = @libavcodec.av1_refmvs_reference_store_new()
  let temporal : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 16, _ => { mv: (0, 0), ref_: 0 },
  )
  temporal[6 * 16 + 3] = { mv: (128, -192), ref_: 1 }
  let history : FixedArray[Int] = FixedArray::make(7, 2)
  // Both pictures upscale to 128 pixels, so they share the 16x16-column
  // motion grid even though their superres-coded widths differ.
  slots.slots[0] = Some({
    poc: 3, upscaled_width: 128, height: 128,
    ref_poc: history, rp: Some(temporal),
  })
  // A picture that only matches on coded width is not eligible: refmvs
  // compares the upscaled grid (dav1d `width[0]`), not the coded width.
  slots.slots[1] = Some({
    poc: 3, upscaled_width: 119, height: 128,
    ref_poc: history, rp: Some(temporal),
  })
  slots.refresh_without_mvs(1, 128, 128, 252)
  let frame = match slots.prepare_frame(
    [0, 2, 2, 3, 4, 5, 6], 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  inspect(frame.state.tile.iw8, content="16")
  inspect(frame.state.init.mfmv_ref[0], content="0")
  assert_true(frame.state.init.use_ref_frame_mvs)
  let rejected = match slots.prepare_frame(
    [1, 2, 2, 3, 4, 5, 6], 4, 5, 128, 128, true, rf, 16,
  ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_true(!rejected.state.init.use_ref_frame_mvs)
}
