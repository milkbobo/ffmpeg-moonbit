///|
/// MoonBit port of the HEVC inverse transforms from FFmpeg 9.0.2
/// `libavcodec/hevc/dsp_template.c` (`idct_4x4/8x8/16x16/32x32`,
/// `idct_*_dc`, `transform_4x4_luma`, `dequant`, `add_residual`) for
/// 8/10/12-bit samples. The transforms take the coded bit depth because the
/// C templates are compiled per depth (`20 - BIT_DEPTH` shifts), and
/// `dequant` uses `15 - BIT_DEPTH - log2_size` (negative shifts for 12-bit
/// large blocks).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The integer butterflies follow the C macros (`TR_4`, `TR_8`, `TR_16`,
/// `TR_32`) with the same intermediate `int` arithmetic, `int16_t` stores and
/// `av_clip_int16` scaling. `col_limit` is the last-significant-coefficient
/// column limit from the CABAC residual parser; passing the transform size
/// gives the full 2-D transform.
///
/// Out of scope: 9/10/12-bit samples and RDPCM (portable transform variants).

///|
/// `transform[32][32]`: the HEVC integer inverse-transform basis. */
let hevc_transform_matrix : Array[Array[Int32]] = [
  [
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
    64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64, 64,
  ],
  [
    90, 90, 88, 85, 82, 78, 73, 67, 61, 54, 46, 38, 31, 22, 13, 4, -4, -13, -22,
    -31, -38, -46, -54, -61, -67, -73, -78, -82, -85, -88, -90, -90,
  ],
  [
    90, 87, 80, 70, 57, 43, 25, 9, -9, -25, -43, -57, -70, -80, -87, -90, -90, -87,
    -80, -70, -57, -43, -25, -9, 9, 25, 43, 57, 70, 80, 87, 90,
  ],
  [
    90, 82, 67, 46, 22, -4, -31, -54, -73, -85, -90, -88, -78, -61, -38, -13, 13,
    38, 61, 78, 88, 90, 85, 73, 54, 31, 4, -22, -46, -67, -82, -90,
  ],
  [
    89, 75, 50, 18, -18, -50, -75, -89, -89, -75, -50, -18, 18, 50, 75, 89, 89, 75,
    50, 18, -18, -50, -75, -89, -89, -75, -50, -18, 18, 50, 75, 89,
  ],
  [
    88, 67, 31, -13, -54, -82, -90, -78, -46, -4, 38, 73, 90, 85, 61, 22, -22, -61,
    -85, -90, -73, -38, 4, 46, 78, 90, 82, 54, 13, -31, -67, -88,
  ],
  [
    87, 57, 9, -43, -80, -90, -70, -25, 25, 70, 90, 80, 43, -9, -57, -87, -87, -57,
    -9, 43, 80, 90, 70, 25, -25, -70, -90, -80, -43, 9, 57, 87,
  ],
  [
    85, 46, -13, -67, -90, -73, -22, 38, 82, 88, 54, -4, -61, -90, -78, -31, 31,
    78, 90, 61, 4, -54, -88, -82, -38, 22, 73, 90, 67, 13, -46, -85,
  ],
  [
    83, 36, -36, -83, -83, -36, 36, 83, 83, 36, -36, -83, -83, -36, 36, 83, 83, 36,
    -36, -83, -83, -36, 36, 83, 83, 36, -36, -83, -83, -36, 36, 83,
  ],
  [
    82, 22, -54, -90, -61, 13, 78, 85, 31, -46, -90, -67, 4, 73, 88, 38, -38, -88,
    -73, -4, 67, 90, 46, -31, -85, -78, -13, 61, 90, 54, -22, -82,
  ],
  [
    80, 9, -70, -87, -25, 57, 90, 43, -43, -90, -57, 25, 87, 70, -9, -80, -80, -9,
    70, 87, 25, -57, -90, -43, 43, 90, 57, -25, -87, -70, 9, 80,
  ],
  [
    78, -4, -82, -73, 13, 85, 67, -22, -88, -61, 31, 90, 54, -38, -90, -46, 46, 90,
    38, -54, -90, -31, 61, 88, 22, -67, -85, -13, 73, 82, 4, -78,
  ],
  [
    75, -18, -89, -50, 50, 89, 18, -75, -75, 18, 89, 50, -50, -89, -18, 75, 75, -18,
    -89, -50, 50, 89, 18, -75, -75, 18, 89, 50, -50, -89, -18, 75,
  ],
  [
    73, -31, -90, -22, 78, 67, -38, -90, -13, 82, 61, -46, -88, -4, 85, 54, -54,
    -85, 4, 88, 46, -61, -82, 13, 90, 38, -67, -78, 22, 90, 31, -73,
  ],
  [
    70, -43, -87, 9, 90, 25, -80, -57, 57, 80, -25, -90, -9, 87, 43, -70, -70, 43,
    87, -9, -90, -25, 80, 57, -57, -80, 25, 90, 9, -87, -43, 70,
  ],
  [
    67, -54, -78, 38, 85, -22, -90, 4, 90, 13, -88, -31, 82, 46, -73, -61, 61, 73,
    -46, -82, 31, 88, -13, -90, -4, 90, 22, -85, -38, 78, 54, -67,
  ],
  [
    64, -64, -64, 64, 64, -64, -64, 64, 64, -64, -64, 64, 64, -64, -64, 64, 64, -64,
    -64, 64, 64, -64, -64, 64, 64, -64, -64, 64, 64, -64, -64, 64,
  ],
  [
    61, -73, -46, 82, 31, -88, -13, 90, -4, -90, 22, 85, -38, -78, 54, 67, -67, -54,
    78, 38, -85, -22, 90, 4, -90, 13, 88, -31, -82, 46, 73, -61,
  ],
  [
    57, -80, -25, 90, -9, -87, 43, 70, -70, -43, 87, 9, -90, 25, 80, -57, -57, 80,
    25, -90, 9, 87, -43, -70, 70, 43, -87, -9, 90, -25, -80, 57,
  ],
  [
    54, -85, -4, 88, -46, -61, 82, 13, -90, 38, 67, -78, -22, 90, -31, -73, 73, 31,
    -90, 22, 78, -67, -38, 90, -13, -82, 61, 46, -88, 4, 85, -54,
  ],
  [
    50, -89, 18, 75, -75, -18, 89, -50, -50, 89, -18, -75, 75, 18, -89, 50, 50, -89,
    18, 75, -75, -18, 89, -50, -50, 89, -18, -75, 75, 18, -89, 50,
  ],
  [
    46, -90, 38, 54, -90, 31, 61, -88, 22, 67, -85, 13, 73, -82, 4, 78, -78, -4,
    82, -73, -13, 85, -67, -22, 88, -61, -31, 90, -54, -38, 90, -46,
  ],
  [
    43, -90, 57, 25, -87, 70, 9, -80, 80, -9, -70, 87, -25, -57, 90, -43, -43, 90,
    -57, -25, 87, -70, -9, 80, -80, 9, 70, -87, 25, 57, -90, 43,
  ],
  [
    38, -88, 73, -4, -67, 90, -46, -31, 85, -78, 13, 61, -90, 54, 22, -82, 82, -22,
    -54, 90, -61, -13, 78, -85, 31, 46, -90, 67, 4, -73, 88, -38,
  ],
  [
    36, -83, 83, -36, -36, 83, -83, 36, 36, -83, 83, -36, -36, 83, -83, 36, 36, -83,
    83, -36, -36, 83, -83, 36, 36, -83, 83, -36, -36, 83, -83, 36,
  ],
  [
    31, -78, 90, -61, 4, 54, -88, 82, -38, -22, 73, -90, 67, -13, -46, 85, -85, 46,
    13, -67, 90, -73, 22, 38, -82, 88, -54, -4, 61, -90, 78, -31,
  ],
  [
    25, -70, 90, -80, 43, 9, -57, 87, -87, 57, -9, -43, 80, -90, 70, -25, -25, 70,
    -90, 80, -43, -9, 57, -87, 87, -57, 9, 43, -80, 90, -70, 25,
  ],
  [
    22, -61, 85, -90, 73, -38, -4, 46, -78, 90, -82, 54, -13, -31, 67, -88, 88, -67,
    31, 13, -54, 82, -90, 78, -46, 4, 38, -73, 90, -85, 61, -22,
  ],
  [
    18, -50, 75, -89, 89, -75, 50, -18, -18, 50, -75, 89, -89, 75, -50, 18, 18, -50,
    75, -89, 89, -75, 50, -18, -18, 50, -75, 89, -89, 75, -50, 18,
  ],
  [
    13, -38, 61, -78, 88, -90, 85, -73, 54, -31, 4, 22, -46, 67, -82, 90, -90, 82,
    -67, 46, -22, -4, 31, -54, 73, -85, 90, -88, 78, -61, 38, -13,
  ],
  [
    9, -25, 43, -57, 70, -80, 87, -90, 90, -87, 80, -70, 57, -43, 25, -9, -9, 25,
    -43, 57, -70, 80, -87, 90, -90, 87, -80, 70, -57, 43, -25, 9,
  ],
  [
    4, -13, 22, -31, 38, -46, 54, -61, 67, -73, 78, -82, 85, -88, 90, -90, 90, -90,
    88, -85, 82, -78, 73, -67, 61, -54, 46, -38, 31, -22, 13, -4,
  ],
]

