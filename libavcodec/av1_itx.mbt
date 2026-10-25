///|
/// MoonBit port of dav1d 1.5.1 `src/itx_1d.c` and the generic
/// `inv_txfm_add_c` from `src/itx_tmpl.c` (plus `inv_txfm_add_wht_wht_4x4`).
/// dav1d is BSD-2-Clause (Copyright © 2018, VideoLAN and dav1d authors);
/// FFmpeg integrates it as libdav1d — the reference decoder for AV1 pixels.

///|
/// 1D inverse transform over `c[base + i * stride]`.
/// One entry per (tx_size_log2, Tx1dType) following `dav1d_tx1d_fns`.
/// DCT = 0, ADST = 1, FLIPADST = 2, IDENTITY = 3 (dav1d `enum Tx1dType`).
fn av1_itx_1d(
  lw : Int,
  kind : Int,
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  match (lw, kind) {
    (0, 0) => av1_inv_dct4_1d(c, base, stride, min, max)
    (0, 1) => av1_inv_adst4_1d(c, base, stride, min, max, false)
    (0, 2) => av1_inv_adst4_1d(c, base, stride, min, max, true)
    (0, 3) => av1_inv_identity4_1d(c, base, stride)
    (1, 0) => av1_inv_dct8_1d(c, base, stride, min, max)
    (1, 1) => av1_inv_adst8_1d(c, base, stride, min, max, false)
    (1, 2) => av1_inv_adst8_1d(c, base, stride, min, max, true)
    (1, 3) => av1_inv_identity8_1d(c, base, stride)
    (2, 0) => av1_inv_dct16_1d(c, base, stride, min, max)
    (2, 1) => av1_inv_adst16_1d(c, base, stride, min, max, false)
    (2, 2) => av1_inv_adst16_1d(c, base, stride, min, max, true)
    (2, 3) => av1_inv_identity16_1d(c, base, stride)
    (3, 0) => av1_inv_dct32_1d_internal(c, base, stride, min, max, false)
    (3, 3) => av1_inv_identity32_1d(c, base, stride)
    (4, 0) => av1_inv_dct64_1d(c, base, stride, min, max)
    _ => () // unreachable for valid txtp/tx combos
  }
}

///|
fn clip_i(v : Int, min : Int, max : Int) -> Int {
  if v < min {
    min
  } else if v > max {
    max
  } else {
    v
  }
}

///|
/// `inv_dct4_1d_internal_c` (tx64 variant folded into inv_dct32/64 chain).
fn av1_inv_dct4_1d_internal(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  tx64 : Bool,
) -> Unit {
  let in0 = c[base]
  let in1 = c[base + stride]
  let (t0, t1, t2, t3) = if tx64 {
    let t0 = (in0 * 181 + 128) >> 8
    (t0, t0, (in1 * 1567 + 2048) >> 12, (in1 * 3784 + 2048) >> 12)
  } else {
    let in2 = c[base + 2 * stride]
    let in3 = c[base + 3 * stride]
    (
      ((in0 + in2) * 181 + 128) >> 8,
      ((in0 - in2) * 181 + 128) >> 8,
      ((in1 * 1567 - in3 * (3784 - 4096) + 2048) >> 12) - in3,
      ((in1 * (3784 - 4096) + in3 * 1567 + 2048) >> 12) + in1,
    )
  }
  c[base] = clip_i(t0 + t3, min, max)
  c[base + stride] = clip_i(t1 + t2, min, max)
  c[base + 2 * stride] = clip_i(t1 - t2, min, max)
  c[base + 3 * stride] = clip_i(t0 - t3, min, max)
}

///|
fn av1_inv_dct4_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  av1_inv_dct4_1d_internal(c, base, stride, min, max, false)
}

///|
fn av1_inv_dct8_1d_internal(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  tx64 : Bool,
) -> Unit {
  av1_inv_dct4_1d_internal(c, base, stride << 1, min, max, tx64)
  let in1 = c[base + stride]
  let in3 = c[base + 3 * stride]
  let (t4a, t5a, t6a, t7a) = if tx64 {
    (
      (in1 * 799 + 2048) >> 12,
      (in3 * -2276 + 2048) >> 12,
      (in3 * 3406 + 2048) >> 12,
      (in1 * 4017 + 2048) >> 12,
    )
  } else {
    let in5 = c[base + 5 * stride]
    let in7 = c[base + 7 * stride]
    (
      ((in1 * 799 - in7 * (4017 - 4096) + 2048) >> 12) - in7,
      (in5 * 1703 - in3 * 1138 + 1024) >> 11,
      (in5 * 1138 + in3 * 1703 + 1024) >> 11,
      ((in1 * (4017 - 4096) + in7 * 799 + 2048) >> 12) + in1,
    )
  }
  let t4 = clip_i(t4a + t5a, min, max)
  let t5a2 = clip_i(t4a - t5a, min, max)
  let t7 = clip_i(t7a + t6a, min, max)
  let t6a2 = clip_i(t7a - t6a, min, max)
  let t5 = ((t6a2 - t5a2) * 181 + 128) >> 8
  let t6 = ((t6a2 + t5a2) * 181 + 128) >> 8
  let t0 = c[base]
  let t1 = c[base + 2 * stride]
  let t2 = c[base + 4 * stride]
  let t3 = c[base + 6 * stride]
  c[base] = clip_i(t0 + t7, min, max)
  c[base + stride] = clip_i(t1 + t6, min, max)
  c[base + 2 * stride] = clip_i(t2 + t5, min, max)
  c[base + 3 * stride] = clip_i(t3 + t4, min, max)
  c[base + 4 * stride] = clip_i(t3 - t4, min, max)
  c[base + 5 * stride] = clip_i(t2 - t5, min, max)
  c[base + 6 * stride] = clip_i(t1 - t6, min, max)
  c[base + 7 * stride] = clip_i(t0 - t7, min, max)
}

