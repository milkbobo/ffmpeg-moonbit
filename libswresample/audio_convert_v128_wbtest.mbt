///|
/// Whitebox tests for the SIMD (`@v128`) libswresample float→s16
/// planar-to-packed interleaver (`audio_convert_v128.mbt`).
///
/// The `ar_*` functions are verbatim transcriptions of the scalar ports in
/// the same package (`swr_lrintf`, `swr_clip_int16`, `swr_flt_to_s16`) —
/// carried here so the reference is explicit even though the package is
/// flat. The SIMD kernel must agree bit-for-bit, including lrintf's
/// round-half-to-even.

///|
/// Verbatim `swr_lrintf`. */
fn ar_lrintf(x : Double) -> Int32 {
  let f = x.floor()
  let frac = x - f
  if frac > 0.5 {
    (f + 1.0).to_int()
  } else if frac < 0.5 {
    f.to_int()
  } else if f.to_int() % 2 == 0 {
    f.to_int()
  } else {
    (f + 1.0).to_int()
  }
}

///|
/// Verbatim `swr_clip_int16`. */
fn ar_clip_int16(v : Int32) -> Int32 {
  if v < -32768 {
    -32768
  } else if v > 32767 {
    32767
  } else {
    v
  }
}

///|
/// Verbatim `swr_flt_to_s16`. */
fn ar_flt_to_s16(x : Double) -> Int32 {
  ar_clip_int16(ar_lrintf(x * 32768.0))
}

///|
/// Verbatim `Swr::flt_planar_to_s16_packed` (the interleave, as s16 values). */
fn ar_pack(planar : Array[Array[Double]], channels : Int32, nb : Int32) -> Array[Int32] {
  let out : Array[Int32] = Array::make(nb * channels, 0)
  for i = 0; i < nb; i = i + 1 {
    for ch = 0; ch < channels; ch = ch + 1 {
      out[i * channels + ch] = ar_flt_to_s16(planar[ch][i])
    }
  }
  out
}

///|
/// Deterministic generator (LCG) over roughly [-1.5, 1.5] so the s16
/// scaling exercises both the round and the clamp. */
fn ar_gen(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v - 32768.0) / 21845.333
  }
  a
}

///|
test "audio convert v128: stereo planar -> interleaved s16 bit-exact" {
  for nb in [1, 2, 3, 4, 5, 8, 17, 64] {
    let seed = 0x9E3779B9U + nb.reinterpret_as_uint() * 31U
    let l = ar_gen(seed, nb)
    let r = ar_gen(seed + 7U, nb)
    let planar : Array[Array[Double]] = [l, r]
    let expected = ar_pack(planar, 2, nb)
    let got : Array[Int32] = Array::make(2 * nb, 0)
    swr_flt_planar_to_s16_packed_v128(planar, 2, nb, got)
    for i = 0; i < 2 * nb; i = i + 1 {
      assert_eq(got[i], expected[i])
    }
  }
}

///|
test "audio convert v128: rounding is half-to-even, not truncation" {
  // 0.5 / 32768 scales to exactly 0.5 -> ties to even (0).
  // 1.5 / 32768 scales to exactly 1.5 -> ties to even (2).
  // 2.5 / 32768 scales to exactly 2.5 -> ties to even (2).
  // A truncating implementation would give 0, 1, 2 instead of 0, 2, 2.
  let vals : Array[Double] = [
    0.5 / 32768.0,
    1.5 / 32768.0,
    2.5 / 32768.0,
    3.5 / 32768.0,
    -0.5 / 32768.0,
    -1.5 / 32768.0,
  ]
  let n = vals.length()
  let planar : Array[Array[Double]] = [vals, vals]
  let got : Array[Int32] = Array::make(2 * n, 0)
  swr_flt_planar_to_s16_packed_v128(planar, 2, n, got)
  for i = 0; i < n; i = i + 1 {
    assert_eq(got[2 * i], ar_flt_to_s16(vals[i]))
  }
  // and the specific tie values
  assert_eq(got[0], 0)
  assert_eq(got[2], 2)
  assert_eq(got[4], 2)
  assert_eq(got[6], 4)
}

///|
test "audio convert v128: clipping at both s16 rails" {
  let vals : Array[Double] = [2.0, -2.0, 1.0, -1.0, 1.0001, -1.0001, 100.0, -100.0]
  let n = vals.length()
  let planar : Array[Array[Double]] = [vals, vals]
  let got : Array[Int32] = Array::make(2 * n, 0)
  swr_flt_planar_to_s16_packed_v128(planar, 2, n, got)
  for i = 0; i < n; i = i + 1 {
    assert_eq(got[2 * i], ar_flt_to_s16(vals[i]))
    assert_true(got[2 * i] >= -32768)
    assert_true(got[2 * i] <= 32767)
  }
  assert_eq(got[0], 32767)
  assert_eq(got[2], -32768)
  assert_eq(got[4], 32767)
  assert_eq(got[6], -32768)
}

///|
test "audio convert v128: mono and 6-channel fall back correctly" {
  // channels != 2 uses the general scalar path inside the kernel, which
  // must still match the reference interleave order.
  for channels in [1, 3, 6] {
    let nb : Int32 = 5
    let planar : Array[Array[Double]] = []
    for ch = 0; ch < channels; ch = ch + 1 {
      planar.push(ar_gen(0x1234U + ch.reinterpret_as_uint() * 17U, nb))
    }
    let expected = ar_pack(planar, channels, nb)
    let got : Array[Int32] = Array::make(nb * channels, 0)
    swr_flt_planar_to_s16_packed_v128(planar, channels, nb, got)
    for i = 0; i < nb * channels; i = i + 1 {
      assert_eq(got[i], expected[i])
    }
  }
}