///|
fn hevc_clip_int16(v : Int32) -> Int32 {
  if v < -32768 {
    -32768
  } else if v > 32767 {
    32767
  } else {
    v
  }
}

///|
fn hevc_i16(v : Int32) -> Int32 {
  v << 16 >> 16
}

///|
fn hevc_scale(v : Int32, add : Int32, shift : Int32) -> Int32 {
  hevc_clip_int16((v + add) >> shift)
}

///|
/// `TR_4`: the IDCT's 4-point butterfly (64/83/36). */
fn hevc_tr4(
  dst : Array[Int32],
  dst_off : Int32,
  dstep : Int32,
  src : Array[Int32],
  src_off : Int32,
  sstep : Int32,
  add : Int32,
  shift : Int32,
  clip : Bool,
) -> Unit {
  let s0 = src[src_off]
  let s1 = src[src_off + sstep]
  let s2 = src[src_off + 2 * sstep]
  let s3 = src[src_off + 3 * sstep]
  let e0 = 64 * s0 + 64 * s2
  let e1 = 64 * s0 - 64 * s2
  let o0 = 83 * s1 + 36 * s3
  let o1 = 36 * s1 - 83 * s3
  let values : Array[Int32] = [e0 + o0, e1 + o1, e1 - o1, e0 - o0]
  for i in 0..<4 {
    let v = values[i]
    dst[dst_off + i * dstep] = if clip { hevc_scale(v, add, shift) } else { v }
  }
}