///|
fn av1_inv_dct8_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  av1_inv_dct8_1d_internal(c, base, stride, min, max, false)
}

///|
fn av1_inv_dct16_1d_internal(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  tx64 : Bool,
) -> Unit {
  av1_inv_dct8_1d_internal(c, base, stride << 1, min, max, tx64)
  let in1 = c[base + stride]
  let in3 = c[base + 3 * stride]
  let in5 = c[base + 5 * stride]
  let in7 = c[base + 7 * stride]
  let (t8a, t9a, t10a, t11a, t12a, t13a, t14a, t15a) = if tx64 {
    (
      (in1 * 401 + 2048) >> 12,
      (in7 * -2598 + 2048) >> 12,
      (in5 * 1931 + 2048) >> 12,
      (in3 * -1189 + 2048) >> 12,
      (in3 * 3920 + 2048) >> 12,
      (in5 * 3612 + 2048) >> 12,
      (in7 * 3166 + 2048) >> 12,
      (in1 * 4076 + 2048) >> 12,
    )
  } else {
    let in9 = c[base + 9 * stride]
    let in11 = c[base + 11 * stride]
    let in13 = c[base + 13 * stride]
    let in15 = c[base + 15 * stride]
    (
      ((in1 * 401 - in15 * (4076 - 4096) + 2048) >> 12) - in15,
      (in9 * 1583 - in7 * 1299 + 1024) >> 11,
      ((in5 * 1931 - in11 * (3612 - 4096) + 2048) >> 12) - in11,
      ((in13 * (3920 - 4096) - in3 * 1189 + 2048) >> 12) + in13,
      ((in13 * 1189 + in3 * (3920 - 4096) + 2048) >> 12) + in3,
      ((in5 * (3612 - 4096) + in11 * 1931 + 2048) >> 12) + in5,
      (in9 * 1299 + in7 * 1583 + 1024) >> 11,
      ((in1 * (4076 - 4096) + in15 * 401 + 2048) >> 12) + in1,
    )
  }
  let t8 = clip_i(t8a + t9a, min, max)
  let t9 = clip_i(t8a - t9a, min, max)
  let t10 = clip_i(t11a - t10a, min, max)
  let t11 = clip_i(t11a + t10a, min, max)
  let t12 = clip_i(t12a + t13a, min, max)
  let t13 = clip_i(t12a - t13a, min, max)
  let t14 = clip_i(t15a - t14a, min, max)
  let t15 = clip_i(t15a + t14a, min, max)
  let t9a2 = ((t14 * 1567 - t9 * (3784 - 4096) + 2048) >> 12) - t9
  let t14a2 = ((t14 * (3784 - 4096) + t9 * 1567 + 2048) >> 12) + t14
  let t10a2 = ((-(t13 * (3784 - 4096) + t10 * 1567) + 2048) >> 12) - t13
  let t13a2 = ((t13 * 1567 - t10 * (3784 - 4096) + 2048) >> 12) - t10
  let t8a2 = clip_i(t8 + t11, min, max)
  let t9_2 = clip_i(t9a2 + t10a2, min, max)
  let t10_2 = clip_i(t9a2 - t10a2, min, max)
  let t11a2 = clip_i(t8 - t11, min, max)
  let t12a2 = clip_i(t15 - t12, min, max)
  let t13_2 = clip_i(t14a2 - t13a2, min, max)
  let t14_2 = clip_i(t14a2 + t13a2, min, max)
  let t15a2 = clip_i(t15 + t12, min, max)
  let t10a3 = ((t13_2 - t10_2) * 181 + 128) >> 8
  let t13a3 = ((t13_2 + t10_2) * 181 + 128) >> 8
  let t11_2 = ((t12a2 - t11a2) * 181 + 128) >> 8
  let t12_2 = ((t12a2 + t11a2) * 181 + 128) >> 8
  let t0 = c[base]
  let t1 = c[base + 2 * stride]
  let t2 = c[base + 4 * stride]
  let t3 = c[base + 6 * stride]
  let t4 = c[base + 8 * stride]
  let t5 = c[base + 10 * stride]
  let t6 = c[base + 12 * stride]
  let t7 = c[base + 14 * stride]
  c[base] = clip_i(t0 + t15a2, min, max)
  c[base + stride] = clip_i(t1 + t14_2, min, max)
  c[base + 2 * stride] = clip_i(t2 + t13a3, min, max)
  c[base + 3 * stride] = clip_i(t3 + t12_2, min, max)
  c[base + 4 * stride] = clip_i(t4 + t11_2, min, max)
  c[base + 5 * stride] = clip_i(t5 + t10a3, min, max)
  c[base + 6 * stride] = clip_i(t6 + t9_2, min, max)
  c[base + 7 * stride] = clip_i(t7 + t8a2, min, max)
  c[base + 8 * stride] = clip_i(t7 - t8a2, min, max)
  c[base + 9 * stride] = clip_i(t6 - t9_2, min, max)
  c[base + 10 * stride] = clip_i(t5 - t10a3, min, max)
  c[base + 11 * stride] = clip_i(t4 - t11_2, min, max)
  c[base + 12 * stride] = clip_i(t3 - t12_2, min, max)
  c[base + 13 * stride] = clip_i(t2 - t13a3, min, max)
  c[base + 14 * stride] = clip_i(t1 - t14_2, min, max)
  c[base + 15 * stride] = clip_i(t0 - t15a2, min, max)
}

///|
fn av1_inv_dct16_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
) -> Unit {
  av1_inv_dct16_1d_internal(c, base, stride, min, max, false)
}

