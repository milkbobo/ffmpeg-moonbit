///|
/// Deterministic checks for the inter-block syntax driver: skip-mode blocks
/// consume no arithmetic symbols, compound blocks do not read inter-intra or
/// motion variation, and the tile neighbour state updates as dav1d does.

///|
fn inter_block_test_state() -> @libavcodec.Av1RefmvsFrameState {
  let poc : FixedArray[Int32] = FixedArray::make(7, 0)
  let has : FixedArray[Bool] = FixedArray::make(7, false)
  let history : FixedArray[FixedArray[Int32]] = FixedArray::makei(7, _ => {
    FixedArray::make(7, 0)
  })
  let init = @libavcodec.av1_refmvs_init_frame(4, 1, false, poc, has, history)
  let refs : FixedArray[FixedArray[@libavcodec.Av1Rtb]] = FixedArray::makei(7, _ => {
    FixedArray::makei(32 * 32, _ => { mv: (0, 0), ref_: 0, })
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
fn inter_block_test_params(
  skip : Bool,
  switchable_filter : Bool,
) -> @libavcodec.Av1InterBlockParams {
  {
    bs: 17,
    bx4: 2,
    by4: 0,
    bx4_ctx: 2,
    by4_ctx: 0,
    w4: 2,
    h4: 2,
    tile_col_start4: 0,
    tile_col_end4: 16,
    tile_row_start4: 0,
    tile_row_end4: 16,
    top_has_right: false,
    have_top: false,
    have_left: true,
    skip_mode: skip,
    skip_ref0: 0,
    skip_ref1: 4,
    seg_present: false,
    seg_ref: -1,
    seg_globalmv: false,
    seg_skip: false,
    switchable_comp_refs: true,
    inter_intra: true,
    masked_compound: true,
    jnt_comp: true,
    dual_filter: true,
    switchable_filter,
    subpel_filter_mode: 1,
    switchable_motion_mode: true,
    warp_motion: true,
    order_hint_bits: 4,
    cur_order_hint: 2,
    ref_order_hint: [1, 2, 0, 0, 0, 0, 0],
    ref_scaled: FixedArray::make(7, false),
  }
}

///|
test "inter block skip mode consumes no symbols and stays compound" {
  let state = inter_block_test_state()
  state.begin_sbrow(0, 0, 16, 0, 8)
  state.splat(
    { ref0: 1, ref1: 5, bs: 17, mf: 0, mv0: (24, -40), mv1: (-8, 16), },
    0,
    0,
    2,
    2,
  )
  let bytes : Array[Byte] = []
  for _ in 0..<64 {
    bytes.push(b'\x00')
  }
  let msac = @libavcodec.Av1Msac::init(Bytes::from_array(bytes), false)
  let cdf = @libavcodec.av1_cdf_copy_defaults(0)
  let rng = msac.rng
  let cnt = msac.cnt
  let pos = msac.pos
  let dif = msac.dif
  let nstate = @libavcodec.av1_inter_tile_state_new(16, 16)
  let b = @libavcodec.av1_inter_read_block(
    msac,
    cdf,
    state,
    nstate,
    inter_block_test_params(true, false),
  )
  assert_eq((b.ref0, b.ref1), (0, 4))
  assert_eq(b.comp_type, 2)
  assert_eq(b.mode, 0)
  assert_eq(b.drl_idx, 0)
  assert_eq(b.mv0, (24, -40))
  assert_eq(b.mv1, (-8, 16))
  assert_eq(b.interintra.kind, 0)
  assert_eq(b.motion_mode, 0)
  assert_eq((b.mask0, b.mask1), (0UL, 0UL))
  assert_eq((b.filter0, b.filter1, b.filter2d), (1, 1, 7))
  assert_eq(msac.rng, rng)
  assert_eq(msac.cnt, cnt)
  assert_eq(msac.pos, pos)
  assert_eq(msac.dif, dif)
  // published as a compound block with NEAREST_NEAREST (mode 0)
  inspect(state.tile.rows[5][2].ref0, content="1")
  inspect(state.tile.rows[5][2].ref1, content="5")
  assert_eq(state.tile.rows[5][2].mv0, (24, -40))
  assert_eq(state.tile.rows[5][2].mv1, (-8, 16))
}

///|
test "inter tile neighbour state updates and gates overlay" {
  let s = @libavcodec.av1_inter_tile_state_new(8, 8)
  let n : @libavcodec.Av1InterNeighbor = {
    intra: false,
    comp_type: 2,
    ref0: 3,
    ref1: 5,
    filter0: 1,
    filter1: 2,
  }
  s.set_block(2, 1, 2, 3, n)
  assert_true(!s.top[2].intra)
  assert_true(!s.top[3].intra)
  assert_true(!s.left[1].intra)
  assert_true(!s.left[3].intra)
  assert_true(s.top[0].intra)
  assert_true(s.left[4].intra)
  inspect(s.top[2].ref1, content="5")
  // left rows 2 and 4 are non-intra (odd sampling from by4+1)
  assert_true(s.has_overlappable_neighbor(2, 1, 2, 3, false, true))
  assert_true(!s.has_overlappable_neighbor(6, 0, 1, 1, false, false))
}
