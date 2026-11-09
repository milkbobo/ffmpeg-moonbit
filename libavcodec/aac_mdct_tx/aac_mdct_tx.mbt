///|
/// Bit-exact port of the `av_tx` AV_TX_FLOAT_MDCT forward transform for the
/// AAC encoder's two sizes (1024 and 128, scale 32768 - `aacenc.c:1124`
/// passes `scale = 32768.0f`), replacing the direct f64 O(N^2) MDCT so the
/// encoder's analysis coefficients carry the same f32 rounding as the stock
/// FFmpeg 9.0.2 build (§370).
///
/// The reference path: `ff_tx_mdct_init` folds the window with the
/// `ff_tx_mdct_gen_exp` twiddles (sqrt(scale) folded into both rotations),
/// runs the preshuffled split-radix FFT of size len/2 (`ff_tx_fft*_ns`
/// codelets), then rotates back. `sinewin_tablegen.h:60` builds the sine
/// window with `sinf` on the f32-rounded angle, and `vector_fmul` /
/// `vector_fmul_reverse` round every window product to f32.
///
/// The tables are regenerated here from the reference formulas; every value
/// lands on an f32 boundary, so a 1-ulp libm difference in the double
/// intermediates cannot change them in practice. `aac_mdct_tx_ref_checks.mbt`
/// (dumped from the oracle by `scripts/aac_mdct_tx_dump.c`) pins the exact
/// bit patterns in the white-box test. Tables are built per encoder rather
/// than at module init: the package initializer is already near the wasm
/// local-count limit.
/// Original FFmpeg code is LGPL-2.1-or-later.

///|
/// The reference runtime tables.
pub struct AacMdctTx {
  sine1024 : Array[Double]
  sine128 : Array[Double]
  kbd1024 : Array[Double]
  kbd128 : Array[Double]
  cos8 : Array[Double]
  cos16 : Array[Double]
  cos32 : Array[Double]
  cos64 : Array[Double]
  cos128 : Array[Double]
  cos256 : Array[Double]
  cos512 : Array[Double]
  exp1024_re : Array[Double]
  exp1024_im : Array[Double]
  exp128_re : Array[Double]
  exp128_im : Array[Double]
  map512 : Array[Int32]
  map64 : Array[Int32]
}

///|
/// Round `x` to binary32 precision, the way every C `float` assignment in
/// the reference does.
fn mtx_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
fn mtx_add(a : Double, b : Double) -> Double {
  mtx_f32(a + b)
}

///|
fn mtx_sub(a : Double, b : Double) -> Double {
  mtx_f32(a - b)
}

///|
fn mtx_mul(a : Double, b : Double) -> Double {
  mtx_f32(a * b)
}

///|
/// `ff_sine_window_init` (`sinewin_tablegen.h:60`):
/// `sinf((i + 0.5) * (M_PI / (2.0 * n)))` - the angle is f32-rounded at the
/// `sinf` call, the result is f32.
fn aac_mdct_tx_sine(n : Int32, fix : Array[UInt32]) -> Array[Double] {
  let out : Array[Double] = Array::make(n, 0.0)
  let freq = 3.14159265358979323846 / (2.0 * n.to_double())
  for i = 0; i < n; i = i + 1 {
    out[i] = mtx_f32(@math.sin(mtx_f32((i.to_double() + 0.5) * freq)))
  }
  // glibc's sinf is not correctly rounded for a few angles; replay the
  // dumped values so the window matches the oracle bit for bit.
  let mut k = 0
  while k < fix.length() {
    out[fix[k].reinterpret_as_int()] = Float::reinterpret_from_uint(fix[k + 1]).to_double()
    k = k + 2
  }
  out
}

