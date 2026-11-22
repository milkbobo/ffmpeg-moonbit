/// Bit-exact replica of the fixed-point MDCT used by FFmpeg's AC-3 fixed
/// encoder: `av_tx_init(AV_TX_INT32_MDCT, len=256, scale=-1)` resolving to
/// `mdct_fwd_int32_c` + `fft128_ns_int32_c` (as confirmed by the reference
/// build's transform tree), plus `ff_kbd_window_init(alpha=5.0, n=256)`
/// quantized to 1<<22.
///
/// Numerical contract replicated from libavutil/tx_template.c (TX_INT32):
///   RESCALE(x) = clip64(llrintf(x * 2^31)) — the double argument is first
///     narrowed to float (nearest-even), then rounded half-to-even;
///   CMUL/SMUL use int64 accumulators rounded with (+0x40000000) >> 31;
///   BF and FOLD rely on 32-bit wrap-around adds (identical bit patterns
///     in MoonBit's Int32 arithmetic);
///   the split-radix tables are RESCALE(cos(i * 2*PI/len)).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// `llrintf` semantics: the argument has already been narrowed to float by
/// the C call, and ties round half-to-even. */
fn ac3_tx_lrintf32(f : Float) -> Int32 {
  let d = f.to_double()
  let a = if d < 0.0 { -d } else { d }
  let i = @math.floor(a)
  let frac = a - i
  let r = if frac > 0.5 {
    i + 1.0
  } else if frac < 0.5 {
    i
  } else if i.mod(2.0) != 0.0 {
    i + 1.0
  } else {
    i
  }
  let s = if d < 0.0 { -r } else { r }
  s.to_int()
}

///|
/// `RESCALE(x)`: av_clip64(llrintf(x * 2147483648.0)). */
fn ac3_tx_rescale(x : Double) -> Int32 {
  ac3_tx_lrintf32(Float::from_double(x * 2147483648.0))
}

///|
/// Modified Bessel I0, minimax rational approximations
/// (libavutil/mathematics.c `av_bessel_i0`). */
fn ac3_bessel_i0(x : Double) -> Double {
  let p1 = [
    -2.2335582639474375249e+15, -5.5050369673018427753e+14, -3.2940087627407749166e+13,
    -8.4925101247114157499e+11, -1.1912746104985237192e+10, -1.0313066708737980747e+08,
    -5.9545626019847898221e+05, -2.4125195876041896775e+03, -7.0935347449210549190e+00,
    -1.5453977791786851041e-02, -2.5172644670688975051e-05, -3.0517226450451067446e-08,
    -2.6843448573468483278e-11, -1.5982226675653184646e-14, -5.2487866627945699800e-18,
  ]
  let q1 = [
    -2.2335582639474375245e+15, 7.8858692566751002988e+12, -1.2207067397808979846e+10,
    1.0377081058062166144e+07, -4.8527560179962773045e+03, 1.0,
  ]
  let p2 = [
    -2.2210262233306573296e-04, 1.3067392038106924055e-02, -4.4700805721174453923e-01,
    5.5674518371240761397e+00, -2.3517945679239481621e+01, 3.1611322818701131207e+01,
    -9.6090021968656180000e+00,
  ]
  let q2 = [
    -5.5194330231005480228e-04, 3.2547697594819615062e-02, -1.1151759188741312645e+00,
    1.3982595353892851542e+01, -6.0228002066743340583e+01, 8.5539563258012929600e+01,
    -3.1446690275135491500e+01, 1.0,
  ]
  fn eval_poly(coeff : Array[Double], x : Double) -> Double {
    let mut sum = coeff[coeff.length() - 1]
    for i = coeff.length() - 2; i >= 0; i = i - 1 {
      sum *= x
      sum += coeff[i]
    }
    sum
  }
  if x == 0.0 {
    return 1.0
  }
  let x = if x < 0.0 { -x } else { x }
  if x <= 15.0 {
    let y = x * x
    eval_poly(p1, y) / eval_poly(q1, y)
  } else {
    let y = 1.0 / x - 1.0 / 15.0
    let r = eval_poly(p2, y) / eval_poly(q2, y)
    let factor = @math.exp(x) / x.sqrt()
    factor * r
  }
}

