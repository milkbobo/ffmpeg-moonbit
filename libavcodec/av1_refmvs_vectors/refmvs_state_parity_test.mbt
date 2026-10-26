///|
/// refmvs state machine verified against dav1d 1.5.1 `src/refmvs.c`:
/// `tile_sbrow_init` ring over 16/32-pixel superblocks, `splat_mv_c`,
/// `save_tmvs_c`, and `load_tmvs_c` with scaled temporal projection and
/// equal-run fast-forward (`scripts/_emit_av1_refmvs_state_vectors.py`).

///|
fn refmvs_state_hash_v(h : Int64, v : Int) -> Int64 {
  (h * 31L + (v & 0xffff).to_int64()) % 1000000007L
}

///|
fn refmvs_state_hash_slots(
  state : @libavcodec.Av1RefmvsTileState,
  off : Int,
  sbsz : Int,
) -> Int64 {
  let mut h = 17L
  for i in 0..<37 {
    let used = i == off || i == off + 2 || i == off + 4 ||
      (i >= off + 5 && i < off + 5 + sbsz)
    if !used {
      continue
    }
    let row = state.rows[i]
    for x in 0..<(state.rp_stride * 2) {
      let b = row[x]
      h = refmvs_state_hash_v(h, b.ref0)
      h = refmvs_state_hash_v(h, b.ref1)
      h = refmvs_state_hash_v(h, b.bs)
      h = refmvs_state_hash_v(h, b.mf)
      h = refmvs_state_hash_v(h, b.mv0.0)
      h = refmvs_state_hash_v(h, b.mv0.1)
      h = refmvs_state_hash_v(h, b.mv1.0)
      h = refmvs_state_hash_v(h, b.mv1.1)
    }
  }
  h
}

///|
fn refmvs_state_hash_rp(
  rp : FixedArray[@libavcodec.Av1Rtb],
  n : Int,
) -> Int64 {
  let mut h = 17L
  for i in 0..<n {
    h = refmvs_state_hash_v(h, rp[i].mv.0)
    h = refmvs_state_hash_v(h, rp[i].mv.1)
    h = refmvs_state_hash_v(h, rp[i].ref_)
  }
  h
}

///|
fn refmvs_state_hash_proj(state : @libavcodec.Av1RefmvsTileState) -> Int64 {
  let mut h = 17L
  for i in 0..<(16 * state.rp_stride) {
    h = refmvs_state_hash_v(h, state.rp_proj[i].mv.0)
    h = refmvs_state_hash_v(h, state.rp_proj[i].mv.1)
    h = refmvs_state_hash_v(h, state.rp_proj[i].ref_)
  }
  h
}

///|
fn refmvs_state_src_maps(
  seed : Int,
  stride : Int,
  ih8 : Int,
) -> FixedArray[FixedArray[@libavcodec.Av1Rtb]] {
  FixedArray::makei(
    7,
    _ => FixedArray::makei(stride * ih8, i => {
      let y = i / stride
      let x = i % stride
      let qx = x / 3
      let qy = y / 2
      let k = qx * 5 + qy * 7 + seed * 3
      {
        mv: (
          ((qx * 11 + qy * 13 + seed * 17) % 9 - 4) * 64,
          ((qx * 19 + qy * 23 + seed * 29) % 9 - 4) * 64,
        ),
        ref_: if k % 6 == 0 { 0 } else { 1 + (k & 7) % 7 },
      }
    }),
  )
}

