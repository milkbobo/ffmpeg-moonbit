///|
/// AV1 multi-symbol arithmetic ENCODER — the write-side twin of
/// `av1_msac.mbt` (the dav1d decoder port). The stream convention is
/// daala's od_ec: the decoder refills `dif` with INVERTED bytes, so the
/// encoder emits the byte image of its `low` accumulator under a
/// one's-complement mapping, and the decoder's `dif >= vw` test selects
/// the upper subinterval (bit 0). Everything here mirrors the decoder's
/// arithmetic so the two stay in lockstep:
///
/// - `encode_bool`/`encode_bool_equi` use the decoder's split
///   `v = (((rng >> 8) * (f >> 6)) >> 1) + 4` — bit 1 takes `[0, v)`,
///   bit 0 takes `[v, rng)` and adds `v` to `low`.
/// - `encode_symbol_adapt` uses the decoder's cumulative bound
///   `F(i) = ((r >> 8) * (cdf[i] >> 6)) >> 1 + 4 * (n - i)` with
///   `F(-1) = rng`: symbol `s` codes on `[F(s), F(s-1))`.
/// - the CDF adaptation is line-for-line the decoder's update (the two
///   must produce identical CDF trajectories).
///
/// `precarry` is the carry-propagation buffer of od_ec_enc: bytes wait
/// there while a carry out of `low` can still change them; `done()`
/// flushes with the shortest unambiguous tail and emits the inverted
/// bytes the decoder refills from.
pub struct Av1MsacEnc {
  /// Selected bytes not yet safe to emit (carry may still bump them).
  precarry : Array[Int32]
  /// low end of the arithmetic interval (17 meaningful bits: 16 window +
  /// 1 carry observation).
  mut low : UInt32
  mut rng : UInt32
  /// Bits since the last carry-out; reaches 8 to emit a byte.
  mut cnt : Int32
  /// CDF adaptation on/off (mirrors the decoder's allow_update_cdf).
  allow_update_cdf : Bool
}

///|
/// `od_ec_enc_init`.
pub fn Av1MsacEnc::init(disable_cdf_update_flag : Bool) -> Av1MsacEnc {
  {
    precarry: [],
    low: 0,
    rng: 0x8000,
    cnt: -9,
    allow_update_cdf: !disable_cdf_update_flag,
  }
}

///|
/// `od_ec_enc_carry_out`: push one byte into the precarry buffer. The
/// caller passes the 9-bit window top `c = low >> (cnt + 16)`; the
/// stored delta `c - 0xFF` is 0 (byte), +1 (carry), or -1 (borrow).
fn Av1MsacEnc::carry_out(self : Av1MsacEnc, c : Int32) -> Unit {
  if c >= 0x100 {
    let mut n = self.precarry.length() - 1
    while n >= 0 && self.precarry[n] == 0xFF {
      self.precarry[n] = 0
      n = n - 1
    }
    if n >= 0 {
      self.precarry[n] = self.precarry[n] + 1
    }
  }
  self.precarry.push(c & 0xFF)
}

///|
/// `od_ec_enc_normalize`: double the interval until `rng >= 32768`,
/// shifting `low`; every 8 shifts emit a byte (the 17th bit is carry).
fn Av1MsacEnc::renormalize(self : Av1MsacEnc) -> Unit {
  let mut c = self.cnt
  while self.rng < 0x8000 {
    self.rng = self.rng << 1
    self.low = self.low << 1
    c = c + 1
    if c == 0 {
      self.carry_out((self.low >> 16).reinterpret_as_int())
      self.low = self.low & 0xFFFF
      c = -8
    }
  }
  self.cnt = c
}

///|
pub fn Av1MsacEnc::encode_bool_equi(self : Av1MsacEnc, bit : UInt32) -> Unit {
  let r = self.rng
  let v = (r >> 8 << 7) + 4
  if bit != 0 {
    self.rng = v
  } else {
    self.low = self.low + v
    self.rng = r - v
  }
  self.renormalize()
}

