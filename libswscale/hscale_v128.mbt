///|
/// SIMD (`@v128`) version of the horizontal scaler `sws_hscale8to15`
/// (`libswscale/hscale.c`: `hScale8To15_c` / `hScale16To15_c`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libswscale/x86/scale.asm`: `ff_hscale8to15_{4,8,X4,X8}_sse2` and the
/// `ff_hscale{9,10,16}to15_*` 16-bit variants): every output pixel is the
/// 14-bit-filter dot product of `filterSize` source samples, and the x86
/// kernels carry that dot with `pmaddwd`. Here the `pmaddwd` structure is
/// kept as `@v128.i32x4_dot_i16x8_s` over 8-tap blocks:
///
///   - 8-bit rows: 16 sample bytes are loaded per block, zero-extended to
///     two `i16x8` halves and dotted with the matching coefficient lanes;
///   - 9..16-bit rows: the same 16 bytes hold eight little-endian `u16`
///     samples, widened zero-extended (replacing the `minshort`/`unicoeff`
///     sign trick of the asm with `i32x4_extend_*_i16x8_u`) to two `i32x4`
///     and multiplied lane-wise.
///
/// Wrapped `i32` addition is associative modulo 2^32, so the lane-partial
/// summation order cannot change the result; the epilogue reproduces the
/// scalar port exactly (`>> (src_bits-1)`, top clamp at 32767, `int16`
/// wrap on store).
///
/// Deviation (documented): the x86 kernels process four output pixels per
/// iteration (gathering samples with `punpckldq`); this port vectorises
/// along the tap dimension of a single output instead, which the `Bytes`
/// addressing of `@v128` loads favours. Fewer than 8 (resp. 4) trailing
/// taps, and windows whose 16-byte load would cross the end of the source
/// buffer, fall back to the scalar tap loop — identical arithmetic.
///
/// Coefficients must fit `int16` (FFmpeg keeps them 14-bit); the bank is
/// packed once per call into a little-endian byte buffer.
///
/// Gated to `native`/`wasm`; other targets keep the scalar
/// `sws_hscale8to15`. Equal outputs are asserted in
/// `hscale_v128_wbtest.mbt`.

///|
/// Horizontal sum of the four `i32x4` lanes (wrapping, order-free). */
#cfg(any(target="native", target="wasm"))
fn hscale_red4(v : V128) -> Int32 {
  let u = @v128.i32x4_extract_lane(v, 0) +
  @v128.i32x4_extract_lane(v, 1) +
  @v128.i32x4_extract_lane(v, 2) +
  @v128.i32x4_extract_lane(v, 3)
  u.reinterpret_as_int()
}

///|
/// `sws_hscale8to15` with the per-output tap dot carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn sws_hscale8to15_v128(
  src : Bytes,
  row_off : Int32,
  f : SwsFilter,
  dst_w : Int32,
  src_bits : Int32,
) -> Array[Int32] {
  let sh = src_bits - 1
  let step = (src_bits + 7) / 8 // bytes per sample: 1 or 2
  // Pack the coefficient bank once as little-endian int16 (+32B pad so
  // vector loads of the last bank never go out of bounds).
  let ncoef = f.coeffs.length()
  let cbuf : FixedArray[Byte] = FixedArray::make(2 * ncoef + 32, b'\x00')
  for i = 0; i < ncoef; i = i + 1 {
    let c = f.coeffs[i]
    cbuf[2 * i] = (c & 0xFF).to_byte()
    cbuf[2 * i + 1] = ((c >> 8) & 0xFF).to_byte()
  }
  let out : Array[Int32] = Array::make(dst_w, 0)
  for i in 0..<dst_w {
    let base = (row_off + f.pos[i]) * step
    let bank = f.size * i // coefficient index of this output's first tap
    let mut acc = @v128.i32x4_splat(0)
    let mut k = 0
    if step == 1 {
      // 8-bit: one 16-byte load = 16 samples; each half is one 8-tap dot.
      while k + 8 <= f.size {
        match src[base + k : base + k + 16] {
          [v128le(v), ..] => {
            let dlo = @v128.i32x4_dot_i16x8_s(
              @v128.i16x8_extend_low_i8x16_u(v),
              @v128.v128_load(cbuf, 2 * (bank + k)),
            )
            acc = @v128.i32x4_add(acc, dlo)
            if k + 16 <= f.size {
              let dhi = @v128.i32x4_dot_i16x8_s(
                @v128.i16x8_extend_high_i8x16_u(v),
                @v128.v128_load(cbuf, 2 * (bank + k) + 16),
              )
              acc = @v128.i32x4_add(acc, dhi)
              k = k + 16
            } else {
              k = k + 8
            }
          }
          _ => break
        }
      }
    } else {
      // 9..16-bit: one 16-byte load = 8 LE u16 samples; each widened half
      // is one 4-tap lane product.
      while k + 4 <= f.size {
        match src[base + 2 * k : base + 2 * k + 16] {
          [v128le(v), ..] => {
            let c16 = @v128.v128_load(cbuf, 2 * (bank + k))
            let dlo = @v128.i32x4_mul(
              @v128.i32x4_extend_low_i16x8_u(v),
              @v128.i32x4_extend_low_i16x8_s(c16),
            )
            acc = @v128.i32x4_add(acc, dlo)
            if k + 8 <= f.size {
              let dhi = @v128.i32x4_mul(
                @v128.i32x4_extend_high_i16x8_u(v),
                @v128.i32x4_extend_high_i16x8_s(c16),
              )
              acc = @v128.i32x4_add(acc, dhi)
              k = k + 8
            } else {
              k = k + 4
            }
          }
          _ => break
        }
      }
    }
    // Scalar tail: the remaining taps, with the scalar port's reads.
    let mut val = hscale_red4(acc)
    while k < f.size {
      let sample = if step == 1 {
        src[base + k].to_int()
      } else {
        src[base + 2 * k].to_int() | (src[base + 2 * k + 1].to_int() << 8)
      }
      val = val + sample * f.coeffs[bank + k]
      k = k + 1
    }
    let v0 = val >> sh
    let v = if v0 < 32767 { v0 } else { 32767 }
    // int16 wrap semantics of the C store.
    out[i] = v << 16 >> 16
  }
  out
}