///|
test "refmvs state machine matches dav1d C (case 0)" {
  let sign : FixedArray[Int] = [1, 1, 0, 1, 1, 0, 0]
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    32 * 20, _ => { mv: (0, 0), ref_: 0 },
  )
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 24, 20, 16)
  let ops : Array[Array[Int]] = [
    [31, 14, 8, 1, 1, 0, 7, 1, 4057, -1026, -580, 3395],
    [20, 6, 8, 4, 5, 4, 14, 0, 1414, 2968, 2444, -2670],
    [28, 7, 8, 1, 1, 0, 21, 3, -3232, 2462, -202, 4116],
    [3, 15, 8, 1, 0, 0, 7, 2, -2051, 806, -3470, -275],
    [22, 9, 8, 7, 7, 7, 5, 2, 3652, 3914, -1177, -3463],
    [0, 1, 4, 4, 0, 2, 21, 1, 2069, -3945, 2274, 1550],
    [29, 3, 1, 4, 1, 5, 7, 1, 1082, -611, 2419, -3736],
    [25, 12, 16, 4, 5, 3, 12, 2, -3165, 577, -3579, -3975],
    [33, 23, 4, 4, 1, 1, 15, 2, -1927, -2016, 1676, -213],
    [0, 16, 1, 8, 7, -1, 7, 3, -3541, -2042, 3354, 3360],
    [18, 19, 2, 13, 5, 7, 5, 0, -1224, -2005, -343, -974],
    [3, 29, 8, 3, 6, 1, 14, 1, 2210, 3944, 2822, -419],
    [0, 25, 16, 1, 7, 0, 5, 3, -3083, 2041, 2315, 2729],
    [36, 19, 1, 8, 2, -1, 17, 1, 1164, -3840, -4146, -365],
    [11, 24, 4, 8, 5, 2, 5, 3, -3685, 1461, 4189, -3734],
    [33, 18, 8, 8, 3, 7, 17, 1, 1544, -2092, 3696, -80],
    [3, 39, 4, 1, 1, 4, 17, 0, -3025, 1791, -1723, 2353],
    [12, 34, 4, 1, 1, -1, 14, 3, -3331, -4032, 1882, 1165],
    [40, 32, 8, 4, 1, 1, 7, 2, 2211, -2667, -4190, -3847],
    [19, 35, 4, 4, 4, 7, 14, 1, 2015, 3239, 3655, -3413],
    [26, 33, 8, 7, 7, 7, 12, 0, -3607, 1526, -3734, 3240],
    [24, 38, 1, 2, 4, 7, 7, 0, 3684, -97, 4165, 74],
    [25, 36, 1, 4, 1, 6, 12, 0, -4195, 767, -2879, -3105],
    [9, 33, 16, 7, 1, 5, 7, 1, -3228, 1365, -2420, -1517],
  ]
  let sbys : Array[Int] = [0, 1, 2]
  let nops : Array[Int] = [8, 8, 8]
  let slot_hashes : Array[Int64] = [430955401L, 255223572L, 304438182L]
  let rp_hashes : Array[Int64] = [11615094L, 202807972L, 712462839L]
  let mut oi = 0
  for s in 0..<sbys.length() {
    let sby = sbys[s]
    state.init_sbrow(sby)
    for _ in 0..<nops[s] {
      let o = ops[oi]
      oi = oi + 1
      let block : @libavcodec.Av1Rb = {
        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],
        mv0: (o[8], o[9]), mv1: (o[10], o[11]),
      }
      state.splat_mv(block, o[0], o[1], o[2], o[3])
    }
    let rs = sby * (16 / 2)
    let re = if rs + 16 / 2 < 20 { rs + 16 / 2 } else { 20 }
    state.save_tmvs(rp, sign, 0, 24, rs, re)
    assert_eq(
      refmvs_state_hash_slots(state, (16 * sby) & 16, 16),
      slot_hashes[s],
    )
    assert_eq(
      refmvs_state_hash_rp(rp, 32 * 20),
      rp_hashes[s],
    )
  }
  let refs = refmvs_state_src_maps(1, 32, 20)
  for i in 0..<(16 * 32) {
    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }
  }
  let loads : Array[Array[Int]] = [
    [0, 0, 24, 0, 16, 1, 0, 0, 0, 1, 0, 0, 1, 4, 3, 2, 1, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    [1, 5, 22, 8, 16, 2, 0, 4, 0, 6, 8, 0, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 0, 0, 0, 0, 0, 0, 0],
    [2, 3, 27, 0, 9, 3, 0, 4, 6, 2, 4, 6, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3],
  ]
  let proj_hashes : Array[Int64] = [605740144L, 309887726L, 739429810L]
  for li in 0..<loads.length() {
    let l = loads[li]
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      FixedArray::make(7, 0), FixedArray::make(7, 0),
      FixedArray::make(7, 0),
      FixedArray::makei(3, i => l[6 + i]),
      FixedArray::makei(3, i => l[9 + i]),
      FixedArray::makei(3, m => FixedArray::makei(7, j => l[12 + m * 7 + j])),
      l[5], true,
    )
    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])
    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])
  }
}