///|
/// `kbd_window_init` (`kbdwin.c:24`) into a float table: the rising half
/// (`n` points) of the Kaiser-Bessel-derived window, accumulated in double
/// through `av_bessel_i0` and rounded to f32 at the store -
/// `ff_aac_kbd_long_1024` is alpha 4, `ff_aac_kbd_short_128` alpha 6
/// (`aactab.c:97`).
fn aac_mdct_tx_kbd(alpha : Double, n : Int32) -> Array[Double] {
  let half = n / 2
  let temp : Array[Double] = Array::make(half + 1, 0.0)
  let a = alpha * 3.14159265358979323846 / n.to_double()
  let alpha2 = 4.0 * a * a
  let mut scale = 0.0
  for i = 0; i <= half; i = i + 1 {
    let tmp = i.to_double() * (n - i).to_double() * alpha2
    temp[i] = @libavutil.av_bessel_i0(tmp.sqrt())
    scale = scale + temp[i] * (if i > 0 && i < half { 2.0 } else { 1.0 })
  }
  scale = 1.0 / (scale + 1.0)
  let out : Array[Double] = Array::make(n, 0.0)
  let mut sum = 0.0
  for i = 0; i < n; i = i + 1 {
    sum = sum + (if i <= half { temp[i] } else { temp[n - i] })
    out[i] = mtx_f32((sum * scale).sqrt())
  }
  out
}

///|
/// `SR_TABLE` init (`tx_template.c:66`): `tab[i] = (float)cos(i * 2*M_PI/n)`
/// for `i < n/4`, zero at `n/4`.
fn aac_mdct_tx_cos(n : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(n / 4 + 1, 0.0)
  let freq = 2.0 * 3.14159265358979323846 / n.to_double()
  for i = 0; i < n / 4; i = i + 1 {
    out[i] = mtx_f32(@math.cos(i.to_double() * freq))
  }
  out
}

///|
/// `ff_tx_mdct_gen_exp` (`tx_template.c:2107`) for `scale = 32768`: the
/// twiddles carry `sqrt(scale)` in both rotations, `theta = 1/8`.
fn aac_mdct_tx_exp(len : Int32, imag : Bool) -> Array[Double] {
  let len4 = len / 2
  let out : Array[Double] = Array::make(len4, 0.0)
  let scale = 32768.0.sqrt()
  let theta = 1.0 / 8.0
  for i = 0; i < len4; i = i + 1 {
    let alpha = 1.57079632679489661923 *
      (i.to_double() + theta) /
      len4.to_double()
    let v = if imag { @math.sin(alpha) } else { @math.cos(alpha) }
    out[i] = mtx_f32(v * scale)
  }
  out
}

///|
/// `split_radix_permutation` (`tx.c:127`), forward direction.
fn aac_mdct_tx_srp(i : Int32, len : Int32) -> Int32 {
  let l1 = len >> 1
  if l1 <= 1 {
    return i & 1
  }
  if (i & l1) == 0 {
    return aac_mdct_tx_srp(i, l1) * 2
  }
  let l2 = l1 >> 1
  return aac_mdct_tx_srp(i, l2) * 4 +
    1 -
    2 * (if ((i & l2) ^ 0) == 0 { 1 } else { 0 })
}

///|
/// `ff_tx_gen_ptwo_revtab` in `FF_TX_MAP_SCATTER` mode (`tx.c:136`): the
/// preshuffle permutation the MDCT's pre-rotation writes through.
fn aac_mdct_tx_map(len : Int32) -> Array[Int32] {
  let out : Array[Int32] = Array::make(len, 0)
  for i = 0; i < len; i = i + 1 {
    out[-aac_mdct_tx_srp(i, len) & (len - 1)] = i
  }
  out
}

///|
pub fn AacMdctTx::new() -> AacMdctTx {
  {
    sine1024: aac_mdct_tx_sine(1024, aac_mdct_tx_sine1024_fix),
    sine128: aac_mdct_tx_sine(128, aac_mdct_tx_sine128_fix),
    kbd1024: aac_mdct_tx_kbd(4.0, 1024),
    kbd128: aac_mdct_tx_kbd(6.0, 128),
    cos8: aac_mdct_tx_cos(8),
    cos16: aac_mdct_tx_cos(16),
    cos32: aac_mdct_tx_cos(32),
    cos64: aac_mdct_tx_cos(64),
    cos128: aac_mdct_tx_cos(128),
    cos256: aac_mdct_tx_cos(256),
    cos512: aac_mdct_tx_cos(512),
    exp1024_re: aac_mdct_tx_exp(1024, false),
    exp1024_im: aac_mdct_tx_exp(1024, true),
    exp128_re: aac_mdct_tx_exp(128, false),
    exp128_im: aac_mdct_tx_exp(128, true),
    map512: aac_mdct_tx_map(512),
    map64: aac_mdct_tx_map(64),
  }
}

