///|
/// MoonBit port of the VP9 sample reconstruction kernels from FFmpeg 9.0.2
/// `libavcodec/vp9dsp_template.c` (8-bit path): intra prediction, inverse
/// transforms (DCT/ADST/IWHT + DC-only fast paths) and the loop-filter core.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Planes are `FixedArray[Int32]` with a stride; the `top` edge buffer holds
/// the above-left pixel at index 0 and the above row at 1..64 (the C reads
/// `top[-1]`), the `left` buffer is stored bottom-most first like the C.

///|
fn vp9_clip_pixel8(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// `av_clip_intp2` for the loop filter (bits = 7 for 8-bit). */
fn vp9_clip_intp2_8(v : Int32) -> Int32 {
  if (v + 128).reinterpret_as_uint() > 255U {
    (v >> 31) ^ 127
  } else {
    v
  }
}

///|
/// `FFABS`. */
fn vp9_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// `FFMIN`. */
fn vp9_min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// `DST(x, y)` accessor. */
fn vp9_dst_set(p : FixedArray[Int32], off : Int32, stride : Int32, x : Int32, y : Int32, v : Int32) -> Unit {
  p[off + x + y * stride] = v
}

///|
/// Intra mode numbers (`enum IntraPredMode`): the base ten modes 0..9 plus
/// the availability-derived variants 10..14. */
const VP9_VERT_PRED : Int32 = 0
const VP9_HOR_PRED : Int32 = 1
const VP9_DC_PRED : Int32 = 2
const VP9_DIAG_DOWN_LEFT_PRED : Int32 = 3
const VP9_DIAG_DOWN_RIGHT_PRED : Int32 = 4
const VP9_VERT_RIGHT_PRED : Int32 = 5
const VP9_HOR_DOWN_PRED : Int32 = 6
const VP9_VERT_LEFT_PRED : Int32 = 7
const VP9_HOR_UP_PRED : Int32 = 8
const VP9_TM_VP8_PRED : Int32 = 9
const VP9_LEFT_DC_PRED : Int32 = 10
const VP9_TOP_DC_PRED : Int32 = 11
const VP9_DC_128_PRED : Int32 = 12
const VP9_DC_127_PRED : Int32 = 13

///|
fn vp9_pred_vert(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  for y in 0..<n {
    for x in 0..<n {
      p[off + x + y * stride] = top[1 + x]
    }
  }
}

///|
fn vp9_pred_hor(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32]) -> Unit {
  for y in 0..<n {
    let v = left[n - 1 - y]
    for x in 0..<n {
      p[off + x + y * stride] = v
    }
  }
}

///|
fn vp9_pred_tm(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let tl = top[0]
  for y in 0..<n {
    let l_m_tl = left[n - 1 - y] - tl
    for x in 0..<n {
      p[off + x + y * stride] = vp9_clip_pixel8(top[1 + x] + l_m_tl)
    }
  }
}

///|
fn vp9_pred_dc(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let mut sum = n
  for i in 0..<n {
    sum += left[i] + top[1 + i]
  }
  let dc = sum >> (if n == 16 {
    5
  } else if n == 32 {
    6
  } else if n == 8 {
    4
  } else {
    3
  })
  for y in 0..<n {
    for x in 0..<n {
      p[off + x + y * stride] = dc
    }
  }
}

///|
fn vp9_pred_dc_left(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32]) -> Unit {
  let mut sum = n >> 1
  for i in 0..<n {
    sum += left[i]
  }
  let dc = sum >> (if n == 16 {
    4
  } else if n == 32 {
    5
  } else if n == 8 {
    3
  } else {
    2
  })
  for y in 0..<n {
    for x in 0..<n {
      p[off + x + y * stride] = dc
    }
  }
}

///|
fn vp9_pred_dc_top(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  let mut sum = n >> 1
  for i in 0..<n {
    sum += top[1 + i]
  }
  let dc = sum >> (if n == 16 {
    4
  } else if n == 32 {
    5
  } else if n == 8 {
    3
  } else {
    2
  })
  for y in 0..<n {
    for x in 0..<n {
      p[off + x + y * stride] = dc
    }
  }
}

///|
fn vp9_pred_dc_const(val : Int32, n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32) -> Unit {
  for y in 0..<n {
    for x in 0..<n {
      p[off + x + y * stride] = val
    }
  }
}