///|
fn av1_inv_dct32_1d_internal(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  tx64 : Bool,
) -> Unit {
  av1_inv_dct16_1d_internal(c, base, stride << 1, min, max, tx64)
  let in1 = c[base + stride]
  let in3 = c[base + 3 * stride]
  let in5 = c[base + 5 * stride]
  let in7 = c[base + 7 * stride]
  let in9 = c[base + 9 * stride]
  let in11 = c[base + 11 * stride]
  let in13 = c[base + 13 * stride]
  let in15 = c[base + 15 * stride]
  let (t16a, t17a, t18a, t19a, t20a, t21a, t22a, t23a, t24a, t25a, t26a, t27a, t28a, t29a, t30a, t31a) = if tx64 {
    (
      (in1 * 201 + 2048) >> 12,
      (in15 * -2751 + 2048) >> 12,
      (in9 * 1751 + 2048) >> 12,
      (in7 * -1380 + 2048) >> 12,
      (in5 * 995 + 2048) >> 12,
      (in11 * -2106 + 2048) >> 12,
      (in13 * 2440 + 2048) >> 12,
      (in3 * -601 + 2048) >> 12,
      (in3 * 4052 + 2048) >> 12,
      (in13 * 3290 + 2048) >> 12,
      (in11 * 3513 + 2048) >> 12,
      (in5 * 3973 + 2048) >> 12,
      (in7 * 3857 + 2048) >> 12,
      (in9 * 3703 + 2048) >> 12,
      (in15 * 3035 + 2048) >> 12,
      (in1 * 4091 + 2048) >> 12,
    )
  } else {
    let in17 = c[base + 17 * stride]
    let in19 = c[base + 19 * stride]
    let in21 = c[base + 21 * stride]
    let in23 = c[base + 23 * stride]
    let in25 = c[base + 25 * stride]
    let in27 = c[base + 27 * stride]
    let in29 = c[base + 29 * stride]
    let in31 = c[base + 31 * stride]
    (
      ((in1 * 201 - in31 * (4091 - 4096) + 2048) >> 12) - in31,
      ((in17 * (3035 - 4096) - in15 * 2751 + 2048) >> 12) + in17,
      ((in9 * 1751 - in23 * (3703 - 4096) + 2048) >> 12) - in23,
      ((in25 * (3857 - 4096) - in7 * 1380 + 2048) >> 12) + in25,
      ((in5 * 995 - in27 * (3973 - 4096) + 2048) >> 12) - in27,
      ((in21 * (3513 - 4096) - in11 * 2106 + 2048) >> 12) + in21,
      (in13 * 1220 - in19 * 1645 + 1024) >> 11,
      ((in29 * (4052 - 4096) - in3 * 601 + 2048) >> 12) + in29,
      ((in29 * 601 + in3 * (4052 - 4096) + 2048) >> 12) + in3,
      (in13 * 1645 + in19 * 1220 + 1024) >> 11,
      ((in21 * 2106 + in11 * (3513 - 4096) + 2048) >> 12) + in11,
      ((in5 * (3973 - 4096) + in27 * 995 + 2048) >> 12) + in5,
      ((in25 * 1380 + in7 * (3857 - 4096) + 2048) >> 12) + in7,
      ((in9 * (3703 - 4096) + in23 * 1751 + 2048) >> 12) + in9,
      ((in17 * 2751 + in15 * (3035 - 4096) + 2048) >> 12) + in15,
      ((in1 * (4091 - 4096) + in31 * 201 + 2048) >> 12) + in1,
    )
  }
  let t16 = clip_i(t16a + t17a, min, max)
  let t17 = clip_i(t16a - t17a, min, max)
  let t18 = clip_i(t19a - t18a, min, max)
  let t19 = clip_i(t19a + t18a, min, max)
  let t20 = clip_i(t20a + t21a, min, max)
  let t21 = clip_i(t20a - t21a, min, max)
  let t22 = clip_i(t23a - t22a, min, max)
  let t23 = clip_i(t23a + t22a, min, max)
  let t24 = clip_i(t24a + t25a, min, max)
  let t25 = clip_i(t24a - t25a, min, max)
  let t26 = clip_i(t27a - t26a, min, max)
  let t27 = clip_i(t27a + t26a, min, max)
  let t28 = clip_i(t28a + t29a, min, max)
  let t29 = clip_i(t28a - t29a, min, max)
  let t30 = clip_i(t31a - t30a, min, max)
  let t31 = clip_i(t31a + t30a, min, max)
  let t17a2 = ((t30 * 799 - t17 * (4017 - 4096) + 2048) >> 12) - t17
  let t30a2 = ((t30 * (4017 - 4096) + t17 * 799 + 2048) >> 12) + t30
  let t18a2 = ((-(t29 * (4017 - 4096) + t18 * 799) + 2048) >> 12) - t29
  let t29a2 = ((t29 * 799 - t18 * (4017 - 4096) + 2048) >> 12) - t18
  let t21a2 = (t26 * 1703 - t21 * 1138 + 1024) >> 11
  let t26a2 = (t26 * 1138 + t21 * 1703 + 1024) >> 11
  let t22a2 = (-(t25 * 1138 + t22 * 1703) + 1024) >> 11
  let t25a2 = (t25 * 1703 - t22 * 1138 + 1024) >> 11
  let t16a2 = clip_i(t16 + t19, min, max)
  let t17_2 = clip_i(t17a2 + t18a2, min, max)
  let t18_2 = clip_i(t17a2 - t18a2, min, max)
  let t19a2 = clip_i(t16 - t19, min, max)
  let t20a2 = clip_i(t23 - t20, min, max)
  let t21_2 = clip_i(t22a2 - t21a2, min, max)
  let t22_2 = clip_i(t22a2 + t21a2, min, max)
  let t23a2 = clip_i(t23 + t20, min, max)
  let t24a2 = clip_i(t24 + t27, min, max)
  let t25_2 = clip_i(t25a2 + t26a2, min, max)
  let t26_2 = clip_i(t25a2 - t26a2, min, max)
  let t27a2 = clip_i(t24 - t27, min, max)
  let t28a2 = clip_i(t31 - t28, min, max)
  let t29_2 = clip_i(t30a2 - t29a2, min, max)
  let t30_2 = clip_i(t30a2 + t29a2, min, max)
  let t31a2 = clip_i(t31 + t28, min, max)
  let t18a3 = ((t29_2 * 1567 - t18_2 * (3784 - 4096) + 2048) >> 12) - t18_2
  let t29a3 = ((t29_2 * (3784 - 4096) + t18_2 * 1567 + 2048) >> 12) + t29_2
  let t19_2x = ((t28a2 * 1567 - t19a2 * (3784 - 4096) + 2048) >> 12) - t19a2
  let t28_2 = ((t28a2 * (3784 - 4096) + t19a2 * 1567 + 2048) >> 12) + t28a2
  let t20_2 = ((-(t27a2 * (3784 - 4096) + t20a2 * 1567) + 2048) >> 12) - t27a2
  let t27_2 = ((t27a2 * 1567 - t20a2 * (3784 - 4096) + 2048) >> 12) - t20a2
  let t21a3 = ((-(t26_2 * (3784 - 4096) + t21_2 * 1567) + 2048) >> 12) - t26_2
  let t26a3 = ((t26_2 * 1567 - t21_2 * (3784 - 4096) + 2048) >> 12) - t21_2
  let t16_2 = clip_i(t16a2 + t23a2, min, max)
  let t17a3 = clip_i(t17_2 + t22_2, min, max)
  let t18_3 = clip_i(t18a3 + t21a3, min, max)
  let t19a3 = clip_i(t19_2x + t20_2, min, max)
  let t20a3 = clip_i(t19_2x - t20_2, min, max)
  let t21_3 = clip_i(t18a3 - t21a3, min, max)
  let t22a3 = clip_i(t17_2 - t22_2, min, max)
  let t23_2 = clip_i(t16a2 - t23a2, min, max)
  let t24_2 = clip_i(t31a2 - t24a2, min, max)
  let t25a3 = clip_i(t30_2 - t25_2, min, max)
  let t26_3 = clip_i(t29a3 - t26a3, min, max)
  let t27a3 = clip_i(t28_2 - t27_2, min, max)
  let t28a3 = clip_i(t28_2 + t27_2, min, max)
  let t29_3 = clip_i(t29a3 + t26a3, min, max)
  let t30a3 = clip_i(t30_2 + t25_2, min, max)
  let t31_2 = clip_i(t31a2 + t24a2, min, max)
  let t20_3 = ((t27a3 - t20a3) * 181 + 128) >> 8
  let t27_3 = ((t27a3 + t20a3) * 181 + 128) >> 8
  let t21a4 = ((t26_3 - t21_3) * 181 + 128) >> 8
  let t26a4 = ((t26_3 + t21_3) * 181 + 128) >> 8
  let t22_3 = ((t25a3 - t22a3) * 181 + 128) >> 8
  let t25_3 = ((t25a3 + t22a3) * 181 + 128) >> 8
  let t23a4 = ((t24_2 - t23_2) * 181 + 128) >> 8
  let t24a3 = ((t24_2 + t23_2) * 181 + 128) >> 8
  let t0 = c[base]
  let t1 = c[base + 2 * stride]
  let t2 = c[base + 4 * stride]
  let t3 = c[base + 6 * stride]
  let t4 = c[base + 8 * stride]
  let t5 = c[base + 10 * stride]
  let t6 = c[base + 12 * stride]
  let t7 = c[base + 14 * stride]
  let t8 = c[base + 16 * stride]
  let t9 = c[base + 18 * stride]
  let t10 = c[base + 20 * stride]
  let t11 = c[base + 22 * stride]
  let t12 = c[base + 24 * stride]
  let t13 = c[base + 26 * stride]
  let t14 = c[base + 28 * stride]
  let t15 = c[base + 30 * stride]
  c[base] = clip_i(t0 + t31_2, min, max)
  c[base + stride] = clip_i(t1 + t30a3, min, max)
  c[base + 2 * stride] = clip_i(t2 + t29_3, min, max)
  c[base + 3 * stride] = clip_i(t3 + t28a3, min, max)
  c[base + 4 * stride] = clip_i(t4 + t27_3, min, max)
  c[base + 5 * stride] = clip_i(t5 + t26a4, min, max)
  c[base + 6 * stride] = clip_i(t6 + t25_3, min, max)
  c[base + 7 * stride] = clip_i(t7 + t24a3, min, max)
  c[base + 8 * stride] = clip_i(t8 + t23a4, min, max)
  c[base + 9 * stride] = clip_i(t9 + t22_3, min, max)
  c[base + 10 * stride] = clip_i(t10 + t21a4, min, max)
  c[base + 11 * stride] = clip_i(t11 + t20_3, min, max)
  c[base + 12 * stride] = clip_i(t12 + t19a3, min, max)
  c[base + 13 * stride] = clip_i(t13 + t18_3, min, max)
  c[base + 14 * stride] = clip_i(t14 + t17a3, min, max)
  c[base + 15 * stride] = clip_i(t15 + t16_2, min, max)
  c[base + 16 * stride] = clip_i(t15 - t16_2, min, max)
  c[base + 17 * stride] = clip_i(t14 - t17a3, min, max)
  c[base + 18 * stride] = clip_i(t13 - t18_3, min, max)
  c[base + 19 * stride] = clip_i(t12 - t19a3, min, max)
  c[base + 20 * stride] = clip_i(t11 - t20_3, min, max)
  c[base + 21 * stride] = clip_i(t10 - t21a4, min, max)
  c[base + 22 * stride] = clip_i(t9 - t22_3, min, max)
  c[base + 23 * stride] = clip_i(t8 - t23a4, min, max)
  c[base + 24 * stride] = clip_i(t7 - t24a3, min, max)
  c[base + 25 * stride] = clip_i(t6 - t25_3, min, max)
  c[base + 26 * stride] = clip_i(t5 - t26a4, min, max)
  c[base + 27 * stride] = clip_i(t4 - t27_3, min, max)
  c[base + 28 * stride] = clip_i(t3 - t28a3, min, max)
  c[base + 29 * stride] = clip_i(t2 - t29_3, min, max)
  c[base + 30 * stride] = clip_i(t1 - t30a3, min, max)
  c[base + 31 * stride] = clip_i(t0 - t31_2, min, max)
}

