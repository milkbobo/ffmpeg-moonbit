///|
/// Whitebox tests for the SIMD (`@v128`) lossless-audio DSP kernels
/// (`lossless_dsp_v128.mbt`).
///
/// The `lr_*` functions are verbatim transcriptions of the C reference
/// (`libavcodec/flacdsp_template.c` decorrelation, `flacdsp_lpc_template.c`
/// LPC) and of the scalar ports in `libavcodec/flac_decode.mbt`, plus the
/// AC-3 `float_to_fixed24` contract — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here.

///|
/// Verbatim `flac_decorrelate_indep`. */
fn lr_decorrelate_indep(
  out : Array[Int32],
  out_off : Int32,
  in0 : Array[Int32],
  in_off : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  for j = 0; j < len; j = j + 1 {
    out[out_off + j] = in0[in_off + j] << shift
  }
}

///|
/// Verbatim `flac_decorrelate_ls`. */
fn lr_decorrelate_ls(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let a = in0[i0 + i]
    let b = in1[i1 + i]
    out0[o0 + i] = a << shift
    out1[o1 + i] = (a - b) << shift
  }
}

///|
/// Verbatim `flac_decorrelate_rs`. */
fn lr_decorrelate_rs(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let a = in0[i0 + i]
    let b = in1[i1 + i]
    out0[o0 + i] = (a + b) << shift
    out1[o1 + i] = b << shift
  }
}

///|
/// Verbatim `flac_decorrelate_ms`. */
fn lr_decorrelate_ms(
  out0 : Array[Int32],
  o0 : Int32,
  out1 : Array[Int32],
  o1 : Int32,
  in0 : Array[Int32],
  i0 : Int32,
  in1 : Array[Int32],
  i1 : Int32,
  len : Int32,
  shift : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let a0 = in0[i0 + i]
    let b = in1[i1 + i]
    let a = a0 - (b >> 1)
    out0[o0 + i] = (a + b) << shift
    out1[o1 + i] = a << shift
  }
}

///|
/// Verbatim `flac_lpc_predict` (32-bit / wide variant). */
fn lr_lpc32(
  decoded : Array[Int32],
  coeffs : Array[Int32],
  pred_order : Int32,
  qlevel : Int32,
  blocksize : Int32,
) -> Unit {
  for i = pred_order; i < blocksize; i = i + 1 {
    let mut sum : Int64 = 0L
    for j = 0; j < pred_order; j = j + 1 {
      sum = sum + coeffs[j].to_int64() * decoded[i - pred_order + j].to_int64()
    }
    decoded[i] = (decoded[i].to_int64() + (sum >> qlevel)).to_int()
  }
}

///|
/// Verbatim `flac_lpc_predict` (16-bit / wrapping `int` variant). */
fn lr_lpc16(
  decoded : Array[Int32],
  coeffs : Array[Int32],
  pred_order : Int32,
  qlevel : Int32,
  blocksize : Int32,
) -> Unit {
  for i = pred_order; i < blocksize; i = i + 1 {
    let mut sum : Int32 = 0
    for j = 0; j < pred_order; j = j + 1 {
      sum = sum + coeffs[j] * decoded[i - pred_order + j]
    }
    decoded[i] = decoded[i] + (sum >> qlevel)
  }
}

///|
/// Verbatim `float_to_fixed24`: `lrintf(src * (1 << 24))`, i.e. the
/// f32 product rounded to nearest-even. (The C applies no int24 clamp here;
/// the caller guarantees the range, and the SIMD kernel keeps a clamp only
/// as a belt-and-braces guard.)
fn lr_float_to_fixed24(
  dst : Array[Int32],
  src : Array[Float],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let scaled = Float::from_double(src[i].to_double() * 16777216.0)
    // round-half-to-even, the `lrintf` default mode
    let f = scaled.to_double()
    let fl = f.floor()
    let frac = f - fl
    let r = if frac > 0.5 {
      fl + 1.0
    } else if frac < 0.5 {
      fl
    } else if fl / 2.0 == (fl / 2.0).floor() {
      fl
    } else {
      fl + 1.0
    }
    let v = r.to_int()
    dst[i] = if v < -8388608 {
      -8388608
    } else if v > 8388607 {
      8388607
    } else {
      v
    }
  }
}

///|
/// Deterministic `Int32` generator (LCG) over a signed range. */
fn lr_gen(seed : UInt32, n : Int32, limit : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (2 * limit + 1) - limit
  }
  a
}