///|
/// `def_diag_downleft(size)`; the 4x4 form is separate in the C. */
fn vp9_pred_diag_downleft(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  let v : FixedArray[Int32] = FixedArray::make(n, 0)
  for i in 0..<(n - 2) {
    v[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
  }
  v[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
  for j in 0..<n {
    for i in 0..<(n - 1 - j) {
      p[off + i + j * stride] = v[j + i]
    }
    for i in (n - 1 - j)..<n {
      p[off + i + j * stride] = top[n]
    }
  }
}

///|
fn vp9_pred_diag_downleft_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  let a0 = top[1]
  let a1 = top[2]
  let a2 = top[3]
  let a3 = top[4]
  let a4 = top[5]
  let a5 = top[6]
  let a6 = top[7]
  let a7 = top[8]
  vp9_dst_set(p, off, stride, 0, 0, (a0 + a1 * 2 + a2 + 2) >> 2)
  let v1 = (a1 + a2 * 2 + a3 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 0, v1)
  vp9_dst_set(p, off, stride, 0, 1, v1)
  let v2 = (a2 + a3 * 2 + a4 + 2) >> 2
  vp9_dst_set(p, off, stride, 2, 0, v2)
  vp9_dst_set(p, off, stride, 1, 1, v2)
  vp9_dst_set(p, off, stride, 0, 2, v2)
  let v3 = (a3 + a4 * 2 + a5 + 2) >> 2
  vp9_dst_set(p, off, stride, 3, 0, v3)
  vp9_dst_set(p, off, stride, 2, 1, v3)
  vp9_dst_set(p, off, stride, 1, 2, v3)
  vp9_dst_set(p, off, stride, 0, 3, v3)
  let v4 = (a4 + a5 * 2 + a6 + 2) >> 2
  vp9_dst_set(p, off, stride, 3, 1, v4)
  vp9_dst_set(p, off, stride, 2, 2, v4)
  vp9_dst_set(p, off, stride, 1, 3, v4)
  let v5 = (a5 + a6 * 2 + a7 + 2) >> 2
  vp9_dst_set(p, off, stride, 3, 2, v5)
  vp9_dst_set(p, off, stride, 2, 3, v5)
  // note: this is different from vp8 and such
  vp9_dst_set(p, off, stride, 3, 3, a7)
}

///|
fn vp9_pred_diag_downright(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let v : FixedArray[Int32] = FixedArray::make(n + n - 1, 0)
  for i in 0..<(n - 2) {
    v[i] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
    v[n + 1 + i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
  }
  v[n - 2] = (left[n - 2] + left[n - 1] * 2 + top[0] + 2) >> 2
  v[n - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
  v[n] = (top[0] + top[1] * 2 + top[2] + 2) >> 2
  for j in 0..<n {
    for i in 0..<n {
      p[off + i + j * stride] = v[n - 1 - j + i]
    }
  }
}

///|
fn vp9_pred_diag_downright_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let tl = top[0]
  let a0 = top[1]
  let a1 = top[2]
  let a2 = top[3]
  let a3 = top[4]
  let l0 = left[3]
  let l1 = left[2]
  let l2 = left[1]
  let l3 = left[0]
  vp9_dst_set(p, off, stride, 0, 3, (l1 + l2 * 2 + l3 + 2) >> 2)
  let v02_13 = (l0 + l1 * 2 + l2 + 2) >> 2
  vp9_dst_set(p, off, stride, 0, 2, v02_13)
  vp9_dst_set(p, off, stride, 1, 3, v02_13)
  let v01_12_23 = (tl + l0 * 2 + l1 + 2) >> 2
  vp9_dst_set(p, off, stride, 0, 1, v01_12_23)
  vp9_dst_set(p, off, stride, 1, 2, v01_12_23)
  vp9_dst_set(p, off, stride, 2, 3, v01_12_23)
  let v00 = (l0 + tl * 2 + a0 + 2) >> 2
  vp9_dst_set(p, off, stride, 0, 0, v00)
  vp9_dst_set(p, off, stride, 1, 1, v00)
  vp9_dst_set(p, off, stride, 2, 2, v00)
  vp9_dst_set(p, off, stride, 3, 3, v00)
  let v10_21_32 = (tl + a0 * 2 + a1 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 0, v10_21_32)
  vp9_dst_set(p, off, stride, 2, 1, v10_21_32)
  vp9_dst_set(p, off, stride, 3, 2, v10_21_32)
  let v20_31 = (a0 + a1 * 2 + a2 + 2) >> 2
  vp9_dst_set(p, off, stride, 2, 0, v20_31)
  vp9_dst_set(p, off, stride, 3, 1, v20_31)
  vp9_dst_set(p, off, stride, 3, 0, (a1 + a2 * 2 + a3 + 2) >> 2)
}

///|
fn vp9_pred_vert_right(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let ve : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
  let vo : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
  for i in 0..<(n / 2 - 2) {
    vo[i] = (left[i * 2 + 3] + left[i * 2 + 2] * 2 + left[i * 2 + 1] + 2) >> 2
    ve[i] = (left[i * 2 + 4] + left[i * 2 + 3] * 2 + left[i * 2 + 2] + 2) >> 2
  }
  vo[n / 2 - 2] = (left[n - 1] + left[n - 2] * 2 + left[n - 3] + 2) >> 2
  ve[n / 2 - 2] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
  ve[n / 2 - 1] = (top[0] + top[1] + 1) >> 1
  vo[n / 2 - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
  for i in 0..<(n - 1) {
    ve[n / 2 + i] = (top[1 + i] + top[2 + i] + 1) >> 1
    vo[n / 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
  }
  for j in 0..<(n / 2) {
    for i in 0..<n {
      p[off + i + (j * 2) * stride] = ve[n / 2 - 1 - j + i]
      p[off + i + (j * 2 + 1) * stride] = vo[n / 2 - 1 - j + i]
    }
  }
}

///|
fn vp9_pred_vert_right_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let tl = top[0]
  let a0 = top[1]
  let a1 = top[2]
  let a2 = top[3]
  let a3 = top[4]
  let l0 = left[3]
  let l1 = left[2]
  let l2 = left[1]
  vp9_dst_set(p, off, stride, 0, 3, (l0 + l1 * 2 + l2 + 2) >> 2)
  vp9_dst_set(p, off, stride, 0, 2, (tl + l0 * 2 + l1 + 2) >> 2)
  let v00_12 = (tl + a0 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 0, v00_12)
  vp9_dst_set(p, off, stride, 1, 2, v00_12)
  let v01_13 = (l0 + tl * 2 + a0 + 2) >> 2
  vp9_dst_set(p, off, stride, 0, 1, v01_13)
  vp9_dst_set(p, off, stride, 1, 3, v01_13)
  let v10_22 = (a0 + a1 + 1) >> 1
  vp9_dst_set(p, off, stride, 1, 0, v10_22)
  vp9_dst_set(p, off, stride, 2, 2, v10_22)
  let v11_23 = (tl + a0 * 2 + a1 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 1, v11_23)
  vp9_dst_set(p, off, stride, 2, 3, v11_23)
  let v20_32 = (a1 + a2 + 1) >> 1
  vp9_dst_set(p, off, stride, 2, 0, v20_32)
  vp9_dst_set(p, off, stride, 3, 2, v20_32)
  let v21_33 = (a0 + a1 * 2 + a2 + 2) >> 2
  vp9_dst_set(p, off, stride, 2, 1, v21_33)
  vp9_dst_set(p, off, stride, 3, 3, v21_33)
  vp9_dst_set(p, off, stride, 3, 0, (a2 + a3 + 1) >> 1)
  vp9_dst_set(p, off, stride, 3, 1, (a1 + a2 * 2 + a3 + 2) >> 2)
}

///|
fn vp9_pred_hor_down(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let v : FixedArray[Int32] = FixedArray::make(n * 3 - 2, 0)
  for i in 0..<(n - 2) {
    v[i * 2] = (left[i + 1] + left[i] + 1) >> 1
    v[i * 2 + 1] = (left[i + 2] + left[i + 1] * 2 + left[i] + 2) >> 2
    v[n * 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
  }
  v[n * 2 - 2] = (top[0] + left[n - 1] + 1) >> 1
  v[n * 2 - 4] = (left[n - 1] + left[n - 2] + 1) >> 1
  v[n * 2 - 1] = (top[1] + top[0] * 2 + left[n - 1] + 2) >> 2
  v[n * 2 - 3] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
  for j in 0..<n {
    for i in 0..<n {
      p[off + i + j * stride] = v[n * 2 - 2 - j * 2 + i]
    }
  }
}

///|
fn vp9_pred_hor_down_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32], top : FixedArray[Int32]) -> Unit {
  let l0 = left[3]
  let l1 = left[2]
  let l2 = left[1]
  let l3 = left[0]
  let tl = top[0]
  let a0 = top[1]
  let a1 = top[2]
  let a2 = top[3]
  vp9_dst_set(p, off, stride, 2, 0, (tl + a0 * 2 + a1 + 2) >> 2)
  vp9_dst_set(p, off, stride, 3, 0, (a0 + a1 * 2 + a2 + 2) >> 2)
  let v00_21 = (tl + l0 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 0, v00_21)
  vp9_dst_set(p, off, stride, 2, 1, v00_21)
  let v10_31 = (a0 + tl * 2 + l0 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 0, v10_31)
  vp9_dst_set(p, off, stride, 3, 1, v10_31)
  let v01_22 = (l0 + l1 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 1, v01_22)
  vp9_dst_set(p, off, stride, 2, 2, v01_22)
  let v11_32 = (tl + l0 * 2 + l1 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 1, v11_32)
  vp9_dst_set(p, off, stride, 3, 2, v11_32)
  let v02_23 = (l1 + l2 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 2, v02_23)
  vp9_dst_set(p, off, stride, 2, 3, v02_23)
  let v12_33 = (l0 + l1 * 2 + l2 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 2, v12_33)
  vp9_dst_set(p, off, stride, 3, 3, v12_33)
  vp9_dst_set(p, off, stride, 0, 3, (l2 + l3 + 1) >> 1)
  vp9_dst_set(p, off, stride, 1, 3, (l1 + l2 * 2 + l3 + 2) >> 2)
}

///|
fn vp9_pred_vert_left(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  let ve : FixedArray[Int32] = FixedArray::make(n - 1, 0)
  let vo : FixedArray[Int32] = FixedArray::make(n - 1, 0)
  for i in 0..<(n - 2) {
    ve[i] = (top[1 + i] + top[2 + i] + 1) >> 1
    vo[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
  }
  ve[n - 2] = (top[n - 1] + top[n] + 1) >> 1
  vo[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
  for j in 0..<(n / 2) {
    for i in 0..<(n - j - 1) {
      p[off + i + (j * 2) * stride] = ve[j + i]
      p[off + i + (j * 2 + 1) * stride] = vo[j + i]
    }
    for i in (n - j - 1)..<n {
      p[off + i + (j * 2) * stride] = top[n]
      p[off + i + (j * 2 + 1) * stride] = top[n]
    }
  }
}

///|
fn vp9_pred_vert_left_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, top : FixedArray[Int32]) -> Unit {
  let a0 = top[1]
  let a1 = top[2]
  let a2 = top[3]
  let a3 = top[4]
  let a4 = top[5]
  let a5 = top[6]
  let a6 = top[7]
  let v00_12 = (a0 + a1 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 0, v00_12)
  let v01 = (a0 + a1 * 2 + a2 + 2) >> 2
  vp9_dst_set(p, off, stride, 0, 1, v01)
  let v10_02 = (a1 + a2 + 1) >> 1
  vp9_dst_set(p, off, stride, 1, 0, v10_02)
  vp9_dst_set(p, off, stride, 0, 2, v10_02)
  let v11_03 = (a1 + a2 * 2 + a3 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 1, v11_03)
  vp9_dst_set(p, off, stride, 0, 3, v11_03)
  let v20_12 = (a2 + a3 + 1) >> 1
  vp9_dst_set(p, off, stride, 2, 0, v20_12)
  vp9_dst_set(p, off, stride, 1, 2, v20_12)
  let v21_13 = (a2 + a3 * 2 + a4 + 2) >> 2
  vp9_dst_set(p, off, stride, 2, 1, v21_13)
  vp9_dst_set(p, off, stride, 1, 3, v21_13)
  let v30_22 = (a3 + a4 + 1) >> 1
  vp9_dst_set(p, off, stride, 3, 0, v30_22)
  vp9_dst_set(p, off, stride, 2, 2, v30_22)
  let v31_23 = (a3 + a4 * 2 + a5 + 2) >> 2
  vp9_dst_set(p, off, stride, 3, 1, v31_23)
  vp9_dst_set(p, off, stride, 2, 3, v31_23)
  vp9_dst_set(p, off, stride, 3, 2, (a4 + a5 + 1) >> 1)
  vp9_dst_set(p, off, stride, 3, 3, (a4 + a5 * 2 + a6 + 2) >> 2)
}

///|
fn vp9_pred_hor_up(n : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32]) -> Unit {
  let v : FixedArray[Int32] = FixedArray::make(n * 2 - 2, 0)
  for i in 0..<(n - 2) {
    v[i * 2] = (left[i] + left[i + 1] + 1) >> 1
    v[i * 2 + 1] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
  }
  v[n * 2 - 4] = (left[n - 2] + left[n - 1] + 1) >> 1
  v[n * 2 - 3] = (left[n - 2] + left[n - 1] * 3 + 2) >> 2
  for j in 0..<(n / 2) {
    for i in 0..<n {
      p[off + i + j * stride] = v[j * 2 + i]
    }
  }
  for j in (n / 2)..<n {
    for i in 0..<(n * 2 - 2 - j * 2) {
      p[off + i + j * stride] = v[j * 2 + i]
    }
    for i in (n * 2 - 2 - j * 2)..<n {
      p[off + i + j * stride] = left[n - 1]
    }
  }
}

///|
fn vp9_pred_hor_up_4x4(p : FixedArray[Int32], off : Int32, stride : Int32, left : FixedArray[Int32]) -> Unit {
  let l0 = left[0]
  let l1 = left[1]
  let l2 = left[2]
  let l3 = left[3]
  let v00_20 = (l0 + l1 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 0, v00_20)
  vp9_dst_set(p, off, stride, 1, 0, (l0 + l1 * 2 + l2 + 2) >> 2)
  let v01_21 = (l1 + l2 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 1, v01_21)
  vp9_dst_set(p, off, stride, 2, 0, v01_21)
  let v11_30 = (l1 + l2 * 2 + l3 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 1, v11_30)
  vp9_dst_set(p, off, stride, 3, 0, v11_30)
  let v02_22 = (l2 + l3 + 1) >> 1
  vp9_dst_set(p, off, stride, 0, 2, v02_22)
  vp9_dst_set(p, off, stride, 2, 1, v02_22)
  let v12_31 = (l2 + l3 * 3 + 2) >> 2
  vp9_dst_set(p, off, stride, 1, 2, v12_31)
  vp9_dst_set(p, off, stride, 3, 1, v12_31)
  vp9_dst_set(p, off, stride, 0, 3, l3)
  vp9_dst_set(p, off, stride, 1, 3, l3)
  vp9_dst_set(p, off, stride, 2, 2, l3)
  vp9_dst_set(p, off, stride, 2, 3, l3)
  vp9_dst_set(p, off, stride, 3, 2, l3)
  vp9_dst_set(p, off, stride, 3, 3, l3)
}

///|
/// `dsp->intra_pred[tx][mode]` for the 8-bit path.  `tx` 0..3 selects the
/// 4/8/16/32 transform size; `mode` is the converted (`check_intra_mode`)
/// prediction mode. */
fn vp9_intra_pred(
  tx : Int32,
  mode : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  left : FixedArray[Int32],
  top : FixedArray[Int32],
) -> Unit {
  let n = 4 << tx
  match mode {
    m if m == VP9_VERT_PRED => vp9_pred_vert(n, p, off, stride, top)
    m if m == VP9_HOR_PRED => vp9_pred_hor(n, p, off, stride, left)
    m if m == VP9_DC_PRED => vp9_pred_dc(n, p, off, stride, left, top)
    m if m == VP9_DIAG_DOWN_LEFT_PRED => {
      if tx == 0 {
        vp9_pred_diag_downleft_4x4(p, off, stride, top)
      } else {
        vp9_pred_diag_downleft(n, p, off, stride, top)
      }
    }
    m if m == VP9_DIAG_DOWN_RIGHT_PRED => {
      if tx == 0 {
        vp9_pred_diag_downright_4x4(p, off, stride, left, top)
      } else {
        vp9_pred_diag_downright(n, p, off, stride, left, top)
      }
    }
    m if m == VP9_VERT_RIGHT_PRED => {
      if tx == 0 {
        vp9_pred_vert_right_4x4(p, off, stride, left, top)
      } else {
        vp9_pred_vert_right(n, p, off, stride, left, top)
      }
    }
    m if m == VP9_HOR_DOWN_PRED => {
      if tx == 0 {
        vp9_pred_hor_down_4x4(p, off, stride, left, top)
      } else {
        vp9_pred_hor_down(n, p, off, stride, left, top)
      }
    }
    m if m == VP9_VERT_LEFT_PRED => {
      if tx == 0 {
        vp9_pred_vert_left_4x4(p, off, stride, top)
      } else {
        vp9_pred_vert_left(n, p, off, stride, top)
      }
    }
    m if m == VP9_HOR_UP_PRED => {
      if tx == 0 {
        vp9_pred_hor_up_4x4(p, off, stride, left)
      } else {
        vp9_pred_hor_up(n, p, off, stride, left)
      }
    }
    m if m == VP9_TM_VP8_PRED => vp9_pred_tm(n, p, off, stride, left, top)
    m if m == VP9_LEFT_DC_PRED => vp9_pred_dc_left(n, p, off, stride, left)
    m if m == VP9_TOP_DC_PRED => vp9_pred_dc_top(n, p, off, stride, top)
    m if m == VP9_DC_128_PRED => vp9_pred_dc_const(128, n, p, off, stride)
    m if m == VP9_DC_127_PRED => vp9_pred_dc_const(127, n, p, off, stride)
    _ => vp9_pred_dc_const(129, n, p, off, stride)
  }
}

///|
/// Inverse 4-point DCT, first pass (rows). */
fn vp9_idct4_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let i0 = inp[ibase]
  let i1 = inp[ibase + istride]
  let i2 = inp[ibase + istride * 2]
  let i3 = inp[ibase + istride * 3]
  let t0 = ((i0 + i2) * 11585 + (1 << 13)) >> 14
  let t1 = ((i0 - i2) * 11585 + (1 << 13)) >> 14
  let t2 = (i1 * 6270 - i3 * 15137 + (1 << 13)) >> 14
  let t3 = (i1 * 15137 + i3 * 6270 + (1 << 13)) >> 14
  out[obase] = t0 + t3
  out[obase + 1] = t1 + t2
  out[obase + 2] = t1 - t2
  out[obase + 3] = t0 - t3
}

///|
fn vp9_iadst4_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let i0 = inp[ibase]
  let i1 = inp[ibase + istride]
  let i2 = inp[ibase + istride * 2]
  let i3 = inp[ibase + istride * 3]
  let t0 = 5283 * i0 + 15212 * i2 + 9929 * i3
  let t1 = 9929 * i0 - 5283 * i2 - 15212 * i3
  let t2 = 13377 * (i0 - i2 + i3)
  let t3 = 13377 * i1
  out[obase] = (t0 + t3 + (1 << 13)) >> 14
  out[obase + 1] = (t1 + t3 + (1 << 13)) >> 14
  out[obase + 2] = (t2 + (1 << 13)) >> 14
  out[obase + 3] = (t0 + t1 - t3 + (1 << 13)) >> 14
}