///|
fn av1_inv_identity4_1d(c : FixedArray[Int], base : Int, stride : Int) -> Unit {
  for i in 0..<4 {
    let x = base + stride * i
    let v = c[x]
    c[x] = v + ((v * 1697 + 2048) >> 12)
  }
}

///|
fn av1_inv_identity8_1d(c : FixedArray[Int], base : Int, stride : Int) -> Unit {
  for i in 0..<8 {
    let x = base + stride * i
    c[x] = c[x] * 2
  }
}

///|
fn av1_inv_identity16_1d(c : FixedArray[Int], base : Int, stride : Int) -> Unit {
  for i in 0..<16 {
    let x = base + stride * i
    let v = c[x]
    c[x] = 2 * v + ((v * 1697 + 1024) >> 11)
  }
}

///|
fn av1_inv_identity32_1d(c : FixedArray[Int], base : Int, stride : Int) -> Unit {
  for i in 0..<32 {
    let x = base + stride * i
    c[x] = c[x] * 4
  }
}

///|
/// `inv_adst4_1d_internal_c`; flip is the FLIPADST output order.
fn av1_inv_adst4_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  flip : Bool,
) -> Unit {
  let in0 = c[base]
  let in1 = c[base + stride]
  let in2 = c[base + 2 * stride]
  let in3 = c[base + 3 * stride]
  let o0 = ((1321 * in0 + (3803 - 4096) * in2 + (2482 - 4096) * in3 +
      (3344 - 4096) * in1 + 2048) >> 12) + in2 + in3 + in1
  let o1 = (((2482 - 4096) * in0 - 1321 * in2 - (3803 - 4096) * in3 +
      (3344 - 4096) * in1 + 2048) >> 12) + in0 - in3 + in1
  let o2 = (209 * (in0 - in2 + in3) + 128) >> 8
  let o3 = (((3803 - 4096) * in0 + (2482 - 4096) * in2 - 1321 * in3 -
      (3344 - 4096) * in1 + 2048) >> 12) + in0 + in2 - in1
  let s0 = clip_i(o0, min, max)
  let s1 = clip_i(o1, min, max)
  let s2 = clip_i(o2, min, max)
  let s3 = clip_i(o3, min, max)
  if flip {
    c[base + 3 * stride] = s0
    c[base + 2 * stride] = s1
    c[base + stride] = s2
    c[base] = s3
  } else {
    c[base] = s0
    c[base + stride] = s1
    c[base + 2 * stride] = s2
    c[base + 3 * stride] = s3
  }
}

