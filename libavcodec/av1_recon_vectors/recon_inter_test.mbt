///|
/// Inter block prediction assembly: single put, compound average/wedge and
/// dav1d joint compound weights.

///|
fn recon_pattern(w : Int32, h : Int32, seed : Int32) -> FixedArray[Int32] {
  FixedArray::makei(w * h, i => (i % w * 5 + i / w * 3 + seed) % 256)
}

///|
fn recon_ref(w : Int32, h : Int32) -> @libavcodec.Av1ReconRefPlane {
  { src: recon_pattern(w, h, 11), stride: w, width: w, height: h, }
}

///|
fn recon_plane(
  w : Int32,
  h : Int32,
  seed : Int32,
) -> @libavcodec.Av1ReconRefPlane {
  { src: recon_pattern(w, h, seed), stride: w, width: w * 2, height: h * 2, }
}

///|
fn recon_block(comp_type : Int32) -> @libavcodec.Av1InterBlock {
  {
    bs: 17,
    ref0: 0,
    ref1: if comp_type == 0 {
      -1
    } else {
      1
    },
    comp_type,
    wedge_idx: 5,
    mode: 0,
    drl_idx: 0,
    mv0: (24, -16),
    mv1: (8, 24),
    interintra: { kind: 0, mode: 0, wedge_idx: 0, },
    motion_mode: 0,
    warp: None,
    warp_type: 0,
    warp_alpha: 0,
    warp_beta: 0,
    warp_gamma: 0,
    warp_delta: 0,
    filter0: 0,
    filter1: 0,
    filter2d: 0,
    mask_sign: 0,
    skip_mode: false,
    has_subpel_filter: true,
    mask0: 0UL,
    mask1: 0UL,
    find_ctx: 0,
  }
}

///|
test "single reference prediction matches the MC kernels" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let b = recon_block(0)
  let r = @libavcodec.av1_recon_predict_block(
    b,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    3,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    None,
    None,
  ).unwrap()
  assert_eq(r.w, 8)
  assert_eq((r.cw, r.ch), (4, 4))
  let expect_y = @av1_mc_core.av1_mc_predict_plane(
    refs_y[0].src,
    128,
    128,
    96,
    128,
    96,
    3,
    2,
    2,
    2,
    24,
    -16,
    0,
    0,
    0,
    8,
  )
  let expect_u = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    3,
    2,
    2,
    2,
    24,
    -16,
    1,
    1,
    0,
    8,
  )
  assert_eq(r.y, expect_y)
  assert_eq(r.u, expect_u)
}

///|
test "compound average and wedge use prep plus blend" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let b = recon_block(2)
  let avg = @libavcodec.av1_recon_predict_block(
    b,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    3,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    None,
    None,
  ).unwrap()
  let p0 = @av1_mc_core.av1_mc_prepare_plane(
    refs_y[0].src,
    128,
    128,
    96,
    128,
    96,
    3,
    2,
    2,
    2,
    24,
    -16,
    0,
    0,
    0,
    8,
  )
  let p1 = @av1_mc_core.av1_mc_prepare_plane(
    refs_y[1].src,
    128,
    128,
    96,
    128,
    96,
    3,
    2,
    2,
    2,
    8,
    24,
    0,
    0,
    0,
    8,
  )
  assert_eq(avg.y, @av1_mc_core.av1_mc_avg(p0, p1, 8))

  let mut wedge = recon_block(4)
  wedge = { ..wedge, mask_sign: 1, }
  let w = @libavcodec.av1_recon_predict_block(
    wedge,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    3,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    None,
    None,
  ).unwrap()
  let mask = @av1_mc_core.av1_wedge_mask(0, 17, 0, 5)
  assert_eq(w.y, @av1_mc_core.av1_mc_mask(p1, p0, mask, 8))
}

