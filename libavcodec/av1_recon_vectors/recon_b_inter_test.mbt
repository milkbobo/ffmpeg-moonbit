///|
/// `av1_recon_b_inter` glue: prediction written into the frame planes plus
/// the residual walk applied through inverse transforms. The expected side
/// rebuilds the same result from the public primitives (predict, coefficient
/// walk with an independent CDF/msac, `av1_itxfm_add`) so offsets and
/// context wiring are checked independently of the glue.

///|
fn av1_rbi_block() -> @libavcodec.Av1InterBlock {
  {
    bs: 17, // BS_8x8
    ref0: 0,
    ref1: -1,
    comp_type: 0,
    wedge_idx: 0,
    mode: 0,
    drl_idx: 0,
    mv0: (0, 0),
    mv1: (0, 0),
    interintra: { kind: 0, mode: 0, wedge_idx: 0, },
    motion_mode: 0,
    warp: None,
    warp_type: 0,
    warp_alpha: 0,
    warp_beta: 0,
    warp_gamma: 0,
    warp_delta: 0,
    mask0: 0,
    mask1: 0,
    find_ctx: 0,
    filter0: 0,
    filter1: 0,
    filter2d: 0,
    mask_sign: 0,
    skip_mode: false,
    has_subpel_filter: true,
  }
}

///|
fn av1_rbi_ref1(
  src : FixedArray[Int32],
  stride : Int32,
  w : Int32,
  h : Int32,
) -> FixedArray[@libavcodec.Av1ReconRefPlane] {
  FixedArray::makei(1, _ => { src, stride, width: w, height: h, })
}

///|
fn av1_rbi_coef(msac : @libavcodec.Av1Msac) -> @libavcodec.Av1CoefState {
  let dq : FixedArray[Int32] = FixedArray::make(48, 4)
  let lossless : FixedArray[Bool] = FixedArray::make(8, false)
  let segq : FixedArray[Int32] = FixedArray::make(8, 1)
  let levels : FixedArray[Byte] = FixedArray::make(32 * 34, b'\x00')
  {
    msac,
    cdf: @libavcodec.av1_cdf_copy_defaults(0),
    levels,
    dq_cur: dq,
    seg_lossless: lossless,
    seg_qidx: segq,
    reduced_tx_set: false,
    bpc: 8,
    ss_h: 1,
    ss_v: 1,
  }
}

