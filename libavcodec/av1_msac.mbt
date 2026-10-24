///|
/// MoonBit port of dav1d 1.5.1 `src/msac.c` / `src/msac.h`: the AV1
/// multi-symbol arithmetic decoder (same coder as the AV1 spec's symbol
/// decoder). FFmpeg's own tree has no software AV1 pixel decoder (av1dec.c
/// defers to libdav1d), so dav1d — the decoder FFmpeg integrates — is the
/// upstream reference for this file and the AV1 pixel pipeline that follows.
///
/// dav1d is BSD-2-Clause (Copyright © 2018, VideoLAN and dav1d authors,
/// Copyright © 2018, Two Orioles, LLC); this port keeps the same algorithm
/// with LGPL-2.1-or-later packaging consistent with the rest of the module.

///|
/// One arithmetic-decoder state over a tile's entropy payload. `dif` keeps
/// 64 bits like dav1d's `ec_win` (`size_t`); `cnt` may go negative before
/// the first refill exactly as upstream.
pub struct Av1Msac {
  data : Bytes
  /// Next unread byte (like `buf_pos`).
  mut pos : Int
  mut dif : UInt64
  mut rng : UInt
  mut cnt : Int
  /// `allow_update_cdf` in dav1d (set once at init).
  allow_update_cdf : Bool
}

///|
/// `EC_WIN_SIZE` is 64 (bits of `dif`).
let av1_ec_win_size : Int = 64

///|
/// `clz` for nonzero UInt (dav1d common/intops.h `clz`).
fn av1_clz(v : UInt) -> Int {
  let mut n = 0
  let mut x = v
  while (x >> 31) == 0 {
    n = n + 1
    x = x << 1
  }
  n
}

///|
/// `ctx_refill`: top up `dif` with inverted bytes until `cnt >= 24`.
fn Av1Msac::refill(self : Av1Msac) -> Unit {
  let mut c = av1_ec_win_size - self.cnt - 24
  let mut dif = self.dif
  while true {
    if self.pos >= self.data.length() {
      // Out of data: dif |= ~(~(ec_win)0xff << c) — set the low c+8 bits.
      dif = dif | ((0xFFFFFFFFFFFFFF00 : UInt64) << c).lnot()
      break
    }
    let b = (self.data[self.pos].to_uint() ^ 0xFF).to_uint64()
    self.pos = self.pos + 1
    dif = dif | (b << c)
    c = c - 8
    if c < 0 {
      break
    }
  }
  self.dif = dif
  self.cnt = av1_ec_win_size - c - 24
}

///|
/// `ctx_norm`: renormalize so 32768 <= rng < 65536.
fn Av1Msac::norm(self : Av1Msac, dif : UInt64, rng : UInt) -> Unit {
  let d = 15 ^ (31 ^ av1_clz(rng))
  let cnt = self.cnt
  self.dif = dif << d
  self.rng = rng << d
  self.cnt = cnt - d
  // C compares (unsigned)cnt < (unsigned)d: a negative cnt (buffer-end
  // padding already applied) must not trigger a refill.
  if cnt >= 0 && cnt < d {
    self.refill()
  }
}

///|
/// `dav1d_msac_init`.
pub fn Av1Msac::init(
  data : Bytes,
  disable_cdf_update_flag : Bool,
) -> Av1Msac {
  let s : Av1Msac = {
    data,
    pos: 0,
    dif: 0,
    rng: 0x8000,
    cnt: -15,
    allow_update_cdf: !disable_cdf_update_flag,
  }
  s.refill()
  s
}

///|
/// `dav1d_msac_decode_bool_equi`: bool with probability 1/2.
pub fn Av1Msac::decode_bool_equi(self : Av1Msac) -> UInt {
  let r = self.rng
  let mut dif = self.dif
  let mut v = ((r >> 8) << 7) + 4
  let vw = v.to_uint64() << (av1_ec_win_size - 16)
  let ret : UInt = if dif >= vw { 1 } else { 0 }
  if ret != 0 {
    dif = dif - vw
    v = v + (r - 2 * v)
  }
  self.norm(dif, v)
  1 - ret
}

///|
/// `dav1d_msac_decode_bool`: bool with probability `f` (Q15).
pub fn Av1Msac::decode_bool(self : Av1Msac, f : UInt) -> UInt {
  let r = self.rng
  let mut dif = self.dif
  let mut v = (((r >> 8) * (f >> 6)) >> 1) + 4
  let vw = v.to_uint64() << (av1_ec_win_size - 16)
  let ret : UInt = if dif >= vw { 1 } else { 0 }
  if ret != 0 {
    dif = dif - vw
    v = v + (r - 2 * v)
  }
  self.norm(dif, v)
  1 - ret
}