///|
/// `inv_adst8_1d_internal_c`.
fn av1_inv_adst8_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  flip : Bool,
) -> Unit {
  let in0 = c[base]
  let in1 = c[base + stride]
  let in2 = c[base + 2 * stride]
  let in3 = c[base + 3 * stride]
  let in4 = c[base + 4 * stride]
  let in5 = c[base + 5 * stride]
  let in6 = c[base + 6 * stride]
  let in7 = c[base + 7 * stride]
  let t0a = (((4076 - 4096) * in7 + 401 * in0 + 2048) >> 12) + in7
  let t1a = ((401 * in7 - (4076 - 4096) * in0 + 2048) >> 12) - in0
  let t2a = (((3612 - 4096) * in5 + 1931 * in2 + 2048) >> 12) + in5
  let t3a = ((1931 * in5 - (3612 - 4096) * in2 + 2048) >> 12) - in2
  let mut t4a = (1299 * in3 + 1583 * in4 + 1024) >> 11
  let mut t5a = (1583 * in3 - 1299 * in4 + 1024) >> 11
  let mut t6a = ((1189 * in1 + (3920 - 4096) * in6 + 2048) >> 12) + in6
  let mut t7a = (((3920 - 4096) * in1 - 1189 * in6 + 2048) >> 12) + in1
  let t0 = clip_i(t0a + t4a, min, max)
  let t1 = clip_i(t1a + t5a, min, max)
  let mut t2 = clip_i(t2a + t6a, min, max)
  let mut t3 = clip_i(t3a + t7a, min, max)
  let t4 = clip_i(t0a - t4a, min, max)
  let t5 = clip_i(t1a - t5a, min, max)
  let mut t6 = clip_i(t2a - t6a, min, max)
  let mut t7 = clip_i(t3a - t7a, min, max)
  t4a = (((3784 - 4096) * t4 + 1567 * t5 + 2048) >> 12) + t4
  t5a = ((1567 * t4 - (3784 - 4096) * t5 + 2048) >> 12) - t5
  t6a = (((3784 - 4096) * t7 - 1567 * t6 + 2048) >> 12) + t7
  t7a = ((1567 * t7 + (3784 - 4096) * t6 + 2048) >> 12) + t6
  let o0 = clip_i(t0 + t2, min, max)
  let o7 = -(clip_i(t1 + t3, min, max))
  t2 = clip_i(t0 - t2, min, max)
  t3 = clip_i(t1 - t3, min, max)
  let o1 = -(clip_i(t4a + t6a, min, max))
  let o6 = clip_i(t5a + t7a, min, max)
  t6 = clip_i(t4a - t6a, min, max)
  t7 = clip_i(t5a - t7a, min, max)
  let o3 = -(((t2 + t3) * 181 + 128) >> 8)
  let o4 = ((t2 - t3) * 181 + 128) >> 8
  let o2 = ((t6 + t7) * 181 + 128) >> 8
  let o5 = -(((t6 - t7) * 181 + 128) >> 8)
  if flip {
    c[base + 7 * stride] = o0
    c[base + 6 * stride] = o1
    c[base + 5 * stride] = o2
    c[base + 4 * stride] = o3
    c[base + 3 * stride] = o4
    c[base + 2 * stride] = o5
    c[base + stride] = o6
    c[base] = o7
  } else {
    c[base] = o0
    c[base + stride] = o1
    c[base + 2 * stride] = o2
    c[base + 3 * stride] = o3
    c[base + 4 * stride] = o4
    c[base + 5 * stride] = o5
    c[base + 6 * stride] = o6
    c[base + 7 * stride] = o7
  }
}