///|
test "recon_b_inter writes prediction and skip contexts" {
  let y0 : FixedArray[Int32] = FixedArray::make(32 * 32, 7)
  let u0 : FixedArray[Int32] = FixedArray::make(16 * 16, 9)
  let v0 : FixedArray[Int32] = FixedArray::make(16 * 16, 9)
  let ref_y : FixedArray[Int32] = FixedArray::make(32 * 32, 0)
  let ref_u : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  for i in 0..<(32 * 32) {
    ref_y[i] = (i * 7 + 3) % 251
  }
  for i in 0..<(16 * 16) {
    ref_u[i] = (i * 5 + 11) % 251
  }
  let refs_y = av1_rbi_ref1(ref_y, 32, 32, 32)
  let refs_u = av1_rbi_ref1(ref_u, 16, 16, 16)
  let refs_v = av1_rbi_ref1(ref_u, 16, 16, 16)
  let b = av1_rbi_block()
  let msac = @libavcodec.Av1Msac::init(
    Bytes::from_array([0, 0, 0, 0, 0, 0, 0, 0]),
    false,
  )
  let a_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let l_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let a_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let l_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let ctx : @libavcodec.Av1ReconInterCtx = {
    coef: av1_rbi_coef(msac),
    cf: FixedArray::make(64 * 64, 0),
    y: y0,
    u: u0,
    v: v0,
    y_stride: 32,
    uv_stride: 16,
    bw: 8,
    bh: 8,
    ss_h: 1,
    ss_v: 1,
    bpc: 8,
    pixel_max: 255,
    mono: false,
    a_lcoef,
    l_lcoef,
    a_ccoef,
    l_ccoef,
  }
  let r = @libavcodec.av1_recon_b_inter(
    ctx,
    17,
    b,
    0,
    true,
    1,
    0U,
    0U,
    0,
    refs_y,
    refs_u,
    refs_v,
    32,
    32,
    4,
    4,
    0,
    None,
    None,
  )
  match r {
    Ok(_) => ()
    Err(e) => fail("skip recon failed: " + e)
  }
  // expected: prediction only
  let exp_y : FixedArray[Int32] = FixedArray::make(32 * 32, 7)
  let exp_u : FixedArray[Int32] = FixedArray::make(16 * 16, 9)
  let exp_v : FixedArray[Int32] = FixedArray::make(16 * 16, 9)
  let pred = match
    @libavcodec.av1_recon_predict_block(
      b,
      refs_y,
      refs_u,
      refs_v,
      32,
      32,
      4,
      4,
      2,
      2,
      1,
      1,
      8,
      0,
      None,
      None,
    ) {
    Ok(p) => p
    Err(e) => {
      fail("predict failed: " + e)
      return
    }
  }
  for yy in 0..<pred.h {
    for xx in 0..<pred.w {
      exp_y[4 * (4 * 32 + 4) + yy * 32 + xx] = pred.y[yy * pred.w + xx]
    }
  }
  for yy in 0..<pred.ch {
    for xx in 0..<pred.cw {
      exp_u[4 * (2 * 16 + 2) + yy * 16 + xx] = pred.u[yy * pred.cw + xx]
      exp_v[4 * (2 * 16 + 2) + yy * 16 + xx] = pred.v[yy * pred.cw + xx]
    }
  }
  for i in 0..<(32 * 32) {
    if y0[i] != exp_y[i] {
      fail(
        "skip Y @" +
        i.to_string() +
        ": " +
        y0[i].to_string() +
        " != " +
        exp_y[i].to_string(),
      )
    }
  }
  for i in 0..<(16 * 16) {
    if u0[i] != exp_u[i] || v0[i] != exp_v[i] {
      fail("skip UV @" + i.to_string())
    }
  }
  for i in 0..<2 {
    if a_lcoef[4 + i] != 0x40 || l_lcoef[4 + i] != 0x40 {
      fail("skip lcoef ctx not reset")
    }
  }
  for i in 0..<1 {
    if a_ccoef[2 + i] != 0x40 ||
      l_ccoef[2 + i] != 0x40 ||
      a_ccoef[32 + 2 + i] != 0x40 ||
      l_ccoef[32 + 2 + i] != 0x40 {
      fail("skip ccoef ctx not reset")
    }
  }
}

