///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/h264idct_template.c` for the
/// 8-bit H.264 4x4 inverse transform and the luma/chroma DC dequantisation
/// transforms.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2004-2011
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Scope: `ff_h264_idct_add`, `ff_h264_idct8_add`, `ff_h264_idct_dc_add`,
/// `ff_h264_luma_dc_dequant_idct` and `ff_h264_chroma_dc_dequant_idct`.
/// The CAVLC decoder still rejects 8x8DCT macroblocks.
///
/// Implementation notes:
///   * The C `SUINT` accumulators are modelled with 32-bit `UInt` so the
///     wrapping arithmetic is bit-identical; `dctcoef` stores truncate to
///     `int16_t` exactly like the C stores into `int16_t`.
///   * Pixels are kept as `Int` in this port's frame buffers; adds and clips
///     produce the same 8-bit result as `av_clip_pixel`.

///|
/// Reinterpret a signed 32-bit value as the C `unsigned`/`SUINT`. */
fn h264_u(x : Int32) -> UInt32 {
  x.reinterpret_as_uint()
}

///|
/// Reinterpret a C `unsigned` accumulator as `int`. */
fn h264_s(x : UInt32) -> Int32 {
  x.reinterpret_as_int()
}

///|
/// Truncate to `int16_t` (sign-extend the low 16 bits). */
fn h264_i16(x : Int32) -> Int32 {
  x << 16 >> 16
}

///|
/// `av_clip_pixel` for 8-bit pixels. */
fn h264_clip8(x : Int32, bit_depth~ : Int32 = 8) -> Int32 {
  if x < 0 {
    0
  } else if x > (1 << bit_depth) - 1 {
    (1 << bit_depth) - 1
  } else {
    x
  }
}

///|
/// `h264_add_pixels4_clear`: transform bypass residual add for a 4x4 block
/// (coefficients are spatial differences and are cleared afterwards).
fn h264_add_pixels4(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for y = 0; y < 4; y = y + 1 {
    for x = 0; x < 4; x = x + 1 {
      let i = y * 4 + x
      let mask = (1 << bit_depth) - 1
      dst[off + y * stride + x] = (dst[off + y * stride + x] + block[bo + i]) &
        mask
      block[bo + i] = 0
    }
  }
}

///|
/// `h264_add_pixels8_clear`: transform bypass residual add for an 8x8 block. */
fn h264_add_pixels8(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for y = 0; y < 8; y = y + 1 {
    for x = 0; x < 8; x = x + 1 {
      let i = y * 8 + x
      let mask = (1 << bit_depth) - 1
      dst[off + y * stride + x] = (dst[off + y * stride + x] + block[bo + i]) &
        mask
      block[bo + i] = 0
    }
  }
}

///|
/// `pred4x4_vertical_add`: transform-bypass vertical prediction with residual
/// accumulated down each column (FFmpeg's profile-244 kernel).
fn h264_add_pixels4_vertical(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let mask = (1 << bit_depth) - 1
  for x = 0; x < 4; x = x + 1 {
    let mut v = dst[off - stride + x]
    for y = 0; y < 4; y = y + 1 {
      v = (v + block[bo + y * 4 + x]) & mask
      dst[off + y * stride + x] = v
      block[bo + y * 4 + x] = 0
    }
  }
}

///|
/// `pred4x4_horizontal_add`: residual accumulated along each row. */
fn h264_add_pixels4_horizontal(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let mask = (1 << bit_depth) - 1
  for y = 0; y < 4; y = y + 1 {
    let mut v = dst[off + y * stride - 1]
    for x = 0; x < 4; x = x + 1 {
      v = (v + block[bo + y * 4 + x]) & mask
      dst[off + y * stride + x] = v
      block[bo + y * 4 + x] = 0
    }
  }
}