///|
fn vp9_idct8_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let inp1 = (x : Int32) => inp[ibase + x * istride]
  let t0a = ((inp1(0) + inp1(4)) * 11585 + (1 << 13)) >> 14
  let t1a = ((inp1(0) - inp1(4)) * 11585 + (1 << 13)) >> 14
  let t2a = (inp1(2) * 6270 - inp1(6) * 15137 + (1 << 13)) >> 14
  let t3a = (inp1(2) * 15137 + inp1(6) * 6270 + (1 << 13)) >> 14
  let t4a = (inp1(1) * 3196 - inp1(7) * 16069 + (1 << 13)) >> 14
  let t5a = (inp1(5) * 13623 - inp1(3) * 9102 + (1 << 13)) >> 14
  let t6a = (inp1(5) * 9102 + inp1(3) * 13623 + (1 << 13)) >> 14
  let t7a = (inp1(1) * 16069 + inp1(7) * 3196 + (1 << 13)) >> 14
  let t0 = t0a + t3a
  let t1 = t1a + t2a
  let t2 = t1a - t2a
  let t3 = t0a - t3a
  let t4 = t4a + t5a
  let t5a2 = t4a - t5a
  let t7 = t7a + t6a
  let t6a2 = t7a - t6a
  let t5 = ((t6a2 - t5a2) * 11585 + (1 << 13)) >> 14
  let t6 = ((t6a2 + t5a2) * 11585 + (1 << 13)) >> 14
  out[obase] = t0 + t7
  out[obase + 1] = t1 + t6
  out[obase + 2] = t2 + t5
  out[obase + 3] = t3 + t4
  out[obase + 4] = t3 - t4
  out[obase + 5] = t2 - t5
  out[obase + 6] = t1 - t6
  out[obase + 7] = t0 - t7
}

