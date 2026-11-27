///|
/// SIMD (`@v128`) version of the G.722 QMF synthesis tap
/// (`libavcodec/g722dsp.c`: `g722_apply_qmf`), against
/// `libavcodec/x86/g722dsp.asm` (`g722_apply_qmf`, SSE2).
///
/// The scalar port is `g722_apply_qmf` in `libavcodec/g722.mbt`:
///
///   x1 = Σ_{i<12} prev[start + 2i    ] * coeff[2i    ]
///   x0 = Σ_{i<12} prev[start + 2i + 1] * coeff[2i + 1]
///
/// i.e. a 24-tap dot product where **even taps feed `x1` and odd taps feed
/// `x0`**.
///
/// **Why the taps must be de-interleaved first.** `i32x4_dot_i16x8_s`
/// (`pmaddwd`) sums *adjacent* lane pairs, so applied to the interleaved
/// `prev[]` it would put one even tap and one odd tap in the same partial —
/// exactly the wrong grouping. The asm solves this with
/// `punpcklwd`/`punpckhwd` before the `pmaddwd`s, i.e. it de-interleaves.
/// This port does the same de-interleave by gathering the even and odd taps
/// into separate `i16x8` vectors, then runs one dot per parity: 12 taps
/// split into an 8-wide block and a zero-padded 4-wide block. Summing all
/// four dot lanes is safe because the padding lanes contribute zero.
///
/// **Bit-exactness**: the C accumulates in `int` (32-bit, wrapping). The
/// G.722 taps are `int16` and the coefficients are the fixed 24-entry table
/// (max magnitude 3876), so the widest partial is bounded far inside
/// `Int32` and no wrap can occur — the accumulation order is unobservable
/// and the vector reduction is bit-identical. The wbtest pins this with
/// `int16` extremes.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernel. Equal
/// outputs are asserted in `g722_dsp_v128_wbtest.mbt`.

///|
/// The G.722 QMF coefficient table (`g722_qmf_coeffs`, 24 `int16` taps).
#cfg(any(target="native", target="wasm"))
let g722v_qmf_coeffs : FixedArray[Int32] = [
  3, -11, -11, 53, 12, -156, 32, 362, -210, -805, 951, 3876, 3876, 951, -805, -210,
  362, 32, -156, 12, 53, -11, -11, 3,
]

///|
/// Build an `i16x8` from eight gathered `int16`-valued `Int32` samples.
#cfg(any(target="native", target="wasm"))
fn g722v_pack8(
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  a4 : Int32,
  a5 : Int32,
  a6 : Int32,
  a7 : Int32,
) -> V128 {
  @simd.i16x8_const(
    a0.reinterpret_as_uint().to_uint16(),
    a1.reinterpret_as_uint().to_uint16(),
    a2.reinterpret_as_uint().to_uint16(),
    a3.reinterpret_as_uint().to_uint16(),
    a4.reinterpret_as_uint().to_uint16(),
    a5.reinterpret_as_uint().to_uint16(),
    a6.reinterpret_as_uint().to_uint16(),
    a7.reinterpret_as_uint().to_uint16(),
  )
}

///|
/// `Σ_{k<8} v[start + stride*k] * c[cbase + stride*k]` reduced over the
/// dot's four lanes. */
#cfg(any(target="native", target="wasm"))
fn g722v_dot8(
  v : FixedArray[Int32],
  start : Int32,
  stride : Int32,
  c : FixedArray[Int32],
  cbase : Int32,
) -> Int32 {
  let a = g722v_pack8(
    v[start],
    v[start + stride],
    v[start + 2 * stride],
    v[start + 3 * stride],
    v[start + 4 * stride],
    v[start + 5 * stride],
    v[start + 6 * stride],
    v[start + 7 * stride],
  )
  let b = g722v_pack8(
    c[cbase],
    c[cbase + stride],
    c[cbase + 2 * stride],
    c[cbase + 3 * stride],
    c[cbase + 4 * stride],
    c[cbase + 5 * stride],
    c[cbase + 6 * stride],
    c[cbase + 7 * stride],
  )
  let d = @simd.i32x4_dot_i16x8_s(a, b)
  @simd.i32x4_extract_lane(d, 0).reinterpret_as_int() +
  @simd.i32x4_extract_lane(d, 1).reinterpret_as_int() +
  @simd.i32x4_extract_lane(d, 2).reinterpret_as_int() +
  @simd.i32x4_extract_lane(d, 3).reinterpret_as_int()
}

///|
/// `Σ_{k in 8..12} v[start + stride*k] * c[cbase + stride*k]`, zero-padded
/// to 8 lanes so it reuses the same dot. */
#cfg(any(target="native", target="wasm"))
fn g722v_dot4(
  v : FixedArray[Int32],
  start : Int32,
  stride : Int32,
  c : FixedArray[Int32],
  cbase : Int32,
) -> Int32 {
  let a = g722v_pack8(
    v[start + 8 * stride],
    v[start + 9 * stride],
    v[start + 10 * stride],
    v[start + 11 * stride],
    0,
    0,
    0,
    0,
  )
  let b = g722v_pack8(
    c[cbase + 8 * stride],
    c[cbase + 9 * stride],
    c[cbase + 10 * stride],
    c[cbase + 11 * stride],
    0,
    0,
    0,
    0,
  )
  let d = @simd.i32x4_dot_i16x8_s(a, b)
  @simd.i32x4_extract_lane(d, 0).reinterpret_as_int() +
  @simd.i32x4_extract_lane(d, 1).reinterpret_as_int()
}

///|
/// `g722_apply_qmf`: `(xout[0], xout[1])` from `prev[start .. start+24)`.
///
/// Returns `(x0, x1)` in the scalar port's order.
#cfg(any(target="native", target="wasm"))
pub fn g722_apply_qmf_v128(
  prev : FixedArray[Int32],
  start : Int32,
) -> (Int32, Int32) {
  let c = g722v_qmf_coeffs
  // even taps (stride 2 from offset 0) -> x1
  let x1 = g722v_dot8(prev, start, 2, c, 0) + g722v_dot4(prev, start, 2, c, 0)
  // odd taps (stride 2 from offset 1) -> x0
  let x0 = g722v_dot8(prev, start + 1, 2, c, 1) +
    g722v_dot4(prev, start + 1, 2, c, 1)
  (x0, x1)
}
