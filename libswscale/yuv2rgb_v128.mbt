///|
/// SIMD (`@v128`) version of the YUV→RGB24 converter
/// (`yuv_rows_to_rgb24`, `libswscale/yuv2rgb.c`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libswscale/x86/yuv_2_rgb.asm`: `ff_yuv_420_rgb24_ssse3` & family):
/// those kernels skip the C lookup tables and compute the integer colour
/// matrix directly (punpck widen, `pmaddwd` with the y/rv/gu/gv/bu
/// coefficients, `packuswb` epilogue). The exact integers the probed
/// official tables encode are recovered from FFmpeg's own construction
/// (`yuv2rgb.c` case 24): a rounded-affine luma ramp
/// `av_clip_uint8((yb + 0x8000) >> 16)` and `fill_table` chroma bases
/// `(x·inc >> 16) - (inc >> 9)`, i.e. every table entry — and therefore
/// every composite pixel value — is
///
///   y_tab[i]   = clip8((76304·i − 65247168) >> 16)
///   base_r[vv] = ((89828·vv − 2541216) >> 16)        vv = V + 512
///   base_b[uv] = ((113536·uv − 17694720) >> 16)      uv = U + 512
///   base_gu[uv]= ((−22050·uv + 69092460) >> 16)
///   off_gv[vv] = ((−45756·vv + 29325312) >> 16)
///
/// with the intermediate `>> 16` truncations kept lane-wise (the asm's
/// fixed-point pipeline does the same). The G channel keeps the scalar
/// port's `& 0xFF` wrap of `(clamped gu part) + off_gv`. The wbtest
/// re-verifies every formula against the probed tables entry-by-entry
/// and the converter byte-for-byte against the scalar rows.
///
/// Deviation (documented): the asm interleaves RGB through register
/// punpcklbw/pshufb; here the epilogue uses two `i8x16_shuffle`s per
/// four pixels into a 12-byte scratch, and each row is staged through a
/// padded byte buffer so vector loads never cross plane ends.
///
/// Available on `native`, `wasm` and `wasm-gc`.
/// Equal outputs are asserted in `yuv2rgb_v128_wbtest.mbt`.