///|
/// `15137U * t4 + 6270U * t5` style chains are computed in `UInt32` wrapping
/// and reinterpreted, mirroring the C's unsigned intermediate arithmetic. */
fn vp9_iadst8_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let inp1 = (x : Int32) => inp[ibase + x * istride]
  let t0a = 16305 * inp1(7) + 1606 * inp1(0)
  let t1a = 1606 * inp1(7) - 16305 * inp1(0)
  let t2a = 14449 * inp1(5) + 7723 * inp1(2)
  let t3a = 7723 * inp1(5) - 14449 * inp1(2)
  let t4a = 10394 * inp1(3) + 12665 * inp1(4)
  let t5a = 12665 * inp1(3) - 10394 * inp1(4)
  let t6a = 4756 * inp1(1) + 15679 * inp1(6)
  let t7a = 15679 * inp1(1) - 4756 * inp1(6)
  let t0 = (t0a + t4a + (1 << 13)) >> 14
  let t1 = (t1a + t5a + (1 << 13)) >> 14
  let t2 = (t2a + t6a + (1 << 13)) >> 14
  let t3 = (t3a + t7a + (1 << 13)) >> 14
  let t4 = (t0a - t4a + (1 << 13)) >> 14
  let t5 = (t1a - t5a + (1 << 13)) >> 14
  let t6 = (t2a - t6a + (1 << 13)) >> 14
  let t7 = (t3a - t7a + (1 << 13)) >> 14
  let u4a = 15137U * t4.reinterpret_as_uint() + 6270U * t5.reinterpret_as_uint()
  let u5a = 6270U * t4.reinterpret_as_uint() - 15137U * t5.reinterpret_as_uint()
  let u6a = 15137U * t7.reinterpret_as_uint() - 6270U * t6.reinterpret_as_uint()
  let u7a = 6270U * t7.reinterpret_as_uint() + 15137U * t6.reinterpret_as_uint()
  out[obase] = t0 + t2
  out[obase + 7] = -(t1 + t3)
  let t2b = t0 - t2
  let t3b = t1 - t3
  out[obase + 1] = -(((1U << 13) + u4a + u6a).reinterpret_as_int() >> 14)
  out[obase + 6] = ((1U << 13) + u5a + u7a).reinterpret_as_int() >> 14
  let t6b = ((1U << 13) + u4a - u6a).reinterpret_as_int() >> 14
  let t7b = ((1U << 13) + u5a - u7a).reinterpret_as_int() >> 14
  out[obase + 3] = -(((t2b + t3b).reinterpret_as_uint() * 11585U + (1U << 13)).reinterpret_as_int() >> 14)
  out[obase + 4] = ((t2b - t3b).reinterpret_as_uint() * 11585U + (1U << 13)).reinterpret_as_int() >> 14
  out[obase + 2] = ((t6b + t7b).reinterpret_as_uint() * 11585U + (1U << 13)).reinterpret_as_int() >> 14
  out[obase + 5] = -(((t6b - t7b).reinterpret_as_uint() * 11585U + (1U << 13)).reinterpret_as_int() >> 14)
}

///|
fn vp9_idct16_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let inp1 = (x : Int32) => inp[ibase + x * istride]
  // (a + b) * k + (1 << 13) rounded via unsigned wrapping, then arithmetic
  // shift — exactly `(dctint)(expr * kU + (1 << 13)) >> 14`.
  let shr14 = (v : UInt32) => v.reinterpret_as_int() >> 14
  let u = (v : Int32) => v.reinterpret_as_uint()
  let t0a = shr14(u(inp1(0) + inp1(8)) * 11585U + (1U << 13))
  let t1a = shr14(u(inp1(0) - inp1(8)) * 11585U + (1U << 13))
  let t2a = shr14(u(inp1(4)) * 6270U - u(inp1(12)) * 15137U + (1U << 13))
  let t3a = shr14(u(inp1(4)) * 15137U + u(inp1(12)) * 6270U + (1U << 13))
  let t4a = shr14(u(inp1(2)) * 3196U - u(inp1(14)) * 16069U + (1U << 13))
  let t7a = shr14(u(inp1(2)) * 16069U + u(inp1(14)) * 3196U + (1U << 13))
  let t5a = shr14(u(inp1(10)) * 13623U - u(inp1(6)) * 9102U + (1U << 13))
  let t6a = shr14(u(inp1(10)) * 9102U + u(inp1(6)) * 13623U + (1U << 13))
  let t8a = shr14(u(inp1(1)) * 1606U - u(inp1(15)) * 16305U + (1U << 13))
  let t15a = shr14(u(inp1(1)) * 16305U + u(inp1(15)) * 1606U + (1U << 13))
  let t9a = shr14(u(inp1(9)) * 12665U - u(inp1(7)) * 10394U + (1U << 13))
  let t14a = shr14(u(inp1(9)) * 10394U + u(inp1(7)) * 12665U + (1U << 13))
  let t10a = shr14(u(inp1(5)) * 7723U - u(inp1(11)) * 14449U + (1U << 13))
  let t13a = shr14(u(inp1(5)) * 14449U + u(inp1(11)) * 7723U + (1U << 13))
  let t11a = shr14(u(inp1(13)) * 15679U - u(inp1(3)) * 4756U + (1U << 13))
  let t12a = shr14(u(inp1(13)) * 4756U + u(inp1(3)) * 15679U + (1U << 13))
  let t0 = t0a + t3a
  let t1 = t1a + t2a
  let t2 = t1a - t2a
  let t3 = t0a - t3a
  let t4 = t4a + t5a
  let t5 = t4a - t5a
  let t6 = t7a - t6a
  let t7 = t7a + t6a
  let t8 = t8a + t9a
  let t9 = t8a - t9a
  let t10 = t11a - t10a
  let t11 = t11a + t10a
  let t12 = t12a + t13a
  let t13 = t12a - t13a
  let t14 = t15a - t14a
  let t15 = t15a + t14a
  let t5a2 = shr14(u(t6 - t5) * 11585U + (1U << 13))
  let t6a2 = shr14(u(t6 + t5) * 11585U + (1U << 13))
  let t9a2 = shr14(u(t14) * 6270U - u(t9) * 15137U + (1U << 13))
  let t14a2 = shr14(u(t14) * 15137U + u(t9) * 6270U + (1U << 13))
  let t10a2 = shr14((0U - (u(t13) * 15137U + u(t10) * 6270U)) + (1U << 13))
  let t13a2 = shr14(u(t13) * 6270U - u(t10) * 15137U + (1U << 13))
  let t0a2 = t0 + t7
  let t1a2 = t1 + t6a2
  let t2a2 = t2 + t5a2
  let t3a2 = t3 + t4
  let t4b = t3 - t4
  let t5b = t2 - t5a2
  let t6b = t1 - t6a2
  let t7b = t0 - t7
  let t8a2 = t8 + t11
  let t9b = t9a2 + t10a2
  let t10b = t9a2 - t10a2
  let t11a2 = t8 - t11
  let t12a2 = t15 - t12
  let t13b = t14a2 - t13a2
  let t14b = t14a2 + t13a2
  let t15a2 = t15 + t12
  let t10a3 = shr14(u(t13b - t10b) * 11585U + (1U << 13))
  let t13a3 = shr14(u(t13b + t10b) * 11585U + (1U << 13))
  let t11b = shr14(u(t12a2 - t11a2) * 11585U + (1U << 13))
  let t12b = shr14(u(t12a2 + t11a2) * 11585U + (1U << 13))
  out[obase] = t0a2 + t15a2
  out[obase + 1] = t1a2 + t14b
  out[obase + 2] = t2a2 + t13a3
  out[obase + 3] = t3a2 + t12b
  out[obase + 4] = t4b + t11b
  out[obase + 5] = t5b + t10a3
  out[obase + 6] = t6b + t9b
  out[obase + 7] = t7b + t8a2
  out[obase + 8] = t7b - t8a2
  out[obase + 9] = t6b - t9b
  out[obase + 10] = t5b - t10a3
  out[obase + 11] = t4b - t11b
  out[obase + 12] = t3a2 - t12b
  out[obase + 13] = t2a2 - t13a3
  out[obase + 14] = t1a2 - t14b
  out[obase + 15] = t0a2 - t15a2
}