///|
/// `pred8x8l_vertical_add`. */
fn h264_add_pixels8_vertical(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let mask = (1 << bit_depth) - 1
  for x = 0; x < 8; x = x + 1 {
    let mut v = dst[off - stride + x]
    for y = 0; y < 8; y = y + 1 {
      v = (v + block[bo + y * 8 + x]) & mask
      dst[off + y * stride + x] = v
      block[bo + y * 8 + x] = 0
    }
  }
}

///|
/// `pred8x8l_horizontal_add`. */
fn h264_add_pixels8_horizontal(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let mask = (1 << bit_depth) - 1
  for y = 0; y < 8; y = y + 1 {
    let mut v = dst[off + y * stride - 1]
    for x = 0; x < 8; x = x + 1 {
      v = (v + block[bo + y * 8 + x]) & mask
      dst[off + y * stride + x] = v
      block[bo + y * 8 + x] = 0
    }
  }
}

///|
/// `ff_h264_idct_add`: 4x4 inverse transform, add to `dst` and clear the
/// coefficient block. `block[bo..bo+16]` is in FFmpeg's transposed layout.
fn h264_idct_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  block[bo] = h264_store_coef(block[bo] + (1 << 5), bit_depth~)
  for i = 0; i < 4; i = i + 1 {
    let b = bo + i
    let z0 = h264_u(block[b]) + h264_u(block[b + 8])
    let z1 = h264_u(block[b]) - h264_u(block[b + 8])
    let z2 = h264_u(block[b + 4] >> 1) - h264_u(block[b + 12])
    let z3 = h264_u(block[b + 4]) + h264_u(block[b + 12] >> 1)
    block[b] = h264_store_coefu(z0 + z3, bit_depth~)
    block[b + 4] = h264_store_coefu(z1 + z2, bit_depth~)
    block[b + 8] = h264_store_coefu(z1 - z2, bit_depth~)
    block[b + 12] = h264_store_coefu(z0 - z3, bit_depth~)
  }
  for i = 0; i < 4; i = i + 1 {
    let b = bo + 4 * i
    let z0 = h264_u(block[b]) + h264_u(block[b + 2])
    let z1 = h264_u(block[b]) - h264_u(block[b + 2])
    let z2 = h264_u(block[b + 1] >> 1) - h264_u(block[b + 3])
    let z3 = h264_u(block[b + 1]) + h264_u(block[b + 3] >> 1)
    let p = dst_off + i
    dst[p] = h264_clip8(dst[p] + (h264_s(z0 + z3) >> 6), bit_depth~)
    dst[p + stride] = h264_clip8(
      dst[p + stride] + (h264_s(z1 + z2) >> 6),
      bit_depth~,
    )
    dst[p + 2 * stride] = h264_clip8(
      dst[p + 2 * stride] + (h264_s(z1 - z2) >> 6),
      bit_depth~,
    )
    dst[p + 3 * stride] = h264_clip8(
      dst[p + 3 * stride] + (h264_s(z0 - z3) >> 6),
      bit_depth~,
    )
  }
  for i = 0; i < 16; i = i + 1 {
    block[bo + i] = 0
  }
}

