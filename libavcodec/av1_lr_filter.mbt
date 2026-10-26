///|
/// AV1 loop-restoration filter kernels: literal port of dav1d 1.5.1
/// `src/looprestoration_tmpl.c` (C reference) for the stripe-level filters.
/// dav1d is BSD-2-Clause (Copyright © 2018, VideoLAN and dav1d authors);
/// this port keeps the same algorithm with LGPL-2.1-or-later packaging.

///|
/// Row buffers use a fixed stride of 400 Int32 (dav1d's BUF_STRIDE 384+16);
/// `REST_UNIT_STRIDE` (390) is used for the Wiener horizontal rows and
/// `FILTER_OUT_STRIDE` (384) for the SGR output rows.

///|
let av1_rest_unit_stride : Int32 = 390

///|
let av1_lr_filter_out_stride : Int32 = 384

///|
let av1_lr_buf_stride : Int32 = 400

///|
let av1_lr_have_left : Int32 = 1

///|
let av1_lr_have_right : Int32 = 2

///|
let av1_lr_have_top : Int32 = 4

///|
let av1_lr_have_bottom : Int32 = 8

///|
let av1_sgr_x_by_x : FixedArray[Int32] = [
  255, 128, 85, 64, 51, 43, 37, 32, 28, 26, 23, 21, 20, 18, 17, 16, 15, 14, 13, 13,
  12, 12, 11, 11, 10, 10, 9, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6,
  6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  4, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
]

///|
fn av1_lr_clip_pixel(v : Int32, bd : Int32) -> Int32 {
  let max = (1 << bd) - 1
  if v < 0 {
    0
  } else if v > max {
    max
  } else {
    v
  }
}

///|
fn av1_lr_iclip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

// ---------------------------------------------------------------------------
// Wiener

///|
/// `wiener_filter_h` (generic padding loop; identical results to dav1d's
/// width-specialised loops).
fn av1_lr_wiener_h(
  hor : FixedArray[Int32],
  dst_row : Int32,
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  fh : FixedArray[Int32],
  w : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  let round_bits_h = if bd == 12 { 5 } else { 3 }
  let rounding_off_h = 1 << (round_bits_h - 1)
  let clip_limit = 1 << (bd + 1 + 7 - round_bits_h)
  let base_sum = 1 << (bd + 6)
  let dst_base = dst_row * av1_rest_unit_stride
  for x in 0..<w {
    let mut sum = base_sum
    if bd == 8 {
      sum = sum + src[src_off + x] * 128
    }
    for i in 0..<7 {
      let idx = x + i - 3
      let v = if idx < 0 {
        if (edges & av1_lr_have_left) == 0 {
          src[src_off]
        } else {
          match left {
            Some(l) => l[left_off + 4 + idx]
            None => src[src_off + idx]
          }
        }
      } else if idx >= w && (edges & av1_lr_have_right) == 0 {
        src[src_off + w - 1]
      } else {
        src[src_off + idx]
      }
      sum = sum + v * fh[i]
    }
    hor[dst_base + x] = av1_lr_iclip(
      (sum + rounding_off_h) >> round_bits_h,
      0,
      clip_limit - 1,
    )
  }
}

///|
/// `wiener_filter_v`: one output row from the six stored horizontal rows
/// (`ptrs[5]` is duplicated as the 7th tap), then shift the window.
fn av1_lr_wiener_v(
  plane : FixedArray[Int32],
  p_off : Int32,
  hor : FixedArray[Int32],
  ptrs : FixedArray[Int32],
  fv : FixedArray[Int32],
  w : Int32,
  bd : Int32,
) -> Unit {
  let round_bits_v = if bd == 12 { 9 } else { 11 }
  let rounding_off_v = 1 << (round_bits_v - 1)
  let round_offset = 1 << (bd + round_bits_v - 1)
  for i in 0..<w {
    let mut sum = -round_offset
    for k in 0..<6 {
      sum = sum + hor[ptrs[k] * av1_rest_unit_stride + i] * fv[k]
    }
    sum = sum + hor[ptrs[5] * av1_rest_unit_stride + i] * fv[6]
    plane[p_off + i] = av1_lr_clip_pixel(
      (sum + rounding_off_v) >> round_bits_v,
      bd,
    )
  }
  for i in 0..<5 {
    ptrs[i] = ptrs[i + 1]
  }
}

///|
/// `wiener_filter_hv`: horizontal filter the new source row into
/// `ptrs[6]`, combine with the six previous rows, then rotate.
fn av1_lr_wiener_hv(
  plane : FixedArray[Int32],
  p_off : Int32,
  hor : FixedArray[Int32],
  ptrs : FixedArray[Int32],
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  fh : FixedArray[Int32],
  fv : FixedArray[Int32],
  w : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  let tmp = FixedArray::make(av1_rest_unit_stride, 0)
  av1_lr_wiener_h(tmp, 0, left, left_off, src, src_off, fh, w, edges, bd)
  let round_bits_v = if bd == 12 { 9 } else { 11 }
  let rounding_off_v = 1 << (round_bits_v - 1)
  let round_offset = 1 << (bd + round_bits_v - 1)
  for i in 0..<w {
    let mut sum = -round_offset
    for k in 0..<6 {
      sum = sum + hor[ptrs[k] * av1_rest_unit_stride + i] * fv[k]
    }
    sum = sum + tmp[i] * fv[6]
    plane[p_off + i] = av1_lr_clip_pixel(
      (sum + rounding_off_v) >> round_bits_v,
      bd,
    )
  }
  for i in 0..<w {
    hor[ptrs[6] * av1_rest_unit_stride + i] = tmp[i]
  }
  for i in 0..<6 {
    ptrs[i] = ptrs[i + 1]
  }
  ptrs[6] = ptrs[0]
}