///|
fn vp9_iadst16_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let inp1 = (x : Int32) => inp[ibase + x * istride]
  let shr14 = (v : UInt32) => v.reinterpret_as_int() >> 14
  let u = (v : Int32) => v.reinterpret_as_uint()
  let t0 = inp1(15) * 16364 + inp1(0) * 804
  let t1 = inp1(15) * 804 - inp1(0) * 16364
  let t2 = inp1(13) * 15893 + inp1(2) * 3981
  let t3 = inp1(13) * 3981 - inp1(2) * 15893
  let t4 = inp1(11) * 14811 + inp1(4) * 7005
  let t5 = inp1(11) * 7005 - inp1(4) * 14811
  let t6 = inp1(9) * 13160 + inp1(6) * 9760
  let t7 = inp1(9) * 9760 - inp1(6) * 13160
  let t8 = inp1(7) * 11003 + inp1(8) * 12140
  let t9 = inp1(7) * 12140 - inp1(8) * 11003
  let t10 = inp1(5) * 8423 + inp1(10) * 14053
  let t11 = inp1(5) * 14053 - inp1(10) * 8423
  let t12 = inp1(3) * 5520 + inp1(12) * 15426
  let t13 = inp1(3) * 15426 - inp1(12) * 5520
  let t14 = inp1(1) * 2404 + inp1(14) * 16207
  let t15 = inp1(1) * 16207 - inp1(14) * 2404
  let t0a = shr14(u(t0 + t8) + (1U << 13))
  let t1a = shr14(u(t1 + t9) + (1U << 13))
  let t2a = shr14(u(t2 + t10) + (1U << 13))
  let t3a = shr14(u(t3 + t11) + (1U << 13))
  let t4a = shr14(u(t4 + t12) + (1U << 13))
  let t5a = shr14(u(t5 + t13) + (1U << 13))
  let t6a = shr14(u(t6 + t14) + (1U << 13))
  let t7a = shr14(u(t7 + t15) + (1U << 13))
  let t8a = shr14(u(t0 - t8) + (1U << 13))
  let t9a = shr14(u(t1 - t9) + (1U << 13))
  let t10a = shr14(u(t2 - t10) + (1U << 13))
  let t11a = shr14(u(t3 - t11) + (1U << 13))
  let t12a = shr14(u(t4 - t12) + (1U << 13))
  let t13a = shr14(u(t5 - t13) + (1U << 13))
  let t14a = shr14(u(t6 - t14) + (1U << 13))
  let t15a = shr14(u(t7 - t15) + (1U << 13))
  let t8b = t8a * 16069 + t9a * 3196
  let t9b = t8a * 3196 - t9a * 16069
  let t10b = t10a * 9102 + t11a * 13623
  let t11b = t10a * 13623 - t11a * 9102
  let t12b = t13a * 16069 - t12a * 3196
  let t13b = t13a * 3196 + t12a * 16069
  let t14b = t15a * 9102 - t14a * 13623
  let t15b = t15a * 13623 + t14a * 9102
  let t0b = t0a + t4a
  let t1b = t1a + t5a
  let t2b = t2a + t6a
  let t3b = t3a + t7a
  let t4b = t0a - t4a
  let t5b = t1a - t5a
  let t6b = t2a - t6a
  let t7b = t3a - t7a
  let t8a2 = shr14(u(t8b + t12b) + (1U << 13))
  let t9a2 = shr14(u(t9b + t13b) + (1U << 13))
  let t10a2 = shr14(u(t10b + t14b) + (1U << 13))
  let t11a2 = shr14(u(t11b + t15b) + (1U << 13))
  let t12a2 = shr14(u(t8b - t12b) + (1U << 13))
  let t13a2 = shr14(u(t9b - t13b) + (1U << 13))
  let t14a2 = shr14(u(t10b - t14b) + (1U << 13))
  let t15a2 = shr14(u(t11b - t15b) + (1U << 13))
  let t4a2 = t4b * 15137 + t5b * 6270
  let t5a2 = t4b * 6270 - t5b * 15137
  let t6a2 = t7b * 15137 - t6b * 6270
  let t7a2 = t7b * 6270 + t6b * 15137
  let t12c = t12a2 * 15137 + t13a2 * 6270
  let t13c = t12a2 * 6270 - t13a2 * 15137
  let t14c = t15a2 * 15137 - t14a2 * 6270
  let t15c = t15a2 * 6270 + t14a2 * 15137
  out[obase] = t0b + t2b
  out[obase + 15] = -(t1b + t3b)
  let t2a3 = t0b - t2b
  let t3a3 = t1b - t3b
  out[obase + 3] = -shr14(u(t4a2 + t6a2) + (1U << 13))
  out[obase + 12] = shr14(u(t5a2 + t7a2) + (1U << 13))
  let t6c = shr14(u(t4a2 - t6a2) + (1U << 13))
  let t7c = shr14(u(t5a2 - t7a2) + (1U << 13))
  out[obase + 1] = -(t8a2 + t10a2)
  out[obase + 14] = t9a2 + t11a2
  let t10c = t8a2 - t10a2
  let t11c = t9a2 - t11a2
  out[obase + 2] = shr14(u(t12c + t14c) + (1U << 13))
  out[obase + 13] = -shr14(u(t13c + t15c) + (1U << 13))
  let t14a3 = shr14(u(t12c - t14c) + (1U << 13))
  let t15a3 = shr14(u(t13c - t15c) + (1U << 13))
  out[obase + 7] = shr14((0U - u(t2a3 + t3a3) * 11585U) + (1U << 13))
  out[obase + 8] = shr14(u(t2a3 - t3a3) * 11585U + (1U << 13))
  out[obase + 4] = shr14(u(t7c + t6c) * 11585U + (1U << 13))
  out[obase + 11] = shr14(u(t7c - t6c) * 11585U + (1U << 13))
  out[obase + 6] = shr14(u(t11c + t10c) * 11585U + (1U << 13))
  out[obase + 9] = shr14(u(t11c - t10c) * 11585U + (1U << 13))
  out[obase + 5] = shr14((0U - u(t14a3 + t15a3) * 11585U) + (1U << 13))
  out[obase + 10] = shr14(u(t14a3 - t15a3) * 11585U + (1U << 13))
  ignore(t0)
}

