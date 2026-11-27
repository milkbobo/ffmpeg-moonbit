///|
/// Whitebox tests for the SIMD (`@v128`) G.722 QMF synthesis tap
/// (`g722_dsp_v128.mbt`).
///
/// The `gr_*` functions are verbatim transcriptions of the scalar port
/// (`libavcodec/g722.mbt`: `g722_apply_qmf` and `g722_qmf_coeffs`) — the
/// parent package's privates are not visible from a subpackage, so the
/// reference is carried here. Both must agree exactly.

///|
/// Verbatim `g722_qmf_coeffs`. */
let gr_qmf_coeffs : FixedArray[Int32] = [
  3, -11, -11, 53, 12, -156, 32, 362, -210, -805, 951, 3876, 3876, 951, -805, -210,
  362, 32, -156, 12, 53, -11, -11, 3,
]

///|
/// Verbatim `g722_apply_qmf`. */
fn gr_apply_qmf(prev : FixedArray[Int32], start : Int32) -> (Int32, Int32) {
  let mut x0 = 0
  let mut x1 = 0
  for i = 0; i < 12; i = i + 1 {
    x1 = x1 + prev[start + 2 * i] * gr_qmf_coeffs[2 * i]
    x0 = x0 + prev[start + 2 * i + 1] * gr_qmf_coeffs[2 * i + 1]
  }
  (x0, x1)
}

///|
/// Deterministic `int16` generator (LCG). */
fn gr_gen_i16(seed : UInt32, n : Int32) -> FixedArray[Int32] {
  let a : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() << 16 >> 16
  }
  a
}

///|
test "g722 dsp v128: apply_qmf bit-exact over offsets and seeds" {
  // start must leave 24 samples of headroom
  for seed in [0x9E3779B9U, 0x5A5A5A5AU, 0x13572468U, 0xFEDCBA98U] {
    let prev = gr_gen_i16(seed, 64)
    for start in [0, 1, 2, 8, 16, 39] {
      let (a0, a1) = gr_apply_qmf(prev, start)
      let (b0, b1) = g722_apply_qmf_v128(prev, start)
      assert_eq(b0, a0)
      assert_eq(b1, a1)
    }
  }
}

///|
test "g722 dsp v128: apply_qmf with int16 extremes" {
  // All-max and all-min inputs: the widest products the tap can meet.
  // Coefficients are fixed, so the summed magnitude stays inside Int32 —
  // this asserts the no-wrap claim the module doc makes.
  let n : Int32 = 40
  for fill in [32767, -32768, 0, 1, -1] {
    let prev : FixedArray[Int32] = FixedArray::make(n, fill)
    let (a0, a1) = gr_apply_qmf(prev, 0)
    let (b0, b1) = g722_apply_qmf_v128(prev, 0)
    assert_eq(b0, a0)
    assert_eq(b1, a1)
  }
  // alternating extremes maximise the cancellation pattern
  let alt : FixedArray[Int32] = FixedArray::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    alt[i] = if i % 2 == 0 { 32767 } else { -32768 }
  }
  let (c0, c1) = gr_apply_qmf(alt, 0)
  let (d0, d1) = g722_apply_qmf_v128(alt, 0)
  assert_eq(d0, c0)
  assert_eq(d1, c1)
}

///|
test "g722 dsp v128: even taps feed x1 and odd taps feed x0" {
  // Pin the lane mapping the vector reduction relies on: a unit impulse on
  // an even tap must show up only in x1, and on an odd tap only in x0.
  let n : Int32 = 32
  for tap in [0, 1, 2, 3, 22, 23] {
    let prev : FixedArray[Int32] = FixedArray::make(n, 0)
    prev[tap] = 1000
    let (x0, x1) = g722_apply_qmf_v128(prev, 0)
    let (r0, r1) = gr_apply_qmf(prev, 0)
    assert_eq(x0, r0)
    assert_eq(x1, r1)
    if tap % 2 == 0 {
      assert_eq(x0, 0)
      assert_true(x1 != 0)
    } else {
      assert_eq(x1, 0)
      assert_true(x0 != 0)
    }
  }
}