///|
/// clip8((i·76304 − 65247168) >> 16) — the luma ramp of the official
/// tables (not target-gated; the scalar tails and the wbtest use it). */
pub fn sws_yramp(i : Int32) -> Int32 {
  let v = (i * 76304 - 65247168) >> 16
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// One scalar pixel with the SIMD kernel's exact arithmetic (tail path). */
#cfg(any(target="native", target="wasm", target="wasm-gc"))
fn yuv2rgb_v128_pixel(
  yv : Int32,
  uv : Int32,
  vv : Int32,
) -> (Int32, Int32, Int32) {
  let idx_r = yv + ((89828 * vv - 2541216) >> 16)
  let r = sws_yramp(idx_r)
  let idx_g = yv + ((-22050 * uv + 69092460) >> 16)
  let g = (sws_yramp(idx_g) + ((-45756 * vv + 29325312) >> 16)) & 0xFF
  let idx_b = yv + ((113536 * uv - 17694720) >> 16)
  let b = sws_yramp(idx_b)
  (r, g, b)
}

///|
/// `yuv_rows_to_rgb24` with the colour matrix carried by `@v128`,
/// four pixels per block.
#cfg(any(target="native", target="wasm", target="wasm-gc"))
pub fn yuv_rows_to_rgb24_v128(
  y : Bytes,
  u : Bytes,
  v : Bytes,
  w : Int32,
  h : Int32,
  cw : Int32,
  paired : Bool,
  bgr : Bool,
) -> Bytes {
  let hshift = if cw == w { 0 } else { 1 }
  let ys : FixedArray[Byte] = FixedArray::make(w + 16, b'\x00')
  let cs : FixedArray[Byte] = FixedArray::make(cw + 16, b'\x00')
  let c2 : FixedArray[Byte] = FixedArray::make(cw + 16, b'\x00')
  let scratch : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let out : Array[Byte] = []
  // lane duplication: [u0,u0,u1,u1]
  let cidx = @v128.i8x16_const(
    b'\x00', b'\x00', b'\x01', b'\x01', b'\x00', b'\x00', b'\x01', b'\x01', b'\x00',
    b'\x00', b'\x01', b'\x01', b'\x00', b'\x00', b'\x01', b'\x01',
  )
  let cy = @v128.i32x4_splat(76304)
  let yc = @v128.i32x4_splat((-65247168).reinterpret_as_uint())
  let crv = @v128.i32x4_splat(89828)
  let crc = @v128.i32x4_splat((-2541216).reinterpret_as_uint())
  let cgu = @v128.i32x4_splat((-22050).reinterpret_as_uint())
  let cguc = @v128.i32x4_splat(69092460)
  let cgv = @v128.i32x4_splat((-45756).reinterpret_as_uint())
  let cgvc = @v128.i32x4_splat(29325312)
  let cbu = @v128.i32x4_splat(113536)
  let cbc = @v128.i32x4_splat((-17694720).reinterpret_as_uint())
  let p512 = @v128.i32x4_splat(512)
  let zero = @v128.i32x4_splat(0)
  let lim = @v128.i32x4_splat(255)
  let mff = @v128.i32x4_splat(0xFF)
  for row = 0; row < h; row = row + 1 {
    let crow = if paired { row / 2 } else { row }
    let yrow = row * w
    let coff = crow * cw
    // stage the three row windows (padded so loads stay in bounds)
    for i = 0; i < w; i = i + 1 {
      ys[i] = y[yrow + i]
    }
    for i = 0; i < cw; i = i + 1 {
      cs[i] = u[coff + i]
      c2[i] = v[coff + i]
    }
    let mut col = 0
    while col + 4 <= w {
      let ch_off = col >> hshift
      let chroma_u = @v128.v128_load(cs, ch_off)
      let chroma_v = @v128.v128_load(c2, ch_off)
      let chroma_u = if hshift == 0 {
        chroma_u
      } else {
        @v128.i8x16_swizzle(chroma_u, cidx)
      }
      let chroma_v = if hshift == 0 {
        chroma_v
      } else {
        @v128.i8x16_swizzle(chroma_v, cidx)
      }
      let yv16 = @v128.i16x8_extend_low_i8x16_u(@v128.v128_load(ys, col))
      let y32 = @v128.i32x4_extend_low_i16x8_u(yv16)
      let uv32 = @v128.i32x4_add(
        @v128.i32x4_extend_low_i16x8_u(@v128.i16x8_extend_low_i8x16_u(chroma_u)),
        p512,
      )
      let vv32 = @v128.i32x4_add(
        @v128.i32x4_extend_low_i16x8_u(@v128.i16x8_extend_low_i8x16_u(chroma_v)),
        p512,
      )
      // r = clip8(yramp(y + base_r(V)))
      let idx_r = @v128.i32x4_add(
        y32,
        @v128.i32x4_shr_s(@v128.i32x4_add(@v128.i32x4_mul(vv32, crv), crc), 16),
      )
      let r = @v128.i32x4_min_s(
        @v128.i32x4_max_s(
          @v128.i32x4_shr_s(@v128.i32x4_add(@v128.i32x4_mul(idx_r, cy), yc), 16),
          zero,
        ),
        lim,
      )
      // g = (clip8(yramp(y + base_gu(U))) + off_gv(V)) & 0xff
      let idx_g = @v128.i32x4_add(
        y32,
        @v128.i32x4_shr_s(@v128.i32x4_add(@v128.i32x4_mul(uv32, cgu), cguc), 16),
      )
      let g = @v128.v128_and_(
        @v128.i32x4_add(
          @v128.i32x4_min_s(
            @v128.i32x4_max_s(
              @v128.i32x4_shr_s(
                @v128.i32x4_add(@v128.i32x4_mul(idx_g, cy), yc),
                16,
              ),
              zero,
            ),
            lim,
          ),
          @v128.i32x4_shr_s(
            @v128.i32x4_add(@v128.i32x4_mul(vv32, cgv), cgvc),
            16,
          ),
        ),
        mff,
      )
      // b = clip8(yramp(y + base_b(U)))
      let idx_b = @v128.i32x4_add(
        y32,
        @v128.i32x4_shr_s(@v128.i32x4_add(@v128.i32x4_mul(uv32, cbu), cbc), 16),
      )
      let b = @v128.i32x4_min_s(
        @v128.i32x4_max_s(
          @v128.i32x4_shr_s(@v128.i32x4_add(@v128.i32x4_mul(idx_b, cy), yc), 16),
          zero,
        ),
        lim,
      )
      // narrow the three 4-lane channels to u8 and interleave RGB24
      let r8 = @v128.i8x16_narrow_i16x8_u(
        @v128.i16x8_narrow_i32x4_u(r, r),
        @v128.i16x8_narrow_i32x4_u(r, r),
      )
      let g8 = @v128.i8x16_narrow_i16x8_u(
        @v128.i16x8_narrow_i32x4_u(g, g),
        @v128.i16x8_narrow_i32x4_u(g, g),
      )
      let b8 = @v128.i8x16_narrow_i16x8_u(
        @v128.i16x8_narrow_i32x4_u(b, b),
        @v128.i16x8_narrow_i32x4_u(b, b),
      )
      // two-shuffle 3-way interleave: [c0,c1,P, c0,c1,P, ...] then slot
      // the third channel's bytes 0..3 into the P positions
      let (ca, cb, cc) = if bgr { (b8, g8, r8) } else { (r8, g8, b8) }
      let t = @v128.i8x16_shuffle(
        ca, cb, 0, 16, 0, 1, 17, 0, 2, 18, 0, 3, 19, 0, 0, 0, 0, 0,
      )
      let rgb = @v128.i8x16_shuffle(
        t, cc, 0, 1, 16, 3, 4, 17, 6, 7, 18, 9, 10, 19, 12, 13, 20, 15,
      )
      @v128.v128_store(scratch, 0, rgb)
      for t2 = 0; t2 < 12; t2 = t2 + 1 {
        out.push(scratch[t2])
      }
      col = col + 4
    }
    // Scalar tail with the same chroma addressing as the vector loop.
    while col < w {
      let yv = y[yrow + col].to_int()
      let uv = u[coff + (col >> hshift)].to_int() + 512
      let vv = v[coff + (col >> hshift)].to_int() + 512
      let (r, g, b) = yuv2rgb_v128_pixel(yv, uv, vv)
      if bgr {
        out.push(b.to_byte())
        out.push(g.to_byte())
        out.push(r.to_byte())
      } else {
        out.push(r.to_byte())
        out.push(g.to_byte())
        out.push(b.to_byte())
      }
      col = col + 1
    }
  }
  Bytes::from_array(out[:])
}