///|
fn vp9_idct32_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32) -> Unit {
  let inp1 = (x : Int32) => inp[ibase + x * istride]
  let shr14 = (v : UInt32) => v.reinterpret_as_int() >> 14
  let u = (v : Int32) => v.reinterpret_as_uint()
  let t0a = shr14(u(inp1(0) + inp1(16)) * 11585U + (1U << 13))
  let t1a = shr14(u(inp1(0) - inp1(16)) * 11585U + (1U << 13))
  let t2a = shr14(u(inp1(8)) * 6270U - u(inp1(24)) * 15137U + (1U << 13))
  let t3a = shr14(u(inp1(8)) * 15137U + u(inp1(24)) * 6270U + (1U << 13))
  let t4a = shr14(u(inp1(4)) * 3196U - u(inp1(28)) * 16069U + (1U << 13))
  let t7a = shr14(u(inp1(4)) * 16069U + u(inp1(28)) * 3196U + (1U << 13))
  let t5a = shr14(u(inp1(20)) * 13623U - u(inp1(12)) * 9102U + (1U << 13))
  let t6a = shr14(u(inp1(20)) * 9102U + u(inp1(12)) * 13623U + (1U << 13))
  let t8a = shr14(u(inp1(2)) * 1606U - u(inp1(30)) * 16305U + (1U << 13))
  let t15a = shr14(u(inp1(2)) * 16305U + u(inp1(30)) * 1606U + (1U << 13))
  let t9a = shr14(u(inp1(18)) * 12665U - u(inp1(14)) * 10394U + (1U << 13))
  let t14a = shr14(u(inp1(18)) * 10394U + u(inp1(14)) * 12665U + (1U << 13))
  let t10a = shr14(u(inp1(10)) * 7723U - u(inp1(22)) * 14449U + (1U << 13))
  let t13a = shr14(u(inp1(10)) * 14449U + u(inp1(22)) * 7723U + (1U << 13))
  let t11a = shr14(u(inp1(26)) * 15679U - u(inp1(6)) * 4756U + (1U << 13))
  let t12a = shr14(u(inp1(26)) * 4756U + u(inp1(6)) * 15679U + (1U << 13))
  let t16a = shr14(u(inp1(1)) * 804U - u(inp1(31)) * 16364U + (1U << 13))
  let t31a = shr14(u(inp1(1)) * 16364U + u(inp1(31)) * 804U + (1U << 13))
  let t17a = shr14(u(inp1(17)) * 12140U - u(inp1(15)) * 11003U + (1U << 13))
  let t30a = shr14(u(inp1(17)) * 11003U + u(inp1(15)) * 12140U + (1U << 13))
  let t18a = shr14(u(inp1(9)) * 7005U - u(inp1(23)) * 14811U + (1U << 13))
  let t29a = shr14(u(inp1(9)) * 14811U + u(inp1(23)) * 7005U + (1U << 13))
  let t19a = shr14(u(inp1(25)) * 15426U - u(inp1(7)) * 5520U + (1U << 13))
  let t28a = shr14(u(inp1(25)) * 5520U + u(inp1(7)) * 15426U + (1U << 13))
  let t20a = shr14(u(inp1(5)) * 3981U - u(inp1(27)) * 15893U + (1U << 13))
  let t27a = shr14(u(inp1(5)) * 15893U + u(inp1(27)) * 3981U + (1U << 13))
  let t21a = shr14(u(inp1(21)) * 14053U - u(inp1(11)) * 8423U + (1U << 13))
  let t26a = shr14(u(inp1(21)) * 8423U + u(inp1(11)) * 14053U + (1U << 13))
  let t22a = shr14(u(inp1(13)) * 9760U - u(inp1(19)) * 13160U + (1U << 13))
  let t25a = shr14(u(inp1(13)) * 13160U + u(inp1(19)) * 9760U + (1U << 13))
  let t23a = shr14(u(inp1(29)) * 16207U - u(inp1(3)) * 2404U + (1U << 13))
  let t24a = shr14(u(inp1(29)) * 2404U + u(inp1(3)) * 16207U + (1U << 13))
  let t0 = t0a + t3a
  let t1 = t1a + t2a
  let t2 = t1a - t2a
  let t3 = t0a - t3a
  let t4 = t4a + t5a
  let t5 = t4a - t5a
  let t6 = t7a - t6a
  let t7 = t7a + t6a
  let t8 = t8a + t9a
  let t9 = t8a - t9a
  let t10 = t11a - t10a
  let t11 = t11a + t10a
  let t12 = t12a + t13a
  let t13 = t12a - t13a
  let t14 = t15a - t14a
  let t15 = t15a + t14a
  let t16 = t16a + t17a
  let t17 = t16a - t17a
  let t18 = t19a - t18a
  let t19 = t19a + t18a
  let t20 = t20a + t21a
  let t21 = t20a - t21a
  let t22 = t23a - t22a
  let t23 = t23a + t22a
  let t24 = t24a + t25a
  let t25 = t24a - t25a
  let t26 = t27a - t26a
  let t27 = t27a + t26a
  let t28 = t28a + t29a
  let t29 = t28a - t29a
  let t30 = t31a - t30a
  let t31 = t31a + t30a
  let t5a2 = shr14(u(t6 - t5) * 11585U + (1U << 13))
  let t6a2 = shr14(u(t6 + t5) * 11585U + (1U << 13))
  let t9a2 = shr14(u(t14) * 6270U - u(t9) * 15137U + (1U << 13))
  let t14a2 = shr14(u(t14) * 15137U + u(t9) * 6270U + (1U << 13))
  let t10a2 = shr14((0U - (u(t13) * 15137U + u(t10) * 6270U)) + (1U << 13))
  let t13a2 = shr14(u(t13) * 6270U - u(t10) * 15137U + (1U << 13))
  let t17a2 = shr14(u(t30) * 3196U - u(t17) * 16069U + (1U << 13))
  let t30a2 = shr14(u(t30) * 16069U + u(t17) * 3196U + (1U << 13))
  let t18a2 = shr14((0U - (u(t29) * 16069U + u(t18) * 3196U)) + (1U << 13))
  let t29a2 = shr14(u(t29) * 3196U - u(t18) * 16069U + (1U << 13))
  let t21a2 = shr14(u(t26) * 13623U - u(t21) * 9102U + (1U << 13))
  let t26a2 = shr14(u(t26) * 9102U + u(t21) * 13623U + (1U << 13))
  let t22a2 = shr14((0U - (u(t25) * 9102U + u(t22) * 13623U)) + (1U << 13))
  let t25a2 = shr14(u(t25) * 13623U - u(t22) * 9102U + (1U << 13))
  let t0a2 = t0 + t7
  let t1a2 = t1 + t6a2
  let t2a2 = t2 + t5a2
  let t3a2 = t3 + t4
  let t4a2 = t3 - t4
  let t5b = t2 - t5a2
  let t6b = t1 - t6a2
  let t7a2 = t0 - t7
  let t8a2 = t8 + t11
  let t9b = t9a2 + t10a2
  let t10b = t9a2 - t10a2
  let t11a2 = t8 - t11
  let t12a2 = t15 - t12
  let t13b = t14a2 - t13a2
  let t14b = t14a2 + t13a2
  let t15a2 = t15 + t12
  let t16a2 = t16 + t19
  let t17b = t17a2 + t18a2
  let t18b = t17a2 - t18a2
  let t19a2 = t16 - t19
  let t20a2 = t23 - t20
  let t21b = t22a2 - t21a2
  let t22b = t22a2 + t21a2
  let t23a2 = t23 + t20
  let t24a2 = t24 + t27
  let t25b = t25a2 + t26a2
  let t26b = t25a2 - t26a2
  let t27a2 = t24 - t27
  let t28a2 = t31 - t28
  let t29b = t30a2 - t29a2
  let t30b = t30a2 + t29a2
  let t31a2 = t31 + t28
  let t10a3 = shr14(u(t13b - t10b) * 11585U + (1U << 13))
  let t13a3 = shr14(u(t13b + t10b) * 11585U + (1U << 13))
  let t11b = shr14(u(t12a2 - t11a2) * 11585U + (1U << 13))
  let t12b = shr14(u(t12a2 + t11a2) * 11585U + (1U << 13))
  let t18a3 = shr14(u(t29b) * 6270U - u(t18b) * 15137U + (1U << 13))
  let t29a3 = shr14(u(t29b) * 15137U + u(t18b) * 6270U + (1U << 13))
  let t19b = shr14(u(t28a2) * 6270U - u(t19a2) * 15137U + (1U << 13))
  let t28b = shr14(u(t28a2) * 15137U + u(t19a2) * 6270U + (1U << 13))
  let t20b = shr14((0U - (u(t27a2) * 15137U + u(t20a2) * 6270U)) + (1U << 13))
  let t27b = shr14(u(t27a2) * 6270U - u(t20a2) * 15137U + (1U << 13))
  let t21a3 = shr14((0U - (u(t26b) * 15137U + u(t21b) * 6270U)) + (1U << 13))
  let t26a3 = shr14(u(t26b) * 6270U - u(t21b) * 15137U + (1U << 13))
  let t0b = t0a2 + t15a2
  let t1b = t1a2 + t14b
  let t2b = t2a2 + t13a3
  let t3b = t3a2 + t12b
  let t4b = t4a2 + t11b
  let t5a3 = t5b + t10a3
  let t6a3 = t6b + t9b
  let t7b = t7a2 + t8a2
  let t8b = t7a2 - t8a2
  let t9a3 = t6b - t9b
  let t10c = t5b - t10a3
  let t11a3 = t4a2 - t11b
  let t12a3 = t3a2 - t12b
  let t13c = t2a2 - t13a3
  let t14a3 = t1a2 - t14b
  let t15b = t0a2 - t15a2
  let t16b = t16a2 + t23a2
  let t17a3 = t17b + t22b
  let t18c = t18a3 + t21a3
  let t19a3 = t19b + t20b
  let t20c = t19b - t20b
  let t21c = t18a3 - t21a3
  let t22a3 = t17b - t22b
  let t23b = t16a2 - t23a2
  let t24b = t31a2 - t24a2
  let t25a3 = t30b - t25b
  let t26c = t29a3 - t26a3
  let t27a3 = t28b - t27b
  let t28c = t28b + t27b
  let t29c = t29a3 + t26a3
  let t30c = t30b + t25b
  let t31b = t31a2 + t24a2
  let t20d = shr14(u(t27a3 - t20c) * 11585U + (1U << 13))
  let t27c = shr14(u(t27a3 + t20c) * 11585U + (1U << 13))
  let t21d = shr14(u(t26c - t21c) * 11585U + (1U << 13))
  let t26d = shr14(u(t26c + t21c) * 11585U + (1U << 13))
  let t22c = shr14(u(t25a3 - t22a3) * 11585U + (1U << 13))
  let t25c = shr14(u(t25a3 + t22a3) * 11585U + (1U << 13))
  let t23c = shr14(u(t24b - t23b) * 11585U + (1U << 13))
  let t24c = shr14(u(t24b + t23b) * 11585U + (1U << 13))
  out[obase] = t0b + t31b
  out[obase + 1] = t1b + t30c
  out[obase + 2] = t2b + t29c
  out[obase + 3] = t3b + t28c
  out[obase + 4] = t4b + t27c
  out[obase + 5] = t5a3 + t26d
  out[obase + 6] = t6a3 + t25c
  out[obase + 7] = t7b + t24c
  out[obase + 8] = t8b + t23c
  out[obase + 9] = t9a3 + t22c
  out[obase + 10] = t10c + t21d
  out[obase + 11] = t11a3 + t20d
  out[obase + 12] = t12a3 + t19a3
  out[obase + 13] = t13c + t18c
  out[obase + 14] = t14a3 + t17a3
  out[obase + 15] = t15b + t16b
  out[obase + 16] = t15b - t16b
  out[obase + 17] = t14a3 - t17a3
  out[obase + 18] = t13c - t18c
  out[obase + 19] = t12a3 - t19a3
  out[obase + 20] = t11a3 - t20d
  out[obase + 21] = t10c - t21d
  out[obase + 22] = t9a3 - t22c
  out[obase + 23] = t8b - t23c
  out[obase + 24] = t7b - t24c
  out[obase + 25] = t6a3 - t25c
  out[obase + 26] = t5a3 - t26d
  out[obase + 27] = t4b - t27c
  out[obase + 28] = t3b - t28c
  out[obase + 29] = t2b - t29c
  out[obase + 30] = t1b - t30c
  out[obase + 31] = t0b - t31b
}