///|
/// `wiener_c`: filter one restoration unit / stripe.
fn av1_lr_wiener(
  plane : FixedArray[Int32],
  p_off0 : Int32,
  stride : Int32,
  left : FixedArray[Int32]?,
  left_off0 : Int32,
  lpf : FixedArray[Int32],
  lpf_off0 : Int32,
  w : Int32,
  h : Int32,
  fh : FixedArray[Int32],
  fv : FixedArray[Int32],
  edges : Int32,
  bd : Int32,
) -> Unit {
  let hor = FixedArray::make(6 * av1_rest_unit_stride, 0)
  let ptrs : FixedArray[Int32] = FixedArray::make(7, 0)
  let mut p_off = p_off0
  let mut src_off = p_off0
  let mut left_off = left_off0
  let mut lpf_off = lpf_off0
  let mut lpf_bottom = lpf_off0 + 6 * stride
  let mut hh = h
  // Number of tail rows emitted after the startup / main loop (dav1d's
  // v1/v2/v3 labels emit 1/2/3 rows respectively).
  let mut tail = 1
  let mut done = false
  if (edges & av1_lr_have_top) != 0 {
    ptrs[0] = 0
    ptrs[1] = 0
    ptrs[2] = 1
    ptrs[3] = 2
    ptrs[4] = 2
    ptrs[5] = 2
    av1_lr_wiener_h(hor, 0, None, 0, lpf, lpf_off, fh, w, edges, bd)
    lpf_off = lpf_off + stride
    av1_lr_wiener_h(hor, 1, None, 0, lpf, lpf_off, fh, w, edges, bd)
    av1_lr_wiener_h(hor, 2, left, left_off, plane, src_off, fh, w, edges, bd)
    left_off = left_off + 4
    src_off = src_off + stride
    hh = hh - 1
    if hh <= 0 {
      tail = 1
      done = true
    } else {
      ptrs[4] = 3
      ptrs[5] = 3
      av1_lr_wiener_h(hor, 3, left, left_off, plane, src_off, fh, w, edges, bd)
      left_off = left_off + 4
      src_off = src_off + stride
      hh = hh - 1
      if hh <= 0 {
        tail = 2
        done = true
      } else {
        ptrs[5] = 4
        av1_lr_wiener_h(
          hor, 4, left, left_off, plane, src_off, fh, w, edges, bd,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        hh = hh - 1
        if hh <= 0 {
          tail = 3
          done = true
        }
      }
    }
  } else {
    for i in 0..<6 {
      ptrs[i] = 0
    }
    av1_lr_wiener_h(hor, 0, left, left_off, plane, src_off, fh, w, edges, bd)
    left_off = left_off + 4
    src_off = src_off + stride
    hh = hh - 1
    if hh <= 0 {
      tail = 1
      done = true
    } else {
      ptrs[4] = 1
      ptrs[5] = 1
      av1_lr_wiener_h(hor, 1, left, left_off, plane, src_off, fh, w, edges, bd)
      left_off = left_off + 4
      src_off = src_off + stride
      hh = hh - 1
      if hh <= 0 {
        tail = 2
        done = true
      } else {
        ptrs[5] = 2
        av1_lr_wiener_h(
          hor, 2, left, left_off, plane, src_off, fh, w, edges, bd,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        hh = hh - 1
        if hh <= 0 {
          tail = 3
          done = true
        } else {
          ptrs[6] = 3
          av1_lr_wiener_hv(
            plane, p_off, hor, ptrs, left, left_off, plane, src_off, fh, fv, w, edges,
            bd,
          )
          left_off = left_off + 4
          src_off = src_off + stride
          p_off = p_off + stride
          hh = hh - 1
          if hh <= 0 {
            tail = 3
            done = true
          } else {
            ptrs[6] = 4
            av1_lr_wiener_hv(
              plane, p_off, hor, ptrs, left, left_off, plane, src_off, fh, fv, w,
              edges, bd,
            )
            left_off = left_off + 4
            src_off = src_off + stride
            p_off = p_off + stride
            hh = hh - 1
            if hh <= 0 {
              tail = 3
              done = true
            }
          }
        }
      }
    }
  }
  if !done {
    ptrs[6] = ptrs[5] + 1
    while hh > 0 {
      av1_lr_wiener_hv(
        plane, p_off, hor, ptrs, left, left_off, plane, src_off, fh, fv, w, edges,
        bd,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      p_off = p_off + stride
      hh = hh - 1
    }
    if (edges & av1_lr_have_bottom) == 0 {
      tail = 3
    } else {
      av1_lr_wiener_hv(
        plane,
        p_off,
        hor,
        ptrs,
        None,
        0,
        lpf,
        lpf_bottom,
        fh,
        fv,
        w,
        edges,
        bd,
      )
      lpf_bottom = lpf_bottom + stride
      p_off = p_off + stride
      av1_lr_wiener_hv(
        plane,
        p_off,
        hor,
        ptrs,
        None,
        0,
        lpf,
        lpf_bottom,
        fh,
        fv,
        w,
        edges,
        bd,
      )
      p_off = p_off + stride
      tail = 1
    }
  }
  for _ in 0..<tail {
    av1_lr_wiener_v(plane, p_off, hor, ptrs, fv, w, bd)
    p_off = p_off + stride
  }
}

// ---------------------------------------------------------------------------
// SGR (self-guided restoration)

///|
fn av1_lr_rotate(ptrs : FixedArray[Int32], n : Int32) -> Unit {
  let t = ptrs[0]
  for i in 0..<(n - 1) {
    ptrs[i] = ptrs[i + 1]
  }
  ptrs[n - 1] = t
}

///|
fn av1_lr_rotate5_x2(ptrs : FixedArray[Int32]) -> Unit {
  let t0 = ptrs[0]
  let t1 = ptrs[1]
  for i in 0..<3 {
    ptrs[i] = ptrs[i + 2]
  }
  ptrs[3] = t0
  ptrs[4] = t1
}

///|
fn av1_sgr_box3_row_h(
  sq : FixedArray[Int32],
  sq_row : Int32,
  sum : FixedArray[Int32],
  s_row : Int32,
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  w : Int32,
  edges : Int32,
) -> Unit {
  let sqb = sq_row * av1_lr_buf_stride
  let sb = s_row * av1_lr_buf_stride
  let mut a = if (edges & av1_lr_have_left) != 0 {
    match left {
      Some(l) => l[left_off + 2]
      None => src[src_off - 2]
    }
  } else {
    src[src_off]
  }
  let mut b = if (edges & av1_lr_have_left) != 0 {
    match left {
      Some(l) => l[left_off + 3]
      None => src[src_off - 1]
    }
  } else {
    src[src_off]
  }
  let mut x = -1
  while x < w + 1 {
    let c = if x + 1 < w || (edges & av1_lr_have_right) != 0 {
      src[src_off + x + 1]
    } else {
      src[src_off + w - 1]
    }
    sum[sb + x + 1] = a + b + c
    sq[sqb + x + 1] = a * a + b * b + c * c
    a = b
    b = c
    x = x + 1
  }
}

///|
fn av1_sgr_box5_row_h(
  sq : FixedArray[Int32],
  sq_row : Int32,
  sum : FixedArray[Int32],
  s_row : Int32,
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  w : Int32,
  edges : Int32,
) -> Unit {
  let sqb = sq_row * av1_lr_buf_stride
  let sb = s_row * av1_lr_buf_stride
  let has_left = (edges & av1_lr_have_left) != 0
  let mut a = if has_left {
    match left {
      Some(l) => l[left_off + 1]
      None => src[src_off - 3]
    }
  } else {
    src[src_off]
  }
  let mut b = if has_left {
    match left {
      Some(l) => l[left_off + 2]
      None => src[src_off - 2]
    }
  } else {
    src[src_off]
  }
  let mut c = if has_left {
    match left {
      Some(l) => l[left_off + 3]
      None => src[src_off - 1]
    }
  } else {
    src[src_off]
  }
  let mut d = src[src_off]
  let mut x = -1
  while x < w + 1 {
    let e = if x + 2 < w || (edges & av1_lr_have_right) != 0 {
      src[src_off + x + 2]
    } else {
      src[src_off + w - 1]
    }
    sum[sb + x + 1] = a + b + c + d + e
    sq[sqb + x + 1] = a * a + b * b + c * c + d * d + e * e
    a = b
    b = c
    c = d
    d = e
    x = x + 1
  }
}

///|
fn av1_sgr_calc_row_ab(
  aa : FixedArray[Int32],
  a_row : Int32,
  bb : FixedArray[Int32],
  b_row : Int32,
  w : Int32,
  s : Int32,
  bd : Int32,
  n : Int32,
  one_by_x : Int32,
) -> Unit {
  let bd_min_8 = bd - 8
  let ab = a_row * av1_lr_buf_stride
  let bbase = b_row * av1_lr_buf_stride
  for i in 0..<(w + 2) {
    let a = (aa[ab + i] + (1 << (2 * bd_min_8) >> 1)) >> (2 * bd_min_8)
    let b = (bb[bbase + i] + (1 << bd_min_8 >> 1)) >> bd_min_8
    let p0 = a * n - b * b
    let p = if p0 < 0 { 0 } else { p0 }
    // dav1d does this in unsigned arithmetic; the product can wrap 32 bits.
    let z = ((p.reinterpret_as_uint() * s.reinterpret_as_uint() + 524288U) >> 20).reinterpret_as_int()
    let x = av1_sgr_x_by_x[if z > 255 { 255 } else { z }]
    aa[ab + i] = (x * bb[bbase + i] * one_by_x + (1 << 11)) >> 12
    bb[bbase + i] = x
  }
}

///|
fn av1_sgr_box3_row_v(
  sq : FixedArray[Int32],
  sqp : FixedArray[Int32],
  sq_out : FixedArray[Int32],
  sq_out_row : Int32,
  sum : FixedArray[Int32],
  smp : FixedArray[Int32],
  sum_out : FixedArray[Int32],
  sum_out_row : Int32,
  w : Int32,
) -> Unit {
  let o1 = sq_out_row * av1_lr_buf_stride
  let o2 = sum_out_row * av1_lr_buf_stride
  for x in 0..<(w + 2) {
    sq_out[o1 + x] = sq[sqp[0] * av1_lr_buf_stride + x] +
      sq[sqp[1] * av1_lr_buf_stride + x] +
      sq[sqp[2] * av1_lr_buf_stride + x]
    sum_out[o2 + x] = sum[smp[0] * av1_lr_buf_stride + x] +
      sum[smp[1] * av1_lr_buf_stride + x] +
      sum[smp[2] * av1_lr_buf_stride + x]
  }
}

///|
fn av1_sgr_box5_row_v(
  sq : FixedArray[Int32],
  sqp : FixedArray[Int32],
  sq_out : FixedArray[Int32],
  sq_out_row : Int32,
  sum : FixedArray[Int32],
  smp : FixedArray[Int32],
  sum_out : FixedArray[Int32],
  sum_out_row : Int32,
  w : Int32,
) -> Unit {
  let o1 = sq_out_row * av1_lr_buf_stride
  let o2 = sum_out_row * av1_lr_buf_stride
  for x in 0..<(w + 2) {
    sq_out[o1 + x] = sq[sqp[0] * av1_lr_buf_stride + x] +
      sq[sqp[1] * av1_lr_buf_stride + x] +
      sq[sqp[2] * av1_lr_buf_stride + x] +
      sq[sqp[3] * av1_lr_buf_stride + x] +
      sq[sqp[4] * av1_lr_buf_stride + x]
    sum_out[o2 + x] = sum[smp[0] * av1_lr_buf_stride + x] +
      sum[smp[1] * av1_lr_buf_stride + x] +
      sum[smp[2] * av1_lr_buf_stride + x] +
      sum[smp[3] * av1_lr_buf_stride + x] +
      sum[smp[4] * av1_lr_buf_stride + x]
  }
}

///|
fn av1_sgr_box3_vert(
  sq : FixedArray[Int32],
  sqp : FixedArray[Int32],
  sum : FixedArray[Int32],
  smp : FixedArray[Int32],
  aa : FixedArray[Int32],
  a_row : Int32,
  bb : FixedArray[Int32],
  b_row : Int32,
  w : Int32,
  s : Int32,
  bd : Int32,
) -> Unit {
  av1_sgr_box3_row_v(sq, sqp, aa, a_row, sum, smp, bb, b_row, w)
  av1_sgr_calc_row_ab(aa, a_row, bb, b_row, w, s, bd, 9, 455)
  av1_lr_rotate(sqp, 3)
  av1_lr_rotate(smp, 3)
}

///|
fn av1_sgr_box5_vert(
  sq : FixedArray[Int32],
  sqp : FixedArray[Int32],
  sum : FixedArray[Int32],
  smp : FixedArray[Int32],
  aa : FixedArray[Int32],
  a_row : Int32,
  bb : FixedArray[Int32],
  b_row : Int32,
  w : Int32,
  s : Int32,
  bd : Int32,
) -> Unit {
  av1_sgr_box5_row_v(sq, sqp, aa, a_row, sum, smp, bb, b_row, w)
  av1_sgr_calc_row_ab(aa, a_row, bb, b_row, w, s, bd, 25, 164)
  av1_lr_rotate5_x2(sqp)
  av1_lr_rotate5_x2(smp)
}

///|
fn av1_sgr_box3_hv(
  sq : FixedArray[Int32],
  sqp : FixedArray[Int32],
  sum : FixedArray[Int32],
  smp : FixedArray[Int32],
  aa : FixedArray[Int32],
  a_row : Int32,
  bb : FixedArray[Int32],
  b_row : Int32,
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  w : Int32,
  s : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  av1_sgr_box3_row_h(
    sq,
    sqp[2],
    sum,
    smp[2],
    left,
    left_off,
    src,
    src_off,
    w,
    edges,
  )
  av1_sgr_box3_vert(sq, sqp, sum, smp, aa, a_row, bb, b_row, w, s, bd)
}

///|
fn av1_sgr_finish_filter_row1(
  tmp : FixedArray[Int32],
  tmp_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  aa : FixedArray[Int32],
  a_p : FixedArray[Int32],
  bb : FixedArray[Int32],
  b_p : FixedArray[Int32],
  p_base : Int32,
  w : Int32,
) -> Unit {
  let pa0 = a_p[p_base] * av1_lr_buf_stride
  let pa1 = a_p[p_base + 1] * av1_lr_buf_stride
  let pa2 = a_p[p_base + 2] * av1_lr_buf_stride
  let pb0 = b_p[p_base] * av1_lr_buf_stride
  let pb1 = b_p[p_base + 1] * av1_lr_buf_stride
  let pb2 = b_p[p_base + 2] * av1_lr_buf_stride
  for i in 0..<w {
    // EIGHT_NEIGHBORS: quarter-weight cross of all three rows plus
    // three-weight diagonal corners.
    let bv = (
        bb[pb1 + i + 1] +
        bb[pb1 + i] +
        bb[pb1 + i + 2] +
        bb[pb0 + i + 1] +
        bb[pb2 + i + 1]
      ) *
      4 +
      (bb[pb0 + i] + bb[pb2 + i] + bb[pb0 + i + 2] + bb[pb2 + i + 2]) * 3
    let av = (
        aa[pa1 + i + 1] +
        aa[pa1 + i] +
        aa[pa1 + i + 2] +
        aa[pa0 + i + 1] +
        aa[pa2 + i + 1]
      ) *
      4 +
      (aa[pa0 + i] + aa[pa2 + i] + aa[pa0 + i + 2] + aa[pa2 + i + 2]) * 3
    tmp[tmp_off + i] = (av - bv * src[src_off + i] + (1 << 8)) >> 9
  }
}

///|
fn av1_sgr_finish_filter2(
  tmp : FixedArray[Int32],
  tmp_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  aa : FixedArray[Int32],
  a_p : FixedArray[Int32],
  bb : FixedArray[Int32],
  b_p : FixedArray[Int32],
  w : Int32,
  h : Int32,
) -> Unit {
  let pa0 = a_p[0] * av1_lr_buf_stride
  let pa1 = a_p[1] * av1_lr_buf_stride
  let pb0 = b_p[0] * av1_lr_buf_stride
  let pb1 = b_p[1] * av1_lr_buf_stride
  for i in 0..<w {
    let bv = (bb[pb0 + i + 1] + bb[pb1 + i + 1]) * 6 +
      (bb[pb0 + i] + bb[pb1 + i] + bb[pb0 + i + 2] + bb[pb1 + i + 2]) * 5
    let av = (aa[pa0 + i + 1] + aa[pa1 + i + 1]) * 6 +
      (aa[pa0 + i] + aa[pa1 + i] + aa[pa0 + i + 2] + aa[pa1 + i + 2]) * 5
    tmp[tmp_off + i] = (av - bv * src[src_off + i] + (1 << 8)) >> 9
  }
  if h <= 1 {
    return
  }
  let t2 = tmp_off + av1_lr_filter_out_stride
  let s2 = src_off + src_stride
  for i in 0..<w {
    let bv = bb[pb1 + i + 1] * 6 + (bb[pb1 + i] + bb[pb1 + i + 2]) * 5
    let av = aa[pa1 + i + 1] * 6 + (aa[pa1 + i] + aa[pa1 + i + 2]) * 5
    tmp[t2 + i] = (av - bv * src[s2 + i] + (1 << 7)) >> 8
  }
}

///|
fn av1_sgr_weighted_row1(
  plane : FixedArray[Int32],
  p_off : Int32,
  t1 : FixedArray[Int32],
  t1_off : Int32,
  w : Int32,
  w1 : Int32,
  bd : Int32,
) -> Unit {
  for i in 0..<w {
    let v = w1 * t1[t1_off + i]
    plane[p_off + i] = av1_lr_clip_pixel(
      plane[p_off + i] + ((v + (1 << 10)) >> 11),
      bd,
    )
  }
}

///|
fn av1_sgr_weighted2(
  plane : FixedArray[Int32],
  p_off : Int32,
  stride : Int32,
  t1 : FixedArray[Int32],
  t1_off : Int32,
  t2 : FixedArray[Int32],
  t2_off : Int32,
  w : Int32,
  h : Int32,
  w0 : Int32,
  w1 : Int32,
  bd : Int32,
) -> Unit {
  for j in 0..<h {
    for i in 0..<w {
      let v = w0 * t1[t1_off + j * av1_lr_filter_out_stride + i] +
        w1 * t2[t2_off + j * av1_lr_filter_out_stride + i]
      plane[p_off + j * stride + i] = av1_lr_clip_pixel(
        plane[p_off + j * stride + i] + ((v + (1 << 10)) >> 11),
        bd,
      )
    }
  }
}

///|
fn av1_sgr_finish1(
  plane : FixedArray[Int32],
  p_off : Int32,
  stride : Int32,
  aa : FixedArray[Int32],
  a_p : FixedArray[Int32],
  bb : FixedArray[Int32],
  b_p : FixedArray[Int32],
  tmp : FixedArray[Int32],
  w : Int32,
  w1 : Int32,
  bd : Int32,
) -> Int32 {
  av1_sgr_finish_filter_row1(tmp, 0, plane, p_off, aa, a_p, bb, b_p, 0, w)
  av1_sgr_weighted_row1(plane, p_off, tmp, 0, w, w1, bd)
  av1_lr_rotate(a_p, 3)
  av1_lr_rotate(b_p, 3)
  p_off + stride
}

///|
fn av1_sgr_finish2(
  plane : FixedArray[Int32],
  p_off : Int32,
  stride : Int32,
  aa : FixedArray[Int32],
  a_p : FixedArray[Int32],
  bb : FixedArray[Int32],
  b_p : FixedArray[Int32],
  tmp : FixedArray[Int32],
  w : Int32,
  h : Int32,
  w1 : Int32,
  bd : Int32,
) -> Int32 {
  av1_sgr_finish_filter2(tmp, 0, plane, p_off, stride, aa, a_p, bb, b_p, w, h)
  av1_sgr_weighted_row1(plane, p_off, tmp, 0, w, w1, bd)
  if h > 1 {
    av1_sgr_weighted_row1(
      plane,
      p_off + stride,
      tmp,
      av1_lr_filter_out_stride,
      w,
      w1,
      bd,
    )
  }
  av1_lr_rotate(a_p, 2)
  av1_lr_rotate(b_p, 2)
  p_off + h * stride
}

///|
fn av1_sgr_finish_mix(
  plane : FixedArray[Int32],
  p_off : Int32,
  stride : Int32,
  a5 : FixedArray[Int32],
  a5_p : FixedArray[Int32],
  b5 : FixedArray[Int32],
  b5_p : FixedArray[Int32],
  a3 : FixedArray[Int32],
  a3_p : FixedArray[Int32],
  b3 : FixedArray[Int32],
  b3_p : FixedArray[Int32],
  tmp5 : FixedArray[Int32],
  tmp3 : FixedArray[Int32],
  w : Int32,
  h : Int32,
  w0 : Int32,
  w1 : Int32,
  bd : Int32,
) -> Int32 {
  av1_sgr_finish_filter2(
    tmp5, 0, plane, p_off, stride, a5, a5_p, b5, b5_p, w, h,
  )
  av1_sgr_finish_filter_row1(tmp3, 0, plane, p_off, a3, a3_p, b3, b3_p, 0, w)
  if h > 1 {
    av1_sgr_finish_filter_row1(
      tmp3,
      av1_lr_filter_out_stride,
      plane,
      p_off + stride,
      a3,
      a3_p,
      b3,
      b3_p,
      1,
      w,
    )
  }
  av1_sgr_weighted2(plane, p_off, stride, tmp5, 0, tmp3, 0, w, h, w0, w1, bd)
  av1_lr_rotate(a5_p, 2)
  av1_lr_rotate(b5_p, 2)
  av1_lr_rotate(a3_p, 4)
  av1_lr_rotate(b3_p, 4)
  p_off + h * stride
}

///|
fn av1_sgr_box35_row_h(
  sq3 : FixedArray[Int32],
  sq3_row : Int32,
  sm3 : FixedArray[Int32],
  sq5 : FixedArray[Int32],
  sq5_row : Int32,
  sm5 : FixedArray[Int32],
  left : FixedArray[Int32]?,
  left_off : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  w : Int32,
  edges : Int32,
) -> Unit {
  av1_sgr_box3_row_h(
    sq3, sq3_row, sm3, sq3_row, left, left_off, src, src_off, w, edges,
  )
  av1_sgr_box5_row_h(
    sq5, sq5_row, sm5, sq5_row, left, left_off, src, src_off, w, edges,
  )
}

///|
/// `sgr_3x3_c`: filter one restoration unit / stripe.
fn av1_lr_sgr3(
  plane : FixedArray[Int32],
  p_off0 : Int32,
  stride : Int32,
  left : FixedArray[Int32]?,
  left_off0 : Int32,
  lpf : FixedArray[Int32],
  lpf_off0 : Int32,
  w : Int32,
  h : Int32,
  s1 : Int32,
  w1 : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  let sq = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let sm = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let aa = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let bb = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let sqp : FixedArray[Int32] = FixedArray::make(3, 0)
  let smp : FixedArray[Int32] = FixedArray::make(3, 0)
  let ap : FixedArray[Int32] = [0, 1, 2]
  let bp : FixedArray[Int32] = [0, 1, 2]
  let tmp = FixedArray::make(av1_lr_filter_out_stride, 0)
  let mut p_off = p_off0
  let mut src_off = p_off0
  let mut left_off = left_off0
  let mut lpf_off = lpf_off0
  let mut lpf_bottom = lpf_off0 + 6 * stride
  let mut hh = h
  // 0 = normal, 1 = vert_2 (2 rows), 2 = vert_1 (1 row)
  let mut mode = 0
  let mut done = false
  if (edges & av1_lr_have_top) != 0 {
    sqp[0] = 0
    sqp[1] = 1
    sqp[2] = 2
    smp[0] = 0
    smp[1] = 1
    smp[2] = 2
    av1_sgr_box3_row_h(sq, 0, sm, 0, None, 0, lpf, lpf_off, w, edges)
    lpf_off = lpf_off + stride
    av1_sgr_box3_row_h(sq, 1, sm, 1, None, 0, lpf, lpf_off, w, edges)
    av1_sgr_box3_hv(
      sq,
      sqp,
      sm,
      smp,
      aa,
      ap[2],
      bb,
      bp[2],
      left,
      left_off,
      plane,
      src_off,
      w,
      s1,
      edges,
      bd,
    )
    left_off = left_off + 4
    src_off = src_off + stride
    av1_lr_rotate(ap, 3)
    av1_lr_rotate(bp, 3)
    hh = hh - 1
    if hh <= 0 {
      mode = 2
      done = true
    } else {
      av1_sgr_box3_hv(
        sq,
        sqp,
        sm,
        smp,
        aa,
        ap[2],
        bb,
        bp[2],
        left,
        left_off,
        plane,
        src_off,
        w,
        s1,
        edges,
        bd,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      av1_lr_rotate(ap, 3)
      av1_lr_rotate(bp, 3)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      }
    }
  } else {
    sqp[0] = 0
    sqp[1] = 0
    sqp[2] = 0
    smp[0] = 0
    smp[1] = 0
    smp[2] = 0
    av1_sgr_box3_row_h(sq, 0, sm, 0, left, left_off, plane, src_off, w, edges)
    left_off = left_off + 4
    src_off = src_off + stride
    av1_sgr_box3_vert(sq, sqp, sm, smp, aa, ap[2], bb, bp[2], w, s1, bd)
    av1_lr_rotate(ap, 3)
    av1_lr_rotate(bp, 3)
    hh = hh - 1
    if hh <= 0 {
      mode = 2
      done = true
    } else {
      sqp[2] = 1
      smp[2] = 1
      av1_sgr_box3_hv(
        sq,
        sqp,
        sm,
        smp,
        aa,
        ap[2],
        bb,
        bp[2],
        left,
        left_off,
        plane,
        src_off,
        w,
        s1,
        edges,
        bd,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      av1_lr_rotate(ap, 3)
      av1_lr_rotate(bp, 3)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      } else {
        sqp[2] = 2
        smp[2] = 2
      }
    }
  }
  if !done {
    while hh > 0 {
      av1_sgr_box3_hv(
        sq,
        sqp,
        sm,
        smp,
        aa,
        ap[2],
        bb,
        bp[2],
        left,
        left_off,
        plane,
        src_off,
        w,
        s1,
        edges,
        bd,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      p_off = av1_sgr_finish1(
        plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
      )
      hh = hh - 1
    }
    if (edges & av1_lr_have_bottom) == 0 {
      mode = 1
    } else {
      av1_sgr_box3_hv(
        sq,
        sqp,
        sm,
        smp,
        aa,
        ap[2],
        bb,
        bp[2],
        None,
        0,
        lpf,
        lpf_bottom,
        w,
        s1,
        edges,
        bd,
      )
      lpf_bottom = lpf_bottom + stride
      p_off = av1_sgr_finish1(
        plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
      )
      av1_sgr_box3_hv(
        sq,
        sqp,
        sm,
        smp,
        aa,
        ap[2],
        bb,
        bp[2],
        None,
        0,
        lpf,
        lpf_bottom,
        w,
        s1,
        edges,
        bd,
      )
      p_off = av1_sgr_finish1(
        plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
      )
      return
    }
  }
  if mode == 1 {
    sqp[2] = sqp[1]
    smp[2] = smp[1]
    av1_sgr_box3_vert(sq, sqp, sm, smp, aa, ap[2], bb, bp[2], w, s1, bd)
    p_off = av1_sgr_finish1(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
    )
    sqp[2] = sqp[1]
    smp[2] = smp[1]
    av1_sgr_box3_vert(sq, sqp, sm, smp, aa, ap[2], bb, bp[2], w, s1, bd)
    p_off = av1_sgr_finish1(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
    )
  } else if mode == 2 {
    sqp[2] = sqp[1]
    smp[2] = smp[1]
    av1_sgr_box3_vert(sq, sqp, sm, smp, aa, ap[2], bb, bp[2], w, s1, bd)
    av1_lr_rotate(ap, 3)
    av1_lr_rotate(bp, 3)
    sqp[2] = sqp[1]
    smp[2] = smp[1]
    av1_sgr_box3_vert(sq, sqp, sm, smp, aa, ap[2], bb, bp[2], w, s1, bd)
    p_off = av1_sgr_finish1(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, w1, bd,
    )
  }
}

///|
/// `sgr_5x5_c`: filter one restoration unit / stripe.
fn av1_lr_sgr5(
  plane : FixedArray[Int32],
  p_off0 : Int32,
  stride : Int32,
  left : FixedArray[Int32]?,
  left_off0 : Int32,
  lpf : FixedArray[Int32],
  lpf_off0 : Int32,
  w : Int32,
  h : Int32,
  s0 : Int32,
  w0 : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  let sq = FixedArray::make(5 * av1_lr_buf_stride, 0)
  let sm = FixedArray::make(5 * av1_lr_buf_stride, 0)
  let aa = FixedArray::make(2 * av1_lr_buf_stride, 0)
  let bb = FixedArray::make(2 * av1_lr_buf_stride, 0)
  let sqp : FixedArray[Int32] = FixedArray::make(5, 0)
  let smp : FixedArray[Int32] = FixedArray::make(5, 0)
  let ap : FixedArray[Int32] = [0, 1]
  let bp : FixedArray[Int32] = [0, 1]
  let tmp = FixedArray::make(2 * av1_lr_filter_out_stride, 0)
  let mut p_off = p_off0
  let mut src_off = p_off0
  let mut left_off = left_off0
  let mut lpf_off = lpf_off0
  let mut lpf_bottom = lpf_off0 + 6 * stride
  let mut hh = h
  // 0 = normal, 1 = vert_2 (2 rows), 2 = odd (2 + 1 rows), 3 = vert_1 (1 row)
  let mut mode = 0
  let mut done = false
  if (edges & av1_lr_have_top) != 0 {
    sqp[0] = 0
    sqp[1] = 0
    sqp[2] = 1
    sqp[3] = 2
    sqp[4] = 3
    smp[0] = 0
    smp[1] = 0
    smp[2] = 1
    smp[3] = 2
    smp[4] = 3
    av1_sgr_box5_row_h(sq, 0, sm, 0, None, 0, lpf, lpf_off, w, edges)
    lpf_off = lpf_off + stride
    av1_sgr_box5_row_h(sq, 1, sm, 1, None, 0, lpf, lpf_off, w, edges)
    av1_sgr_box5_row_h(sq, 2, sm, 2, left, left_off, plane, src_off, w, edges)
    left_off = left_off + 4
    src_off = src_off + stride
    hh = hh - 1
    if hh <= 0 {
      mode = 3
      done = true
    } else {
      av1_sgr_box5_row_h(sq, 3, sm, 3, left, left_off, plane, src_off, w, edges)
      left_off = left_off + 4
      src_off = src_off + stride
      av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
      av1_lr_rotate(ap, 2)
      av1_lr_rotate(bp, 2)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      } else {
        sqp[3] = 4
        smp[3] = 4
      }
    }
  } else {
    for i in 0..<5 {
      sqp[i] = 0
      smp[i] = 0
    }
    av1_sgr_box5_row_h(sq, 0, sm, 0, left, left_off, plane, src_off, w, edges)
    left_off = left_off + 4
    src_off = src_off + stride
    hh = hh - 1
    if hh <= 0 {
      mode = 3
      done = true
    } else {
      sqp[4] = 1
      smp[4] = 1
      av1_sgr_box5_row_h(sq, 1, sm, 1, left, left_off, plane, src_off, w, edges)
      left_off = left_off + 4
      src_off = src_off + stride
      av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
      av1_lr_rotate(ap, 2)
      av1_lr_rotate(bp, 2)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      } else {
        sqp[3] = 2
        sqp[4] = 3
        smp[3] = 2
        smp[4] = 3
        av1_sgr_box5_row_h(
          sq, 2, sm, 2, left, left_off, plane, src_off, w, edges,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        hh = hh - 1
        if hh <= 0 {
          mode = 2
          done = true
        } else {
          av1_sgr_box5_row_h(
            sq, 3, sm, 3, left, left_off, plane, src_off, w, edges,
          )
          left_off = left_off + 4
          src_off = src_off + stride
          av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
          p_off = av1_sgr_finish2(
            plane, p_off, stride, aa, ap, bb, bp, tmp, w, 2, w0, bd,
          )
          hh = hh - 1
          if hh <= 0 {
            mode = 1
            done = true
          } else {
            sqp[3] = 4
            smp[3] = 4
          }
        }
      }
    }
  }
  if !done {
    while hh > 0 {
      av1_sgr_box5_row_h(
        sq,
        sqp[3],
        sm,
        smp[3],
        left,
        left_off,
        plane,
        src_off,
        w,
        edges,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      hh = hh - 1
      if hh <= 0 {
        mode = 2
        done = true
      } else {
        av1_sgr_box5_row_h(
          sq,
          sqp[4],
          sm,
          smp[4],
          left,
          left_off,
          plane,
          src_off,
          w,
          edges,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
        p_off = av1_sgr_finish2(
          plane, p_off, stride, aa, ap, bb, bp, tmp, w, 2, w0, bd,
        )
        hh = hh - 1
      }
    }
    if !done {
      if (edges & av1_lr_have_bottom) == 0 {
        mode = 1
      } else {
        av1_sgr_box5_row_h(
          sq,
          sqp[3],
          sm,
          smp[3],
          None,
          0,
          lpf,
          lpf_bottom,
          w,
          edges,
        )
        lpf_bottom = lpf_bottom + stride
        av1_sgr_box5_row_h(
          sq,
          sqp[4],
          sm,
          smp[4],
          None,
          0,
          lpf,
          lpf_bottom,
          w,
          edges,
        )
        // output_2
        av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
        p_off = av1_sgr_finish2(
          plane, p_off, stride, aa, ap, bb, bp, tmp, w, 2, w0, bd,
        )
        return
      }
    }
  }
  if mode == 1 {
    sqp[3] = sqp[2]
    sqp[4] = sqp[2]
    smp[3] = smp[2]
    smp[4] = smp[2]
    av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
    p_off = av1_sgr_finish2(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, 2, w0, bd,
    )
  } else if mode == 2 {
    sqp[4] = sqp[3]
    smp[4] = smp[3]
    av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
    p_off = av1_sgr_finish2(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, 2, w0, bd,
    )
    // output_1
    sqp[3] = sqp[2]
    sqp[4] = sqp[2]
    smp[3] = smp[2]
    smp[4] = smp[2]
    av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
    p_off = av1_sgr_finish2(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, 1, w0, bd,
    )
  } else if mode == 3 {
    sqp[4] = sqp[3]
    smp[4] = smp[3]
    av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
    av1_lr_rotate(ap, 2)
    av1_lr_rotate(bp, 2)
    // output_1
    sqp[3] = sqp[2]
    sqp[4] = sqp[2]
    smp[3] = smp[2]
    smp[4] = smp[2]
    av1_sgr_box5_vert(sq, sqp, sm, smp, aa, ap[1], bb, bp[1], w, s0, bd)
    p_off = av1_sgr_finish2(
      plane, p_off, stride, aa, ap, bb, bp, tmp, w, 1, w0, bd,
    )
  }
}

///|
/// `sgr_mix_c`: filter one restoration unit / stripe with both radii.
fn av1_lr_sgr_mix(
  plane : FixedArray[Int32],
  p_off0 : Int32,
  stride : Int32,
  left : FixedArray[Int32]?,
  left_off0 : Int32,
  lpf : FixedArray[Int32],
  lpf_off0 : Int32,
  w : Int32,
  h : Int32,
  s0 : Int32,
  s1 : Int32,
  w0 : Int32,
  w1 : Int32,
  edges : Int32,
  bd : Int32,
) -> Unit {
  let sq5 = FixedArray::make(5 * av1_lr_buf_stride, 0)
  let sm5 = FixedArray::make(5 * av1_lr_buf_stride, 0)
  let sq3 = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let sm3 = FixedArray::make(3 * av1_lr_buf_stride, 0)
  let a5 = FixedArray::make(2 * av1_lr_buf_stride, 0)
  let b5 = FixedArray::make(2 * av1_lr_buf_stride, 0)
  let a3 = FixedArray::make(4 * av1_lr_buf_stride, 0)
  let b3 = FixedArray::make(4 * av1_lr_buf_stride, 0)
  let sq5p : FixedArray[Int32] = FixedArray::make(5, 0)
  let sm5p : FixedArray[Int32] = FixedArray::make(5, 0)
  let sq3p : FixedArray[Int32] = FixedArray::make(3, 0)
  let sm3p : FixedArray[Int32] = FixedArray::make(3, 0)
  let a5p : FixedArray[Int32] = [0, 1]
  let b5p : FixedArray[Int32] = [0, 1]
  let a3p : FixedArray[Int32] = [0, 1, 2, 3]
  let b3p : FixedArray[Int32] = [0, 1, 2, 3]
  let tmp5 = FixedArray::make(2 * av1_lr_filter_out_stride, 0)
  let tmp3 = FixedArray::make(2 * av1_lr_filter_out_stride, 0)
  let mut p_off = p_off0
  let mut src_off = p_off0
  let mut left_off = left_off0
  let mut lpf_off = lpf_off0
  let mut lpf_bottom = lpf_off0 + 6 * stride
  let mut hh = h
  // 0 = normal, 1 = vert_2 (2 rows), 2 = odd (2 + 1 rows), 3 = vert_1 (1 row)
  let mut mode = 0
  let mut done = false
  if (edges & av1_lr_have_top) != 0 {
    sq5p[0] = 0
    sq5p[1] = 0
    sq5p[2] = 1
    sq5p[3] = 2
    sq5p[4] = 3
    sm5p[0] = 0
    sm5p[1] = 0
    sm5p[2] = 1
    sm5p[3] = 2
    sm5p[4] = 3
    sq3p[0] = 0
    sq3p[1] = 1
    sq3p[2] = 2
    sm3p[0] = 0
    sm3p[1] = 1
    sm3p[2] = 2
    av1_sgr_box35_row_h(
      sq3,
      0,
      sm3,
      sq5,
      0,
      sm5,
      None,
      0,
      lpf,
      lpf_off,
      w,
      edges,
    )
    lpf_off = lpf_off + stride
    av1_sgr_box35_row_h(
      sq3,
      1,
      sm3,
      sq5,
      1,
      sm5,
      None,
      0,
      lpf,
      lpf_off,
      w,
      edges,
    )
    av1_sgr_box35_row_h(
      sq3, 2, sm3, sq5, 2, sm5, left, left_off, plane, src_off, w, edges,
    )
    left_off = left_off + 4
    src_off = src_off + stride
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    hh = hh - 1
    if hh <= 0 {
      mode = 3
      done = true
    } else {
      av1_sgr_box35_row_h(
        sq3,
        sq3p[2],
        sm3,
        sq5,
        3,
        sm5,
        left,
        left_off,
        plane,
        src_off,
        w,
        edges,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
      av1_lr_rotate(a5p, 2)
      av1_lr_rotate(b5p, 2)
      av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
      av1_lr_rotate(a3p, 4)
      av1_lr_rotate(b3p, 4)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      } else {
        sq5p[3] = 4
        sm5p[3] = 4
      }
    }
  } else {
    for i in 0..<5 {
      sq5p[i] = 0
      sm5p[i] = 0
    }
    for i in 0..<3 {
      sq3p[i] = 0
      sm3p[i] = 0
    }
    av1_sgr_box35_row_h(
      sq3, 0, sm3, sq5, 0, sm5, left, left_off, plane, src_off, w, edges,
    )
    left_off = left_off + 4
    src_off = src_off + stride
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    hh = hh - 1
    if hh <= 0 {
      mode = 3
      done = true
    } else {
      sq5p[4] = 1
      sm5p[4] = 1
      sq3p[2] = 1
      sm3p[2] = 1
      av1_sgr_box35_row_h(
        sq3, 1, sm3, sq5, 1, sm5, left, left_off, plane, src_off, w, edges,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
      av1_lr_rotate(a5p, 2)
      av1_lr_rotate(b5p, 2)
      av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
      av1_lr_rotate(a3p, 4)
      av1_lr_rotate(b3p, 4)
      hh = hh - 1
      if hh <= 0 {
        mode = 1
        done = true
      } else {
        sq5p[3] = 2
        sq5p[4] = 3
        sm5p[3] = 2
        sm5p[4] = 3
        sq3p[2] = 2
        sm3p[2] = 2
        av1_sgr_box35_row_h(
          sq3, 2, sm3, sq5, 2, sm5, left, left_off, plane, src_off, w, edges,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        av1_sgr_box3_vert(
          sq3,
          sq3p,
          sm3,
          sm3p,
          a3,
          a3p[3],
          b3,
          b3p[3],
          w,
          s1,
          bd,
        )
        av1_lr_rotate(a3p, 4)
        av1_lr_rotate(b3p, 4)
        hh = hh - 1
        if hh <= 0 {
          mode = 2
          done = true
        } else {
          av1_sgr_box35_row_h(
            sq3,
            sq3p[2],
            sm3,
            sq5,
            3,
            sm5,
            left,
            left_off,
            plane,
            src_off,
            w,
            edges,
          )
          left_off = left_off + 4
          src_off = src_off + stride
          av1_sgr_box5_vert(
            sq5,
            sq5p,
            sm5,
            sm5p,
            a5,
            a5p[1],
            b5,
            b5p[1],
            w,
            s0,
            bd,
          )
          av1_sgr_box3_vert(
            sq3,
            sq3p,
            sm3,
            sm3p,
            a3,
            a3p[3],
            b3,
            b3p[3],
            w,
            s1,
            bd,
          )
          p_off = av1_sgr_finish_mix(
            plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3,
            w, 2, w0, w1, bd,
          )
          hh = hh - 1
          if hh <= 0 {
            mode = 1
            done = true
          } else {
            sq5p[3] = 4
            sm5p[3] = 4
          }
        }
      }
    }
  }
  if !done {
    while hh > 0 {
      av1_sgr_box35_row_h(
        sq3,
        sq3p[2],
        sm3,
        sq5,
        sq5p[3],
        sm5,
        left,
        left_off,
        plane,
        src_off,
        w,
        edges,
      )
      left_off = left_off + 4
      src_off = src_off + stride
      av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
      av1_lr_rotate(a3p, 4)
      av1_lr_rotate(b3p, 4)
      hh = hh - 1
      if hh <= 0 {
        mode = 2
        done = true
      } else {
        av1_sgr_box35_row_h(
          sq3,
          sq3p[2],
          sm3,
          sq5,
          sq5p[4],
          sm5,
          left,
          left_off,
          plane,
          src_off,
          w,
          edges,
        )
        left_off = left_off + 4
        src_off = src_off + stride
        av1_sgr_box5_vert(
          sq5,
          sq5p,
          sm5,
          sm5p,
          a5,
          a5p[1],
          b5,
          b5p[1],
          w,
          s0,
          bd,
        )
        av1_sgr_box3_vert(
          sq3,
          sq3p,
          sm3,
          sm3p,
          a3,
          a3p[3],
          b3,
          b3p[3],
          w,
          s1,
          bd,
        )
        p_off = av1_sgr_finish_mix(
          plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w,
          2, w0, w1, bd,
        )
        hh = hh - 1
      }
    }
    if !done {
      if (edges & av1_lr_have_bottom) == 0 {
        mode = 1
      } else {
        av1_sgr_box35_row_h(
          sq3,
          sq3p[2],
          sm3,
          sq5,
          sq5p[3],
          sm5,
          None,
          0,
          lpf,
          lpf_bottom,
          w,
          edges,
        )
        lpf_bottom = lpf_bottom + stride
        av1_sgr_box3_vert(
          sq3,
          sq3p,
          sm3,
          sm3p,
          a3,
          a3p[3],
          b3,
          b3p[3],
          w,
          s1,
          bd,
        )
        av1_lr_rotate(a3p, 4)
        av1_lr_rotate(b3p, 4)
        av1_sgr_box35_row_h(
          sq3,
          sq3p[2],
          sm3,
          sq5,
          sq5p[4],
          sm5,
          None,
          0,
          lpf,
          lpf_bottom,
          w,
          edges,
        )
        // output_2
        av1_sgr_box5_vert(
          sq5,
          sq5p,
          sm5,
          sm5p,
          a5,
          a5p[1],
          b5,
          b5p[1],
          w,
          s0,
          bd,
        )
        av1_sgr_box3_vert(
          sq3,
          sq3p,
          sm3,
          sm3p,
          a3,
          a3p[3],
          b3,
          b3p[3],
          w,
          s1,
          bd,
        )
        p_off = av1_sgr_finish_mix(
          plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w,
          2, w0, w1, bd,
        )
        return
      }
    }
  }
  if mode == 1 {
    sq5p[3] = sq5p[2]
    sq5p[4] = sq5p[2]
    sm5p[3] = sm5p[2]
    sm5p[4] = sm5p[2]
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    // output_2
    av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    p_off = av1_sgr_finish_mix(
      plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w, 2,
      w0, w1, bd,
    )
  } else if mode == 2 {
    sq5p[4] = sq5p[3]
    sm5p[4] = sm5p[3]
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    p_off = av1_sgr_finish_mix(
      plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w, 2,
      w0, w1, bd,
    )
    // output_1
    sq5p[3] = sq5p[2]
    sq5p[4] = sq5p[2]
    sm5p[3] = sm5p[2]
    sm5p[4] = sm5p[2]
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    p_off = av1_sgr_finish_mix(
      plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w, 1,
      w0, w1, bd,
    )
  } else if mode == 3 {
    sq5p[4] = sq5p[3]
    sm5p[4] = sm5p[3]
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
    av1_lr_rotate(a5p, 2)
    av1_lr_rotate(b5p, 2)
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    // output_1
    sq5p[3] = sq5p[2]
    sq5p[4] = sq5p[2]
    sm5p[3] = sm5p[2]
    sm5p[4] = sm5p[2]
    sq3p[2] = sq3p[1]
    sm3p[2] = sm3p[1]
    av1_sgr_box5_vert(sq5, sq5p, sm5, sm5p, a5, a5p[1], b5, b5p[1], w, s0, bd)
    av1_sgr_box3_vert(sq3, sq3p, sm3, sm3p, a3, a3p[3], b3, b3p[3], w, s1, bd)
    av1_lr_rotate(a3p, 4)
    av1_lr_rotate(b3p, 4)
    p_off = av1_sgr_finish_mix(
      plane, p_off, stride, a5, a5p, b5, b5p, a3, a3p, b3, b3p, tmp5, tmp3, w, 1,
      w0, w1, bd,
    )
  }
}

///|
/// Regression probe used by `libavcodec/lr_kernel`: run one LR kernel with
/// explicit buffers, mirroring dav1d's C reference harness.
pub fn av1_lr_filter_probe(
  kind : Int32,
  w : Int32,
  h : Int32,
  edges : Int32,
  p0 : Int32,
  p1 : Int32,
  p2 : Int32,
  q0 : Int32,
  q1 : Int32,
  plane : FixedArray[Int32],
  left : FixedArray[Int32],
  lpf : FixedArray[Int32],
  p_off : Int32,
  left_off : Int32,
  lpf_off : Int32,
  stride : Int32,
  bd : Int32,
) -> Unit {
  let left_opt : FixedArray[Int32]? = if (edges & av1_lr_have_left) != 0 {
    Some(left)
  } else {
    None
  }
  if kind <= 1 {
    let fh = FixedArray::make(8, 0)
    let fv = FixedArray::make(8, 0)
    fh[0] = p0
    fh[6] = p0
    fh[1] = p1
    fh[5] = p1
    fh[2] = p2
    fh[4] = p2
    fh[3] = -(p0 + p1 + p2) * 2
    fv[0] = p1
    fv[6] = p1
    fv[1] = p2
    fv[5] = p2
    fv[2] = p0
    fv[4] = p0
    fv[3] = 128 - (p1 + p2 + p0) * 2
    av1_lr_wiener(
      plane, p_off, stride, left_opt, left_off, lpf, lpf_off, w, h, fh, fv, edges,
      bd,
    )
  } else if kind == 2 {
    av1_lr_sgr3(
      plane, p_off, stride, left_opt, left_off, lpf, lpf_off, w, h, p1, q1, edges,
      bd,
    )
  } else if kind == 3 {
    av1_lr_sgr5(
      plane, p_off, stride, left_opt, left_off, lpf, lpf_off, w, h, p0, q0, edges,
      bd,
    )
  } else {
    av1_lr_sgr_mix(
      plane, p_off, stride, left_opt, left_off, lpf, lpf_off, w, h, p0, p1, q0, q1,
      edges, bd,
    )
  }
}
