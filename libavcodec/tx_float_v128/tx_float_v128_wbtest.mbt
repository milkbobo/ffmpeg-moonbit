///|
/// Whitebox tests for the SIMD (`@v128`) split-radix FFT combine kernels
/// (`tx_float_v128.mbt`).
///
/// The `tr_*` functions are verbatim transcriptions of the scalar port
/// (`libavcodec/aac_mdct_tx/aac_mdct_tx.mbt`: `mtx_f32`, `aac_mtx_bf`,
/// `aac_mtx_butterflies`, `aac_mtx_transform`, `aac_mtx_combine`,
/// `aac_mtx_fft4`) — the parent package's privates are not visible from a
/// subpackage, so the reference is carried here. Every kernel must agree
/// bit-for-bit.

///|
/// `mtx_f32`: round to binary32. */
fn tr_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
fn tr_add(a : Double, b : Double) -> Double {
  tr_f32(a + b)
}

///|
fn tr_sub(a : Double, b : Double) -> Double {
  tr_f32(a - b)
}

///|
fn tr_mul(a : Double, b : Double) -> Double {
  tr_f32(a * b)
}

///|
/// Verbatim `aac_mtx_bf`. */
fn tr_bf(a : Double, b : Double) -> (Double, Double) {
  (tr_sub(a, b), tr_add(a, b))
}

///|
/// Verbatim `aac_mtx_butterflies`. */
fn tr_butterflies(
  zr : Array[Double],
  zi : Array[Double],
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  t1 : Double,
  t2 : Double,
  t5_in : Double,
  t6_in : Double,
) -> Unit {
  let r0 = zr[a0]
  let i0 = zi[a0]
  let r1 = zr[a1]
  let i1 = zi[a1]
  let t3 = tr_sub(t5_in, t1)
  let t5 = tr_add(t5_in, t1)
  let a2r = tr_sub(r0, t5)
  let a0r = tr_add(r0, t5)
  let a3i = tr_sub(i1, t3)
  let a1i = tr_add(i1, t3)
  let t4 = tr_sub(t2, t6_in)
  let t6 = tr_add(t2, t6_in)
  let a3r = tr_sub(r1, t4)
  let a1r = tr_add(r1, t4)
  let a2i = tr_sub(i0, t6)
  let a0i = tr_add(i0, t6)
  zr[a2] = a2r
  zr[a0] = a0r
  zi[a3] = a3i
  zi[a1] = a1i
  zr[a3] = a3r
  zr[a1] = a1r
  zi[a2] = a2i
  zi[a0] = a0i
}

///|
/// Verbatim `aac_mtx_transform`. */
fn tr_transform(
  zr : Array[Double],
  zi : Array[Double],
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  wre : Double,
  wim : Double,
) -> Unit {
  let t1 = tr_sub(tr_mul(zr[a2], wre), tr_mul(zi[a2], -wim))
  let t2 = tr_add(tr_mul(zr[a2], -wim), tr_mul(zi[a2], wre))
  let t5 = tr_sub(tr_mul(zr[a3], wre), tr_mul(zi[a3], wim))
  let t6 = tr_add(tr_mul(zr[a3], wim), tr_mul(zi[a3], wre))
  tr_butterflies(zr, zi, a0, a1, a2, a3, t1, t2, t5, t6)
}

///|
/// Verbatim `aac_mtx_combine`. */
fn tr_combine(
  zr : Array[Double],
  zi : Array[Double],
  tab : Array[Double],
  off : Int32,
  len : Int32,
) -> Unit {
  let o1 = 2 * len
  let o2 = 4 * len
  let o3 = 6 * len
  let iters = len / 4
  for t in 0..<iters {
    let z = off + t * 8
    let c = t * 8
    let w = o1 - 7 - t * 8
    // the port runs eight TRANSFORMs per t, in slot order
    // 0, 2, 4, 6, 1, 3, 5, 7 — all eight must be present
    tr_transform(
      zr,
      zi,
      z + 0,
      z + o1 + 0,
      z + o2 + 0,
      z + o3 + 0,
      tab[c + 0],
      tab[w + 7],
    )
    tr_transform(
      zr,
      zi,
      z + 2,
      z + o1 + 2,
      z + o2 + 2,
      z + o3 + 2,
      tab[c + 2],
      tab[w + 5],
    )
    tr_transform(
      zr,
      zi,
      z + 4,
      z + o1 + 4,
      z + o2 + 4,
      z + o3 + 4,
      tab[c + 4],
      tab[w + 3],
    )
    tr_transform(
      zr,
      zi,
      z + 6,
      z + o1 + 6,
      z + o2 + 6,
      z + o3 + 6,
      tab[c + 6],
      tab[w + 1],
    )
    tr_transform(
      zr,
      zi,
      z + 1,
      z + o1 + 1,
      z + o2 + 1,
      z + o3 + 1,
      tab[c + 1],
      tab[w + 6],
    )
    tr_transform(
      zr,
      zi,
      z + 3,
      z + o1 + 3,
      z + o2 + 3,
      z + o3 + 3,
      tab[c + 3],
      tab[w + 4],
    )
    tr_transform(
      zr,
      zi,
      z + 5,
      z + o1 + 5,
      z + o2 + 5,
      z + o3 + 5,
      tab[c + 5],
      tab[w + 2],
    )
    tr_transform(
      zr,
      zi,
      z + 7,
      z + o1 + 7,
      z + o2 + 7,
      z + o3 + 7,
      tab[c + 7],
      tab[w + 0],
    )
  }
}