///|
fn vp9_iwht4_1d(inp : FixedArray[Int32], ibase : Int32, istride : Int32, out : FixedArray[Int32], obase : Int32, pass : Int32) -> Unit {
  let g = (x : Int32) => inp[ibase + x * istride]
  let mut t0 = if pass == 0 {
    g(0) >> 2
  } else {
    g(0)
  }
  let mut t1 = if pass == 0 {
    g(3) >> 2
  } else {
    g(3)
  }
  let mut t2 = if pass == 0 {
    g(1) >> 2
  } else {
    g(1)
  }
  let mut t3 = if pass == 0 {
    g(2) >> 2
  } else {
    g(2)
  }
  t0 += t2
  t3 -= t1
  let t4 = (t0 - t3) >> 1
  t1 = t4 - t1
  t2 = t4 - t2
  t0 -= t1
  t3 += t2
  out[obase] = t0
  out[obase + 1] = t1
  out[obase + 2] = t2
  out[obase + 3] = t3
}

///|
/// `itxfm_wrapper(type_a, type_b, sz, bits, has_dconly)` — two-pass inverse
/// transform with pixel add + clip.  `tx_kind`: 0..3 = 4/8/16/32, 4 = the
/// lossless WHT 4x4.  `txtp`: 0=DCT_DCT 1=DCT_ADST 2=ADST_DCT 3=ADST_ADST
/// (row type = txtp >> 1, col type = txtp & 1 — see `ff_vp9_intra_txfm_type`
/// and `dsp->itxfm_add[tx][txtp]`).
fn vp9_itxfm_add(
  tx_kind : Int32,
  txtp : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  block : FixedArray[Int32],
  boff : Int32,
  eob : Int32,
) -> Unit {
  // DC-only shortcut (idct_idct only, has_dconly)
  if tx_kind < 4 && txtp == 0 && eob == 1 {
    let t = ((((block[boff] * 11585 + (1 << 13)) >> 14) * 11585 + (1 << 13)) >>
    14)
    let shift = if tx_kind == 3 { 6 } else { tx_kind + 4 }
    block[boff] = 0
    let add = (t + (1 << (shift - 1))) >> shift
    for i in 0..<(4 << tx_kind) {
      for j in 0..<(4 << tx_kind) {
        let o = off + j * stride + i
        p[o] = vp9_clip_pixel8(p[o] + add)
      }
    }
    return
  }
  let sz = match tx_kind {
    4 => 4
    k => 4 << k
  }
  let bits = match tx_kind {
    0 => 4
    1 => 5
    2 => 6
    3 => 6
    _ => 0
  }
  let tmp : FixedArray[Int32] = FixedArray::make(sz * sz, 0)
  let out : FixedArray[Int32] = FixedArray::make(sz, 0)
  // first pass reads block columns (type_a), second pass reads tmp columns
  // (type_b); txtp bit 0 picks the row transform, txtp bit 1 the column one
  // (`iadst_idct` = DCT_ADST = txtp 1, `idct_iadst` = ADST_DCT = txtp 2).
  let use_adst_a = (txtp & 1) != 0 && tx_kind < 3
  let use_adst_b = (txtp >> 1) != 0 && tx_kind < 3
  for i in 0..<sz {
    match tx_kind {
      4 => vp9_iwht4_1d(block, boff + i, sz, tmp, i * sz, 0)
      0 =>
        if use_adst_a {
          vp9_iadst4_1d(block, boff + i, sz, tmp, i * sz)
        } else {
          vp9_idct4_1d(block, boff + i, sz, tmp, i * sz)
        }
      1 =>
        if use_adst_a {
          vp9_iadst8_1d(block, boff + i, sz, tmp, i * sz)
        } else {
          vp9_idct8_1d(block, boff + i, sz, tmp, i * sz)
        }
      2 =>
        if use_adst_a {
          vp9_iadst16_1d(block, boff + i, sz, tmp, i * sz)
        } else {
          vp9_idct16_1d(block, boff + i, sz, tmp, i * sz)
        }
      _ => vp9_idct32_1d(block, boff + i, sz, tmp, i * sz)
    }
  }
  // `dctcoef` is int16_t at 8 bpp: the pass-1 outputs are truncated on
  // store, matching the C exactly
  for i in 0..<(sz * sz) {
    tmp[i] = vp9_i16(tmp[i])
    block[boff + i] = 0
  }
  // second pass + add
  for i in 0..<sz {
    if tx_kind == 4 {
      vp9_iwht4_1d(tmp, i, sz, out, 0, 1)
    } else if use_adst_b {
      match tx_kind {
        0 => vp9_iadst4_1d(tmp, i, sz, out, 0)
        1 => vp9_iadst8_1d(tmp, i, sz, out, 0)
        _ => vp9_iadst16_1d(tmp, i, sz, out, 0)
      }
    } else {
      match tx_kind {
        0 => vp9_idct4_1d(tmp, i, sz, out, 0)
        1 => vp9_idct8_1d(tmp, i, sz, out, 0)
        2 => vp9_idct16_1d(tmp, i, sz, out, 0)
        _ => vp9_idct32_1d(tmp, i, sz, out, 0)
      }
    }
    for j in 0..<sz {
      out[j] = vp9_i16(out[j])
    }
    for j in 0..<sz {
      let add = if bits > 0 {
        (out[j] + (1 << (bits - 1))) >> bits
      } else {
        out[j]
      }
      let o = off + i + j * stride
      p[o] = vp9_clip_pixel8(p[o] + add)
    }
  }
}