///|
/// `ff_kbd_window_init(window, alpha, n)` followed by the fixed-point
/// quantization `iwin[i] = lrintf(fwin[i] * (1 << 22))` (ac3_fixed_mdct_init). */
fn ac3_kbd_window_fixed(alpha : Double, n : Int32) -> FixedArray[Int32] {
  let half = n / 2
  let alpha2 = 4.0 *
    (alpha * @math.PI / n.to_double()) *
    (alpha * @math.PI / n.to_double())
  let temp : FixedArray[Double] = FixedArray::make(half + 1, 0.0)
  let mut scale = 0.0
  for i = 0; i <= half; i = i + 1 {
    let t = i.to_double() * (n - i).to_double() * alpha2
    temp[i] = ac3_bessel_i0(t.sqrt())
    let w = if i != 0 && i != half { 2.0 } else { 1.0 }
    scale += temp[i] * w
  }
  scale = 1.0 / (scale + 1.0)
  let win : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut sum = 0.0
  for i = 0; i <= half; i = i + 1 {
    sum += temp[i]
    let f = Float::from_double((sum * scale).sqrt())
    win[i] = ac3_tx_lrintf32(f * Float::from_int(1 << 22))
  }
  for i = half + 1; i < n; i = i + 1 {
    sum += temp[n - i]
    let f = Float::from_double((sum * scale).sqrt())
    win[i] = ac3_tx_lrintf32(f * Float::from_int(1 << 22))
  }
  win
}

///|
/// `split_radix_permutation` (libavutil/tx.c). */
fn ac3_tx_split_radix_permutation(i : Int32, len : Int32, inv : Bool) -> Int32 {
  let len = len >> 1
  if len <= 1 {
    return i & 1
  }
  if (i & len) == 0 {
    return ac3_tx_split_radix_permutation(i, len, inv) * 2
  }
  let len = len >> 1
  let nb = (if (i & len) == 0 { 1 } else { 0 }) ^ (if inv { 1 } else { 0 })
  ac3_tx_split_radix_permutation(i, len, inv) * 4 + 1 - 2 * nb
}

///|
/// Preshuffle map for fft128 (`ff_tx_gen_ptwo_revtab`, SCATTER direction):
/// `map[-perm(i) & 127] = i`. */
fn ac3_tx_fft128_map() -> FixedArray[Int32] {
  let map : FixedArray[Int32] = FixedArray::make(128, 0)
  for i = 0; i < 128; i = i + 1 {
    let p = ac3_tx_split_radix_permutation(i, 128, false)
    map[-p & 127] = i
  }
  map
}

///|
/// Split-radix twiddle table (`SR_TABLE`): len/4+1 entries
/// `RESCALE(cos(i * 2*PI/len))` with the last entry zero. */
fn ac3_tx_sr_table(len : Int32) -> FixedArray[Int32] {
  let freq = 2.0 * @math.PI / len.to_double()
  let n = len / 4
  let tab : FixedArray[Int32] = FixedArray::make(n + 1, 0)
  for i = 0; i < n; i = i + 1 {
    tab[i] = ac3_tx_rescale(@math.cos(i.to_double() * freq))
  }
  tab[n] = 0
  tab
}

///|
/// MDCT exp table (`ff_tx_mdct_gen_exp` with scale_d = -1, forward):
/// `exp[i] = {RESCALE(cos(alpha)), RESCALE(sin(alpha))}` with
/// `alpha = PI/2 * (i + len4 + 1/8) / len4`, len4 = 128. */
fn ac3_tx_mdct_exp() -> FixedArray[(Int32, Int32)] {
  let len4 = 128
  let theta = len4.to_double() + 1.0 / 8.0
  let tab : FixedArray[(Int32, Int32)] = FixedArray::make(len4, (0, 0))
  for i = 0; i < len4; i = i + 1 {
    let alpha = @math.PI / 2.0 * (i.to_double() + theta) / len4.to_double()
    tab[i] = (
      ac3_tx_rescale(@math.cos(alpha)),
      ac3_tx_rescale(@math.sin(alpha)),
    )
  }
  tab
}

///|
/// Complex FFT working arrays (re/im pairs). All split-radix twiddle tables
/// live in one concatenated array addressed by per-size offsets. */
priv struct Ac3Fft {
  re : FixedArray[Int32]
  im : FixedArray[Int32]
  tab : FixedArray[Int32]
  tab8_off : Int32
  tab16_off : Int32
  tab32_off : Int32
  tab64_off : Int32
  tab128_off : Int32
}