///|
/// `inv_adst16_1d_internal_c`.
fn av1_inv_adst16_1d(
  c : FixedArray[Int],
  base : Int,
  stride : Int,
  min : Int,
  max : Int,
  flip : Bool,
) -> Unit {
  let inp = FixedArray::make(16, 0)
  for i in 0..<16 {
    inp[i] = c[base + i * stride]
  }
  let t = FixedArray::make(16, 0)
  t[0] = ((inp[15] * (4091 - 4096) + inp[0] * 201 + 2048) >> 12) + inp[15]
  t[1] = ((inp[15] * 201 - inp[0] * (4091 - 4096) + 2048) >> 12) - inp[0]
  t[2] = ((inp[13] * (3973 - 4096) + inp[2] * 995 + 2048) >> 12) + inp[13]
  t[3] = ((inp[13] * 995 - inp[2] * (3973 - 4096) + 2048) >> 12) - inp[2]
  t[4] = ((inp[11] * (3703 - 4096) + inp[4] * 1751 + 2048) >> 12) + inp[11]
  t[5] = ((inp[11] * 1751 - inp[4] * (3703 - 4096) + 2048) >> 12) - inp[4]
  t[6] = (inp[9] * 1645 + inp[6] * 1220 + 1024) >> 11
  t[7] = (inp[9] * 1220 - inp[6] * 1645 + 1024) >> 11
  t[8] = ((inp[7] * 2751 + inp[8] * (3035 - 4096) + 2048) >> 12) + inp[8]
  t[9] = ((inp[7] * (3035 - 4096) - inp[8] * 2751 + 2048) >> 12) + inp[7]
  t[10] = ((inp[5] * 2106 + inp[10] * (3513 - 4096) + 2048) >> 12) + inp[10]
  t[11] = ((inp[5] * (3513 - 4096) - inp[10] * 2106 + 2048) >> 12) + inp[5]
  t[12] = ((inp[3] * 1380 + inp[12] * (3857 - 4096) + 2048) >> 12) + inp[12]
  t[13] = ((inp[3] * (3857 - 4096) - inp[12] * 1380 + 2048) >> 12) + inp[3]
  t[14] = ((inp[1] * 601 + inp[14] * (4052 - 4096) + 2048) >> 12) + inp[14]
  t[15] = ((inp[1] * (4052 - 4096) - inp[14] * 601 + 2048) >> 12) + inp[1]
  let ta = FixedArray::make(16, 0)
  ta[0] = clip_i(t[0] + t[8], min, max)
  ta[1] = clip_i(t[1] + t[9], min, max)
  ta[2] = clip_i(t[2] + t[10], min, max)
  ta[3] = clip_i(t[3] + t[11], min, max)
  ta[4] = clip_i(t[4] + t[12], min, max)
  ta[5] = clip_i(t[5] + t[13], min, max)
  ta[6] = clip_i(t[6] + t[14], min, max)
  ta[7] = clip_i(t[7] + t[15], min, max)
  ta[8] = clip_i(t[0] - t[8], min, max)
  ta[9] = clip_i(t[1] - t[9], min, max)
  ta[10] = clip_i(t[2] - t[10], min, max)
  ta[11] = clip_i(t[3] - t[11], min, max)
  ta[12] = clip_i(t[4] - t[12], min, max)
  ta[13] = clip_i(t[5] - t[13], min, max)
  ta[14] = clip_i(t[6] - t[14], min, max)
  ta[15] = clip_i(t[7] - t[15], min, max)
  t[8] = ((ta[8] * (4017 - 4096) + ta[9] * 799 + 2048) >> 12) + ta[8]
  t[9] = ((ta[8] * 799 - ta[9] * (4017 - 4096) + 2048) >> 12) - ta[9]
  t[10] = ((ta[10] * 2276 + ta[11] * (3406 - 4096) + 2048) >> 12) + ta[11]
  t[11] = ((ta[10] * (3406 - 4096) - ta[11] * 2276 + 2048) >> 12) + ta[10]
  t[12] = ((ta[13] * (4017 - 4096) - ta[12] * 799 + 2048) >> 12) + ta[13]
  t[13] = ((ta[13] * 799 + ta[12] * (4017 - 4096) + 2048) >> 12) + ta[12]
  t[14] = ((ta[15] * 2276 - ta[14] * (3406 - 4096) + 2048) >> 12) - ta[14]
  t[15] = ((ta[15] * (3406 - 4096) + ta[14] * 2276 + 2048) >> 12) + ta[15]
  t[0] = clip_i(ta[0] + ta[4], min, max)
  t[1] = clip_i(ta[1] + ta[5], min, max)
  t[2] = clip_i(ta[2] + ta[6], min, max)
  t[3] = clip_i(ta[3] + ta[7], min, max)
  t[4] = clip_i(ta[0] - ta[4], min, max)
  t[5] = clip_i(ta[1] - ta[5], min, max)
  t[6] = clip_i(ta[2] - ta[6], min, max)
  t[7] = clip_i(ta[3] - ta[7], min, max)
  ta[8] = clip_i(t[8] + t[12], min, max)
  ta[9] = clip_i(t[9] + t[13], min, max)
  ta[10] = clip_i(t[10] + t[14], min, max)
  ta[11] = clip_i(t[11] + t[15], min, max)
  ta[12] = clip_i(t[8] - t[12], min, max)
  ta[13] = clip_i(t[9] - t[13], min, max)
  ta[14] = clip_i(t[10] - t[14], min, max)
  ta[15] = clip_i(t[11] - t[15], min, max)
  let t4r = ((t[4] * (3784 - 4096) + t[5] * 1567 + 2048) >> 12) + t[4]
  let t5r = ((t[4] * 1567 - t[5] * (3784 - 4096) + 2048) >> 12) - t[5]
  let t6r = ((t[7] * (3784 - 4096) - t[6] * 1567 + 2048) >> 12) + t[7]
  let t7r = ((t[7] * 1567 + t[6] * (3784 - 4096) + 2048) >> 12) + t[6]
  t[4] = t4r
  t[5] = t5r
  t[6] = t6r
  t[7] = t7r
  t[12] = ((ta[12] * (3784 - 4096) + ta[13] * 1567 + 2048) >> 12) + ta[12]
  t[13] = ((ta[12] * 1567 - ta[13] * (3784 - 4096) + 2048) >> 12) - ta[13]
  t[14] = ((ta[15] * (3784 - 4096) - ta[14] * 1567 + 2048) >> 12) + ta[15]
  t[15] = ((ta[15] * 1567 + ta[14] * (3784 - 4096) + 2048) >> 12) + ta[14]
  let o = FixedArray::make(16, 0)
  o[0] = clip_i(t[0] + t[2], min, max)
  o[15] = -(clip_i(t[1] + t[3], min, max))
  let t2a = clip_i(t[0] - t[2], min, max)
  let t3a = clip_i(t[1] - t[3], min, max)
  o[3] = -(clip_i(t[4] + t[6], min, max))
  o[12] = clip_i(t[5] + t[7], min, max)
  let t6 = clip_i(t[4] - t[6], min, max)
  let t7 = clip_i(t[5] - t[7], min, max)
  o[1] = -(clip_i(ta[8] + ta[10], min, max))
  o[14] = clip_i(ta[9] + ta[11], min, max)
  let t10 = clip_i(ta[8] - ta[10], min, max)
  let t11 = clip_i(ta[9] - ta[11], min, max)
  o[2] = clip_i(t[12] + t[14], min, max)
  o[13] = -(clip_i(t[13] + t[15], min, max))
  let t14a = clip_i(t[12] - t[14], min, max)
  let t15a = clip_i(t[13] - t[15], min, max)
  o[7] = -(((t2a + t3a) * 181 + 128) >> 8)
  o[8] = ((t2a - t3a) * 181 + 128) >> 8
  o[4] = ((t6 + t7) * 181 + 128) >> 8
  o[11] = -(((t6 - t7) * 181 + 128) >> 8)
  o[6] = ((t10 + t11) * 181 + 128) >> 8
  o[9] = -(((t10 - t11) * 181 + 128) >> 8)
  o[5] = -(((t14a + t15a) * 181 + 128) >> 8)
  o[10] = ((t14a - t15a) * 181 + 128) >> 8
  for i in 0..<16 {
    let idx = if flip { 15 - i } else { i }
    c[base + idx * stride] = o[i]
  }
}

