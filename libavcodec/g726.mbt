///|
/// G.726 ADPCM decoder, ported from FFmpeg 9.0.2 `libavcodec/g726.c`.
///
/// Supports 16/24/32/40 kbit/s (2-5 bits per sample, MSB-first packing) and
/// keeps the adaptive predictor/quantizer state across packets, like the C.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// G.726's 11-bit float (`Float11`).
pub struct G726Float11 {
  mut sign : Int32
  exp : Int32
  mut mant : Int32
}

///|
fn g726_float11_new() -> G726Float11 {
  { sign: 0, exp: 0, mant: 0, }
}

///|
/// `quant_tbl16`.
let g726_quant16 : FixedArray[Int32] = [260, 2147483647]

///|
/// `iquant_tbl16`.
let g726_iquant16 : FixedArray[Int32] = [116, 365, 365, 116]

///|
/// `W_tbl16`.
let g726_w16 : FixedArray[Int32] = [-22, 439, 439, -22]

///|
/// `F_tbl16`.
let g726_f16 : FixedArray[Int32] = [0, 7, 7, 0]

///|
/// `quant_tbl24`.
let g726_quant24 : FixedArray[Int32] = [7, 217, 330, 2147483647]

///|
/// `iquant_tbl24`.
let g726_iquant24 : FixedArray[Int32] = [
  -32768, 135, 273, 373, 373, 273, 135, -32768,
]

///|
/// `W_tbl24`.
let g726_w24 : FixedArray[Int32] = [-4, 30, 137, 582, 582, 137, 30, -4]

///|
/// `F_tbl24`.
let g726_f24 : FixedArray[Int32] = [0, 1, 2, 7, 7, 2, 1, 0]

///|
/// `quant_tbl32`.
let g726_quant32 : FixedArray[Int32] = [
  -125, 79, 177, 245, 299, 348, 399, 2147483647,
]

///|
/// `iquant_tbl32`.
let g726_iquant32 : FixedArray[Int32] = [
  -32768, 4, 135, 213, 273, 323, 373, 425, 425, 373, 323, 273, 213, 135, 4, -32768,
]

///|
/// `W_tbl32`.
let g726_w32 : FixedArray[Int32] = [
  -12, 18, 41, 64, 112, 198, 355, 1122, 1122, 355, 198, 112, 64, 41, 18, -12,
]

///|
/// `F_tbl32`.
let g726_f32 : FixedArray[Int32] = [
  0, 0, 0, 1, 1, 1, 3, 7, 7, 3, 1, 1, 1, 0, 0, 0,
]

///|
/// `quant_tbl40`.
let g726_quant40 : FixedArray[Int32] = [
  -122, -16, 67, 138, 197, 249, 297, 338, 377, 412, 444, 474, 501, 527, 552, 2147483647,
]

///|
/// `iquant_tbl40`.
let g726_iquant40 : FixedArray[Int32] = [
  -32768, -66, 28, 104, 169, 224, 274, 318, 358, 395, 429, 459, 488, 514, 539, 566,
  566, 539, 514, 488, 459, 429, 395, 358, 318, 274, 224, 169, 104, 28, -66, -32768,
]

///|
/// `W_tbl40`.
let g726_w40 : FixedArray[Int32] = [
  14, 14, 24, 39, 40, 41, 58, 100, 141, 179, 219, 280, 358, 440, 529, 696, 696, 529,
  440, 358, 280, 219, 179, 141, 100, 58, 41, 40, 39, 24, 14, 14,
]

///|
/// `F_tbl40`.
let g726_f40 : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 6, 6, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1,
  0, 0, 0, 0, 0,
]

///|
fn g726_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn g726_sign16(v : Int32) -> Int32 {
  if v >= 0x8000 {
    v - 0x10000
  } else if v < -0x8000 {
    v + 0x10000
  } else {
    v
  }
}

///|
fn g726_clip_intp2(v : Int32, bits : Int32) -> Int32 {
  let limit = 1 << bits
  g726_clip(v, -limit, limit - 1)
}