///|
/// Build the concatenated split-radix tables (3 + 5 + 9 + 17 + 33 entries). */
fn Ac3Fft::new(len : Int32) -> Ac3Fft {
  let tab8 = ac3_tx_sr_table(8)
  let tab16 = ac3_tx_sr_table(16)
  let tab32 = ac3_tx_sr_table(32)
  let tab64 = ac3_tx_sr_table(64)
  let tab128 = ac3_tx_sr_table(128)
  let total = tab8.length() +
    tab16.length() +
    tab32.length() +
    tab64.length() +
    tab128.length()
  let tab : FixedArray[Int32] = FixedArray::make(total, 0)
  let mut o = 0
  let off8 = o
  for v in tab8 {
    tab[o] = v
    o += 1
  }
  let off16 = o
  for v in tab16 {
    tab[o] = v
    o += 1
  }
  let off32 = o
  for v in tab32 {
    tab[o] = v
    o += 1
  }
  let off64 = o
  for v in tab64 {
    tab[o] = v
    o += 1
  }
  let off128 = o
  for v in tab128 {
    tab[o] = v
    o += 1
  }
  {
    re: FixedArray::make(len, 0),
    im: FixedArray::make(len, 0),
    tab,
    tab8_off: off8,
    tab16_off: off16,
    tab32_off: off32,
    tab64_off: off64,
    tab128_off: off128,
  }
}

///|
/// `CMUL` on values: returns (dre, dim) with int64 accumulators. */
fn ac3_tx_cmul_v(
  are : Int32,
  aim : Int32,
  bre : Int32,
  bim : Int32,
) -> (Int32, Int32) {
  let accu = bre.to_int64() * are.to_int64() - bim.to_int64() * aim.to_int64()
  let dre = ((accu + 0x40000000) >> 31).to_int()
  let accu2 = bim.to_int64() * are.to_int64() + bre.to_int64() * aim.to_int64()
  let dim = ((accu2 + 0x40000000) >> 31).to_int()
  (dre, dim)
}

///|
/// `FOLD(x, y)`: 32-bit wrap-around sum, +32, arithmetic shift right 6. */
fn ac3_tx_fold(x : Int32, y : Int32) -> Int32 {
  (x + y + 32) >> 6
}

///|
/// `BUTTERFLIES(a0, a1, a2, a3)` with running t1/t2/t5/t6 (in-place). */
fn Ac3Fft::butterflies(
  self : Ac3Fft,
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  t1 : Int32,
  t2 : Int32,
  t5 : Int32,
  t6 : Int32,
) -> Unit {
  let re = self.re
  let im = self.im
  let r0 = re[a0]
  let i0 = im[a0]
  let r1 = re[a1]
  let i1 = im[a1]
  let t3 = t5 - t1
  let t5n = t5 + t1
  re[a2] = r0 - t5n
  re[a0] = r0 + t5n
  im[a3] = i1 - t3
  im[a1] = i1 + t3
  let t4 = t2 - t6
  let t6n = t2 + t6
  re[a3] = r1 - t4
  re[a1] = r1 + t4
  im[a2] = i0 - t6n
  im[a0] = i0 + t6n
}

///|
/// `TRANSFORM(a0, a1, a2, a3, wre, wim)`. */
fn Ac3Fft::transform(
  self : Ac3Fft,
  a0 : Int32,
  a1 : Int32,
  a2 : Int32,
  a3 : Int32,
  wre : Int32,
  wim : Int32,
) -> Unit {
  let re = self.re
  let im = self.im
  let (t1, t2) = ac3_tx_cmul_v(re[a2], im[a2], wre, -wim)
  let (t5, t6) = ac3_tx_cmul_v(re[a3], im[a3], wre, wim)
  self.butterflies(a0, a1, a2, a3, t1, t2, t5, t6)
}

///|
/// `fft4_ns` at base offset `o`. */
fn Ac3Fft::fft4(self : Ac3Fft, o : Int32) -> Unit {
  let re = self.re
  let im = self.im
  let t3 = re[o] - re[o + 1]
  let t1 = re[o] + re[o + 1]
  let t8 = re[o + 3] - re[o + 2]
  let t6 = re[o + 3] + re[o + 2]
  let d2re = t1 - t6
  let d0re = t1 + t6
  let t4 = im[o] - im[o + 1]
  let t2 = im[o] + im[o + 1]
  let t7 = im[o + 2] - im[o + 3]
  let t5 = im[o + 2] + im[o + 3]
  let d3im = t4 - t8
  let d1im = t4 + t8
  let d3re = t3 - t7
  let d1re = t3 + t7
  let d2im = t2 - t5
  let d0im = t2 + t5
  re[o + 2] = d2re
  re[o] = d0re
  im[o + 3] = d3im
  im[o + 1] = d1im
  re[o + 3] = d3re
  re[o + 1] = d1re
  im[o + 2] = d2im
  im[o] = d0im
}