///|
test "recon_b_inter applies residual transforms in place" {
  let y0 : FixedArray[Int32] = FixedArray::make(32 * 32, 0)
  let u0 : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  let v0 : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  let ref_y : FixedArray[Int32] = FixedArray::make(32 * 32, 0)
  let ref_u : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  for i in 0..<(32 * 32) {
    ref_y[i] = (i * 11 + 5) % 240
  }
  for i in 0..<(16 * 16) {
    ref_u[i] = (i * 13 + 29) % 240
  }
  let refs_y = av1_rbi_ref1(ref_y, 32, 32, 32)
  let refs_u = av1_rbi_ref1(ref_u, 16, 16, 16)
  let refs_v = av1_rbi_ref1(ref_u, 16, 16, 16)
  let b = av1_rbi_block()
  let stream : Array[Byte] = []
  for i in 0..<256 {
    stream.push(((i * 37 + 11) % 256).to_byte())
  }
  let bytes = Bytes::from_array(stream)
  let msac = @libavcodec.Av1Msac::init(bytes, false)
  let a_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let l_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let a_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let l_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let ctx : @libavcodec.Av1ReconInterCtx = {
    coef: av1_rbi_coef(msac),
    cf: FixedArray::make(64 * 64, 0),
    y: y0,
    u: u0,
    v: v0,
    y_stride: 32,
    uv_stride: 16,
    bw: 8,
    bh: 8,
    ss_h: 1,
    ss_v: 1,
    bpc: 8,
    pixel_max: 255,
    mono: false,
    a_lcoef,
    l_lcoef,
    a_ccoef,
    l_ccoef,
  }
  let r = @libavcodec.av1_recon_b_inter(
    ctx,
    17,
    b,
    0,
    false,
    1,
    0U,
    0U,
    0,
    refs_y,
    refs_u,
    refs_v,
    32,
    32,
    4,
    4,
    0,
    None,
    None,
  )
  match r {
    Ok(_) => ()
    Err(e) => fail("residual recon failed: " + e)
  }
  // independent expected path
  let exp_y : FixedArray[Int32] = FixedArray::make(32 * 32, 0)
  let exp_u : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  let exp_v : FixedArray[Int32] = FixedArray::make(16 * 16, 0)
  let pred = match
    @libavcodec.av1_recon_predict_block(
      b,
      refs_y,
      refs_u,
      refs_v,
      32,
      32,
      4,
      4,
      2,
      2,
      1,
      1,
      8,
      0,
      None,
      None,
    ) {
    Ok(p) => p
    Err(e) => {
      fail("predict failed: " + e)
      return
    }
  }
  for yy in 0..<pred.h {
    for xx in 0..<pred.w {
      exp_y[4 * (4 * 32 + 4) + yy * 32 + xx] = pred.y[yy * pred.w + xx]
    }
  }
  for yy in 0..<pred.ch {
    for xx in 0..<pred.cw {
      exp_u[4 * (2 * 16 + 2) + yy * 16 + xx] = pred.u[yy * pred.cw + xx]
      exp_v[4 * (2 * 16 + 2) + yy * 16 + xx] = pred.v[yy * pred.cw + xx]
    }
  }
  let msac2 = @libavcodec.Av1Msac::init(bytes, false)
  let exp_coef = av1_rbi_coef(msac2)
  let exp_cf : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
  let e_a_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let e_l_lcoef : FixedArray[Int32] = FixedArray::make(32, 0)
  let e_a_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let e_l_ccoef : FixedArray[Int32] = FixedArray::make(64, 0)
  let applied = Ref(0)
  let reader : @libavcodec.Av1CoefReader = {
    decode: (a_arr, a_off, l_arr, l_off, tx, plane, _intra, luma_txtp) => {
      @libavcodec.av1_decode_coefs(
        exp_coef,
        a_arr,
        a_off,
        l_arr,
        l_off,
        tx,
        17,
        0,
        0,
        0,
        0,
        false,
        plane,
        exp_cf,
        luma_txtp~,
      )
    },
  }
  let apply_y = (rx, ry, tx, txtp, eob) => {
    applied.val = applied.val + 1
    @libavcodec.av1_itxfm_add(
      exp_y,
      4 * ((4 + ry) * 32 + 4 + rx),
      32,
      exp_cf,
      eob,
      tx,
      txtp,
      255,
    )
  }
  let apply_uv = (pl, cx, cy, tx, txtp, eob) => {
    applied.val = applied.val + 1
    let plane = if pl == 0 { exp_u } else { exp_v }
    @libavcodec.av1_itxfm_add(
      plane,
      4 * ((2 + cy) * 16 + 2 + cx),
      16,
      exp_cf,
      eob,
      tx,
      txtp,
      255,
    )
  }
  let txtp_map : FixedArray[Byte] = FixedArray::make(1024, b'\x00')
  @libavcodec.av1_read_inter_residual(
    reader,
    17,
    1,
    0U,
    0U,
    0,
    2,
    2,
    1,
    1,
    1,
    1,
    true,
    4,
    4,
    8,
    8,
    e_a_lcoef,
    e_l_lcoef,
    e_a_ccoef,
    e_l_ccoef,
    txtp_map,
    Some(apply_y),
    Some(apply_uv),
  )
  if applied.val == 0 {
    fail("expected at least one decoded coefficient block")
  }
  for i in 0..<(32 * 32) {
    if y0[i] != exp_y[i] {
      fail(
        "res Y @" +
        i.to_string() +
        ": " +
        y0[i].to_string() +
        " != " +
        exp_y[i].to_string(),
      )
    }
  }
  for i in 0..<(16 * 16) {
    if u0[i] != exp_u[i] {
      fail(
        "res U @" +
        i.to_string() +
        ": " +
        u0[i].to_string() +
        " != " +
        exp_u[i].to_string(),
      )
    }
    if v0[i] != exp_v[i] {
      fail("res V @" + i.to_string())
    }
  }
  for i in 0..<32 {
    if a_lcoef[i] != e_a_lcoef[i] || l_lcoef[i] != e_l_lcoef[i] {
      fail("res lcoef ctx @" + i.to_string())
    }
  }
  for i in 0..<64 {
    if a_ccoef[i] != e_a_ccoef[i] || l_ccoef[i] != e_l_ccoef[i] {
      fail("res ccoef ctx @" + i.to_string())
    }
  }
  if msac.rng != msac2.rng || msac.dif != msac2.dif {
    fail("res msac state diverged from the expected walk")
  }
}