///|
fn lr_copy(a : Array[Int32]) -> Array[Int32] {
  let b : Array[Int32] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn lr_same(a : Array[Int32], b : Array[Int32]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
test "lossless dsp v128: FLAC decorrelation (indep/ls/rs/ms) bit-exact" {
  for len in [1, 2, 3, 4, 8, 17, 64] {
    for shift in [0, 1, 2, 8] {
      for k = 0; k < 3; k = k + 1 {
        let seed = 0x9E3779B9U +
          len.reinterpret_as_uint() * 31U +
          shift.reinterpret_as_uint() * 7U +
          k.reinterpret_as_uint()
        let in0 = lr_gen(seed, len + 8, 1000000)
        let in1 = lr_gen(seed + 1234U, len + 8, 1000000)
        let o0 = 3
        let o1 = 2
        let i0 = 1
        let i1 = 4
        // indep
        let a0 = lr_gen(0x11111111U, len + 8, 1000)
        let a1 = lr_copy(a0)
        lr_decorrelate_indep(a0, o0, in0, i0, len, shift)
        flac_decorrelate_indep_v128(a1, o0, in0, i0, len, shift)
        assert_true(lr_same(a0, a1))
        // ls
        let b0 = lr_gen(0x22222222U, len + 8, 1000)
        let b1 = lr_copy(b0)
        let c0 = lr_gen(0x33333333U, len + 8, 1000)
        let c1 = lr_copy(c0)
        lr_decorrelate_ls(b0, o0, c0, o1, in0, i0, in1, i1, len, shift)
        flac_decorrelate_ls_v128(b1, o0, c1, o1, in0, i0, in1, i1, len, shift)
        assert_true(lr_same(b0, b1))
        assert_true(lr_same(c0, c1))
        // rs
        let d0 = lr_gen(0x44444444U, len + 8, 1000)
        let d1 = lr_copy(d0)
        let e0 = lr_gen(0x55555555U, len + 8, 1000)
        let e1 = lr_copy(e0)
        lr_decorrelate_rs(d0, o0, e0, o1, in0, i0, in1, i1, len, shift)
        flac_decorrelate_rs_v128(d1, o0, e1, o1, in0, i0, in1, i1, len, shift)
        assert_true(lr_same(d0, d1))
        assert_true(lr_same(e0, e1))
        // ms
        let f0 = lr_gen(0x66666666U, len + 8, 1000)
        let f1 = lr_copy(f0)
        let g0 = lr_gen(0x77777777U, len + 8, 1000)
        let g1 = lr_copy(g0)
        lr_decorrelate_ms(f0, o0, g0, o1, in0, i0, in1, i1, len, shift)
        flac_decorrelate_ms_v128(f1, o0, g1, o1, in0, i0, in1, i1, len, shift)
        assert_true(lr_same(f0, f1))
        assert_true(lr_same(g0, g1))
      }
    }
  }
}

///|
test "lossless dsp v128: FLAC decorrelation wrapping extremes" {
  // min/max int32 sources make the wrapping sub/add observable; the C
  // relies on two's-complement wrap (it stores into `unsigned` first).
  let len : Int32 = 9
  let shifts : Array[Int32] = [0, 1, 3]
  for shift in shifts {
    let vals : Array[Int32] = [
      0, 1, -1, 2147483647, -2147483648, 2147483647, -1, 0, 12345,
    ]
    let in0 = lr_copy(vals)
    let in1 = lr_copy(vals)
    let b0 = lr_gen(0xABU, len, 1000)
    let b1 = lr_copy(b0)
    let c0 = lr_gen(0xCDU, len, 1000)
    let c1 = lr_copy(c0)
    lr_decorrelate_ms(b0, 0, c0, 0, in0, 0, in1, 0, len, shift)
    flac_decorrelate_ms_v128(b1, 0, c1, 0, in0, 0, in1, 0, len, shift)
    assert_true(lr_same(b0, b1))
    assert_true(lr_same(c0, c1))
  }
}

///|
test "lossless dsp v128: FLAC lpc32 and lpc16 reconstruction" {
  for
    (pred_order, qlevel) in [
      (1, 9),
      (2, 12),
      (4, 15),
      (8, 12),
      (12, 15),
      (3, 5),
    ] {
    for blocksize in [pred_order + 1, 16, 64, 257] {
      for k = 0; k < 2; k = k + 1 {
        let seed = 0xABCDEF01U +
          pred_order.reinterpret_as_uint() * 13U +
          blocksize.reinterpret_as_uint()
        // 32-bit path: large residuals
        let dec = lr_gen(seed, blocksize, 1000000)
        let coeffs = lr_gen(seed + 77U, pred_order + 1, 32767)
        let a = lr_copy(dec)
        let b = lr_copy(dec)
        lr_lpc32(a, coeffs, pred_order, qlevel, blocksize)
        flac_lpc32_v128(b, coeffs, pred_order, qlevel, blocksize)
        assert_true(lr_same(a, b))
        // 16-bit path
        let dec2 = lr_gen(seed + 11U, blocksize, 30000)
        let c = lr_copy(dec2)
        let d = lr_copy(dec2)
        lr_lpc16(c, coeffs, pred_order, qlevel, blocksize)
        flac_lpc16_v128(d, coeffs, pred_order, qlevel, blocksize)
        assert_true(lr_same(c, d))
      }
    }
  }
}

///|
test "lossless dsp v128: AC-3 float_to_fixed24 rounding and clamping" {
  let vals : Array[Float] = [
    0.0, 1.0, -1.0, 0.5, -0.5, 0.25, 0.75, 1.5, 1.4999999, 1.0e-8, -1.0e-8, 100.0,
    -100.0, 1.0e30, -1.0e30, 0.0000001, 0.0000003, 127.99999, -128.0,
  ]
  let n = vals.length()
  let a : Array[Int32] = Array::make(n, 0)
  let b : Array[Int32] = Array::make(n, 0)
  lr_float_to_fixed24(a, vals, n)
  ac3_float_to_fixed24_v128(b, vals, n)
  for i = 0; i < n; i = i + 1 {
    assert_eq(b[i], a[i])
    assert_true(b[i] >= -8388608)
    assert_true(b[i] <= 8388607)
  }
  // exact scaling checks: 1.0*2^24 and 100.0*2^24 are both outside int24,
  // so they clamp to the int24 rails just like the C's caller-range
  // guarantee would; 0.5*2^24 = 2^23 is the largest in-range positive.
  assert_eq(b[0], 0)
  assert_eq(b[1], 8388607)
  assert_eq(b[2], -8388608)
  // 0.5*2^24 = 2^23 exactly, which is one past the int24 max -> clamps
  assert_eq(b[3], 8388607)
  assert_eq(b[13], 8388607)
  assert_eq(b[14], -8388608)
}