///|
/// `fft8_ns` at base offset `o`. */
fn Ac3Fft::fft8(self : Ac3Fft, o : Int32) -> Unit {
  let re = self.re
  let im = self.im
  let cos = self.tab[self.tab8_off + 1]
  self.fft4(o)
  // BF(t1, dst[5].re, src[4].re, -src[5].re): t1 = src4 - (-src5), dst5 = src4 + (-src5)
  let t1 = re[o + 4] + re[o + 5]
  let t2 = im[o + 4] + im[o + 5]
  let t5 = re[o + 6] + re[o + 7]
  let t6 = im[o + 6] + im[o + 7]
  re[o + 5] = re[o + 4] - re[o + 5]
  im[o + 5] = im[o + 4] - im[o + 5]
  re[o + 7] = re[o + 6] - re[o + 7]
  im[o + 7] = im[o + 6] - im[o + 7]
  self.butterflies(o, o + 2, o + 4, o + 6, t1, t2, t5, t6)
  self.transform(o + 1, o + 3, o + 5, o + 7, cos, cos)
}

///|
/// `fft16_ns` at base offset `o`. */
fn Ac3Fft::fft16(self : Ac3Fft, o : Int32) -> Unit {
  let re = self.re
  let im = self.im
  let co = self.tab16_off
  self.fft8(o)
  self.fft4(o + 8)
  self.fft4(o + 12)
  let t1 = re[o + 8]
  let t2 = im[o + 8]
  let t5 = re[o + 12]
  let t6 = im[o + 12]
  self.butterflies(o, o + 4, o + 8, o + 12, t1, t2, t5, t6)
  self.transform(
    o + 2,
    o + 6,
    o + 10,
    o + 14,
    self.tab[co + 2],
    self.tab[co + 2],
  )
  self.transform(
    o + 1,
    o + 5,
    o + 9,
    o + 13,
    self.tab[co + 1],
    self.tab[co + 3],
  )
  self.transform(
    o + 3,
    o + 7,
    o + 11,
    o + 15,
    self.tab[co + 3],
    self.tab[co + 1],
  )
}

///|
/// `fft_sr_combine(z, cos, len)` at base offset `zo`, table offset `co`.
/// C: `for (i = 0; i < len; i += 4)` with `z += 8` per iteration — len/4
/// iterations covering z[0..2*len-1]. Our loop counter steps by 8, so the
/// bound is 2*len, not len (with len it would only write the first half,
/// which happens to be harmless for len=4 but breaks fft64/fft128). */
fn Ac3Fft::combine(self : Ac3Fft, zo : Int32, co : Int32, len : Int32) -> Unit {
  let o1 = 2 * len
  let o2 = 4 * len
  let o3 = 6 * len
  let tab = self.tab
  let mut w = co + o1 - 7
  let mut c = co
  let mut i = 0
  while i < 2 * len {
    self.transform(
      zo + i,
      zo + o1 + i,
      zo + o2 + i,
      zo + o3 + i,
      tab[c],
      tab[w + 7],
    )
    self.transform(
      zo + i + 2,
      zo + o1 + i + 2,
      zo + o2 + i + 2,
      zo + o3 + i + 2,
      tab[c + 2],
      tab[w + 5],
    )
    self.transform(
      zo + i + 4,
      zo + o1 + i + 4,
      zo + o2 + i + 4,
      zo + o3 + i + 4,
      tab[c + 4],
      tab[w + 3],
    )
    self.transform(
      zo + i + 6,
      zo + o1 + i + 6,
      zo + o2 + i + 6,
      zo + o3 + i + 6,
      tab[c + 6],
      tab[w + 1],
    )
    self.transform(
      zo + i + 1,
      zo + o1 + i + 1,
      zo + o2 + i + 1,
      zo + o3 + i + 1,
      tab[c + 1],
      tab[w + 6],
    )
    self.transform(
      zo + i + 3,
      zo + o1 + i + 3,
      zo + o2 + i + 3,
      zo + o3 + i + 3,
      tab[c + 3],
      tab[w + 4],
    )
    self.transform(
      zo + i + 5,
      zo + o1 + i + 5,
      zo + o2 + i + 5,
      zo + o3 + i + 5,
      tab[c + 5],
      tab[w + 2],
    )
    self.transform(
      zo + i + 7,
      zo + o1 + i + 7,
      zo + o2 + i + 7,
      zo + o3 + i + 7,
      tab[c + 7],
      tab[w],
    )
    i += 8
    c += 8
    w -= 8
  }
}

