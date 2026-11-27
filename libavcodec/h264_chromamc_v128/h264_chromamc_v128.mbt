///|
/// SIMD (`@v128`) version of the H.264 chroma motion-compensation
/// kernel (`libavcodec/h264chroma_template.c`: `put_h264_chroma_mc8`;
/// the scalar port is `h264_mc_chroma` in `libavcodec/h264_mc.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_chromamc.asm`: `ff_put_h264_chroma_mc8_ssse3`
/// & family): the 2x2 bilinear tap
///
///   out = (A·(8−dx)(8−dy) + B·dx(8−dy) + C·(8−dx)dy + D·dx·dy + 32) >> 6
///
/// runs lane-wise over eight output pixels: two consecutive loads per
/// staged row (offset by one pixel) widen to `i32x4` and multiply by
/// the four precomputed weight splats (the asm's punpcklbw + pmaddwd
/// pairs). The scalar port reads its taps through edge-replicating
/// clamps; each source row (and its +1 neighbour) is staged once into
/// a packed byte scratch through the same clamps, which keeps the
/// vector loads contiguous without changing a single tap value.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernel.
/// Equal outputs are asserted in `h264_chromamc_v128_wbtest.mbt`
/// against a verbatim transcription of the scalar kernel.

///|
/// `h264_mc_clamp`: edge replication. */
#cfg(any(target="native", target="wasm"))
fn hcm_clamp(v : Int32, limit : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= limit {
    limit - 1
  } else {
    v
  }
}

///|
/// `h264_mc_chroma` with the bilinear tap carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_mc_chroma_v128(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  src_x : Int32,
  src_y : Int32,
  mx : Int32,
  my : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  pic_w : Int32,
  pic_h : Int32,
  sbase~ : Int32 = 0,
  vshift~ : Int32 = 1,
) -> Unit {
  let ysh = 2 + vshift
  let fy = src_y + (my >> ysh)
  let dx = mx & 7
  let dy = if vshift == 1 { my & 7 } else { (my << 1) & 7 }
  let ax = 8 - dx
  let ay = 8 - dy
  let wab = ax * ay // weight of A (row0, col+0)
  let wbb = dx * ay // B (row0, col+1)
  let wcb = ax * dy // C (row1, col+0)
  let wdb = dx * dy // D (row1, col+1)
  let sw_ab = @simd.i32x4_splat(wab.reinterpret_as_uint())
  let sw_bb = @simd.i32x4_splat(wbb.reinterpret_as_uint())
  let sw_cb = @simd.i32x4_splat(wcb.reinterpret_as_uint())
  let sw_db = @simd.i32x4_splat(wdb.reinterpret_as_uint())
  let rnd = @simd.i32x4_splat(32)
  // staged rows: w+1 taps, padded so 16-byte loads stay in bounds
  let ra : FixedArray[Byte] = FixedArray::make(w + 1 + 16, b'\x00')
  let rb : FixedArray[Byte] = FixedArray::make(w + 1 + 16, b'\x00')
  let fx0 = src_x + (mx >> 3)
  for row = 0; row < h; row = row + 1 {
    let y0 = hcm_clamp(fy + row, pic_h)
    let y1 = hcm_clamp(fy + row + 1, pic_h)
    let r0 = sbase + y0 * sstride
    let r1 = sbase + y1 * sstride
    for col = 0; col <= w; col = col + 1 {
      let xc = hcm_clamp(fx0 + col, pic_w)
      ra[col] = src[r0 + xc].to_byte()
      rb[col] = src[r1 + xc].to_byte()
    }
    let mut col = 0
    while col + 4 <= w {
      // widen the two load offsets of each staged row
      let a = @simd.i32x4_extend_low_i16x8_u(
        @simd.i16x8_extend_low_i8x16_u(@simd.v128_load(ra, col)),
      )
      let b = @simd.i32x4_extend_low_i16x8_u(
        @simd.i16x8_extend_low_i8x16_u(@simd.v128_load(ra, col + 1)),
      )
      let c = @simd.i32x4_extend_low_i16x8_u(
        @simd.i16x8_extend_low_i8x16_u(@simd.v128_load(rb, col)),
      )
      let d = @simd.i32x4_extend_low_i16x8_u(
        @simd.i16x8_extend_low_i8x16_u(@simd.v128_load(rb, col + 1)),
      )
      let acc = @simd.i32x4_add(
        @simd.i32x4_add(@simd.i32x4_mul(a, sw_ab), @simd.i32x4_mul(b, sw_bb)),
        @simd.i32x4_add(@simd.i32x4_mul(c, sw_cb), @simd.i32x4_mul(d, sw_db)),
      )
      let o = @simd.i32x4_shr_s(@simd.i32x4_add(acc, rnd), 6)
      let p = dstoff + row * dstride + col
      dst[p] = @simd.i32x4_extract_lane(o, 0).reinterpret_as_int()
      dst[p + 1] = @simd.i32x4_extract_lane(o, 1).reinterpret_as_int()
      dst[p + 2] = @simd.i32x4_extract_lane(o, 2).reinterpret_as_int()
      dst[p + 3] = @simd.i32x4_extract_lane(o, 3).reinterpret_as_int()
      col = col + 4
    }
    // scalar tail (w % 4)
    while col < w {
      let a = ra[col].to_int()
      let b = ra[col + 1].to_int()
      let c = rb[col].to_int()
      let d = rb[col + 1].to_int()
      dst[dstoff + row * dstride + col] = (
          a * wab + b * wbb + c * wcb + d * wdb + 32
        ) >>
        6
      col = col + 1
    }
  }
}