///|
/// `dav1d_inv_wht4_1d_c`.
fn av1_inv_wht4_1d(c : FixedArray[Int], base : Int, stride : Int) -> Unit {
  let in0 = c[base]
  let in1 = c[base + stride]
  let in2 = c[base + 2 * stride]
  let in3 = c[base + 3 * stride]
  let t0 = in0 + in1
  let t2 = in2 - in3
  let t4 = (t0 - t2) >> 1
  let t3 = t4 - in3
  let t1 = t4 - in1
  c[base] = t0 - t3
  c[base + stride] = t3
  c[base + 2 * stride] = t1
  c[base + 3 * stride] = t2 + t1
}

///|
/// `inv_txfm_add_wht_wht_4x4_c`: lossless inverse transform + add.
fn av1_inv_txfm_add_wht_wht_4x4(
  dst : FixedArray[Int],
  dst_off : Int,
  dst_stride : Int,
  coeff : FixedArray[Int],
  bd_max : Int,
) -> Unit {
  let tmp = FixedArray::make(16, 0)
  for y in 0..<4 {
    for x in 0..<4 {
      tmp[y * 4 + x] = coeff[y + x * 4] >> 2
    }
    av1_inv_wht4_1d(tmp, y * 4, 1)
  }
  for i in 0..<16 {
    coeff[i] = 0
  }
  for x in 0..<4 {
    av1_inv_wht4_1d(tmp, x, 4)
  }
  let mut i = 0
  for y in 0..<4 {
    for x in 0..<4 {
      let v = dst[dst_off + y * dst_stride + x] + tmp[i]
      i = i + 1
      dst[dst_off + y * dst_stride + x] = av1_clip_px(v, bd_max)
    }
  }
}