///|
test "refmvs state machine matches dav1d C (case 1)" {
  let sign : FixedArray[Int] = [1, 0, 1, 1, 0, 0, 1]
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    32 * 24, _ => { mv: (0, 0), ref_: 0 },
  )
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 20, 24, 32)
  let ops : Array[Array[Int]] = [
    [1, 29, 4, 2, 3, 3, 14, 0, 2139, -855, 1462, 3834],
    [22, 28, 16, 4, 7, 6, 15, 1, 408, -1864, 398, 4105],
    [11, 21, 16, 8, 6, 6, 15, 3, 1275, -4102, 1960, -1168],
    [28, 6, 4, 4, 6, 1, 7, 2, -568, 126, -3895, -1625],
    [30, 10, 8, 16, 3, 6, 5, 2, 78, 2784, -540, 707],
    [28, 30, 8, 1, 7, 1, 17, 3, 571, -2688, -3821, 1384],
    [2, 28, 4, 4, 0, -1, 12, 2, -1809, 3725, -700, 3873],
    [36, 2, 4, 16, 1, 6, 14, 2, 1073, -1020, 1042, -614],
    [6, 43, 4, 1, 6, 5, 12, 3, -1966, -439, 4003, 119],
    [37, 36, 3, 2, 4, 6, 21, 2, 654, -2714, 1457, -3010],
    [36, 39, 4, 8, 6, 7, 12, 2, -710, -1557, 1049, 1189],
    [8, 34, 16, 4, 0, -1, 14, 3, 2878, 2289, -3587, 2994],
    [19, 32, 8, 4, 6, 5, 14, 1, -3550, -1718, 3505, -1823],
    [19, 46, 4, 2, 5, -1, 21, 0, 2367, -3620, 1259, 79],
    [11, 38, 2, 1, 0, 7, 14, 1, -2497, 724, 1943, -4085],
    [15, 38, 4, 10, 3, -1, 15, 3, -2638, 1717, -2203, -2932],
  ]
  let sbys : Array[Int] = [0, 1]
  let nops : Array[Int] = [8, 8]
  let slot_hashes : Array[Int64] = [595817387L, 755945490L]
  let rp_hashes : Array[Int64] = [883176718L, 698097895L]
  let mut oi = 0
  for s in 0..<sbys.length() {
    let sby = sbys[s]
    state.init_sbrow(sby)
    for _ in 0..<nops[s] {
      let o = ops[oi]
      oi = oi + 1
      let block : @libavcodec.Av1Rb = {
        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],
        mv0: (o[8], o[9]), mv1: (o[10], o[11]),
      }
      state.splat_mv(block, o[0], o[1], o[2], o[3])
    }
    let rs = sby * (32 / 2)
    let re = if rs + 32 / 2 < 24 { rs + 32 / 2 } else { 24 }
    state.save_tmvs(rp, sign, 0, 20, rs, re)
    assert_eq(
      refmvs_state_hash_slots(state, (32 * sby) & 16, 32),
      slot_hashes[s],
    )
    assert_eq(
      refmvs_state_hash_rp(rp, 32 * 24),
      rp_hashes[s],
    )
  }
  let refs = refmvs_state_src_maps(14, 32, 24)
  for i in 0..<(16 * 32) {
    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }
  }
  let loads : Array[Array[Int]] = [
    [0, 0, 20, 0, 16, 2, 0, 4, 0, 8, 1, 0, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 0, 0, 0, 0, 0, 0, 0],
    [1, 5, 18, 16, 24, 3, 0, 4, 6, 4, 6, 8, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3],
    [2, 3, 23, 0, 9, 1, 0, 0, 0, 9, 0, 0, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  ]
  let proj_hashes : Array[Int64] = [519119326L, 650537584L, 979194402L]
  for li in 0..<loads.length() {
    let l = loads[li]
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      FixedArray::make(7, 0), FixedArray::make(7, 0),
      FixedArray::make(7, 0),
      FixedArray::makei(3, i => l[6 + i]),
      FixedArray::makei(3, i => l[9 + i]),
      FixedArray::makei(3, m => FixedArray::makei(7, j => l[12 + m * 7 + j])),
      l[5], true,
    )
    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])
    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])
  }
}