///|
test "recon rejects pending paths and computes jnt weights" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u = refs_y
  let refs_v = refs_y
  let ii = {
    ..recon_block(0),
    interintra: { kind: 1, mode: 0, wedge_idx: 0, },
  }
  assert_true(
    @libavcodec.av1_recon_predict_block(
      ii,
      refs_y,
      refs_u,
      refs_v,
      128,
      96,
      3,
      2,
      2,
      2,
      1,
      1,
      8,
      0,
      None,
      None,
    )
    is Err(_),
  )
  let obmc = { ..recon_block(0), motion_mode: 1, }
  assert_true(
    @libavcodec.av1_recon_predict_block(
      obmc,
      refs_y,
      refs_u,
      refs_v,
      128,
      96,
      3,
      2,
      2,
      2,
      1,
      1,
      8,
      0,
      None,
      None,
    )
    is Err(_),
  )
  // near ref1 (d0=1) vs far ref0 (d1=2): weight 5
  inspect(@libavcodec.av1_jnt_comp_weight(4, 5, 7, 6), content="5")
  // far ref1 (d0=2) vs near ref0 (d1=1): weight 11
  inspect(@libavcodec.av1_jnt_comp_weight(4, 5, 6, 7), content="11")
}

///|
fn recon_state() -> @libavcodec.Av1RefmvsFrameState {
  let poc : FixedArray[Int32] = FixedArray::make(7, 0)
  let has : FixedArray[Bool] = FixedArray::make(7, false)
  let history : FixedArray[FixedArray[Int32]] = FixedArray::makei(7, _ => {
    FixedArray::make(7, 0)
  })
  let init = @libavcodec.av1_refmvs_init_frame(4, 1, false, poc, has, history)
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(7, _ => {
    FixedArray::makei(16 * 16, _ => { mv: (0, 0), ref_: 0, })
  })
  let rf : @libavcodec.Av1Rf = {
    iw4: 32,
    ih4: 32,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp: false,
    force_integer_mv: false,
    use_ref_frame_mvs: false,
    gm_types: FixedArray::make(7, 0),
    gm_matrices: FixedArray::makei(7, _ => FixedArray::make(6, 0)),
  }
  @libavcodec.av1_refmvs_frame_state_new(rf, init, refs, 16, 16, 16, 16)
}

///|
test "inter-intra blend uses the II masks" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let base = @libavcodec.av1_recon_predict_block(
    recon_block(0),
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    3,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    None,
    None,
  ).unwrap()
  let intra : @libavcodec.Av1ReconPlanes = {
    y: recon_pattern(8, 8, 5),
    u: recon_pattern(4, 4, 6),
    v: recon_pattern(4, 4, 7),
    w: 8,
    h: 8,
    cw: 4,
    ch: 4,
  }
  let ii = {
    ..recon_block(0),
    interintra: { kind: 1, mode: 1, wedge_idx: 0, },
  }
  let r = @libavcodec.av1_recon_predict_block(
    ii,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    3,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    Some(intra),
    None,
  ).unwrap()
  assert_eq(
    r.y,
    @av1_mc_core.av1_mc_blend_pixels(
      base.y,
      intra.y,
      @av1_mc_core.av1_ii_mask(0, 17, 1),
    ),
  )
  assert_eq(
    r.u,
    @av1_mc_core.av1_mc_blend_pixels(
      base.u,
      intra.u,
      @av1_mc_core.av1_ii_mask(2, 17, 1),
    ),
  )
}

