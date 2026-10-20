///|
/// MPEG-1/2/2.5 Audio Layer I and Layer II tables, ported from FFmpeg 9.0.2
/// `libavcodec/mpegaudiodata.c` and `libavcodec/mpegaudiodec_common.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later. This port keeps the same license.
///
/// Provenance:
///   * `mpa_sblimit_table`, `mpa_alloc_table_{1,3,4}`, `mpa_quant_steps`,
///     `mpa_quant_bits` are **extracted verbatim** from the C arrays by script
///     (`alloc_table_1` serves both table index 0 and 1, `alloc_table_3` both 2
///     and 3, `alloc_table_4` index 4 — see `ff_mpa_alloc_tables`).
///   * `mpa_scale_factor_modshift`, `mpa_scale_factor_mult`,
///     `mpa_scale_factor_mult2` and `mpa_division_tabs` are **derived** the same
///     way the C runtime does it (`mpegaudiodec_common_init_static`,
///     `decode_init_static`, `mpegaudiodec_common_init_static`'s division tables),
///     so they are emitted as code instead of 2368 magic numbers.


///| `ff_mpa_sblimit_table[5]` — used subbands per allocation table.
let mpa_sblimit_table : Array[Int] = [
  27, 30, 8, 12, 30,
]

///| `ff_mpa_quant_steps[17]` — number of quantisation steps per qindex.
let mpa_quant_steps : Array[Int] = [
  3, 5, 7, 9, 15,
  31, 63, 127, 255, 511,
  1023, 2047, 4095, 8191, 16383,
  32767, 65535,
]

///| `ff_mpa_quant_bits[17]` — bits per sample, negative when 3 samples are grouped.
let mpa_quant_bits : Array[Int] = [
  -5, -7, 3, -10, 4,
  5, 6, 7, 8, 9,
  10, 11, 12, 13, 14,
  15, 16,
]

///| `alloc_table_1` — Layer II bit-allocation table (index 0 and 1).
let mpa_alloc_table_1 : Array[Int] = [
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  4, 0, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  3, 0, 1, 2, 3, 4, 5, 16, 3, 0, 1, 2, 3, 4, 5, 16,
  2, 0, 1, 16, 2, 0, 1, 16, 2, 0, 1, 16, 2, 0, 1, 16,
  2, 0, 1, 16, 2, 0, 1, 16, 2, 0, 1, 16,
]

///| `alloc_table_3` — Layer II bit-allocation table (index 2 and 3).
let mpa_alloc_table_3 : Array[Int] = [
  4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  4, 0, 1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
]

///| `alloc_table_4` — Layer II bit-allocation table (index 4, MPEG-2 LSF).
let mpa_alloc_table_4 : Array[Int] = [
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  4, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 3, 0, 1, 3, 4, 5, 6, 7,
  3, 0, 1, 3, 4, 5, 6, 7, 2, 0, 1, 3, 2, 0, 1, 3,
  2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,
  2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,
  2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,
  2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3, 2, 0, 1, 3,
  2, 0, 1, 3,
]

///|
/// `ff_mpa_alloc_tables[5]` — the table selected by `ff_mpa_l2_select_table`.
let mpa_alloc_tables : Array[Array[Int]] = [
  mpa_alloc_table_1,
  mpa_alloc_table_1,
  mpa_alloc_table_3,
  mpa_alloc_table_3,
  mpa_alloc_table_4,
]

///|
/// `ff_scale_factor_modshift[64]`: `mod | (shift << 2)` with `shift = i / 3`,
/// `mod = i % 3` (`mpegaudiodec_common_init_static`). Layer I/II scalefactors are
/// 6-bit indices into this table.
let mpa_scale_factor_modshift : Array[Int] = {
  let t : Array[Int] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    t[i] = (i % 3) | ((i / 3) << 2)
  }
  t
}

///|
/// `scale_factor_mult[15][3]` (`decode_init_static`): `n = i + 2`,
/// `norm = ((1 << n) * FRAC_ONE) / ((1 << n) - 1)`, then
/// `MULLx(norm, FIXR(k * 2.0), FRAC_BITS)` with
/// `k in {1.0, 0.7937005259, 0.6299605249}`.
let mpa_scale_factor_mult : Array[Array[Int]] = {
  let t : Array[Array[Int]] = []
  for i = 0; i < 15; i = i + 1 {
    let n = i + 2
    let norm = ((1 << n) * frac_one) / ((1 << n) - 1)
    t.push([
      mullx(norm, fixr(1.0 * 2.0), frac_bits),
      mullx(norm, fixr(0.7937005259 * 2.0), frac_bits),
      mullx(norm, fixr(0.6299605249 * 2.0), frac_bits),
    ])
  }
  t
}

///|
/// `scale_factor_mult2[3][3]` (`SCALE_GEN`): `FIXR_OLD(k * v)` for
/// `k in {1.0, 0.7937005259, 0.6299605249}` and `v in {4/3, 4/5, 4/9}` —
/// the Layer II group-quantisation multipliers (3, 5 and 9 steps).
let mpa_scale_factor_mult2 : Array[Array[Int]] = {
  let t : Array[Array[Int]] = []
  let vs : Array[Double] = [4.0 / 3.0, 4.0 / 5.0, 4.0 / 9.0]
  for i = 0; i < 3; i = i + 1 {
    let v = vs[i]
    t.push([fixr(1.0 * v), fixr(0.7937005259 * v), fixr(0.6299605249 * v)])
  }
  t
}

///|
/// `ff_division_tabs[4]` (`mpegaudiodec_common_init_static`): for the grouped
/// quantisers, `tab[v] = val1 + (val2 << 4) + (val3 << 8)` where `v` is split as
/// `val1 = v % steps`, `val2 = (v / steps) % steps`, `val3 = v / steps / steps`.
/// Index 2 stays empty because `ff_mpa_quant_bits[2] > 0` (no grouping).
let mpa_division_tabs : Array[Array[Int]] = {
  let tabs : Array[Array[Int]] = []
  for i = 0; i < 4; i = i + 1 {
    let bits = mpa_quant_bits[i]
    if bits < 0 {
      let n = 1 << (-bits + 1)
      let steps = mpa_quant_steps[i]
      let t : Array[Int] = Array::make(n, 0)
      for j = 0; j < n; j = j + 1 {
        let val1 = j % steps
        let v2 = j / steps
        let val2 = v2 % steps
        let val3 = v2 / steps
        t[j] = val1 + (val2 << 4) + (val3 << 8)
      }
      tabs.push(t)
    } else {
      tabs.push([])
    }
  }
  tabs
}