///|
/// `dav1d_msac_decode_bool`'s writer: bool with probability `f` (Q15).
pub fn Av1MsacEnc::encode_bool(
  self : Av1MsacEnc,
  f : UInt32,
  bit : UInt32,
) -> Unit {
  let r = self.rng
  let v = (((r >> 8) * (f >> 6)) >> 1) + 4
  if bit != 0 {
    self.rng = v
  } else {
    self.low = self.low + v
    self.rng = r - v
  }
  self.renormalize()
}

///|
/// `dav1d_msac_decode_symbol_adapt`'s writer: symbol `s` of
/// `0..n_symbols-1` on the Q15 CDF at `cdf_base` (`n_symbols + 1` slots,
/// last = count), updating the CDF exactly like the decoder.
pub fn Av1MsacEnc::encode_symbol_adapt(
  self : Av1MsacEnc,
  cdf : FixedArray[UInt16],
  cdf_base : Int32,
  n_symbols : Int32,
  s : Int32,
) -> Unit {
  let r = self.rng >> 8
  let n_u = n_symbols.reinterpret_as_uint()
  // F(i) = ((r * (cdf[i] >> 6)) >> 1) + 4 * (n - i); F(-1) = rng.
  let f_of = fn(i : Int32) -> UInt32 {
    if i < 0 {
      self.rng
    } else {
      ((r * (cdf[cdf_base + i].to_uint() >> 6)) >> 1) +
      4 * (if i <= n_symbols { n_u - i.reinterpret_as_uint() } else { 0U })
    }
  }
  let v = f_of(s)
  let u = f_of(s - 1)
  self.low = self.low + v
  self.rng = u - v
  self.renormalize()
  if self.allow_update_cdf {
    let count = cdf[cdf_base + n_symbols].to_uint()
    let rate = 4 +
      (count >> 4).reinterpret_as_int() +
      (if n_symbols > 2 { 1 } else { 0 })
    let mut i = 0
    while i < s {
      let x = cdf[cdf_base + i].to_uint()
      cdf[cdf_base + i] = (x + ((32768 - x) >> rate)).to_uint16()
      i = i + 1
    }
    while i < n_symbols {
      let x = cdf[cdf_base + i].to_uint()
      cdf[cdf_base + i] = (x - (x >> rate)).to_uint16()
      i = i + 1
    }
    cdf[cdf_base + n_symbols] = (count + (if count < 32 { 1 } else { 0 })).to_uint16()
  }
}

///|
/// `dav1d_msac_decode_bool_adapt`'s writer: bool on the 2-slot CDF
/// `[prob, count]`, updating like the decoder.
pub fn Av1MsacEnc::encode_bool_adapt(
  self : Av1MsacEnc,
  cdf : FixedArray[UInt16],
  cdf_base : Int32,
  bit : UInt32,
) -> Unit {
  self.encode_bool(cdf[cdf_base].to_uint(), bit)
  if self.allow_update_cdf {
    let count = cdf[cdf_base + 1].to_uint()
    let rate = 4 + (count >> 4).reinterpret_as_int()
    if bit != 0 {
      let x = cdf[cdf_base].to_uint()
      cdf[cdf_base] = (x + ((32768 - x) >> rate)).to_uint16()
    } else {
      let x = cdf[cdf_base].to_uint()
      cdf[cdf_base] = (x - (x >> rate)).to_uint16()
    }
    cdf[cdf_base + 1] = (count + (if count < 32 { 1 } else { 0 })).to_uint16()
  }
}

///|
/// `dav1d_msac_decode_bools`'s writer: `n` raw bits MSB-first at 1/2.
pub fn Av1MsacEnc::encode_bools(
  self : Av1MsacEnc,
  n : Int32,
  v : UInt32,
) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.encode_bool_equi((v >> i) & 1U)
  }
}

///|
/// `dav1d_msac_decode_uniform`'s writer: uniform value in 0..n-1 (n > 1),
/// the same short-code shape as the decoder.
pub fn Av1MsacEnc::encode_uniform(
  self : Av1MsacEnc,
  n : UInt32,
  v : UInt32,
) -> Unit {
  let l = av1_ulog2(n) + 1
  let m = (1U << l) - n
  if v < m {
    self.encode_bools(l - 1, v)
  } else {
    self.encode_bools(l - 1, (v + m) >> 1)
    self.encode_bool_equi((v + m) & 1U)
  }
}