///|
/// The loop-filter core (`loop_filter` in `vp9dsp_template.c`), 8-bit
/// (`F = 1 << (BIT_DEPTH - 8)` and the `E/I/H <<= BIT_DEPTH - 8` shifts are
/// identity at 8-bit).  `stridea` is the step between the 8 rows (1 for
/// vertical filtering), `strideb` the in-row step. */
fn vp9_loop_filter_core(
  p : FixedArray[Int32],
  off : Int32,
  e : Int32,
  i : Int32,
  h : Int32,
  stridea : Int32,
  strideb : Int32,
  wd : Int32,
) -> Unit {
  let f = 1
  let mut o = off
  for _row in 0..<8 {
    let p3 = p[o + strideb * -4]
    let p2 = p[o + strideb * -3]
    let p1 = p[o + strideb * -2]
    let p0 = p[o + strideb * -1]
    let q0 = p[o]
    let q1 = p[o + strideb]
    let q2 = p[o + strideb * 2]
    let q3 = p[o + strideb * 3]
    let fm = vp9_abs(p3 - p2) <= i &&
      vp9_abs(p2 - p1) <= i &&
      vp9_abs(p1 - p0) <= i &&
      vp9_abs(q1 - q0) <= i &&
      vp9_abs(q2 - q1) <= i &&
      vp9_abs(q3 - q2) <= i &&
      vp9_abs(p0 - q0) * 2 + (vp9_abs(p1 - q1) >> 1) <= e
    if !fm {
      o += stridea
      continue
    }
    let mut flat8out = false
    let mut flat8in = false
    // read unconditionally: values are only consumed when wd >= 16, and the
    // padded plane base keeps the (possibly out-of-frame) reads in bounds
    let p7 = p[o + strideb * -8]
    let p6 = p[o + strideb * -7]
    let p5 = p[o + strideb * -6]
    let p4 = p[o + strideb * -5]
    let q4 = p[o + strideb * 4]
    let q5 = p[o + strideb * 5]
    let q6 = p[o + strideb * 6]
    let q7 = p[o + strideb * 7]
    if wd >= 16 {
      flat8out = vp9_abs(p7 - p0) <= f &&
        vp9_abs(p6 - p0) <= f &&
        vp9_abs(p5 - p0) <= f &&
        vp9_abs(p4 - p0) <= f &&
        vp9_abs(q4 - q0) <= f &&
        vp9_abs(q5 - q0) <= f &&
        vp9_abs(q6 - q0) <= f &&
        vp9_abs(q7 - q0) <= f
    }
    if wd >= 8 {
      flat8in = vp9_abs(p3 - p0) <= f &&
        vp9_abs(p2 - p0) <= f &&
        vp9_abs(p1 - p0) <= f &&
        vp9_abs(q1 - q0) <= f &&
        vp9_abs(q2 - q0) <= f &&
        vp9_abs(q3 - q0) <= f
    }
    if wd >= 16 && flat8out && flat8in {
      p[o + strideb * -7] = (p7 + p7 + p7 + p7 + p7 + p7 + p7 + p6 * 2 +
      p5 + p4 + p3 + p2 + p1 + p0 + q0 + 8) >>
        4
      p[o + strideb * -6] = (p7 + p7 + p7 + p7 + p7 + p7 + p6 + p5 * 2 +
      p4 + p3 + p2 + p1 + p0 + q0 + q1 + 8) >>
        4
      p[o + strideb * -5] = (p7 + p7 + p7 + p7 + p7 + p6 + p5 + p4 * 2 +
      p3 + p2 + p1 + p0 + q0 + q1 + q2 + 8) >>
        4
      p[o + strideb * -4] = (p7 + p7 + p7 + p7 + p6 + p5 + p4 + p3 * 2 +
      p2 + p1 + p0 + q0 + q1 + q2 + q3 + 8) >>
        4
      p[o + strideb * -3] = (p7 + p7 + p7 + p6 + p5 + p4 + p3 + p2 * 2 +
      p1 + p0 + q0 + q1 + q2 + q3 + q4 + 8) >>
        4
      p[o + strideb * -2] = (p7 + p7 + p6 + p5 + p4 + p3 + p2 + p1 * 2 +
      p0 + q0 + q1 + q2 + q3 + q4 + q5 + 8) >>
        4
      p[o + strideb * -1] = (p7 + p6 + p5 + p4 + p3 + p2 + p1 + p0 * 2 +
      q0 + q1 + q2 + q3 + q4 + q5 + q6 + 8) >>
        4
      p[o + strideb * 0] = (p6 + p5 + p4 + p3 + p2 + p1 + p0 + q0 * 2 +
      q1 + q2 + q3 + q4 + q5 + q6 + q7 + 8) >>
        4
      p[o + strideb * 1] = (p5 + p4 + p3 + p2 + p1 + p0 + q0 + q1 * 2 +
      q2 + q3 + q4 + q5 + q6 + q7 + q7 + 8) >>
        4
      p[o + strideb * 2] = (p4 + p3 + p2 + p1 + p0 + q0 + q1 + q2 * 2 +
      q3 + q4 + q5 + q6 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 3] = (p3 + p2 + p1 + p0 + q0 + q1 + q2 + q3 * 2 +
      q4 + q5 + q6 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 4] = (p2 + p1 + p0 + q0 + q1 + q2 + q3 + q4 * 2 +
      q5 + q6 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 5] = (p1 + p0 + q0 + q1 + q2 + q3 + q4 + q5 * 2 +
      q6 + q7 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 6] = (p0 + q0 + q1 + q2 + q3 + q4 + q5 + q6 * 2 +
      q7 + q7 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
    } else if wd >= 8 && flat8in {
      p[o + strideb * -3] = (p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0 + 4) >> 3
      p[o + strideb * -2] = (p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1 + 4) >> 3
      p[o + strideb * -1] = (p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2 + 4) >> 3
      p[o + strideb * 0] = (p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3 + 4) >> 3
      p[o + strideb * 1] = (p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3 + 4) >> 3
      p[o + strideb * 2] = (p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3 + 4) >> 3
    } else {
      let hev = vp9_abs(p1 - p0) > h || vp9_abs(q1 - q0) > h
      if hev {
        let mut fv = vp9_clip_intp2_8(p1 - q1)
        fv = vp9_clip_intp2_8(3 * (q0 - p0) + fv)
        let f1 = vp9_min(fv + 4, 127) >> 3
        let f2 = vp9_min(fv + 3, 127) >> 3
        p[o + strideb * -1] = vp9_clip_pixel8(p0 + f2)
        p[o + strideb * 0] = vp9_clip_pixel8(q0 - f1)
      } else {
        let fv = vp9_clip_intp2_8(3 * (q0 - p0))
        let f1 = vp9_min(fv + 4, 127) >> 3
        let f2 = vp9_min(fv + 3, 127) >> 3
        p[o + strideb * -1] = vp9_clip_pixel8(p0 + f2)
        p[o + strideb * 0] = vp9_clip_pixel8(q0 - f1)
        let f = (f1 + 1) >> 1
        p[o + strideb * -2] = vp9_clip_pixel8(p1 + f)
        p[o + strideb * 1] = vp9_clip_pixel8(q1 - f)
      }
    }
    o += stridea
  }
}

///|
/// `loop_filter_h_*_8`: horizontal direction, `stridea = stride`. */
fn vp9_loop_filter_h(p : FixedArray[Int32], off : Int32, stride : Int32, e : Int32, i : Int32, h : Int32, wd : Int32) -> Unit {
  vp9_loop_filter_core(p, off, e, i, h, stride, 1, wd)
}

///|
/// `loop_filter_v_*_8`: vertical direction, `stridea = 1`. */
fn vp9_loop_filter_v(p : FixedArray[Int32], off : Int32, stride : Int32, e : Int32, i : Int32, h : Int32, wd : Int32) -> Unit {
  vp9_loop_filter_core(p, off, e, i, h, 1, stride, wd)
}

///|
/// `loop_filter_{h,v}_16_16`: two consecutive 16-wide filters. */
fn vp9_loop_filter_16(dir : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, e : Int32, i : Int32, h : Int32) -> Unit {
  if dir == 0 {
    vp9_loop_filter_h(p, off, stride, e, i, h, 16)
    vp9_loop_filter_h(p, off + 8 * stride, stride, e, i, h, 16)
  } else {
    vp9_loop_filter_v(p, off, stride, e, i, h, 16)
    vp9_loop_filter_v(p, off + 8, stride, e, i, h, 16)
  }
}

///|
/// `loop_filter_mix2`: two consecutive edges with independent (packed 16-bit
/// halves) E/I/H levels; `wd1`/`wd2` in {4, 8}. */
fn vp9_loop_filter_mix2(dir : Int32, wd1 : Int32, wd2 : Int32, p : FixedArray[Int32], off : Int32, stride : Int32, e : Int32, i : Int32, h : Int32) -> Unit {
  let e1 = e & 0xFF
  let i1 = i & 0xFF
  let h1 = h & 0xFF
  let e2 = e >> 8
  let i2 = i >> 8
  let h2 = h >> 8
  if dir == 0 {
    vp9_loop_filter_h(p, off, stride, e1, i1, h1, 4 << wd1)
    vp9_loop_filter_h(p, off + 8 * stride, stride, e2, i2, h2, 4 << wd2)
  } else {
    vp9_loop_filter_v(p, off, stride, e1, i1, h1, 4 << wd1)
    vp9_loop_filter_v(p, off + 8, stride, e2, i2, h2, 4 << wd2)
  }
}