///|
/// `TR_4x4_LUMA` butterfly (29/55/74) used by the 4x4 DST.
fn hevc_tr4_luma(
  dst : Array[Int32],
  dst_off : Int32,
  dstep : Int32,
  src : Array[Int32],
  src_off : Int32,
  sstep : Int32,
  add : Int32,
  shift : Int32,
  clip : Bool,
) -> Unit {
  let s0 = src[src_off]
  let s1 = src[src_off + sstep]
  let s2 = src[src_off + 2 * sstep]
  let s3 = src[src_off + 3 * sstep]
  let c0 = s0 + s2
  let c1 = s2 + s3
  let c2 = s0 - s3
  let c3 = 74 * s1
  let v0 = 29 * c0 + 55 * c1 + c3
  let v1 = 55 * c2 - 29 * c1 + c3
  let v2 = 74 * (s0 - s2 + s3)
  let v3 = 55 * c0 + 29 * c2 - c3
  let values : Array[Int32] = [v0, v1, v2, v3]
  for i in 0..<4 {
    let v = values[i]
    dst[dst_off + i * dstep] = if clip { hevc_scale(v, add, shift) } else { v }
  }
}

///|
/// Generic `TR_H` for H = 4/8/16/32: odd-part matrix rows are
/// `transform[(32/H)*j][i]`, the even part recurses into `TR_{H/2}`. */
fn hevc_tr(
  h : Int32,
  dst : Array[Int32],
  dst_off : Int32,
  dstep : Int32,
  src : Array[Int32],
  src_off : Int32,
  sstep : Int32,
  end : Int32,
  add : Int32,
  shift : Int32,
  clip : Bool,
) -> Unit {
  if h == 4 {
    hevc_tr4(dst, dst_off, dstep, src, src_off, sstep, add, shift, clip)
  } else {
    let half = h / 2
    let e : Array[Int32] = Array::make(half, 0)
    let o : Array[Int32] = Array::make(half, 0)
    let row_stride = 32 / h
    let mut j = 1
    while j < end {
      let row = hevc_transform_matrix[row_stride * j]
      for i in 0..<half {
        o[i] = o[i] + row[i] * src[src_off + j * sstep]
      }
      j = j + 2
    }
    hevc_tr(half, e, 0, 1, src, src_off, 2 * sstep, end / 2, add, shift, false)
    for i in 0..<half {
      let a = e[i] + o[i]
      let b = e[i] - o[i]
      dst[dst_off + i * dstep] = if clip {
        hevc_scale(a, add, shift)
      } else {
        a
      }
      dst[dst_off + (h - 1 - i) * dstep] = if clip {
        hevc_scale(b, add, shift)
      } else {
        b
      }
    }
  }
}