///|
/// `dav1d_msac_decode_hi_tok`'s writer: token `tok` in 3..15 as up to
/// four nested 3-symbol CDF decisions. The escape symbol is `3` — the
/// decoder's `decode_symbol_adapt` can legally return `n_symbols`
/// (the arithmetic tail beyond the last CDF bound, where the count
/// slot's F collapses to 0), and `encode_symbol_adapt` codes it by the
/// same rule. `tok == 15` is itself the escape out of the fourth
/// decision — the golomb extension follows separately in the sign walk.
pub fn Av1MsacEnc::encode_hi_tok(
  self : Av1MsacEnc,
  cdf : FixedArray[UInt16],
  cdf_base : Int32,
  tok : Int32,
) -> Unit {
  fn sym(s : Int32) -> Unit {
    self.encode_symbol_adapt(cdf, cdf_base, 3, s)
  }
  if tok <= 5 {
    sym(tok - 3)
  } else if tok <= 8 {
    sym(3)
    sym(tok - 6)
  } else if tok <= 11 {
    sym(3)
    sym(3)
    sym(tok - 9)
  } else if tok <= 14 {
    sym(3)
    sym(3)
    sym(3)
    sym(tok - 12)
  } else {
    sym(3)
    sym(3)
    sym(3)
    sym(3)
  }
}

///|
/// `read_golomb`'s writer: value `v` >= 0 codes as `val = v + 1` in
/// unary-prefixed binary — `len` zero bools, the terminating one, then
/// the `len` bits below the leading one of `val` (MSB first), all at
/// probability 1/2.
pub fn Av1MsacEnc::encode_golomb(self : Av1MsacEnc, v : Int32) -> Unit {
  let val = v + 1
  let len = av1_ulog2(val.reinterpret_as_uint())
  for _i in 0..<len {
    self.encode_bool_equi(0U)
  }
  self.encode_bool_equi(1U)
  self.encode_bools(len, (val - (1 << len)).reinterpret_as_uint())
}

///|
/// `od_ec_enc_done`: close the interval and emit the tile's entropy
/// bytes. The full-precision formulation (§438a's calibration choice):
/// pick the interval's upper endpoint, flush it through the carry chain
/// down to its last set bit, and let the decoder's end-of-buffer refill
/// supply the remaining low ONE bits — `dif`'s tail-of-buffer fill is
/// all ones, which is the one's-complement image of zeros, exactly the
/// endpoint's zero tail. The shortest-prefix termination of od_ec (a few
/// bytes less per tile) is a later optimization slice; this one only
/// needs the interval arithmetic to be right.
pub fn Av1MsacEnc::done(self : Av1MsacEnc) -> Bytes {
  // `cnt` in (-8..0]: bits still needed to complete the pending byte.
  // Shift the window so the endpoint lands byte-aligned, then carry out
  // every remaining byte (the 17th bit propagates as a carry, which is
  // what `carry_out` is for).
  let s = -self.cnt
  // Upper endpoint of the interval, low `s` bits zero. The window is 17
  // bits shifted by s < 8: up to 25 bits, i.e. four bytes — emitted in
  // full (zero bytes included; a `while v != 0` loop would drop a
  // trailing 0x00 and shorten the stream under long tiles).
  let mut v = (self.low + self.rng - 1) << s
  for _i in 0..<8 {
    // Emit the top byte (0..0x1FF; >= 0x100 is a carry into the chain).
    // Zero bytes past the endpoint are harmless padding: the decoder's
    // end-of-buffer refill substitutes ONE bits, which keep `dif` inside
    // the coded interval's upper half and decode the same symbols.
    self.carry_out(((v >> 16) & 0x1FF).reinterpret_as_int())
    v = (v & 0xFFFF) << 8
  }
  // Invert: the decoder refills dif with ~byte.
  let out : Array[Byte] = []
  for b in self.precarry {
    out.push((b ^ 0xFF).to_byte())
  }
  Bytes::from_array(out[:])
}
