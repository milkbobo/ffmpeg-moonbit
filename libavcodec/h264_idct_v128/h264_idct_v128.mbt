///|
/// SIMD (`@v128`) versions of the H.264 inverse-transform add kernels
/// (`libavcodec/h264idct_template.c`: `ff_h264_idct_add`,
/// `ff_h264_idct_dc_add`, `ff_h264_idct8_dc_add`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_idct.asm`: `ff_h264_idct_add_8_sse2`,
/// `ff_h264_idct_dc_add_8_mmxext`, `ff_h264_idct8_dc_add_8_mmxext`):
/// the 4x4 transform as two lane-wise butterfly passes with the
/// transpose in between. Where the asm keeps lanes in `i16` with a
/// carefully overflow-free ordering, this port widens to `i32x4`
/// lanes with the scalar port's exact truncation points — the C
/// `SUINT` accumulators wrap exactly like `i32` lanes, and the
/// `int16_t` coefficient stores (`h264_store_coef` at 8-bit) are
/// reproduced as `<< 16 >> 16`, so the arithmetic is bit-identical to
/// the scalar port by construction rather than by overflow analysis.
/// Pass 1 runs over column lanes, pass 2 over row lanes; pixels stay
/// in the port's `Array[Int32]` planes (the asm's `packuswb` epilogue
/// becomes `min/max` lane clamps, equal to `av_clip_pixel`).
///
/// Deviations (documented): `ff_h264_idct8_add` (the full 8x8
/// transform) and the transform-bypass `add_pixels` family keep their
/// scalar ports — the 8x8 lane mesh is a follow-up; the wbtest
/// references are verbatim transcriptions of the scalar kernels
/// because the parent package's privates are not visible from a
/// subpackage.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels.
/// Equal outputs are asserted in `h264_idct_v128_wbtest.mbt`.

///|
/// `i32x4` from four scalars. */
#cfg(any(target="native", target="wasm"))
fn h264v_lane4(a : Int32, b : Int32, c : Int32, d : Int32) -> V128 {
  let v = @v128.i32x4_splat(0)
  let v = @v128.i32x4_replace_lane(v, a.reinterpret_as_uint(), 0)
  let v = @v128.i32x4_replace_lane(v, b.reinterpret_as_uint(), 1)
  let v = @v128.i32x4_replace_lane(v, c.reinterpret_as_uint(), 2)
  @v128.i32x4_replace_lane(v, d.reinterpret_as_uint(), 3)
}

///|
/// Signed lane extract. */
#cfg(any(target="native", target="wasm"))
fn h264v_ext(v : V128, lane : Int32) -> Int32 {
  @v128.i32x4_extract_lane(v, lane).reinterpret_as_int()
}

///|
/// `h264_store_coef`: `int16` wrap at 8-bit, identity above. */
#cfg(any(target="native", target="wasm"))
fn h264v_store(value : Int32, bit_depth : Int32) -> Int32 {
  if bit_depth == 8 {
    value << 16 >> 16
  } else {
    value
  }
}