///|
/// The long sine window (`ff_sine_1024`) the encoder multiplies samples by.
pub fn AacMdctTx::sine_long(self : AacMdctTx) -> Array[Double] {
  self.sine1024
}

///|
/// The short sine window (`ff_sine_128`).
pub fn AacMdctTx::sine_short(self : AacMdctTx) -> Array[Double] {
  self.sine128
}

///|
/// The long KBD window (`ff_aac_kbd_long_1024`), `window_shape` 1.
pub fn AacMdctTx::kbd_long(self : AacMdctTx) -> Array[Double] {
  self.kbd1024
}

///|
/// The short KBD window (`ff_aac_kbd_short_128`).
pub fn AacMdctTx::kbd_short(self : AacMdctTx) -> Array[Double] {
  self.kbd128
}

///|
/// The long window of `shape` (`use_kb_window`): sine (0) or KBD (1).
pub fn AacMdctTx::long_window(self : AacMdctTx, shape : Int32) -> Array[Double] {
  if shape != 0 {
    self.kbd1024
  } else {
    self.sine1024
  }
}

///|
/// The short window of `shape` (`use_kb_window`): sine (0) or KBD (1).
pub fn AacMdctTx::short_window(
  self : AacMdctTx,
  shape : Int32,
) -> Array[Double] {
  if shape != 0 {
    self.kbd128
  } else {
    self.sine128
  }
}

///|
/// `BF(x, y, a, b)`: `x = a - b; y = a + b` (`tx_priv.h:106`), f32.
fn aac_mtx_bf(a : Double, b : Double) -> (Double, Double) {
  (mtx_sub(a, b), mtx_add(a, b))
}