///|
test "refmvs state machine matches dav1d C (case 2)" {
  let sign : FixedArray[Int] = [0, 1, 1, 0, 0, 1, 1]
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 16, _ => { mv: (0, 0), ref_: 0 },
  )
  let state = @libavcodec.av1_refmvs_tile_state_new(16, 16, 16, 16)
  let ops : Array[Array[Int]] = [
    [6, 14, 2, 1, 2, 7, 14, 3, -1247, -3981, 4098, 2075],
    [3, 8, 8, 1, 0, 6, 17, 0, -2884, -647, -1492, 3618],
    [16, 3, 4, 13, 4, 6, 12, 0, 232, 826, -3836, -225],
    [11, 10, 16, 6, 0, 5, 7, 1, -1757, -1563, 1501, -10],
    [16, 9, 16, 7, 2, 4, 14, 1, 2993, -2884, 375, -1212],
    [25, 12, 2, 2, 5, -1, 14, 3, -3769, -1050, -694, 220],
    [4, 0, 8, 16, 6, 0, 12, 3, -4194, 1635, -2882, -3278],
    [12, 15, 4, 1, 0, 0, 14, 1, 3027, -364, 1216, -2964],
    [13, 23, 16, 1, 7, 7, 17, 2, 2420, -2246, 457, 2145],
    [4, 20, 8, 12, 7, 0, 15, 1, 2010, -3481, -504, 2194],
    [11, 16, 1, 16, 4, 1, 15, 2, 321, -1618, -531, 3652],
    [0, 25, 1, 7, 3, 1, 15, 1, -71, -1057, -540, 2365],
    [31, 26, 1, 6, 7, 3, 15, 3, -3592, 651, 410, 3104],
    [2, 31, 8, 1, 4, 3, 15, 3, -2427, -447, -3758, -3135],
    [7, 21, 1, 11, 7, 1, 7, 1, -3364, 797, 2130, -339],
    [9, 23, 16, 2, 3, 3, 21, 2, 2693, -3105, 1136, -2083],
  ]
  let sbys : Array[Int] = [0, 1]
  let nops : Array[Int] = [8, 8]
  let slot_hashes : Array[Int64] = [552370318L, 633135332L]
  let rp_hashes : Array[Int64] = [34867706L, 255730248L]
  let mut oi = 0
  for s in 0..<sbys.length() {
    let sby = sbys[s]
    state.init_sbrow(sby)
    for _ in 0..<nops[s] {
      let o = ops[oi]
      oi = oi + 1
      let block : @libavcodec.Av1Rb = {
        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],
        mv0: (o[8], o[9]), mv1: (o[10], o[11]),
      }
      state.splat_mv(block, o[0], o[1], o[2], o[3])
    }
    let rs = sby * (16 / 2)
    let re = if rs + 16 / 2 < 16 { rs + 16 / 2 } else { 16 }
    state.save_tmvs(rp, sign, 0, 16, rs, re)
    assert_eq(
      refmvs_state_hash_slots(state, (16 * sby) & 16, 16),
      slot_hashes[s],
    )
    assert_eq(
      refmvs_state_hash_rp(rp, 16 * 16),
      rp_hashes[s],
    )
  }
  let refs = refmvs_state_src_maps(27, 16, 16)
  for i in 0..<(16 * 16) {
    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }
  }
  let loads : Array[Array[Int]] = [
    [0, 0, 16, 0, 16, 3, 0, 4, 6, 6, 8, 1, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3],
    [1, 5, 14, 8, 16, 1, 0, 0, 0, 2, 0, 0, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    [2, 3, 15, 0, 9, 2, 0, 4, 0, 7, 9, 0, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0],
  ]
  let proj_hashes : Array[Int64] = [588874849L, 201612762L, 873058574L]
  for li in 0..<loads.length() {
    let l = loads[li]
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      FixedArray::make(7, 0), FixedArray::make(7, 0),
      FixedArray::make(7, 0),
      FixedArray::makei(3, i => l[6 + i]),
      FixedArray::makei(3, i => l[9 + i]),
      FixedArray::makei(3, m => FixedArray::makei(7, j => l[12 + m * 7 + j])),
      l[5], true,
    )
    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])
    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])
  }
}