///|
/// `idct_NxN`: full 2-D inverse transform with the C's per-column limits. */
pub fn hevc_idct(
  coeffs : Array[Int32],
  log2_size : Int32,
  col_limit : Int32,
  bd : Int32,
) -> Result[Unit, String] {
  if log2_size < 2 || log2_size > 5 {
    return Err("hevc: invalid transform size")
  }
  let h = 1 << log2_size
  let mut limit2 = if col_limit + 4 < h { col_limit + 4 } else { h }
  for i in 0..<h {
    hevc_tr(h, coeffs, i, h, coeffs, i, h, limit2, 64, 7, true)
    if limit2 < h && i % 4 == 0 && i != 0 {
      limit2 = limit2 - 4
    }
  }
  let limit = if col_limit < h { col_limit } else { h }
  // vertical pass: shift = 20 - BIT_DEPTH (12 for 8-bit), with the C's
  // rounding offset 1 << (shift - 1) (2048 for 8-bit).
  let vshift = 20 - bd
  let vadd = 1 << (vshift - 1)
  for row in 0..<h {
    hevc_tr(h, coeffs, row * h, 1, coeffs, row * h, 1, limit, vadd, vshift, true)
  }
  Ok(())
}

///|
/// `idct_NxN_dc`: DC-only inverse transform. */
pub fn hevc_idct_dc(
  coeffs : Array[Int32],
  log2_size : Int32,
  bd : Int32,
) -> Result[Unit, String] {
  if log2_size < 2 || log2_size > 5 {
    return Err("hevc: invalid transform size")
  }
  let h = 1 << log2_size
  let shift : Int32 = 14 - bd
  let add : Int32 = 1 << (shift - 1)
  let coeff = (((coeffs[0] + 1) >> 1) + add) >> shift
  for i in 0..<(h * h) {
    coeffs[i] = coeff
  }
  Ok(())
}

///|
/// `transform_4x4_luma`: HEVC 4x4 DST for intra luma. */
pub fn hevc_transform_4x4_luma(coeffs : Array[Int32], bd : Int32) -> Unit {
  for i in 0..<4 {
    hevc_tr4_luma(coeffs, i, 4, coeffs, i, 4, 64, 7, true)
  }
  let vshift = 20 - bd
  let vadd = 1 << (vshift - 1)
  for row in 0..<4 {
    hevc_tr4_luma(coeffs, row * 4, 1, coeffs, row * 4, 1, vadd, vshift, true)
  }
}

///|
/// `dequant` (ITU-T H.265 8.6.3), bit-depth aware: the shift is
/// `15 - BIT_DEPTH - log2_size`; it right-shifts (with rounding) when
/// positive, is the identity when zero, and left-shifts (reinterpreting the
/// int16 bit pattern as unsigned, as the C does) for 12-bit large blocks. */
pub fn hevc_dequant(
  coeffs : Array[Int32],
  log2_size : Int32,
  bd : Int32,
) -> Result[Unit, String] {
  if log2_size < 2 || log2_size > 5 {
    return Err("hevc: invalid transform size")
  }
  let shift = 15 - bd - log2_size
  let size = (1 << log2_size) * (1 << log2_size)
  if bd <= 9 || shift > 0 {
    let offset = 1 << (shift - 1)
    for i in 0..<size {
      coeffs[i] = hevc_i16((coeffs[i] + offset) >> shift)
    }
  } else if bd > 10 && shift < 0 {
    for i in 0..<size {
      // C: *coeffs = *(uint16_t*)coeffs << -shift
      let v = ((coeffs[i] & 0xFFFF) << (0 - shift)) & 0xFFFF
      coeffs[i] = if v >= 0x8000 { v - 0x10000 } else { v }
    }
  }
  // shift == 0: identity, nothing to do
  Ok(())
}

///|
/// `add_residualNxN`: clip-add the transformed residual onto pixels
/// (`av_clip_pixel` clips to the coded bit depth). */
pub fn hevc_add_residual(
  dst : Array[Int32],
  res : Array[Int32],
  stride : Int32,
  size : Int32,
  bd : Int32,
) -> Unit {
  let max = (1 << bd) - 1
  for y in 0..<size {
    for x in 0..<size {
      let v = dst[y * stride + x] + res[y * size + x]
      dst[y * stride + x] = if v < 0 { 0 } else if v > max { max } else { v }
    }
  }
}