///|
/// `ff_h264_idct8_add`: 8x8 inverse transform (High-profile
/// `transform_8x8_mode`), add to `dst` and clear the 64 coefficients.
fn h264_idct8_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  block[bo] = h264_store_coef(block[bo] + 32, bit_depth~)
  for i = 0; i < 8; i = i + 1 {
    let b = bo + i
    let a0 = h264_u(block[b]) + h264_u(block[b + 32])
    let a2 = h264_u(block[b]) - h264_u(block[b + 32])
    let a4 = h264_u(block[b + 16] >> 1) - h264_u(block[b + 48])
    let a6 = h264_u(block[b + 48] >> 1) + h264_u(block[b + 16])
    let b0 = a0 + a6
    let b2 = a2 + a4
    let b4 = a2 - a4
    let b6 = a0 - a6
    let a1 = h264_s(
      h264_u(0) -
      h264_u(block[b + 24]) +
      h264_u(block[b + 40]) -
      h264_u(block[b + 56]) -
      h264_u(block[b + 56] >> 1),
    )
    let a3 = h264_s(
      h264_u(block[b + 8]) +
      h264_u(block[b + 56]) -
      h264_u(block[b + 24]) -
      h264_u(block[b + 24] >> 1),
    )
    let a5 = h264_s(
      h264_u(0) -
      h264_u(block[b + 8]) +
      h264_u(block[b + 56]) +
      h264_u(block[b + 40]) +
      h264_u(block[b + 40] >> 1),
    )
    let a7 = h264_s(
      h264_u(block[b + 24]) +
      h264_u(block[b + 40]) +
      h264_u(block[b + 8]) +
      h264_u(block[b + 8] >> 1),
    )
    let b1 = h264_s(h264_u(a7 >> 2) + h264_u(a1))
    let b3 = h264_s(h264_u(a3) + h264_u(a5 >> 2))
    let b5 = h264_s(h264_u(a3 >> 2) - h264_u(a5))
    let b7 = h264_s(h264_u(a7) - h264_u(a1 >> 2))
    block[b] = h264_store_coefu(b0 + h264_u(b7), bit_depth~)
    block[b + 56] = h264_store_coefu(b0 - h264_u(b7), bit_depth~)
    block[b + 8] = h264_store_coefu(b2 + h264_u(b5), bit_depth~)
    block[b + 48] = h264_store_coefu(b2 - h264_u(b5), bit_depth~)
    block[b + 16] = h264_store_coefu(b4 + h264_u(b3), bit_depth~)
    block[b + 40] = h264_store_coefu(b4 - h264_u(b3), bit_depth~)
    block[b + 24] = h264_store_coefu(b6 + h264_u(b1), bit_depth~)
    block[b + 32] = h264_store_coefu(b6 - h264_u(b1), bit_depth~)
  }
  for i = 0; i < 8; i = i + 1 {
    let b = bo + i * 8
    let a0 = h264_u(block[b]) + h264_u(block[b + 4])
    let a2 = h264_u(block[b]) - h264_u(block[b + 4])
    let a4 = h264_u(block[b + 2] >> 1) - h264_u(block[b + 6])
    let a6 = h264_u(block[b + 6] >> 1) + h264_u(block[b + 2])
    let b0 = a0 + a6
    let b2 = a2 + a4
    let b4 = a2 - a4
    let b6 = a0 - a6
    let a1 = h264_s(
      h264_u(0) -
      h264_u(block[b + 3]) +
      h264_u(block[b + 5]) -
      h264_u(block[b + 7]) -
      h264_u(block[b + 7] >> 1),
    )
    let a3 = h264_s(
      h264_u(block[b + 1]) +
      h264_u(block[b + 7]) -
      h264_u(block[b + 3]) -
      h264_u(block[b + 3] >> 1),
    )
    let a5 = h264_s(
      h264_u(0) -
      h264_u(block[b + 1]) +
      h264_u(block[b + 7]) +
      h264_u(block[b + 5]) +
      h264_u(block[b + 5] >> 1),
    )
    let a7 = h264_s(
      h264_u(block[b + 3]) +
      h264_u(block[b + 5]) +
      h264_u(block[b + 1]) +
      h264_u(block[b + 1] >> 1),
    )
    let b1 = h264_s(h264_u(a7 >> 2) + h264_u(a1))
    let b3 = h264_s(h264_u(a3) + h264_u(a5 >> 2))
    let b5 = h264_s(h264_u(a3 >> 2) - h264_u(a5))
    let b7 = h264_s(h264_u(a7) - h264_u(a1 >> 2))
    let p = dst_off + i
    dst[p] = h264_clip8(dst[p] + (h264_s(b0 + h264_u(b7)) >> 6), bit_depth~)
    dst[p + stride] = h264_clip8(
      dst[p + stride] + (h264_s(b2 + h264_u(b5)) >> 6),
      bit_depth~,
    )
    dst[p + 2 * stride] = h264_clip8(
      dst[p + 2 * stride] + (h264_s(b4 + h264_u(b3)) >> 6),
      bit_depth~,
    )
    dst[p + 3 * stride] = h264_clip8(
      dst[p + 3 * stride] + (h264_s(b6 + h264_u(b1)) >> 6),
      bit_depth~,
    )
    dst[p + 4 * stride] = h264_clip8(
      dst[p + 4 * stride] + (h264_s(b6 - h264_u(b1)) >> 6),
      bit_depth~,
    )
    dst[p + 5 * stride] = h264_clip8(
      dst[p + 5 * stride] + (h264_s(b4 - h264_u(b3)) >> 6),
      bit_depth~,
    )
    dst[p + 6 * stride] = h264_clip8(
      dst[p + 6 * stride] + (h264_s(b2 - h264_u(b5)) >> 6),
      bit_depth~,
    )
    dst[p + 7 * stride] = h264_clip8(
      dst[p + 7 * stride] + (h264_s(b0 - h264_u(b7)) >> 6),
      bit_depth~,
    )
  }
  for i = 0; i < 64; i = i + 1 {
    block[bo + i] = 0
  }
}

