///|
/// `run_value_bits_long[64]` / `run_value_bits_short[16]`,
/// `aacenctab.h:104-131`: bits to code one codebook run value (the section
/// length), with the long-window 5-bit escape ladder 5 -> 10 -> 15 and the
/// short-window 3 -> 6 -> 9.
let aac_trellis_run_bits_long : Array[Int32] = [
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 5, 5, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10,
  10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 15,
]

///|
let aac_trellis_run_bits_short : Array[Int32] = [
  3, 3, 3, 3, 3, 3, 6, 6, 6, 6, 6, 6, 6, 6, 9,
]

///|
/// `CB_TOT_ALL` trellis-state maps, `aacenctab.h:137-140`: the trellis walks
/// codebook *indices* 0..14, which exclude NOISE_BT (12) - a noise band maps
/// in via `aac_cb_in_map[13] = 12` and then only its own index survives the
/// `cb >= 12` guard, so special band types are preserved untouched.
let aac_trellis_cb_out : Array[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15,
]

///|
let aac_trellis_cb_in : Array[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 12, 13, 14,
]

///|
/// One Viterbi node: the previous codebook index the cheapest path came from,
/// the path cost and the run length of the current codebook section.
priv struct AacTrellisNode {
  prev : Int32
  cost : Double
  run : Int32
}

///|
/// `codebook_trellis_rate`, `aaccoder_trellis.h:52`: the rate-optimising
/// codebook selector the reference encoder runs between the quantiser search
/// and the write (`encode_band_info`, `aacenc.c:615-627`). For every window
/// group it re-chooses each band's codebook (and which bands to zero) by a
/// Viterbi over (codebook x run) that prices spectral bits with the same
/// f32 cost function the search used, plus the section-data overhead
/// (`run_bits + 4` per section start, `run_value_bits` per extension), and
/// mutates `cb`/`zeroes` in place - C does the same on the element's sticky
/// arrays and its section writer then just re-derives the runs.
///
/// All costs are integer-valued (spectral bits and run bits), so the
/// search is exact: identical inputs give identical output. Special band
/// types keep themselves (noise 13, intensity 14/15 have no other legal
/// candidate), and a `NOISE_BT` band's scalefactor chain is untouched -
/// only `cb` and `zeroes` move.
fn aac_encode_codebook_trellis(
  coefs : Array[Double],
  sf : Array[Int32],
  cb : Array[Int32],
  zeroes : Array[Int32],
  band_sizes : Array[Int32],
  num_windows : Int32,
  group_len : Array[Int32],
  max_sfb : Int32,
  is8 : Bool,
) -> Unit {
  let run_bits : Int32 = if is8 { 3 } else { 5 }
  let run_table = if is8 {
    aac_trellis_run_bits_short
  } else {
    aac_trellis_run_bits_long
  }
  let start_cost = run_bits.to_double() + 4.0
  let scoefs = aac_two_abs_pow34(coefs, 1024)
  let qcoefs : Array[Int32] = Array::make(128, 0)
  // The DP table is per window group (C reuses one stack array; the values
  // are never carried across groups, so a fresh table is equivalent).
  let path : Array[Array[AacTrellisNode]] = []
  for _ in 0..<(max_sfb + 1) {
    let row : Array[AacTrellisNode] = []
    for _ in 0..<15 {
      row.push({ prev: -1, cost: 61450.0, run: 0, })
    }
    path.push(row)
  }
  let mut w = 0
  while w < num_windows {
    let gl = group_len[w]
    for i in 0..<15 {
      path[0][i] = { prev: -1, cost: start_cost, run: 0, }
    }
    let mut next_minbits = 1.0e308
    let mut next_mincb : Int32 = 0
    let mut start : Int32 = w * 128
    for swb in 0..<max_sfb {
      let size = band_sizes[swb]
      let slot = w * 16 + swb
      if zeroes[slot] != 0 {
        // A zero band: only cb 0 is reachable. Either extend the zero
        // section or enter it from the cheapest path below.
        let mut cost_stay = path[swb][0].cost
        let cost_get = next_minbits + start_cost
        if run_table[path[swb][0].run] != run_table[path[swb][0].run + 1] {
          cost_stay = aac_two_add(cost_stay, run_bits.to_double())
        }
        if cost_get < cost_stay {
          path[swb + 1][0] = { prev: next_mincb, cost: cost_get, run: 1, }
        } else {
          path[swb + 1][0] = {
            prev: 0,
            cost: cost_stay,
            run: path[swb][0].run + 1,
          }
        }
        next_minbits = path[swb + 1][0].cost
        next_mincb = 0
        for i in 1..<15 {
          path[swb + 1][i] = { prev: -1, cost: 61450.0, run: 0, }
        }
      } else {
        let minbits = next_minbits
        let mincb = next_mincb
        let startcb = aac_trellis_cb_in[cb[slot]]
        next_minbits = 1.0e308
        next_mincb = 0
        for i in 0..<startcb {
          path[swb + 1][i] = { prev: -1, cost: 61450.0, run: 0, }
        }
        for i in startcb..<15 {
          if i >= 12 && cb[slot] != aac_trellis_cb_out[i] {
            path[swb + 1][i] = { prev: -1, cost: 61450.0, run: 0, }
            continue
          }
          let out_cb = aac_trellis_cb_out[i]
          let mut bits = 0.0
          for w2 in 0..<gl {
            let off = start + w2 * 128
            let r = aac_two_band_cost(
              coefs,
              off,
              scoefs,
              off,
              qcoefs,
              size,
              sf[slot],
              out_cb,
              0.0,
            )
            bits = aac_two_add(bits, r.bits.to_double())
          }
          let mut cost_stay = aac_two_add(path[swb][i].cost, bits)
          let cost_get = aac_two_add(aac_two_add(minbits, bits), start_cost)
          if run_table[path[swb][i].run] != run_table[path[swb][i].run + 1] {
            cost_stay = aac_two_add(cost_stay, run_bits.to_double())
          }
          if cost_get < cost_stay {
            path[swb + 1][i] = { prev: mincb, cost: cost_get, run: 1, }
          } else {
            path[swb + 1][i] = {
              prev: i,
              cost: cost_stay,
              run: path[swb][i].run + 1,
            }
          }
          if path[swb + 1][i].cost < next_minbits {
            next_minbits = path[swb + 1][i].cost
            next_mincb = i
          }
        }
      }
      start = start + size
    }
    // Backtrack the cheapest path and write the runs onto the band arrays.
    let mut idx : Int32 = 0
    for i in 1..<15 {
      if path[max_sfb][i].cost < path[max_sfb][idx].cost {
        idx = i
      }
    }
    let stack : Array[(Int32, Int32)] = []
    let mut ppos = max_sfb
    while ppos > 0 {
      let run = path[ppos][idx].run
      stack.push((run, idx))
      idx = path[ppos - run + 1][idx].prev
      ppos = ppos - run
    }
    let mut b : Int32 = 0
    let mut s = stack.length()
    while s > 0 {
      let (run, i) = stack[s - 1]
      let out_cb = aac_trellis_cb_out[i]
      for _ in 0..<run {
        cb[w * 16 + b] = out_cb
        zeroes[w * 16 + b] = if out_cb != 0 { 0 } else { 1 }
        b = b + 1
      }
      s = s - 1
    }
    // C's trellis writer emits the section data itself (codebook nibble plus
    // run lengths with escape ladders); this port's section writer derives
    // identical runs from the `cb` array, so only the arrays move here.
    w = w + gl
  }
}