///|
fn g726_log2_16bit(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
fn g726_sgn(v : Int32) -> Int32 {
  if v < 0 {
    -1
  } else {
    1
  }
}

///|
/// `i2f`.
fn g726_i2f(i : Int32) -> G726Float11 {
  let sign = if i < 0 { 1 } else { 0 }
  let a = if sign != 0 { -i } else { i }
  let exp = g726_log2_16bit(a) + (if a != 0 { 1 } else { 0 })
  let mant = if a != 0 { a << 6 >> exp } else { 1 << 5 }
  { sign, exp, mant, }
}

///|
/// `mult`: the C returns int16, so the result is truncated to 16 bits.
fn g726_mult(f1 : G726Float11, f2 : G726Float11) -> Int32 {
  let exp = f1.exp + f2.exp
  let res = (f1.mant * f2.mant + 0x30) >> 4
  let res = if exp > 19 { res << (exp - 19) } else { res >> (19 - exp) }
  g726_sign16(if (f1.sign ^ f2.sign) != 0 { -res } else { res })
}

///|
/// G.726 decoder with persistent predictor/quantizer state.
pub struct G726Decoder {
  code_size : Int32
  little_endian : Bool
  iquant : FixedArray[Int32]
  quant : FixedArray[Int32]
  w : FixedArray[Int32]
  f : FixedArray[Int32]
  sr : Array[G726Float11]
  dq : Array[G726Float11]
  a : FixedArray[Int32]
  b : FixedArray[Int32]
  pk : FixedArray[Int32]
  mut ap : Int32
  mut yu : Int32
  mut yl : Int32
  mut dms : Int32
  mut dml : Int32
  mut td : Int32
  mut se : Int32
  mut sez : Int32
  mut y : Int32
}

///|
/// Create a decoder for `code_size` bits per sample (2/3/4/5, i.e.
/// 16/24/32/40 kbit/s at 8 kHz).
pub fn g726_decoder_new(
  code_size : Int32,
  little_endian~ : Bool = false,
) -> Result[G726Decoder, String] {
  if code_size < 2 || code_size > 5 {
    return Err("g726: invalid code size")
  }
  let (quant, iquant, w, f) = if code_size == 2 {
    (g726_quant16, g726_iquant16, g726_w16, g726_f16)
  } else if code_size == 3 {
    (g726_quant24, g726_iquant24, g726_w24, g726_f24)
  } else if code_size == 4 {
    (g726_quant32, g726_iquant32, g726_w32, g726_f32)
  } else {
    (g726_quant40, g726_iquant40, g726_w40, g726_f40)
  }
  let sr : Array[G726Float11] = []
  let dq : Array[G726Float11] = []
  for _ in 0..<2 {
    sr.push(g726_float11_new())
  }
  for _ in 0..<6 {
    dq.push(g726_float11_new())
  }
  for i = 0; i < 2; i = i + 1 {
    sr[i].mant = 1 << 5
  }
  for i = 0; i < 6; i = i + 1 {
    dq[i].mant = 1 << 5
  }
  Ok({
    code_size,
    little_endian,
    iquant,
    quant,
    w,
    f,
    sr,
    dq,
    a: FixedArray::make(2, 0),
    b: FixedArray::make(6, 0),
    pk: FixedArray::make(2, 1),
    ap: 0,
    yu: 544,
    yl: 34816,
    dms: 0,
    dml: 0,
    td: 0,
    se: 0,
    sez: 0,
    y: 544,
  })
}

///|
/// `inverse_quant`.
fn G726Decoder::inverse_quant(self : G726Decoder, i : Int32) -> Int32 {
  let dql = self.iquant[i] + (self.y >> 2)
  let dex = (dql >> 7) & 0xF
  let dqt = (1 << 7) + (dql & 0x7F)
  if dql < 0 {
    0
  } else {
    dqt << dex >> 7
  }
}

///|
/// `g726_decode`: decode one codeword to a 16-bit sample.
fn G726Decoder::step(self : G726Decoder, code : Int32) -> Int32 {
  let i_sig = code >> (self.code_size - 1)
  let mut dq = self.inverse_quant(code)
  let ylint = self.yl >> 15
  let ylfrac = (self.yl >> 10) & 0x1F
  let thr2 = if ylint > 9 { 0x1F << 10 } else { (0x20 + ylfrac) << ylint }
  let tr = self.td == 1 && dq > (3 * thr2) >> 2
  if i_sig != 0 {
    dq = -dq
  }
  let re_signal = g726_sign16(self.se + dq)
  let pk0 = if self.sez + dq != 0 { g726_sgn(self.sez + dq) } else { 0 }
  let dq0 = if dq != 0 { g726_sgn(dq) } else { 0 }
  if tr {
    self.a[0] = 0
    self.a[1] = 0
    for i = 0; i < 6; i = i + 1 {
      self.b[i] = 0
    }
  } else {
    let fa1 = g726_clip_intp2((-self.a[0] * self.pk[0] * pk0) >> 5, 8)
    self.a[1] = self.a[1] + 128 * pk0 * self.pk[1] + fa1 - (self.a[1] >> 7)
    self.a[1] = g726_clip(self.a[1], -12288, 12288)
    self.a[0] = self.a[0] + 192 * pk0 * self.pk[0] - (self.a[0] >> 8)
    self.a[0] = g726_clip(self.a[0], -(15360 - self.a[1]), 15360 - self.a[1])
    for i = 0; i < 6; i = i + 1 {
      self.b[i] = self.b[i] +
        128 * dq0 * g726_sgn(-self.dq[i].sign) -
        (self.b[i] >> 8)
    }
  }
  self.pk[1] = self.pk[0]
  self.pk[0] = if pk0 != 0 { pk0 } else { 1 }
  self.sr[1] = self.sr[0]
  self.sr[0] = g726_i2f(re_signal)
  for i = 5; i > 0; i = i - 1 {
    self.dq[i] = self.dq[i - 1]
  }
  self.dq[0] = g726_i2f(dq)
  self.dq[0].sign = i_sig
  self.td = if self.a[1] < -11776 { 1 } else { 0 }
  self.dms = self.dms + (self.f[code] << 4) + (-self.dms >> 5)
  self.dml = self.dml + (self.f[code] << 4) + (-self.dml >> 7)
  if tr {
    self.ap = 256
  } else {
    self.ap = self.ap + (-self.ap >> 4)
    let diff = (self.dms << 2) - self.dml
    let abs_diff = if diff < 0 { -diff } else { diff }
    if self.y <= 1535 || self.td != 0 || abs_diff >= self.dml >> 3 {
      self.ap = self.ap + 0x20
    }
  }
  self.yu = g726_clip(self.y + self.w[code] + (-self.y >> 5), 544, 5120)
  self.yl = self.yl + self.yu + (-self.yl >> 6)
  let al = if self.ap >= 256 { 1 << 6 } else { self.ap >> 2 }
  self.y = (self.yl + (self.yu - (self.yl >> 6)) * al) >> 6
  self.se = 0
  for i = 0; i < 6; i = i + 1 {
    self.se = self.se + g726_mult(g726_i2f(self.b[i] >> 2), self.dq[i])
  }
  self.sez = self.se >> 1
  for i = 0; i < 2; i = i + 1 {
    self.se = self.se + g726_mult(g726_i2f(self.a[i] >> 2), self.sr[i])
  }
  self.se = self.se >> 1
  g726_sign16(g726_clip(re_signal * 4, -0xFFFF, 0xFFFF))
}

///|
/// Decode a packet of G.726 codewords. The default packing is MSB-first;
/// `little_endian` selects the `g726le`/AU layout (first bit is the LSB).
pub fn G726Decoder::decode(self : G726Decoder, data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  let total_bits = data.length() * 8
  let mut bitpos = 0
  while bitpos + self.code_size <= total_bits {
    let mut code = 0
    for i = 0; i < self.code_size; i = i + 1 {
      let bit = if self.little_endian {
        (data[bitpos / 8].to_int() >> (bitpos % 8)) & 1
      } else {
        (data[bitpos / 8].to_int() >> (7 - bitpos % 8)) & 1
      }
      if self.little_endian {
        code = code | (bit << i)
      } else {
        code = (code << 1) | bit
      }
      bitpos = bitpos + 1
    }
    out.push(self.step(code))
  }
  out
}