///|
/// `fft32_ns` at base offset `o`. */
fn Ac3Fft::fft32(self : Ac3Fft, o : Int32) -> Unit {
  self.fft16(o)
  self.fft8(o + 16)
  self.fft8(o + 24)
  self.combine(o, self.tab32_off, 4)
}

///|
/// `fft64_ns` at base offset `o`. */
fn Ac3Fft::fft64(self : Ac3Fft, o : Int32) -> Unit {
  self.fft32(o)
  self.fft16(o + 32)
  self.fft16(o + 48)
  self.combine(o, self.tab64_off, 8)
}

///|
/// `fft128_ns` (in-place over the whole 128-point array). */
fn Ac3Fft::fft128(self : Ac3Fft) -> Unit {
  self.fft64(0)
  self.fft32(64)
  self.fft32(96)
  self.combine(0, self.tab128_off, 16)
}

///|
/// `ff_tx_mdct_fwd` for len=256: 512 windowed samples in, 256 coefficients
/// out. Includes the folding/pre-reindexing (sub_map = the fft128 preshuffle
/// map, SCATTER direction) and the post-twiddle pair stage. */
priv struct Ac3Mdct {
  fft : Ac3Fft
  exp : FixedArray[(Int32, Int32)]
  map : FixedArray[Int32]
}

///|
fn Ac3Mdct::new() -> Ac3Mdct {
  { fft: Ac3Fft::new(128), exp: ac3_tx_mdct_exp(), map: ac3_tx_fft128_map(), }
}

///|
/// Run the forward MDCT: `src` holds 512 windowed samples, `dst` receives
/// 256 int32 coefficients. */
fn Ac3Mdct::run(
  self : Ac3Mdct,
  dst : FixedArray[Int32],
  src : FixedArray[Int32],
) -> Unit {
  let fft = self.fft
  let re = fft.re
  let im = fft.im
  // Folding and pre-reindexing
  for i = 0; i < 128; i = i + 1 {
    let k = 2 * i
    let idx = self.map[i]
    let tre = if k < 128 {
      ac3_tx_fold(-src[128 + k], src[127 - k])
    } else {
      ac3_tx_fold(-src[128 + k], -src[639 - k])
    }
    let tim = if k < 128 {
      ac3_tx_fold(-src[384 + k], -src[383 - k])
    } else {
      ac3_tx_fold(src[k - 128], -src[383 - k])
    }
    let (dre, dim) = ac3_tx_cmul_v(tre, tim, self.exp[i].0, self.exp[i].1)
    // CMUL(z[idx].im, z[idx].re, tmp.re, tmp.im, exp[i].re, exp[i].im)
    im[idx] = dre
    re[idx] = dim
  }
  fft.fft128()
  // Post-twiddle
  let exp = self.exp
  for i = 0; i < 64; i = i + 1 {
    let i0 = 64 + i
    let i1 = 64 - i - 1
    let s1re = re[i1]
    let s1im = im[i1]
    let s0re = re[i0]
    let s0im = im[i0]
    // CMUL(dst[2*i1 + 1], dst[2*i0], src0.re, src0.im, exp[i0].im, exp[i0].re)
    let (d0re, d0im) = ac3_tx_cmul_v(s0re, s0im, exp[i0].1, exp[i0].0)
    dst[2 * i1 + 1] = d0re
    dst[2 * i0] = d0im
    // CMUL(dst[2*i0 + 1], dst[2*i1], src1.re, src1.im, exp[i1].im, exp[i1].re)
    let (d1re, d1im) = ac3_tx_cmul_v(s1re, s1im, exp[i1].1, exp[i1].0)
    dst[2 * i0 + 1] = d1re
    dst[2 * i1] = d1im
  }
}
