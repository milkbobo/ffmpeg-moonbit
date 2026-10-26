///|
/// Inter-block syntax driver verified against the dav1d 1.5.1 `decode_b`
/// inter branch (compound flag through subpel filter), with real env.h
/// context helpers, refmvs and default CDFs over LCG byte streams
/// (`scripts/_emit_av1_inter_block_vectors.py`).

///|
fn av1_ib_hash(row : Int, x : Int, seed : UInt) -> UInt {
  let mut h = (row.reinterpret_as_uint() * 0x9E3779B1U) ^
    (x.reinterpret_as_uint() * 0x85EBCA6BU) ^ (seed * 0xC2B2AE35U)
  h = h ^ (h >> 15)
  h = h * 0x2545F491U
  h ^ (h >> 13)
}

///|
fn av1_ib_neighbor(i : Int, seed : UInt) -> @libavcodec.Av1InterNeighbor {
  let iu = i.reinterpret_as_uint()
  let intra = (iu * 5U + seed) % 4U == 0U
  let comp = (iu * 3U + seed) % 2U != 0U
  {
    intra,
    comp_type: if intra || !comp { 0 } else { 1 },
    ref0: if intra { -1 } else { ((iu * 7U + seed) % 7U).reinterpret_as_int() },
    ref1: if !intra && comp {
      ((iu * 11U + seed) % 7U).reinterpret_as_int()
    } else {
      -1
    },
    filter0: ((iu * 13U + seed) % 4U).reinterpret_as_int(),
    filter1: ((iu * 17U + seed) % 4U).reinterpret_as_int(),
  }
}

///|
fn av1_ib_gm_matrix(j : Int, seed : UInt) -> FixedArray[Int] {
  let ju = j.reinterpret_as_uint()
  let typ = ((ju + seed) % 4U).reinterpret_as_int()
  let m2 = 65536 + ((ju * 19U + seed * 3U) % 8193U).reinterpret_as_int() - 4096
  let m3 = ((ju * 23U + seed * 5U) % 513U).reinterpret_as_int() - 256
  let mut m4 = ((ju * 29U + seed * 7U) % 513U).reinterpret_as_int() - 256
  let mut m5 = 65536 + ((ju * 31U + seed * 11U) % 8193U).reinterpret_as_int() -
    4096
  if typ == 2 {
    m4 = -m3
    m5 = m2
  }
  [
    ((ju * 13U + seed) * 37U % (1U << 20)).reinterpret_as_int() - (1 << 19),
    ((ju * 17U + seed) * 41U % (1U << 20)).reinterpret_as_int() - (1 << 19),
    m2, m3, m4, m5,
  ]
}

///|
fn av1_ib_fill_rows(state : @libavcodec.Av1RefmvsFrameState, seed : UInt) -> Unit {
  let bss : FixedArray[Int] = [21, 17, 12, 9, 14, 16]
  for r in 0..<35 {
    for x in 0..<64 {
      let h = av1_ib_hash(r, x, seed)
      state.tile.physical[r][x] = {
        ref0: (h >> 5).reinterpret_as_int() % 8,
        ref1: if ((h >> 8) & 1U) != 0U {
          -1
        } else {
          (h >> 9).reinterpret_as_int() % 8
        },
        bs: bss[(h >> 2).reinterpret_as_int() % 6],
        mf: ((h >> 12) & 3U).reinterpret_as_int(),
        mv0: (
          (h >> 14).reinterpret_as_int() % 201 - 100,
          (h >> 25).reinterpret_as_int() % 201 - 100,
        ),
        mv1: (
          (h >> 3).reinterpret_as_int() % 201 - 100,
          (h >> 20).reinterpret_as_int() % 201 - 100,
        ),
      }
    }
  }
  for i in 0..<(16 * 32) {
    let h = av1_ib_hash(16 + i / 32, i % 32, seed ^ 0x5bd1e995U)
    state.tile.rp_proj[i] = {
      mv: (
        (h >> 7).reinterpret_as_int() % 201 - 100,
        (h >> 19).reinterpret_as_int() % 201 - 100,
      ),
      ref_: (h >> 3).reinterpret_as_int() % 8,
    }
  }
}