///|
fn av1_clip_px(v : Int, bd_max : Int) -> Int {
  if v < 0 {
    0
  } else if v > bd_max {
    bd_max
  } else {
    v
  }
}

///|
/// Generic `inv_txfm_add_c` from dav1d itx_tmpl.c. `tx` is a RectTxfmSize,
/// `txtp` a TxfmType. `shift` comes from the itxfm_fn table.
fn av1_inv_txfm_add(
  dst : FixedArray[Int],
  dst_off : Int,
  dst_stride : Int,
  coeff : FixedArray[Int],
  eob : Int,
  tx : Int,
  shift : Int,
  txtp : Int,
  bd_max : Int,
) -> Unit {
  let lw = av1_txfm_info(tx, 2)
  let lh = av1_txfm_info(tx, 3)
  let w = 4 << lw
  let h = 4 << lh
  let has_dconly = txtp == 0 // DCT_DCT
  let is_rect2 = w * 2 == h || h * 2 == w
  let rnd = (1 << shift) >> 1
  if eob < (if has_dconly { 1 } else { 0 }) {
    let mut dc = coeff[0]
    coeff[0] = 0
    if is_rect2 {
      dc = (dc * 181 + 128) >> 8
    }
    dc = (dc * 181 + 128) >> 8
    dc = (dc + rnd) >> shift
    dc = (dc * 181 + 128 + 2048) >> 12
    for y in 0..<h {
      for x in 0..<w {
        let p = dst_off + y * dst_stride + x
        dst[p] = av1_clip_px(dst[p] + dc, bd_max)
      }
    }
    return
  }
  let txtps0 = av1_tx1d_types[txtp * 2].to_int()
  let txtps1 = av1_tx1d_types[txtp * 2 + 1].to_int()
  let sh = if h < 32 { h } else { 32 }
  let sw = if w < 32 { w } else { 32 }
  // 8-bit: row/col clip range is int16.
  let clip_min = -32768
  let clip_max = 32767
  let tmp = FixedArray::make(64 * 64, 0)
  let last_nonzero_col = if txtps1 == 3 && txtps0 != 3 {
    if sh - 1 < eob { sh - 1 } else { eob }
  } else if txtps0 == 3 && txtps1 != 3 {
    eob >> (lw + 2)
  } else {
    av1_lnz(tx, eob)
  }
  for y in 0..=last_nonzero_col {
    let cbase = y * w
    if is_rect2 {
      for x in 0..<sw {
        tmp[cbase + x] = (coeff[y + x * sh] * 181 + 128) >> 8
      }
    } else {
      for x in 0..<sw {
        tmp[cbase + x] = coeff[y + x * sh]
      }
    }
    av1_itx_1d(lw, txtps0, tmp, cbase, 1, clip_min, clip_max)
  }
  for i in ((last_nonzero_col + 1) * w)..<(sh * w) {
    tmp[i] = 0
  }
  for i in 0..<(sw * sh) {
    coeff[i] = 0
  }
  for i in 0..<(w * sh) {
    tmp[i] = clip_i((tmp[i] + rnd) >> shift, clip_min, clip_max)
  }
  for x in 0..<w {
    av1_itx_1d(lh, txtps1, tmp, x, w, clip_min, clip_max)
  }
  let mut i = 0
  for y in 0..<h {
    for x in 0..<w {
      let p = dst_off + y * dst_stride + x
      dst[p] = av1_clip_px(dst[p] + ((tmp[i] + 8) >> 4), bd_max)
      i = i + 1
    }
  }
}

///|
/// `itxfm_add` dispatch: WHT_WHT special-cased, shift per dav1d's macro
/// table (`inv_txfm_fn(w, h, shift)`).
pub fn av1_itxfm_add(
  dst : FixedArray[Int],
  dst_off : Int,
  dst_stride : Int,
  coeff : FixedArray[Int],
  eob : Int,
  tx : Int,
  txtp : Int,
  bd_max : Int,
) -> Unit {
  if tx == 0 && txtp == 16 {
    // TX_4X4 + WHT_WHT (lossless)
    av1_inv_txfm_add_wht_wht_4x4(dst, dst_off, dst_stride, coeff, bd_max)
    return
  }
  let lw = av1_txfm_info(tx, 2)
  let lh = av1_txfm_info(tx, 3)
  let shift = av1_itx_shift(lw, lh)
  av1_inv_txfm_add(
    dst, dst_off, dst_stride, coeff, eob, tx, shift, txtp, bd_max,
  )
}

///|
/// Shift table from `inv_txfm_fn84( , 4, 4, 0)` etc.
fn av1_itx_shift(lw : Int, lh : Int) -> Int {
  match (lw, lh) {
    (0, 0) => 0 // 4x4
    (0, 1) => 0 // 4x8
    (0, 2) => 1 // 4x16
    (1, 0) => 0 // 8x4
    (1, 1) => 1 // 8x8
    (1, 2) => 1 // 8x16
    (1, 3) => 2 // 8x32
    (2, 0) => 1 // 16x4
    (2, 1) => 1 // 16x8
    (2, 2) => 2 // 16x16
    (2, 3) => 1 // 16x32
    (2, 4) => 2 // 16x64
    (3, 1) => 2 // 32x8
    (3, 2) => 1 // 32x16
    (3, 3) => 2 // 32x32
    (3, 4) => 1 // 32x64
    (4, 2) => 2 // 64x16
    (4, 3) => 1 // 64x32
    (4, 4) => 2 // 64x64
    _ => 0
  }
}