///|
test "refmvs state machine matches dav1d C (case 3)" {
  let sign : FixedArray[Int] = [0, 1, 1, 1, 0, 1, 1]
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    16 * 7, _ => { mv: (0, 0), ref_: 0 },
  )
  let state = @libavcodec.av1_refmvs_tile_state_new(16, 9, 7, 32)
  let ops : Array[Array[Int]] = [
    [8, 4, 10, 8, 6, 4, 7, 0, -1426, 3590, -2861, -3918],
    [9, 8, 4, 1, 3, 3, 14, 2, -973, 3314, -2623, -2702],
    [14, 6, 2, 4, 3, 6, 15, 2, -2053, -3568, 2599, 2878],
    [10, 4, 2, 8, 1, -1, 21, 2, -2422, -527, -613, 1767],
    [9, 12, 2, 1, 2, -1, 5, 0, 277, 800, 3268, -274],
    [1, 7, 1, 7, 0, 7, 21, 3, 9, 1827, -1316, 870],
    [14, 9, 2, 5, 1, 3, 14, 0, -3871, 1890, -3007, 708],
    [10, 7, 8, 2, 1, 5, 14, 0, -1602, 1487, 2203, -2328],
  ]
  let sbys : Array[Int] = [0]
  let nops : Array[Int] = [8]
  let slot_hashes : Array[Int64] = [586551442L]
  let rp_hashes : Array[Int64] = [772768757L]
  let mut oi = 0
  for s in 0..<sbys.length() {
    let sby = sbys[s]
    state.init_sbrow(sby)
    for _ in 0..<nops[s] {
      let o = ops[oi]
      oi = oi + 1
      let block : @libavcodec.Av1Rb = {
        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],
        mv0: (o[8], o[9]), mv1: (o[10], o[11]),
      }
      state.splat_mv(block, o[0], o[1], o[2], o[3])
    }
    let rs = sby * (32 / 2)
    let re = if rs + 32 / 2 < 7 { rs + 32 / 2 } else { 7 }
    state.save_tmvs(rp, sign, 0, 9, rs, re)
    assert_eq(
      refmvs_state_hash_slots(state, (32 * sby) & 16, 32),
      slot_hashes[s],
    )
    assert_eq(
      refmvs_state_hash_rp(rp, 16 * 7),
      rp_hashes[s],
    )
  }
  let refs = refmvs_state_src_maps(40, 16, 7)
  for i in 0..<(16 * 16) {
    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }
  }
  let loads : Array[Array[Int]] = [
    [0, 0, 9, 0, 7, 1, 0, 0, 0, 4, 0, 0, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    [1, 5, 7, 0, 7, 2, 0, 4, 0, 9, 2, 0, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0],
    [2, 3, 12, 0, 7, 3, 0, 4, 6, 5, 7, 9, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4],
  ]
  let proj_hashes : Array[Int64] = [186192311L, 984959997L, 53560572L]
  for li in 0..<loads.length() {
    let l = loads[li]
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      FixedArray::make(7, 0), FixedArray::make(7, 0),
      FixedArray::make(7, 0),
      FixedArray::makei(3, i => l[6 + i]),
      FixedArray::makei(3, i => l[9 + i]),
      FixedArray::makei(3, m => FixedArray::makei(7, j => l[12 + m * 7 + j])),
      l[5], true,
    )
    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])
    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])
  }
}