///|
/// `BUTTERFLIES` (`tx_template.c:540`) with `t1..t6` preset by the caller's
/// `CMUL`s: writes the four complex slots in place.
fn aac_mtx_butterflies(
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
  let t3 = mtx_sub(t5_in, t1)
  let t5 = mtx_add(t5_in, t1)
  let a2r = mtx_sub(r0, t5)
  let a0r = mtx_add(r0, t5)
  let a3i = mtx_sub(i1, t3)
  let a1i = mtx_add(i1, t3)
  let t4 = mtx_sub(t2, t6_in)
  let t6 = mtx_add(t2, t6_in)
  let a3r = mtx_sub(r1, t4)
  let a1r = mtx_add(r1, t4)
  let a2i = mtx_sub(i0, t6)
  let a0i = mtx_add(i0, t6)
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
/// `TRANSFORM` (`tx_template.c:554`): `CMUL` the second and third complex
/// inputs by `(wre, ±wim)`, then run the butterfly block.
fn aac_mtx_transform(
  zr : Array[Double],
  zi : Array[Double],
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  wre : Double,
  wim : Double,
) -> Unit {
  let t1 = mtx_sub(mtx_mul(zr[a2], wre), mtx_mul(zi[a2], -wim))
  let t2 = mtx_add(mtx_mul(zr[a2], -wim), mtx_mul(zi[a2], wre))
  let t5 = mtx_sub(mtx_mul(zr[a3], wre), mtx_mul(zi[a3], wim))
  let t6 = mtx_add(mtx_mul(zr[a3], wim), mtx_mul(zi[a3], wre))
  aac_mtx_butterflies(zr, zi, a0, a1, a2, a3, t1, t2, t5, t6)
}

///|
/// `ff_tx_fft_sr_combine` (`tx_template.c:562`), `len = n/8`. `wim` walks the
/// same cos table backwards from `cos + o1 - 7`, shrinking 8 per iteration.
fn aac_mtx_combine(
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
    aac_mtx_transform(
      zr,
      zi,
      z + 0,
      z + o1 + 0,
      z + o2 + 0,
      z + o3 + 0,
      tab[c + 0],
      tab[w + 7],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 2,
      z + o1 + 2,
      z + o2 + 2,
      z + o3 + 2,
      tab[c + 2],
      tab[w + 5],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 4,
      z + o1 + 4,
      z + o2 + 4,
      z + o3 + 4,
      tab[c + 4],
      tab[w + 3],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 6,
      z + o1 + 6,
      z + o2 + 6,
      z + o3 + 6,
      tab[c + 6],
      tab[w + 1],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 1,
      z + o1 + 1,
      z + o2 + 1,
      z + o3 + 1,
      tab[c + 1],
      tab[w + 6],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 3,
      z + o1 + 3,
      z + o2 + 3,
      z + o3 + 3,
      tab[c + 3],
      tab[w + 4],
    )
    aac_mtx_transform(
      zr,
      zi,
      z + 5,
      z + o1 + 5,
      z + o2 + 5,
      z + o3 + 5,
      tab[c + 5],
      tab[w + 2],
    )
    aac_mtx_transform(
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
/// `ff_tx_fft4_ns` (`tx_template.c:643`).
fn aac_mtx_fft4(zr : Array[Double], zi : Array[Double], o : Int32) -> Unit {
  let (t3, t1) = aac_mtx_bf(zr[o + 0], zr[o + 1])
  let (t8, t6) = aac_mtx_bf(zr[o + 3], zr[o + 2])
  let (d2r, d0r) = aac_mtx_bf(t1, t6)
  let (t4, t2) = aac_mtx_bf(zi[o + 0], zi[o + 1])
  let (t7, t5) = aac_mtx_bf(zi[o + 2], zi[o + 3])
  let (d3i, d1i) = aac_mtx_bf(t4, t8)
  let (d3r, d1r) = aac_mtx_bf(t3, t7)
  let (d2i, d0i) = aac_mtx_bf(t2, t5)
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
/// `ff_tx_fft8_ns` (`tx_template.c:660`).
fn aac_mtx_fft8(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  let cos = t.cos8[1]
  aac_mtx_fft4(zr, zi, o)
  let (t1, r5) = aac_mtx_bf(zr[o + 4], -zr[o + 5])
  zr[o + 5] = r5
  let (t2, i5) = aac_mtx_bf(zi[o + 4], -zi[o + 5])
  zi[o + 5] = i5
  let (t5, r7) = aac_mtx_bf(zr[o + 6], -zr[o + 7])
  zr[o + 7] = r7
  let (t6, i7) = aac_mtx_bf(zi[o + 6], -zi[o + 7])
  zi[o + 7] = i7
  aac_mtx_butterflies(zr, zi, o + 0, o + 2, o + 4, o + 6, t1, t2, t5, t6)
  aac_mtx_transform(zr, zi, o + 1, o + 3, o + 5, o + 7, cos, cos)
}

///|
/// `ff_tx_fft16_ns` (`tx_template.c:679`).
fn aac_mtx_fft16(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  let c1 = t.cos16[1]
  let c2 = t.cos16[2]
  let c3 = t.cos16[3]
  aac_mtx_fft8(t, zr, zi, o + 0)
  aac_mtx_fft4(zr, zi, o + 8)
  aac_mtx_fft4(zr, zi, o + 12)
  let t1 = zr[o + 8]
  let t2 = zi[o + 8]
  let t5 = zr[o + 12]
  let t6 = zi[o + 12]
  aac_mtx_butterflies(zr, zi, o + 0, o + 4, o + 8, o + 12, t1, t2, t5, t6)
  aac_mtx_transform(zr, zi, o + 2, o + 6, o + 10, o + 14, c2, c2)
  aac_mtx_transform(zr, zi, o + 1, o + 5, o + 9, o + 13, c1, c3)
  aac_mtx_transform(zr, zi, o + 3, o + 7, o + 11, o + 15, c3, c1)
}

///|
/// `DECL_SR_CODELET(n, n2, n4)` (`tx_template.c:641`): the halves/quarters
/// recurse, then the split-radix combine finishes the doubling.
fn aac_mtx_fft32(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  aac_mtx_fft16(t, zr, zi, o)
  aac_mtx_fft8(t, zr, zi, o + 16)
  aac_mtx_fft8(t, zr, zi, o + 24)
  aac_mtx_combine(zr, zi, t.cos32, o, 4)
}

///|
fn aac_mtx_fft64(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  aac_mtx_fft32(t, zr, zi, o)
  aac_mtx_fft16(t, zr, zi, o + 32)
  aac_mtx_fft16(t, zr, zi, o + 48)
  aac_mtx_combine(zr, zi, t.cos64, o, 8)
}

///|
fn aac_mtx_fft128(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  aac_mtx_fft64(t, zr, zi, o)
  aac_mtx_fft32(t, zr, zi, o + 64)
  aac_mtx_fft32(t, zr, zi, o + 96)
  aac_mtx_combine(zr, zi, t.cos128, o, 16)
}

///|
fn aac_mtx_fft256(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  aac_mtx_fft128(t, zr, zi, o)
  aac_mtx_fft64(t, zr, zi, o + 128)
  aac_mtx_fft64(t, zr, zi, o + 192)
  aac_mtx_combine(zr, zi, t.cos256, o, 32)
}

///|
fn aac_mtx_fft512(
  t : AacMdctTx,
  zr : Array[Double],
  zi : Array[Double],
  o : Int32,
) -> Unit {
  aac_mtx_fft256(t, zr, zi, o)
  aac_mtx_fft128(t, zr, zi, o + 256)
  aac_mtx_fft128(t, zr, zi, o + 384)
  aac_mtx_combine(zr, zi, t.cos512, o, 64)
}

///|
/// `ff_tx_mdct_fwd` (`tx_template.c:1273`) for `len` outputs from `2*len`
/// inputs: fold, pre-rotate in the preshuffle scatter order, run the
/// split-radix FFT of size `len/2`, rotate back into interleaved outputs.
/// The twiddle tables carry `sqrt(32768)` so no extra scaling is applied
/// here (matching the reference `scale` fold).
fn aac_mdct_tx_forward(
  t : AacMdctTx,
  src : Array[Double],
  len : Int32,
) -> Array[Double] {
  let (exp_re, exp_im, map) = if len == 1024 {
    (t.exp1024_re, t.exp1024_im, t.map512)
  } else {
    (t.exp128_re, t.exp128_im, t.map64)
  }
  let len2 = len / 2
  let len3 = len2 * 3
  let len4 = len / 4
  let zr : Array[Double] = Array::make(len2, 0.0)
  let zi : Array[Double] = Array::make(len2, 0.0)
  for i = 0; i < len2; i = i + 1 {
    let k = 2 * i
    let idx = map[i]
    let tr = if k < len2 {
      mtx_add(-src[len2 + k], src[len2 - 1 - k])
    } else {
      mtx_add(-src[len2 + k], -src[5 * len2 - 1 - k])
    }
    let ti = if k < len2 {
      mtx_add(-src[len3 + k], -src[len3 - 1 - k])
    } else {
      mtx_add(src[k - len2], -src[len3 - 1 - k])
    }
    let er = exp_re[i]
    let ei = exp_im[i]
    // `CMUL(z[idx].im, z[idx].re, ...)` - the components are swapped.
    zi[idx] = mtx_sub(mtx_mul(tr, er), mtx_mul(ti, ei))
    zr[idx] = mtx_add(mtx_mul(tr, ei), mtx_mul(ti, er))
  }
  if len2 == 512 {
    aac_mtx_fft512(t, zr, zi, 0)
  } else {
    aac_mtx_fft64(t, zr, zi, 0)
  }
  let dst : Array[Double] = Array::make(len, 0.0)
  for i = 0; i < len4; i = i + 1 {
    let i0 = len4 + i
    let i1 = len4 - 1 - i
    let s0r = zr[i0]
    let s0i = zi[i0]
    let s1r = zr[i1]
    let s1i = zi[i1]
    let e0r = exp_re[i0]
    let e0i = exp_im[i0]
    let e1r = exp_re[i1]
    let e1i = exp_im[i1]
    dst[2 * i1 + 1] = mtx_sub(mtx_mul(s0r, e0i), mtx_mul(s0i, e0r))
    dst[2 * i0] = mtx_add(mtx_mul(s0r, e0r), mtx_mul(s0i, e0i))
    dst[2 * i0 + 1] = mtx_sub(mtx_mul(s1r, e1i), mtx_mul(s1i, e1r))
    dst[2 * i1] = mtx_add(mtx_mul(s1r, e1r), mtx_mul(s1i, e1i))
  }
  dst
}

///|
/// `ff_tx_mdct_fwd` for the long window (2048 samples in, 1024 out).
pub fn aac_mdct_tx_1024(t : AacMdctTx, src : Array[Double]) -> Array[Double] {
  aac_mdct_tx_forward(t, src, 1024)
}

///|
/// `ff_tx_mdct_fwd` for one short block (256 samples in, 128 out).
pub fn aac_mdct_tx_128(t : AacMdctTx, src : Array[Double]) -> Array[Double] {
  aac_mdct_tx_forward(t, src, 128)
}