///|
test "OBMC blends the top neighbour overlap" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let state = recon_state()
  state.begin_sbrow(0, 0, 16, 0, 8)
  state.tile.rows[6][3] = {
    ref0: 1,
    ref1: -1,
    bs: 17,
    mf: 0,
    mv0: (8, 4),
    mv1: (0, 0),
  }
  let nstate = @libavcodec.av1_inter_tile_state_new(16, 16)
  nstate.top[3] = {
    intra: false,
    comp_type: 0,
    ref0: 1,
    ref1: -1,
    filter0: 0,
    filter1: 0,
  }
  let obmc : @libavcodec.Av1ReconObmc = {
    rows: state.tile.rows,
    nstate,
    w4: 2,
    h4: 2,
    have_top: true,
    have_left: false,
  }
  let b = { ..recon_block(0), motion_mode: 1, }
  let r = @libavcodec.av1_recon_predict_block(
    b,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    2,
    2,
    2,
    2,
    1,
    1,
    8,
    0,
    None,
    Some(obmc),
  ).unwrap()
  let y0 = @av1_mc_core.av1_mc_predict_plane(
    refs_y[0].src,
    128,
    128,
    96,
    128,
    96,
    2,
    2,
    2,
    2,
    24,
    -16,
    0,
    0,
    0,
    8,
  )
  let lap = @av1_mc_core.av1_mc_predict_plane(
    refs_y[0].src,
    128,
    128,
    96,
    128,
    96,
    2 + 0,
    2,
    2,
    1,
    8,
    4,
    0,
    0,
    0,
    8,
  )
  let sub = FixedArray::makei(8 * 4, i => y0[i])
  let blended = @av1_mc_core.av1_mc_obmc_horizontal(sub, lap, 8, 4)
  for i in 0..<(8 * 4) {
    assert_eq(r.y[i], blended[i])
  }
  // 4:2:0 chroma needs 16 pixels of edge; an 8x8 block keeps chroma intact
  let u0 = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    2,
    2,
    2,
    2,
    24,
    -16,
    1,
    1,
    0,
    8,
  )
  assert_eq(r.u, u0)
}

///|
fn sub8x8_neighbor(mv : (Int32, Int32), bs : Int32) -> @libavcodec.Av1Rb {
  { ref0: 1, ref1: -1, bs, mf: 0, mv0: mv, mv1: (0, 0), }
}

///|
test "chroma sub8x8 splits a 4x4 block by neighbour motion" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v = refs_u
  let state = recon_state()
  state.begin_sbrow(0, 0, 16, 0, 8)
  state.tile.rows[6][1] = sub8x8_neighbor((8, 0), 21)
  state.tile.rows[6][2] = sub8x8_neighbor((0, 16), 21)
  state.tile.rows[7][1] = sub8x8_neighbor((24, 8), 21)
  let nstate = @libavcodec.av1_inter_tile_state_new(16, 16)
  let obmc : @libavcodec.Av1ReconObmc = {
    rows: state.tile.rows,
    nstate,
    w4: 1,
    h4: 1,
    have_top: true,
    have_left: true,
  }
  let b : @libavcodec.Av1InterBlock = {
    ..recon_block(0),
    bs: 21,
    mv0: (16, 8),
  }
  let r = @libavcodec.av1_recon_predict_block(
    b,
    refs_y,
    refs_u,
    refs_v,
    128,
    96,
    2,
    2,
    1,
    1,
    1,
    1,
    8,
    0,
    None,
    Some(obmc),
  ).unwrap()
  let tl = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    1,
    1,
    1,
    1,
    8,
    0,
    1,
    1,
    0,
    8,
  )
  let left = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    1,
    2,
    1,
    1,
    24,
    8,
    1,
    1,
    0,
    8,
  )
  let top = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    2,
    1,
    1,
    1,
    0,
    16,
    1,
    1,
    0,
    8,
  )
  let own = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src,
    64,
    128,
    96,
    128,
    96,
    2,
    2,
    1,
    1,
    16,
    8,
    1,
    1,
    0,
    8,
  )
  let expected : FixedArray[Int32] = [
    tl[0],
    tl[1],
    top[0],
    top[1],
    tl[2],
    tl[3],
    top[2],
    top[3],
    left[0],
    left[1],
    own[0],
    own[1],
    left[2],
    left[3],
    own[2],
    own[3],
  ]
  assert_eq(r.u, expected)
}

///|
test "chroma sub8x8 without neighbours is rejected" {
  let refs : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let b : @libavcodec.Av1InterBlock = {
    ..recon_block(0),
    bs: 21,
    mv0: (16, 8),
  }
  assert_true(
    @libavcodec.av1_recon_predict_block(
      b,
      refs,
      refs,
      refs,
      128,
      96,
      2,
      2,
      1,
      1,
      1,
      1,
      8,
      0,
      None,
      None,
    )
    is Err(_),
  )
}