///|
test "refmvs state machine matches dav1d C (case 4)" {
  let sign : FixedArray[Int] = [1, 1, 0, 1, 0, 1, 1]
  let rp : FixedArray[@libavcodec.Av1Rtb] = FixedArray::makei(
    32 * 20, _ => { mv: (0, 0), ref_: 0 },
  )
  let state = @libavcodec.av1_refmvs_tile_state_new(32, 24, 20, 32)
  let ops : Array[Array[Int]] = [
    [24, 30, 2, 1, 7, 0, 12, 3, 3310, -1789, 1037, -363],
    [23, 26, 2, 6, 2, 5, 7, 1, -310, 4105, 2841, -1845],
    [6, 13, 4, 2, 0, 2, 15, 0, 1590, 1120, -1598, -772],
    [15, 2, 8, 8, 5, 7, 21, 2, -293, 2417, 3519, 463],
    [16, 5, 16, 8, 6, 0, 14, 1, -3641, 461, 1558, -361],
    [36, 2, 1, 2, 6, 2, 12, 0, -408, 3844, -1267, 656],
    [40, 6, 8, 4, 1, 2, 17, 3, -2731, -481, 3989, -884],
    [38, 28, 4, 1, 3, -1, 7, 3, 393, -2700, -834, 832],
    [28, 32, 4, 2, 1, 3, 15, 3, 3032, 2374, 473, -628],
    [37, 38, 11, 2, 6, 2, 17, 3, -1301, -1448, -1776, -1510],
    [14, 35, 4, 2, 6, -1, 12, 3, -3039, -908, -2946, -3478],
    [17, 34, 4, 1, 5, 0, 14, 0, -1954, -3175, 84, -2623],
    [28, 39, 16, 1, 0, 3, 14, 0, -1614, 1250, -3543, 1968],
    [10, 39, 2, 1, 1, 0, 5, 1, 1862, -3311, -757, 2079],
    [40, 36, 8, 4, 7, 3, 5, 3, -976, 921, 967, 1262],
    [16, 36, 1, 1, 3, 2, 12, 0, 144, 229, 3153, -681],
  ]
  let sbys : Array[Int] = [0, 1]
  let nops : Array[Int] = [8, 8]
  let slot_hashes : Array[Int64] = [550091985L, 756640194L]
  let rp_hashes : Array[Int64] = [935036728L, 733375501L]
  let mut oi = 0
  for s in 0..<sbys.length() {
    let sby = sbys[s]
    state.init_sbrow(sby)
    for _ in 0..<nops[s] {
      let o = ops[oi]
      oi = oi + 1
      let block : @libavcodec.Av1Rb = {
        ref0: o[4], ref1: o[5], bs: o[6], mf: o[7],
        mv0: (o[8], o[9]), mv1: (o[10], o[11]),
      }
      state.splat_mv(block, o[0], o[1], o[2], o[3])
    }
    let rs = sby * (32 / 2)
    let re = if rs + 32 / 2 < 20 { rs + 32 / 2 } else { 20 }
    state.save_tmvs(rp, sign, 0, 24, rs, re)
    assert_eq(
      refmvs_state_hash_slots(state, (32 * sby) & 16, 32),
      slot_hashes[s],
    )
    assert_eq(
      refmvs_state_hash_rp(rp, 32 * 20),
      rp_hashes[s],
    )
  }
  let refs = refmvs_state_src_maps(53, 32, 20)
  for i in 0..<(16 * 32) {
    state.rp_proj[i] = { mv: (0, 0), ref_: 0 }
  }
  let loads : Array[Array[Int]] = [
    [0, 0, 24, 0, 16, 2, 0, 4, 0, 2, 4, 0, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 0, 0, 0, 0, 0, 0, 0],
    [1, 5, 22, 16, 20, 3, 0, 4, 6, 7, 9, 2, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4, 3, 2, 1, 4],
    [2, 3, 27, 0, 9, 1, 0, 0, 0, 3, 0, 0, 3, 2, 1, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  ]
  let proj_hashes : Array[Int64] = [715228694L, 643532476L, 755309723L]
  for li in 0..<loads.length() {
    let l = loads[li]
    let init = @libavcodec.av1_refmvs_frame_init_probe(
      FixedArray::make(7, 0), FixedArray::make(7, 0),
      FixedArray::make(7, 0),
      FixedArray::makei(3, i => l[6 + i]),
      FixedArray::makei(3, i => l[9 + i]),
      FixedArray::makei(3, m => FixedArray::makei(7, j => l[12 + m * 7 + j])),
      l[5], true,
    )
    state.load_tmvs(init, refs, l[1], l[2], l[3], l[4])
    assert_eq(refmvs_state_hash_proj(state), proj_hashes[li])
  }
}