///|
/// Verbatim `aac_mtx_fft4`. */
fn tr_fft4(zr : Array[Double], zi : Array[Double], o : Int32) -> Unit {
  let (t3, t1) = tr_bf(zr[o + 0], zr[o + 1])
  let (t8, t6) = tr_bf(zr[o + 3], zr[o + 2])
  let (d2r, d0r) = tr_bf(t1, t6)
  let (t4, t2) = tr_bf(zi[o + 0], zi[o + 1])
  let (t7, t5) = tr_bf(zi[o + 2], zi[o + 3])
  let (d3i, d1i) = tr_bf(t4, t8)
  let (d3r, d1r) = tr_bf(t3, t7)
  let (d2i, d0i) = tr_bf(t2, t5)
  zr[o + 2] = d2r
  zr[o + 0] = d0r
  zi[o + 3] = d3i
  zi[o + 1] = d1i
  zr[o + 3] = d3r
  zr[o + 1] = d1r
  zi[o + 2] = d2i
  zi[o + 0] = d0i
}

///|
/// Deterministic generator (LCG) over a modest range. */
fn tr_gen(seed : UInt32, n : Int32) -> Array[Double] {
  let a : Array[Double] = Array::make(n, 0.0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    let v = ((s >> 16) & 0xFFFF).to_double()
    a[i] = (v - 32768.0) / 16384.0
  }
  a
}

///|
fn tr_copy(a : Array[Double]) -> Array[Double] {
  let b : Array[Double] = Array::make(a.length(), 0.0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn tr_same(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      if !(a[i] == 0.0 && b[i] == 0.0) {
        return false
      }
    }
  }
  true
}

///|
test "tx float v128: split-radix combine bit-exact over all lengths" {
  // len = n/8, and the combine stores into [off, off + 8*len). Use a
  // power-of-two length set matching the port's fft32..fft512 stages.
  for len in [4, 8, 16, 32, 64] {
    for off in [0, 8] {
      let n = 8 * len + off
      let seed = 0x9E3779B9U +
        len.reinterpret_as_uint() * 31U +
        off.reinterpret_as_uint()
      let zr = tr_gen(seed, n)
      let zi = tr_gen(seed + 17U, n)
      // the cosine table must cover the slots the walk touches:
      // max index = max(c + 6, o1 - 7 - t*8 + 7) with t < len/4
      let tab = tr_gen(seed + 33U, 2 * len + 8)
      let a1 = tr_copy(zr)
      let b1 = tr_copy(zi)
      tr_combine(a1, b1, tab, off, len)
      let a2 = tr_copy(zr)
      let b2 = tr_copy(zi)
      fft_sr_combine_v128(a2, b2, tab, off, len)
      assert_true(tr_same(a1, a2))
      assert_true(tr_same(b1, b2))
    }
  }
}

///|
test "tx float v128: combine with a real cosine twiddle table" {
  // Use an actual cos table so the twiddles are the realistic small
  // magnitudes the FFT feeds in, rather than arbitrary noise.
  let pi = 3.14159265358979323846
  for len in [4, 8, 16, 32] {
    let n = 8 * len
    // cos table over 2*len+8 entries, matching the port's layout
    let tab : Array[Double] = Array::make(2 * len + 8, 0.0)
    for i = 0; i < 2 * len + 8; i = i + 1 {
      tab[i] = tr_f32(@math.cos(pi * i.to_double() / (2.0 * len.to_double())))
    }
    let seed = 0xABCDEF01U + len.reinterpret_as_uint()
    let zr = tr_gen(seed, n)
    let zi = tr_gen(seed + 5U, n)
    let a1 = tr_copy(zr)
    let b1 = tr_copy(zi)
    tr_combine(a1, b1, tab, 0, len)
    let a2 = tr_copy(zr)
    let b2 = tr_copy(zi)
    fft_sr_combine_v128(a2, b2, tab, 0, len)
    assert_true(tr_same(a1, a2))
    assert_true(tr_same(b1, b2))
  }
}

///|
test "tx float v128: fft4 scalar-deviation path matches the reference" {
  for off in [0, 4, 8, 12] {
    let n = off + 4
    let seed = 0x13572468U + off.reinterpret_as_uint()
    let zr = tr_gen(seed, n)
    let zi = tr_gen(seed + 9U, n)
    let a1 = tr_copy(zr)
    let b1 = tr_copy(zi)
    tr_fft4(a1, b1, off)
    let a2 = tr_copy(zr)
    let b2 = tr_copy(zi)
    fft4_ns_v128(a2, b2, off)
    assert_true(tr_same(a1, a2))
    assert_true(tr_same(b1, b2))
  }
}

///|
test "tx float v128: combine does not touch slots outside its window" {
  let len : Int32 = 8
  let n = 8 * len + 16
  let seed = 0x55AA55AAU
  let zr = tr_gen(seed, n)
  let zi = tr_gen(seed + 3U, n)
  let tab = tr_gen(seed + 7U, 2 * len + 8)
  let a1 = tr_copy(zr)
  let b1 = tr_copy(zi)
  tr_combine(a1, b1, tab, 0, len)
  let a2 = tr_copy(zr)
  let b2 = tr_copy(zi)
  fft_sr_combine_v128(a2, b2, tab, 0, len)
  // everything from 8*len onward must be untouched on both sides
  for i = 8 * len; i < n; i = i + 1 {
    assert_eq(a2[i], zr[i])
    assert_eq(b2[i], zi[i])
    assert_eq(a1[i], zr[i])
  }
}