///|
/// `dav1d_msac_decode_symbol_adapt`: symbol from (and possibly update) a
/// Q15 CDF. `cdf_base` indexes `n_symbols + 1` slots (last = count).
/// Returns the symbol in 0..n_symbols-1.
pub fn Av1Msac::decode_symbol_adapt(
  self : Av1Msac,
  cdf : FixedArray[UInt16],
  cdf_base : Int,
  n_symbols : Int,
) -> Int {
  let c : UInt = (self.dif >> (av1_ec_win_size - 16)).to_uint()
  let r = self.rng >> 8
  let n_u = n_symbols.reinterpret_as_uint()
  let mut u : UInt = 0
  let mut v : UInt = self.rng
  let mut val = 0
  while true {
    u = v
    v = (r * (cdf[cdf_base + val].to_uint() >> 6)) >> 1
    v = v + 4 * (n_u - val.reinterpret_as_uint())
    if c >= v {
      break
    }
    val = val + 1
  }
  self.norm(
    self.dif - (v.to_uint64() << (av1_ec_win_size - 16)),
    u - v,
  )
  if self.allow_update_cdf {
    let count = cdf[cdf_base + n_symbols].to_uint()
    let rate = 4 +
      (count >> 4).reinterpret_as_int() +
      (if n_symbols > 2 { 1 } else { 0 })
    let mut i = 0
    while i < val {
      let x = cdf[cdf_base + i].to_uint()
      cdf[cdf_base + i] = (x + ((32768 - x) >> rate)).to_uint16()
      i = i + 1
    }
    while i < n_symbols {
      let x = cdf[cdf_base + i].to_uint()
      cdf[cdf_base + i] = (x - (x >> rate)).to_uint16()
      i = i + 1
    }
    cdf[cdf_base + n_symbols] = (count +
        (if count < 32 { 1 } else { 0 })).to_uint16()
  }
  val
}

///|
/// `dav1d_msac_decode_bool_adapt`: bool from (and possibly update) a
/// 2-slot CDF ([prob, count]).
pub fn Av1Msac::decode_bool_adapt(
  self : Av1Msac,
  cdf : FixedArray[UInt16],
  cdf_base : Int,
) -> UInt {
  let bit = self.decode_bool(cdf[cdf_base].to_uint())
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
    cdf[cdf_base + 1] = (count +
        (if count < 32 { 1 } else { 0 })).to_uint16()
  }
  bit
}

///|
/// `dav1d_msac_decode_bools`: `n` raw bits MSB-first at probability 1/2.
pub fn Av1Msac::decode_bools(self : Av1Msac, n : Int) -> UInt {
  let mut v : UInt = 0
  for _ in 0..<n {
    v = (v << 1) | self.decode_bool_equi()
  }
  v
}

///|
/// `ulog2` as in dav1d common/intops.h.
fn av1_ulog2(v : UInt) -> Int {
  31 - av1_clz(v)
}

///|
/// `dav1d_msac_decode_uniform`: uniform value in 0..n-1 (n > 1).
pub fn Av1Msac::decode_uniform(self : Av1Msac, n : UInt) -> Int {
  let l = av1_ulog2(n) + 1
  let m = (1U << l) - n
  let v = self.decode_bools(l - 1)
  if v < m {
    v.reinterpret_as_int()
  } else {
    ((v << 1) - m + self.decode_bool_equi()).reinterpret_as_int()
  }
}

///|
/// `inv_recenter` from dav1d common/intops.h.
fn av1_inv_recenter(r : UInt, v : UInt) -> UInt {
  if v > (r << 1) {
    v
  } else if (v & 1) == 0 {
    (v >> 1) + r
  } else {
    r - ((v + 1) >> 1)
  }
}

///|
/// `dav1d_msac_decode_subexp` (palette-delta path).
pub fn Av1Msac::decode_subexp(
  self : Av1Msac,
  ref_val : Int,
  n : Int,
  k : UInt,
) -> Int {
  let mut k = k
  let mut a : UInt = 0
  if self.decode_bool_equi() != 0 {
    if self.decode_bool_equi() != 0 {
      k = k + self.decode_bool_equi() + 1
    }
    a = 1U << k.reinterpret_as_int()
  }
  let v = self.decode_bools(k.reinterpret_as_int()) + a
  if ref_val * 2 <= n {
    av1_inv_recenter(ref_val.reinterpret_as_uint(), v).reinterpret_as_int()
  } else {
    n - 1 -
    av1_inv_recenter((n - 1 - ref_val).reinterpret_as_uint(), v).reinterpret_as_int()
  }
}

///|
/// `dav1d_msac_decode_hi_tok`: high token for br coefficient coding.
pub fn Av1Msac::decode_hi_tok(
  self : Av1Msac,
  cdf : FixedArray[UInt16],
  cdf_base : Int,
) -> Int {
  let mut tok_br = self.decode_symbol_adapt(cdf, cdf_base, 3)
  let mut tok = 3 + tok_br
  if tok_br == 3 {
    tok_br = self.decode_symbol_adapt(cdf, cdf_base, 3)
    tok = 6 + tok_br
    if tok_br == 3 {
      tok_br = self.decode_symbol_adapt(cdf, cdf_base, 3)
      tok = 9 + tok_br
      if tok_br == 3 {
        tok = 12 + self.decode_symbol_adapt(cdf, cdf_base, 3)
      }
    }
  }
  tok
}