///|
fn av1_ib_lcg_bytes(seed : UInt, n : Int) -> Bytes {
  let mut state = seed
  let out : Array[Byte] = []
  for _ in 0..<n {
    state = state * 1664525 + 1013904223
    out.push(((state >> 16) & 0xff).reinterpret_as_int().to_byte())
  }
  Bytes::from_array(out)
}

///|
fn av1_ib_bit(flags : UInt, n : Int) -> Bool {
  ((flags >> n) & 1U) != 0U
}

///|
test "inter block syntax driver matches dav1d" {
//<<DATA>>
  let actual : Array[Int] = []
  for i in 0..<96 {
    let cseed = cseeds[i]
    let rseed = rseeds[i]
    let fl = flags[i]
    let buf = av1_ib_lcg_bytes(mseeds[i], 8192)
    let msac = @libavcodec.Av1Msac::init(buf, false)
    let cdf = @libavcodec.av1_cdf_copy_defaults(0)
    let hp = av1_ib_bit(fl, 7)
    let force_integer = av1_ib_bit(fl, 8)
    let use_ref = av1_ib_bit(fl, 9)
    let sign_bias = FixedArray::makei(7, j => ((av1_ib_hash(0, j, rseed) >> 3) & 1U).reinterpret_as_int())
    let pocdiff = FixedArray::makei(7, j => ((av1_ib_hash(2, j, rseed) >> 4) % 63U).reinterpret_as_int() - 31)
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      sign_bias, FixedArray::make(7, 0), pocdiff,
      FixedArray::make(3, 0), FixedArray::make(3, 0),
      FixedArray::makei(3, _ => FixedArray::make(7, 0)), 0, use_ref,
    )
    let gm_types = FixedArray::makei(7, j => ((j.reinterpret_as_uint() + cseed) % 4U).reinterpret_as_int())
    let gm_matrices = FixedArray::makei(7, j => av1_ib_gm_matrix(j, cseed))
    let rf : @libavcodec.Av1Rf = {
      iw4: 64, ih4: 64,
      sign_bias: FixedArray::make(7, 0),
      pocdiff: FixedArray::make(7, 0),
      hp, force_integer_mv: force_integer, use_ref_frame_mvs: use_ref,
      gm_types, gm_matrices,
    }
    let empty : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
      32 * 32, _ => { mv: (0, 0), ref_: 0 },
    )
    let state = @libavcodec.av1_refmvs_frame_state_new(
      rf, init, FixedArray::make(7, empty), 32, 32, 32, 16,
    )
    state.tile.init_sbrow(0)
    av1_ib_fill_rows(state, rseed)
    let nstate = @libavcodec.av1_inter_tile_state_new(16, 16)
    for j in 0..<16 {
      nstate.top[j] = av1_ib_neighbor(j, cseed)
      nstate.left[j] = av1_ib_neighbor(j, cseed + 1U)
    }
    let bs = cfg[i * 7 + 0]
    let bx = cfg[i * 7 + 1]
    let by = cfg[i * 7 + 2]
    let bw4 = cfg[i * 7 + 5]
    let bh4 = cfg[i * 7 + 6]
    let subpel = ((fl >> 18) % 5U).reinterpret_as_int()
    let seg_present = av1_ib_bit(fl, 11)
    let params : @libavcodec.Av1InterBlockParams = {
      bs, bx4: bx, by4: by, w4: bw4, h4: bh4,
      tile_col_start4: 0, tile_col_end4: 16,
      tile_row_start4: 0, tile_row_end4: 16,
      top_has_right: av1_ib_bit(fl, 17),
      have_top: by > 0, have_left: bx > 0,
      skip_mode: av1_ib_bit(fl, 10),
      skip_ref0: cfg[i * 7 + 3], skip_ref1: cfg[i * 7 + 4],
      seg_present,
      seg_ref: ((fl >> 14) & 7U).reinterpret_as_int() - 1,
      seg_globalmv: av1_ib_bit(fl, 12), seg_skip: av1_ib_bit(fl, 13),
      switchable_comp_refs: av1_ib_bit(fl, 0),
      inter_intra: av1_ib_bit(fl, 1),
      masked_compound: av1_ib_bit(fl, 2), jnt_comp: av1_ib_bit(fl, 3),
      dual_filter: av1_ib_bit(fl, 4),
      switchable_filter: subpel == 4,
      subpel_filter_mode: if subpel == 4 { 0 } else { subpel },
      switchable_motion_mode: av1_ib_bit(fl, 5),
      warp_motion: av1_ib_bit(fl, 6),
      order_hint_bits: 2 + ((fl >> 21) % 6U).reinterpret_as_int(),
      cur_order_hint: ((cseed * 3U) % 64U).reinterpret_as_int(),
      ref_order_hint: FixedArray::makei(7, j => ((cseed * 5U + j.reinterpret_as_uint() * 7U) % 64U).reinterpret_as_int()),
      ref_scaled: FixedArray::makei(7, j => av1_ib_bit(fl, 24 + j)),
    }
    let b = @libavcodec.av1_inter_read_block(msac, cdf, state, nstate, params)
    let wedge = if b.interintra.kind != 0 {
      b.interintra.wedge_idx
    } else {
      b.wedge_idx
    }
    actual.push(b.ref0)
    actual.push(b.ref1)
    actual.push(b.comp_type)
    actual.push(wedge)
    actual.push(b.mode)
    actual.push(b.drl_idx)
    actual.push(b.mv0.0)
    actual.push(b.mv0.1)
    actual.push(b.mv1.0)
    actual.push(b.mv1.1)
    actual.push(b.interintra.kind)
    actual.push(b.interintra.mode)
    actual.push(b.interintra.wedge_idx)
    actual.push(b.motion_mode)
    actual.push(b.warp_type)
    let matrix = match b.warp {
      Some(m) => m
      None => [0, 0, 65536, 0, 0, 65536]
    }
    for j in 0..<6 {
      actual.push(matrix[j])
    }
    actual.push(b.filter0)
    actual.push(b.filter1)
    actual.push(b.filter2d)
    actual.push(b.mask_sign)
    actual.push(if b.skip_mode { 1 } else { 0 })
    actual.push(if b.has_subpel_filter { 1 } else { 0 })
    actual.push(msac.rng.reinterpret_as_int())
    if b.mask0 != exp_m0[i] {
      fail("mask0 case " + i.to_string() + ": " + b.mask0.to_string() + " != " + exp_m0[i].to_string())
    }
    if b.mask1 != exp_m1[i] {
      fail("mask1 case " + i.to_string() + ": " + b.mask1.to_string() + " != " + exp_m1[i].to_string())
    }
    if exp_allow[i] >= 0 {
      let allow = !params.ref_scaled[b.ref0] && !force_integer &&
        av1_ib_bit(fl, 6) && (b.mask0 | b.mask1) != 0UL
      assert_eq(if allow { 1 } else { 0 }, exp_allow[i])
    }
    if false && (msac.dif >> 32).reinterpret_as_int64() != exp_difhi[i] {
      fail("difhi case " + i.to_string() + " rng " + msac.rng.to_string() + " dif " + (msac.dif >> 32).to_string() + " exp " + exp_difhi[i].to_string())
    }
  }
  for k in 0..<actual.length() {
    if actual[k] != expected[k] {
      fail("case " + (k / 28).to_string() + " field " + (k % 28).to_string() + ": " + actual[k].to_string() + " != " + expected[k].to_string())
    }
  }
}