///|
/// `ff_h264_idct_add`: 4x4 inverse transform, add to the pixel plane,
/// clear the coefficients. */
#cfg(any(target="native", target="wasm"))
pub fn h264_idct_add_v128(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  // DC rounding, then pass 1 with the four columns as lanes.
  let r0 = h264v_lane4(
    h264v_store(block[bo] + 32, bit_depth),
    block[bo + 1],
    block[bo + 2],
    block[bo + 3],
  )
  let r1 = h264v_lane4(block[bo + 4], block[bo + 5], block[bo + 6], block[bo + 7])
  let r2 = h264v_lane4(
    block[bo + 8], block[bo + 9], block[bo + 10], block[bo + 11],
  )
  let r3 = h264v_lane4(
    block[bo + 12], block[bo + 13], block[bo + 14], block[bo + 15],
  )
  let z0 = @v128.i32x4_add(r0, r2)
  let z1 = @v128.i32x4_sub(r0, r2)
  let z2 = @v128.i32x4_sub(@v128.i32x4_shr_s(r1, 1), r3)
  let z3 = @v128.i32x4_add(r1, @v128.i32x4_shr_s(r3, 1))
  // the int16 stores of the column pass
  let s0 = h264v_store_lane(@v128.i32x4_add(z0, z3), bit_depth)
  let s1 = h264v_store_lane(@v128.i32x4_add(z1, z2), bit_depth)
  let s2 = h264v_store_lane(@v128.i32x4_sub(z1, z2), bit_depth)
  let s3 = h264v_store_lane(@v128.i32x4_sub(z0, z3), bit_depth)
  // pass 2: lane-transpose the column-pass vectors (E_j lane i = new
  // block[row i][col j]) so the scalar row butterflies run lane-wise
  // over the four rows; outputs go down dst column i, +stride steps,
  // exactly like the scalar loop nesting
  let e0 = h264v_lane4(
    h264v_ext(s0, 0), h264v_ext(s1, 0), h264v_ext(s2, 0), h264v_ext(s3, 0),
  )
  let e1 = h264v_lane4(
    h264v_ext(s0, 1), h264v_ext(s1, 1), h264v_ext(s2, 1), h264v_ext(s3, 1),
  )
  let e2 = h264v_lane4(
    h264v_ext(s0, 2), h264v_ext(s1, 2), h264v_ext(s2, 2), h264v_ext(s3, 2),
  )
  let e3 = h264v_lane4(
    h264v_ext(s0, 3), h264v_ext(s1, 3), h264v_ext(s2, 3), h264v_ext(s3, 3),
  )
  let q0 = @v128.i32x4_add(e0, e2)
  let q1 = @v128.i32x4_sub(e0, e2)
  let q2 = @v128.i32x4_sub(@v128.i32x4_shr_s(e1, 1), e3)
  let q3 = @v128.i32x4_add(e1, @v128.i32x4_shr_s(e3, 1))
  let o0 = @v128.i32x4_shr_s(@v128.i32x4_add(q0, q3), 6)
  let o1 = @v128.i32x4_shr_s(@v128.i32x4_add(q1, q2), 6)
  let o2 = @v128.i32x4_shr_s(@v128.i32x4_sub(q1, q2), 6)
  let o3 = @v128.i32x4_shr_s(@v128.i32x4_sub(q0, q3), 6)
  let mx = (1 << bit_depth) - 1
  for r = 0; r < 4; r = r + 1 {
    let o = if r == 0 {
      o0
    } else if r == 1 {
      o1
    } else if r == 2 {
      o2
    } else {
      o3
    }
    let p = dst_off + r * stride
    dst[p] = h264v_clip(dst[p] + h264v_ext(o, 0), mx)
    dst[p + 1] = h264v_clip(dst[p + 1] + h264v_ext(o, 1), mx)
    dst[p + 2] = h264v_clip(dst[p + 2] + h264v_ext(o, 2), mx)
    dst[p + 3] = h264v_clip(dst[p + 3] + h264v_ext(o, 3), mx)
  }
  for i = 0; i < 16; i = i + 1 {
    block[bo + i] = 0
  }
}

///|
/// `h264_store_coef` applied lane-wise (the column-pass stores). */
#cfg(any(target="native", target="wasm"))
fn h264v_store_lane(v : V128, bit_depth : Int32) -> V128 {
  if bit_depth == 8 {
    @v128.i32x4_shr_s(@v128.i32x4_shl(v, 16), 16)
  } else {
    v
  }
}

///|
/// `av_clip_pixel` for the plane stores. */
#cfg(any(target="native", target="wasm"))
fn h264v_clip(x : Int32, mx : Int32) -> Int32 {
  if x < 0 {
    0
  } else if x > mx {
    mx
  } else {
    x
  }
}

///|
/// `ff_h264_idct_dc_add`: DC-only 4x4 residual add. */
#cfg(any(target="native", target="wasm"))
pub fn h264_idct_dc_add_v128(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  let dcv = @v128.i32x4_splat(dc.reinterpret_as_uint())
  let lim = @v128.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint())
  let zero = @v128.i32x4_splat(0)
  for row = 0; row < 4; row = row + 1 {
    let p = dst_off + row * stride
    let cur = h264v_lane4(dst[p], dst[p + 1], dst[p + 2], dst[p + 3])
    let v = @v128.i32x4_min_s(
      @v128.i32x4_max_s(@v128.i32x4_add(cur, dcv), zero),
      lim,
    )
    dst[p] = h264v_ext(v, 0)
    dst[p + 1] = h264v_ext(v, 1)
    dst[p + 2] = h264v_ext(v, 2)
    dst[p + 3] = h264v_ext(v, 3)
  }
}

///|
/// `ff_h264_idct8_dc_add`: DC-only 8x8 residual add. */
#cfg(any(target="native", target="wasm"))
pub fn h264_idct8_dc_add_v128(
  dst : Array[Int32],
  dst_off : Int32,
  stride : Int32,
  block : Array[Int32],
  bo : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  let dc = (block[bo] + 32) >> 6
  block[bo] = 0
  let dcv = @v128.i32x4_splat(dc.reinterpret_as_uint())
  let lim = @v128.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint())
  let zero = @v128.i32x4_splat(0)
  for row = 0; row < 8; row = row + 1 {
    for half = 0; half < 2; half = half + 1 {
      let p = dst_off + row * stride + 4 * half
      let cur = h264v_lane4(dst[p], dst[p + 1], dst[p + 2], dst[p + 3])
      let v = @v128.i32x4_min_s(
        @v128.i32x4_max_s(@v128.i32x4_add(cur, dcv), zero),
        lim,
      )
      dst[p] = h264v_ext(v, 0)
      dst[p + 1] = h264v_ext(v, 1)
      dst[p + 2] = h264v_ext(v, 2)
      dst[p + 3] = h264v_ext(v, 3)
    }
  }
}