///|
/// `ff_h264_idct8_dc_add`: 8x8 block with only the DC coefficient. Its
/// rounding (`+32` then `>>6`) differs from the full transform, so
/// `ff_h264_idct8_add4`'s shortcut has to be ported explicitly. */
fn h264_idct8_dc_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  for j = 0; j < 8; j = j + 1 {
    for i = 0; i < 8; i = i + 1 {
      let p = dst_off + j * stride + i
      dst[p] = h264_clip8(dst[p] + dc, bit_depth~)
    }
  }
}

///|
/// `ff_h264_idct8_add4` for one 8x8 quadrant: dispatch on the quadrant's
/// non-zero count (`nz` uses this port's raster 4x4 grid; the quadrant's
/// top-left block holds the count written by the 8x8 residual decode).
fn h264_idct8_add4(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  nz : Array[Int32],
  i8x8 : Int32,
  nz_base~ : Int32 = 0,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let nnz = nz[nz_base + i8x8 / 2 * 8 + i8x8 % 2 * 2]
  if nnz == 0 {
    ()
  } else if nnz == 1 && block[bo] != 0 {
    h264_idct8_dc_add(dst, dst_off, stride, block, bo, bit_depth~)
  } else {
    h264_idct8_add(dst, dst_off, stride, block, bo, bit_depth~)
  }
}

///|
/// `ff_h264_idct_dc_add`: only the DC coefficient is nonzero. */
fn h264_idct_dc_add(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  for j = 0; j < 4; j = j + 1 {
    for i = 0; i < 4; i = i + 1 {
      let p = dst_off + j * stride + i
      dst[p] = h264_clip8(dst[p] + dc, bit_depth~)
    }
  }
}

///|
/// `ff_h264_luma_dc_dequant_idct`: inverse 4x4 Hadamard over the 16 luma DC
/// coefficients, dequantise and scatter into the DC positions of the 16 luma
/// blocks of `out` (FFmpeg's `sl->mb` layout).
fn h264_luma_dc_dequant_idct(
  out : Array[Int32],
  out_off : Int32,
  input : Array[Int32],
  in_off : Int32,
  qmul : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let temp : Array[Int32] = Array::make(16, 0)
  for i = 0; i < 4; i = i + 1 {
    let b = in_off + 4 * i
    let z0 = input[b] + input[b + 1]
    let z1 = input[b] - input[b + 1]
    let z2 = input[b + 2] - input[b + 3]
    let z3 = input[b + 2] + input[b + 3]
    temp[4 * i] = z0 + z3
    temp[4 * i + 1] = z0 - z3
    temp[4 * i + 2] = z1 - z2
    temp[4 * i + 3] = z1 + z2
  }
  let uq = h264_u(qmul)
  let x_offset : Array[Int32] = [0, 32, 128, 160]
  for i = 0; i < 4; i = i + 1 {
    let off = x_offset[i]
    let z0 = h264_u(temp[i]) + h264_u(temp[8 + i])
    let z1 = h264_u(temp[i]) - h264_u(temp[8 + i])
    let z2 = h264_u(temp[4 + i]) - h264_u(temp[12 + i])
    let z3 = h264_u(temp[4 + i]) + h264_u(temp[12 + i])
    out[out_off + off] = h264_store_coef(
      h264_s((z0 + z3) * uq + 128U) >> 8,
      bit_depth~,
    )
    out[out_off + 16 + off] = h264_store_coef(
      h264_s((z1 + z2) * uq + 128U) >> 8,
      bit_depth~,
    )
    out[out_off + 64 + off] = h264_store_coef(
      h264_s((z1 - z2) * uq + 128U) >> 8,
      bit_depth~,
    )
    out[out_off + 80 + off] = h264_store_coef(
      h264_s((z0 - z3) * uq + 128U) >> 8,
      bit_depth~,
    )
  }
}

