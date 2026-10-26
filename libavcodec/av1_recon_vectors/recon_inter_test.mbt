///|
/// Inter block prediction assembly: single put, compound average/wedge and
/// dav1d joint compound weights.

///|
fn recon_pattern(w : Int, h : Int, seed : Int) -> FixedArray[Int32] {
  FixedArray::makei(w * h, i => ((i % w) * 5 + (i / w) * 3 + seed) % 256)
}

///|
fn recon_ref(w : Int, h : Int) -> @libavcodec.Av1ReconRefPlane {
  {
    src: recon_pattern(w, h, 11),
    stride: w,
    width: w,
    height: h,
  }
}

///|
fn recon_plane(w : Int, h : Int, seed : Int) -> @libavcodec.Av1ReconRefPlane {
  {
    src: recon_pattern(w, h, seed),
    stride: w,
    width: w * 2,
    height: h * 2,
  }
}

///|
fn recon_block(comp_type : Int) -> @libavcodec.Av1InterBlock {
  {
    bs: 17,
    ref0: 0,
    ref1: if comp_type == 0 { -1 } else { 1 },
    comp_type,
    wedge_idx: 5,
    mode: 0,
    drl_idx: 0,
    mv0: (24, -16),
    mv1: (8, 24),
    interintra: { kind: 0, mode: 0, wedge_idx: 0 },
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
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21), recon_plane(64, 48, 21), recon_plane(64, 48, 21),
    recon_plane(64, 48, 21), recon_plane(64, 48, 21), recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31), recon_plane(64, 48, 31), recon_plane(64, 48, 31),
    recon_plane(64, 48, 31), recon_plane(64, 48, 31), recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let b = recon_block(0)
  let r = @libavcodec.av1_recon_predict_block(
    b, refs_y, refs_u, refs_v, 128, 96, 3, 2, 2, 2, 1, 1, 8, 0,
  ).unwrap()
  assert_eq(r.w, 8)
  assert_eq((r.cw, r.ch), (4, 4))
  let expect_y = @av1_mc_core.av1_mc_predict_plane(
    refs_y[0].src, 128, 128, 96, 128, 96, 3, 2, 2, 2, 24, -16, 0, 0, 0, 8,
  )
  let expect_u = @av1_mc_core.av1_mc_predict_plane(
    refs_u[0].src, 64, 128, 96, 128, 96, 3, 2, 2, 2, 24, -16, 1, 1, 0, 8,
  )
  assert_eq(r.y, expect_y)
  assert_eq(r.u, expect_u)
}

///|
test "compound average and wedge use prep plus blend" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 21), recon_plane(64, 48, 21), recon_plane(64, 48, 21),
    recon_plane(64, 48, 21), recon_plane(64, 48, 21), recon_plane(64, 48, 21),
    recon_plane(64, 48, 21),
  ]
  let refs_v : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_plane(64, 48, 31), recon_plane(64, 48, 31), recon_plane(64, 48, 31),
    recon_plane(64, 48, 31), recon_plane(64, 48, 31), recon_plane(64, 48, 31),
    recon_plane(64, 48, 31),
  ]
  let b = recon_block(2)
  let avg = @libavcodec.av1_recon_predict_block(
    b, refs_y, refs_u, refs_v, 128, 96, 3, 2, 2, 2, 1, 1, 8, 0,
  ).unwrap()
  let p0 = @av1_mc_core.av1_mc_prepare_plane(
    refs_y[0].src, 128, 128, 96, 128, 96, 3, 2, 2, 2, 24, -16, 0, 0, 0, 8,
  )
  let p1 = @av1_mc_core.av1_mc_prepare_plane(
    refs_y[1].src, 128, 128, 96, 128, 96, 3, 2, 2, 2, 8, 24, 0, 0, 0, 8,
  )
  assert_eq(avg.y, @av1_mc_core.av1_mc_avg(p0, p1, 8))

  let mut wedge = recon_block(4)
  wedge = { ..wedge, mask_sign: 1 }
  let w = @libavcodec.av1_recon_predict_block(
    wedge, refs_y, refs_u, refs_v, 128, 96, 3, 2, 2, 2, 1, 1, 8, 0,
  ).unwrap()
  let mask = @av1_mc_core.av1_wedge_mask(0, 17, 0, 5)
  assert_eq(w.y, @av1_mc_core.av1_mc_mask(p1, p0, mask, 8))
}

///|
test "recon rejects pending paths and computes jnt weights" {
  let refs_y : FixedArray[@libavcodec.Av1ReconRefPlane] = [
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96), recon_ref(128, 96), recon_ref(128, 96),
    recon_ref(128, 96),
  ]
  let refs_u = refs_y
  let refs_v = refs_y
  let ii = { ..recon_block(0), interintra: { kind: 1, mode: 0, wedge_idx: 0 } }
  assert_true(
    @libavcodec.av1_recon_predict_block(
      ii, refs_y, refs_u, refs_v, 128, 96, 3, 2, 2, 2, 1, 1, 8, 0,
    ) is Err(_),
  )
  let obmc = { ..recon_block(0), motion_mode: 1 }
  assert_true(
    @libavcodec.av1_recon_predict_block(
      obmc, refs_y, refs_u, refs_v, 128, 96, 3, 2, 2, 2, 1, 1, 8, 0,
    ) is Err(_),
  )
  // near ref1 (d0=1) vs far ref0 (d1=2): weight 5
  inspect(@libavcodec.av1_jnt_comp_weight(4, 5, 7, 6), content="5")
  // far ref1 (d0=2) vs near ref0 (d1=1): weight 11
  inspect(@libavcodec.av1_jnt_comp_weight(4, 5, 6, 7), content="11")
}