///|
/// `ff_h264_chroma_dc_dequant_idct`: inverse 2x2 Hadamard over the four
/// chroma DC coefficients stored at offsets 0/16/32/48 of the chroma block
/// region, dequantise and write them back in place.
fn h264_chroma_dc_dequant_idct(
  block : Array[Int32],
  base : Int32,
  qmul : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let a0 = block[base]
  let b0 = block[base + 16]
  let c0 = block[base + 32]
  let d0 = block[base + 48]
  let e = h264_u(a0) - h264_u(b0)
  let a = h264_u(a0) + h264_u(b0)
  let b = h264_u(c0) - h264_u(d0)
  let c = h264_u(c0) + h264_u(d0)
  let uq = h264_u(qmul)
  block[base] = h264_store_coef(h264_s((a + c) * uq) >> 7, bit_depth~)
  block[base + 16] = h264_store_coef(h264_s((e + b) * uq) >> 7, bit_depth~)
  block[base + 32] = h264_store_coef(h264_s((a - c) * uq) >> 7, bit_depth~)
  block[base + 48] = h264_store_coef(h264_s((e - b) * uq) >> 7, bit_depth~)
}

///|
/// `ff_h264_chroma422_dc_dequant_idct`: inverse 2x4 Hadamard over the eight
/// 4:2:2 chroma DC coefficients stored at the `(x + 2 * y) * 16` offsets of
/// the chroma block region, dequantise and write them back in place.
fn h264_chroma422_dc_dequant_idct(
  block : Array[Int32],
  base : Int32,
  qmul : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  // Vertical butterfly: row y pairs columns x=0/1 at offsets 32*y + 16*x.
  let temp : Array[Int32] = Array::make(8, 0)
  for i = 0; i < 4; i = i + 1 {
    let r = base + 32 * i
    temp[2 * i] = block[r] + block[r + 16]
    temp[2 * i + 1] = block[r] - block[r + 16]
  }
  let uq = h264_u(qmul)
  let x_offset : Array[Int32] = [0, 16]
  for i = 0; i < 2; i = i + 1 {
    let off = base + x_offset[i]
    let z0 = h264_u(temp[2 * 0 + i]) + h264_u(temp[2 * 2 + i])
    let z1 = h264_u(temp[2 * 0 + i]) - h264_u(temp[2 * 2 + i])
    let z2 = h264_u(temp[2 * 1 + i]) - h264_u(temp[2 * 3 + i])
    let z3 = h264_u(temp[2 * 1 + i]) + h264_u(temp[2 * 3 + i])
    block[off] = h264_store_coef(h264_s((z0 + z3) * uq + 128U) >> 8, bit_depth~)
    block[off + 32] = h264_store_coef(
      h264_s((z1 + z2) * uq + 128U) >> 8,
      bit_depth~,
    )
    block[off + 64] = h264_store_coef(
      h264_s((z1 - z2) * uq + 128U) >> 8,
      bit_depth~,
    )
    block[off + 96] = h264_store_coef(
      h264_s((z0 - z3) * uq + 128U) >> 8,
      bit_depth~,
    )
  }
}
