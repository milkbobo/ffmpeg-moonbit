///|
/// WavPack lossless decoder, ported from FFmpeg 9.0.2 `libavcodec/wavpack.c`,
/// `wavpackdata.c` and the `wavpack.h` helpers.
///
/// `ff_wavpack_decode` parses a complete `.wv` file (concatenated `wvpk`
/// blocks) and returns interleaved PCM in FFmpeg's output form: S16 for
/// 16-bit streams and S32 (24-bit left-justified) for 24/32-bit streams.
///
/// Scope: lossless integer PCM, 1-2 channels, single-block packets, 16/24/32
/// bits per sample. Hybrid/lossy, float, DSD and multi-block (>2 channel)
/// streams are rejected. CRCs are not verified (like the other audio ports).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `ff_wp_exp2_table`.
let wavpack_exp2_table : FixedArray[Int32] = [
  0x00, 0x01, 0x01, 0x02, 0x03, 0x03, 0x04, 0x05, 0x06, 0x06, 0x07, 0x08, 0x08, 0x09,
  0x0a, 0x0b, 0x0b, 0x0c, 0x0d, 0x0e, 0x0e, 0x0f, 0x10, 0x10, 0x11, 0x12, 0x13, 0x13,
  0x14, 0x15, 0x16, 0x16, 0x17, 0x18, 0x19, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1d, 0x1e,
  0x1f, 0x20, 0x20, 0x21, 0x22, 0x23, 0x24, 0x24, 0x25, 0x26, 0x27, 0x28, 0x28, 0x29,
  0x2a, 0x2b, 0x2c, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
  0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41,
  0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
  0x4e, 0x4f, 0x50, 0x51, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,
  0x5b, 0x5c, 0x5d, 0x5e, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
  0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x82, 0x83,
  0x84, 0x85, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92,
  0x93, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9f, 0xa0, 0xa1, 0xa2,
  0xa3, 0xa4, 0xa5, 0xa6, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad, 0xaf, 0xb0, 0xb1, 0xb2,
  0xb3, 0xb4, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbc, 0xbd, 0xbe, 0xbf, 0xc0, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc8, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf, 0xd0, 0xd2, 0xd3, 0xd4,
  0xd6, 0xd7, 0xd8, 0xd9, 0xdb, 0xdc, 0xdd, 0xde, 0xe0, 0xe1, 0xe2, 0xe4, 0xe5, 0xe6,
  0xe8, 0xe9, 0xea, 0xec, 0xed, 0xee, 0xf0, 0xf1, 0xf2, 0xf4, 0xf5, 0xf6, 0xf8, 0xf9,
  0xfa, 0xfc, 0xfd, 0xff,
]

///|
/// `wv_rates`.
let wavpack_rates : FixedArray[Int32] = [
  6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000,
  88200, 96000, 192000, 0,
]

///|
/// `wp_exp2`.
fn wavpack_exp2(v : Int32) -> Int32 {
  let mut val = v
  let neg = val < 0
  if neg {
    val = -val
  }
  let mut res = wavpack_exp2_table[val & 0xFF] | 0x100
  val = val >> 8
  if val > 31 {
    return -2147483648
  }
  res = if val > 9 { res << (val - 9) } else { res >> (9 - val) }
  if neg {
    -res
  } else {
    res
  }
}

///|
fn wavpack_u32le(data : Bytes, off : Int32) -> UInt32 {
  data[off].to_uint() |
  (data[off + 1].to_uint() << 8) |
  (data[off + 2].to_uint() << 16) |
  (data[off + 3].to_uint() << 24)
}

///|
/// Little-endian `GetBitContext` (`BITSTREAM_READER_LE`): the first bit read
/// is the LSB of the byte.
priv struct WavpackBits {
  data : Bytes
  mut pos : Int32
}

///|
fn WavpackBits::new(data : Bytes) -> WavpackBits {
  { data, pos: 0, }
}

///|
fn WavpackBits::bits_left(self : WavpackBits) -> Int32 {
  self.data.length() * 8 - self.pos
}

///|
fn WavpackBits::read1(self : WavpackBits) -> UInt32 {
  let p = self.pos
  self.pos = p + 1
  if p < 0 || p >= self.data.length() * 8 {
    return 0U
  }
  (self.data[p / 8].to_uint() >> (p % 8)) & 1U
}

///|
/// `get_bits` for the little-endian reader: the first bit is the LSB.
fn WavpackBits::read(self : WavpackBits, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = v | (self.read1() << i)
  }
  v
}

///|
fn wavpack_i16les(data : Bytes, off : Int32) -> Int32 {
  let v = data[off].to_int() | (data[off + 1].to_int() << 8)
  if v >= 0x8000 {
    v - 0x10000
  } else {
    v
  }
}

///|
/// `get_unary(gb, 0, 33)`.
fn wavpack_unary(gb : WavpackBits) -> Int32 {
  let mut n = 0
  while n < 33 && gb.read1() == 1U {
    n = n + 1
  }
  n
}

///|
/// `get_tail`.
fn wavpack_get_tail(gb : WavpackBits, k : Int32) -> Int32 {
  if k < 1 {
    return 0
  }
  let p = wavpack_log2(k)
  let e = (1L << (p + 1)).to_int() - k - 1
  let mut res = gb.read(p).reinterpret_as_int()
  if res >= e {
    res = res * 2 - e + gb.read1().reinterpret_as_int()
  }
  res
}

///|
/// `av_log2` for positive values.
fn wavpack_log2(v : Int32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `GET_MED`.
fn wavpack_get_med(c : WavpackChannel, n : Int32) -> Int32 {
  (c.median[n] >> 4) + 1
}

///|
/// `DEC_MED`.
fn wavpack_dec_med(c : WavpackChannel, n : Int32) -> Unit {
  let d = 128U >> n
  let sum = c.median[n].reinterpret_as_uint() + d - 2U
  let q = (sum / d).reinterpret_as_int()
  c.median[n] = c.median[n] - q * 2
}

///|
/// `INC_MED`.
fn wavpack_inc_med(c : WavpackChannel, n : Int32) -> Unit {
  let d = 128U >> n
  let sum = c.median[n].reinterpret_as_uint() + d
  let q = (sum / d).reinterpret_as_int()
  c.median[n] = c.median[n] + q * 5
}

///|
/// Per-channel adaptive median state (`WvChannel`).
pub struct WavpackChannel {
  median : FixedArray[Int32]
}

///|
fn wavpack_channel_new() -> WavpackChannel {
  { median: FixedArray::make(3, 0), }
}

///|
/// One decorrelation pass (`Decorr`).
priv struct WavpackDecorr {
  mut value : Int32
  mut delta : Int32
  mut weight_a : Int32
  mut weight_b : Int32
  samples_a : FixedArray[Int32]
  samples_b : FixedArray[Int32]
}

///|
fn wavpack_decorr_new() -> WavpackDecorr {
  {
    value: 0,
    delta: 0,
    weight_a: 0,
    weight_b: 0,
    samples_a: FixedArray::make(8, 0),
    samples_b: FixedArray::make(8, 0),
  }
}

///|
/// `UPDATE_WEIGHT_CLIP`.
fn wavpack_update_weight_clip(
  weight : Int32,
  delta : Int32,
  samples : Int32,
  input : Int32,
) -> Int32 {
  if samples != 0 && input != 0 {
    if (samples ^ input) < 0 {
      let w = weight - delta
      if w < -1024 {
        -1024
      } else {
        w
      }
    } else {
      let w = weight + delta
      if w > 1024 {
        1024
      } else {
        w
      }
    }
  } else {
    weight
  }
}

///|
/// Decoded WavPack audio. `samples` is interleaved and already in FFmpeg's
/// output form (24-bit left-justified in S32).
pub struct WavpackAudio {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Array[Int32]
}

///|
/// Frame-level decode state built from one block's metadata.
priv struct WavpackFrame {
  mut samples : Int32
  mut flags : UInt32
  mut stereo : Bool
  mut stereo_in : Bool
  mut joint : Bool
  mut terms : Int32
  decorr : Array[WavpackDecorr]
  ch : Array[WavpackChannel]
  mut extra_bits : Int32
  mut and_ : Int32
  mut or_ : Int32
  mut shift : Int32
  mut post_shift : Int32
  mut got_extra_bits : Bool
  mut data : WavpackBits
  mut extra : WavpackBits
  mut zero : Int32
  mut one : Int32
  mut zeroes : Int32
}

///|
fn wavpack_frame_new() -> WavpackFrame {
  let decorr : Array[WavpackDecorr] = []
  for _ in 0..<16 {
    decorr.push(wavpack_decorr_new())
  }
  {
    samples: 0,
    flags: 0U,
    stereo: false,
    stereo_in: false,
    joint: false,
    terms: 0,
    decorr,
    ch: [wavpack_channel_new(), wavpack_channel_new()],
    extra_bits: 0,
    and_: 0,
    or_: 0,
    shift: 0,
    post_shift: 0,
    got_extra_bits: false,
    data: WavpackBits::new(b""),
    extra: WavpackBits::new(b""),
    zero: 0,
    one: 0,
    zeroes: 0,
  }
}

///|
/// One entropy-decoded value and whether the bitstream ended.
priv struct WavpackValue {
  value : Int32
  last : Bool
}

///|
/// `wv_get_value` for the lossless path (`error_limit` is always 0, so the
/// hybrid binary-search refinement is skipped).
fn wavpack_get_value(
  s : WavpackFrame,
  gb : WavpackBits,
  channel : Int32,
) -> Result[WavpackValue, String] {
  let c = s.ch[channel]
  if s.ch[0].median[0] < 2 && s.ch[1].median[0] < 2 && s.zero == 0 && s.one == 0 {
    if s.zeroes != 0 {
      s.zeroes = s.zeroes - 1
      if s.zeroes != 0 {
        return Ok({ value: 0, last: false, })
      }
    } else {
      let mut t = wavpack_unary(gb)
      if t >= 2 {
        if t >= 32 || gb.bits_left() < t - 1 {
          return Ok({ value: 0, last: true, })
        }
        t = gb.read(t - 1).reinterpret_as_int() | (1 << (t - 1))
      } else if gb.bits_left() < 0 {
        return Ok({ value: 0, last: true, })
      }
      s.zeroes = t
      if s.zeroes != 0 {
        for i = 0; i < 3; i = i + 1 {
          s.ch[0].median[i] = 0
          s.ch[1].median[i] = 0
        }
        return Ok({ value: 0, last: false, })
      }
    }
  }
  let mut t = 0
  if s.zero != 0 {
    t = 0
    s.zero = 0
  } else {
    t = wavpack_unary(gb)
    if gb.bits_left() < 0 {
      return Ok({ value: 0, last: true, })
    }
    if t == 16 {
      let t2 = wavpack_unary(gb)
      if t2 < 2 {
        if gb.bits_left() < 0 {
          return Ok({ value: 0, last: true, })
        }
        t = t + t2
      } else {
        if t2 >= 32 || gb.bits_left() < t2 - 1 {
          return Ok({ value: 0, last: true, })
        }
        t = t + (gb.read(t2 - 1).reinterpret_as_int() | (1 << (t2 - 1)))
      }
    }
    if s.one != 0 {
      s.one = t & 1
      t = (t >> 1) + 1
    } else {
      s.one = t & 1
      t = t >> 1
    }
    s.zero = if s.one == 0 { 1 } else { 0 }
  }
  let mut base = 0
  let mut add = 0
  if t == 0 {
    base = 0
    add = wavpack_get_med(c, 0) - 1
    wavpack_dec_med(c, 0)
  } else if t == 1 {
    base = wavpack_get_med(c, 0)
    add = wavpack_get_med(c, 1) - 1
    wavpack_inc_med(c, 0)
    wavpack_dec_med(c, 1)
  } else if t == 2 {
    base = wavpack_get_med(c, 0) + wavpack_get_med(c, 1)
    add = wavpack_get_med(c, 2) - 1
    wavpack_inc_med(c, 0)
    wavpack_inc_med(c, 1)
    wavpack_dec_med(c, 2)
  } else {
    base = wavpack_get_med(c, 0) +
      wavpack_get_med(c, 1) +
      wavpack_get_med(c, 2) * (t - 2)
    add = wavpack_get_med(c, 2) - 1
    wavpack_inc_med(c, 0)
    wavpack_inc_med(c, 1)
    wavpack_inc_med(c, 2)
  }
  let ret = base + wavpack_get_tail(gb, add)
  if gb.bits_left() <= 0 {
    return Ok({ value: 0, last: true, })
  }
  let sign = gb.read1()
  Ok({ value: if sign != 0U { -ret - 1 } else { ret }, last: false, })
}

///|
/// `wv_get_value_integer`.
fn wavpack_get_value_integer(s : WavpackFrame, value : Int32) -> Int32 {
  let mut v = value
  if s.extra_bits != 0 {
    v = v * (1 << s.extra_bits)
    if s.got_extra_bits && s.extra.bits_left() >= s.extra_bits {
      v = v | s.extra.read(s.extra_bits).reinterpret_as_int()
    }
  }
  let bit = (v & s.and_) | s.or_
  let bit = ((v + bit) << s.shift) - bit
  bit << s.post_shift
}

///|
/// Apply one decorrelation pass for stereo. `wide` selects the S32 arithmetic
/// path (64-bit products) used for 24/32-bit output.
fn wavpack_decorr_stereo(
  d : WavpackDecorr,
  l_in : Int32,
  r_in : Int32,
  pos : Int32,
  wide : Bool,
) -> (Int32, Int32) {
  let mut l = l_in
  let mut r = r_in
  let t = d.value
  if t > 0 {
    let mut a = 0
    let mut b = 0
    let mut j = 0
    if t > 8 {
      if (t & 1) != 0 {
        a = 2 * d.samples_a[0] - d.samples_a[1]
        b = 2 * d.samples_b[0] - d.samples_b[1]
      } else {
        a = (3 * d.samples_a[0] - d.samples_a[1]) >> 1
        b = (3 * d.samples_b[0] - d.samples_b[1]) >> 1
      }
      d.samples_a[1] = d.samples_a[0]
      d.samples_b[1] = d.samples_b[0]
      j = 0
    } else {
      a = d.samples_a[pos]
      b = d.samples_b[pos]
      j = (pos + t) & 7
    }
    let l2 = if wide {
      (l.to_int64() + ((d.weight_a.to_int64() * a.to_int64() + 512L) >> 10)).to_int()
    } else {
      l +
      (
        (d.weight_a.reinterpret_as_uint() * a.reinterpret_as_uint() + 512U).reinterpret_as_int() >>
        10
      )
    }
    let r2 = if wide {
      (r.to_int64() + ((d.weight_b.to_int64() * b.to_int64() + 512L) >> 10)).to_int()
    } else {
      r +
      (
        (d.weight_b.reinterpret_as_uint() * b.reinterpret_as_uint() + 512U).reinterpret_as_int() >>
        10
      )
    }
    if a != 0 && l != 0 {
      d.weight_a = d.weight_a - ((((l ^ a) >> 30) & 2) - 1) * d.delta
    }
    if b != 0 && r != 0 {
      d.weight_b = d.weight_b - ((((r ^ b) >> 30) & 2) - 1) * d.delta
    }
    d.samples_a[j] = l2
    d.samples_b[j] = r2
    l = l2
    r = r2
  } else if t == -1 {
    let l2 = if wide {
      (l.to_int64() +
      ((d.weight_a.to_int64() * d.samples_a[0].to_int64() + 512L) >> 10)).to_int()
    } else {
      l +
      (
        (d.weight_a.reinterpret_as_uint() * d.samples_a[0].reinterpret_as_uint() +
        512U).reinterpret_as_int() >>
        10
      )
    }
    d.weight_a = wavpack_update_weight_clip(
      d.weight_a,
      d.delta,
      d.samples_a[0],
      l,
    )
    l = l2
    let r2 = if wide {
      (r.to_int64() + ((d.weight_b.to_int64() * l2.to_int64() + 512L) >> 10)).to_int()
    } else {
      r +
      (
        (d.weight_b.reinterpret_as_uint() * l2.reinterpret_as_uint() + 512U).reinterpret_as_int() >>
        10
      )
    }
    d.weight_b = wavpack_update_weight_clip(d.weight_b, d.delta, l2, r)
    r = r2
    d.samples_a[0] = r
  } else {
    let r2 = if wide {
      (r.to_int64() +
      ((d.weight_b.to_int64() * d.samples_b[0].to_int64() + 512L) >> 10)).to_int()
    } else {
      r +
      (
        (d.weight_b.reinterpret_as_uint() * d.samples_b[0].reinterpret_as_uint() +
        512U).reinterpret_as_int() >>
        10
      )
    }
    d.weight_b = wavpack_update_weight_clip(
      d.weight_b,
      d.delta,
      d.samples_b[0],
      r,
    )
    r = r2
    let mut pred = r2
    if t == -3 {
      pred = d.samples_a[0]
      d.samples_a[0] = r
    }
    let l2 = if wide {
      (l.to_int64() + ((d.weight_a.to_int64() * pred.to_int64() + 512L) >> 10)).to_int()
    } else {
      l +
      (
        (d.weight_a.reinterpret_as_uint() * pred.reinterpret_as_uint() + 512U).reinterpret_as_int() >>
        10
      )
    }
    d.weight_a = wavpack_update_weight_clip(d.weight_a, d.delta, pred, l)
    l = l2
    d.samples_b[0] = l
  }
  (l, r)
}

///|
/// Apply one decorrelation pass for mono.
fn wavpack_decorr_mono(
  d : WavpackDecorr,
  input : Int32,
  pos : Int32,
  wide : Bool,
) -> Int32 {
  let mut t_in = input
  let t = d.value
  let mut a = 0
  let mut j = 0
  if t > 8 {
    if (t & 1) != 0 {
      a = 2 * d.samples_a[0] - d.samples_a[1]
    } else {
      a = (3 * d.samples_a[0] - d.samples_a[1]) >> 1
    }
    d.samples_a[1] = d.samples_a[0]
    j = 0
  } else {
    a = d.samples_a[pos]
    j = (pos + t) & 7
  }
  let s = if wide {
    (t_in.to_int64() + ((d.weight_a.to_int64() * a.to_int64() + 512L) >> 10)).to_int()
  } else {
    t_in +
    (
      (d.weight_a.reinterpret_as_uint() * a.reinterpret_as_uint() + 512U).reinterpret_as_int() >>
      10
    )
  }
  if a != 0 && t_in != 0 {
    d.weight_a = d.weight_a - ((((t_in ^ a) >> 30) & 2) - 1) * d.delta
  }
  d.samples_a[j] = s
  t_in = s
  t_in
}

///|
/// Decode one block payload (starting at `block_samples`) into planar
/// left/right arrays of `nb_samples` values.
fn wavpack_decode_block(
  payload : Bytes,
) -> Result[(WavpackFrame, Array[Int32], Array[Int32], Int32), String] {
  let n = payload.length()
  if n < 12 {
    return Err("wavpack: block too short")
  }
  let s = wavpack_frame_new()
  s.samples = wavpack_u32le(payload, 0).reinterpret_as_int()
  s.flags = wavpack_u32le(payload, 4)
  if s.samples <= 0 || s.samples > 150000 {
    return Err("wavpack: invalid sample count")
  }
  let flags = s.flags
  if (flags & 0x80000000U) != 0U {
    return Err("wavpack: DSD streams are not supported")
  }
  if (flags & 0x80U) != 0U {
    return Err("wavpack: float streams are not supported")
  }
  if (flags & 0x8U) != 0U {
    return Err("wavpack: hybrid streams are not supported")
  }
  if (flags & 0x1800U) != 0x1800U {
    return Err("wavpack: multi-block channel streams are not supported")
  }
  let bytes_per_sample = (flags & 0x03U).reinterpret_as_int() + 1
  if bytes_per_sample == 1 {
    return Err("wavpack: 8-bit streams are not supported")
  }
  let orig_bpp = bytes_per_sample * 8
  let out_bpp = if bytes_per_sample <= 2 { 2 } else { 4 }
  let post_shift = out_bpp * 8 -
    orig_bpp +
    ((flags >> 13) & 0x1F).reinterpret_as_int()
  if post_shift < 0 || post_shift > 31 {
    return Err("wavpack: invalid post shift")
  }
  s.post_shift = post_shift
  s.stereo = (flags & 0x04U) == 0U
  s.stereo_in = if (flags & 0x40000000U) != 0U { false } else { s.stereo }
  s.joint = (flags & 0x10U) != 0U
  let mut got_terms = false
  let mut got_weights = false
  let mut got_samples = false
  let mut got_entropy = false
  let mut got_pcm = false
  let mut custom_rate = 0
  let mut pos = 12 // after samples/flags/CRC(u32)
  while pos + 2 <= n {
    let id = payload[pos].to_int()
    pos = pos + 1
    let mut size = payload[pos].to_int()
    pos = pos + 1
    if (id & 0x80) != 0 {
      if pos + 2 > n {
        return Err("wavpack: truncated metadata length")
      }
      size = size | (wavpack_i16les(payload, pos) << 8)
      pos = pos + 2
    }
    size = size << 1
    let ssize = size
    if (id & 0x40) != 0 {
      size = size - 1
    }
    if size < 0 || pos + ssize > n {
      return Err("wavpack: metadata out of bounds")
    }
    let kind = id & 0x3F
    let payload_start = pos
    if kind == 2 {
      // WP_ID_DECTERMS
      if size > 16 {
        return Err("wavpack: too many decorrelation terms")
      }
      s.terms = size
      for i = 0; i < s.terms; i = i + 1 {
        let val = payload[payload_start + i].to_int()
        let d = s.decorr[s.terms - i - 1]
        d.value = (val & 0x1F) - 5
        d.delta = val >> 5
      }
      got_terms = true
    } else if kind == 3 {
      // WP_ID_DECWEIGHTS
      if !got_terms {
        return Err("wavpack: decorrelation weights without terms")
      }
      let weights = size >> (if s.stereo_in { 1 } else { 0 })
      if weights > 16 || weights > s.terms {
        return Err("wavpack: too many decorrelation weights")
      }
      let mut wp = 0
      for i = 0; i < weights; i = i + 1 {
        let d = s.decorr[s.terms - i - 1]
        let t = payload[payload_start + wp].to_int()
        wp = wp + 1
        let ta = if t >= 0x80 { t - 0x100 } else { t }
        d.weight_a = ta * 8
        if d.weight_a > 0 {
          d.weight_a = d.weight_a + ((d.weight_a + 64) >> 7)
        }
        if s.stereo_in {
          let t2 = payload[payload_start + wp].to_int()
          wp = wp + 1
          let tb = if t2 >= 0x80 { t2 - 0x100 } else { t2 }
          d.weight_b = tb * 8
          if d.weight_b > 0 {
            d.weight_b = d.weight_b + ((d.weight_b + 64) >> 7)
          }
        }
      }
      got_weights = true
    } else if kind == 4 {
      // WP_ID_DECSAMPLES
      if !got_terms {
        return Err("wavpack: decorrelation samples without terms")
      }
      let mut t = 0
      let mut wp = 0
      let mut i = s.terms - 1
      while i >= 0 && t < size {
        let d = s.decorr[i]
        if d.value > 8 {
          if wp + 2 > size {
            return Err("wavpack: truncated decorrelation samples")
          }
          d.samples_a[0] = wavpack_exp2(
            wavpack_i16les(payload, payload_start + wp),
          )
          d.samples_a[1] = wavpack_exp2(
            wavpack_i16les(payload, payload_start + wp + 2),
          )
          wp = wp + 4
          if s.stereo_in {
            if wp + 2 > size {
              return Err("wavpack: truncated decorrelation samples")
            }
            d.samples_b[0] = wavpack_exp2(
              wavpack_i16les(payload, payload_start + wp),
            )
            d.samples_b[1] = wavpack_exp2(
              wavpack_i16les(payload, payload_start + wp + 2),
            )
            wp = wp + 4
            t = t + 4
          }
          t = t + 4
        } else if d.value < 0 {
          if wp + 4 > size {
            return Err("wavpack: truncated decorrelation samples")
          }
          d.samples_a[0] = wavpack_exp2(
            wavpack_i16les(payload, payload_start + wp),
          )
          d.samples_b[0] = wavpack_exp2(
            wavpack_i16les(payload, payload_start + wp + 2),
          )
          wp = wp + 4
          t = t + 4
        } else {
          for j = 0; j < d.value; j = j + 1 {
            if wp + 2 > size {
              return Err("wavpack: truncated decorrelation samples")
            }
            d.samples_a[j] = wavpack_exp2(
              wavpack_i16les(payload, payload_start + wp),
            )
            wp = wp + 2
            if s.stereo_in {
              if wp + 2 > size {
                return Err("wavpack: truncated decorrelation samples")
              }
              d.samples_b[j] = wavpack_exp2(
                wavpack_i16les(payload, payload_start + wp),
              )
              wp = wp + 2
            }
          }
          t = t + d.value * 2 * (if s.stereo_in { 2 } else { 1 })
        }
        i = i - 1
      }
      got_samples = true
    } else if kind == 5 {
      // WP_ID_ENTROPY
      let want = 6 * (if s.stereo_in { 2 } else { 1 })
      if size != want {
        return Err("wavpack: invalid entropy metadata size")
      }
      let mut wp = 0
      for j = 0; j <= (if s.stereo_in { 1 } else { 0 }); j = j + 1 {
        for i = 0; i < 3; i = i + 1 {
          s.ch[j].median[i] = wavpack_exp2(
            wavpack_i16les(payload, payload_start + wp),
          )
          wp = wp + 2
        }
      }
      got_entropy = true
    } else if kind == 9 {
      // WP_ID_INT32INFO
      if size != 4 {
        return Err("wavpack: invalid INT32INFO")
      }
      let extra = payload[payload_start].to_int()
      if extra > 30 {
        return Err("wavpack: invalid extra bits")
      }
      s.extra_bits = extra
      if payload[payload_start + 1] != b'\x00' {
        s.shift = payload[payload_start + 1].to_int()
      }
      if payload[payload_start + 2] != b'\x00' {
        s.and_ = 1
        s.or_ = 1
        s.shift = payload[payload_start + 2].to_int()
      }
      if payload[payload_start + 3] != b'\x00' {
        s.and_ = 1
        s.shift = payload[payload_start + 3].to_int()
      }
      if s.shift > 31 {
        s.and_ = 0
        s.or_ = 0
        s.shift = 0
      }
    } else if kind == 10 {
      // WP_ID_DATA
      s.data = WavpackBits::new(
        payload[payload_start:payload_start + size].to_owned(),
      )
      got_pcm = true
    } else if kind == 12 {
      // WP_ID_EXTRABITS
      if size <= 4 {
        return Err("wavpack: invalid EXTRABITS")
      }
      s.extra = WavpackBits::new(
        payload[payload_start:payload_start + size].to_owned(),
      )
      let _ = s.extra.read(32)
      s.got_extra_bits = true
    } else if kind == 0x27 {
      // WP_ID_SAMPLE_RATE
      if size != 3 {
        return Err("wavpack: invalid custom sample rate")
      }
      custom_rate = payload[payload_start].to_int() |
        (payload[payload_start + 1].to_int() << 8) |
        (payload[payload_start + 2].to_int() << 16)
    }
    pos = pos + ssize
  }
  if !got_pcm {
    return Err("wavpack: missing packed samples")
  }
  if !got_terms || !got_weights || !got_samples || !got_entropy {
    return Err("wavpack: incomplete block metadata")
  }
  // Sample rate lives in the flags; a custom rate overrides it.
  let sr = ((flags >> 23) & 0xF).reinterpret_as_int()
  let sample_rate = if sr == 0xF { custom_rate } else { wavpack_rates[sr] }
  if sample_rate <= 0 {
    return Err("wavpack: invalid sample rate")
  }
  let nb = s.samples
  let left : Array[Int32] = Array::make(nb, 0)
  let right : Array[Int32] = Array::make(nb, 0)
  s.zero = 0
  s.one = 0
  s.zeroes = 0
  let wide = bytes_per_sample > 1
  let gb = s.data
  let mut pos_ring = 0
  let mut count = 0
  let mut last = false
  while count < nb && !last {
    if s.stereo_in {
      let lv = match wavpack_get_value(s, gb, 0) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if lv.last {
        last = true
        break
      }
      let rv = match wavpack_get_value(s, gb, 1) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if rv.last {
        last = true
        break
      }
      let l = lv.value
      let r = rv.value
      let mut ll = l
      let mut rr = r
      for i = 0; i < s.terms; i = i + 1 {
        let (a, b) = wavpack_decorr_stereo(s.decorr[i], ll, rr, pos_ring, wide)
        ll = a
        rr = b
      }
      if bytes_per_sample == 2 {
        let al = if ll < 0 { -ll.to_int64() } else { ll.to_int64() }
        let ar = if rr < 0 { -rr.to_int64() } else { rr.to_int64() }
        if al + ar > 1L << 19 {
          return Err("wavpack: sample too large")
        }
      }
      pos_ring = (pos_ring + 1) & 7
      if s.joint {
        rr = rr - (ll >> 1)
        ll = ll + rr
      }
      left[count] = wavpack_get_value_integer(s, ll)
      right[count] = wavpack_get_value_integer(s, rr)
    } else {
      let tv = match wavpack_get_value(s, gb, 0) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      if tv.last {
        last = true
        break
      }
      let mut sval = tv.value
      for i = 0; i < s.terms; i = i + 1 {
        sval = wavpack_decorr_mono(s.decorr[i], sval, pos_ring, wide)
      }
      pos_ring = (pos_ring + 1) & 7
      left[count] = wavpack_get_value_integer(s, sval)
      if s.stereo {
        right[count] = left[count]
      }
    }
    count = count + 1
  }
  if count < nb && last {
    // The C zero-fills a truncated block; mirror that instead of failing.
    for i = count; i < nb; i = i + 1 {
      left[i] = 0
      right[i] = 0
    }
  }
  Ok((s, left, right, sample_rate))
}

///|
/// Decode a complete `.wv` file into interleaved PCM.
pub fn ff_wavpack_decode(data : Bytes) -> Result[WavpackAudio, String] {
  let out : Array[Int32] = []
  let mut sample_rate = 0
  let mut channels = 0
  let mut bits = 0
  let mut total = 0L
  let mut expected_total = -1L
  let mut pos = 0
  while pos + 32 <= data.length() {
    if data[pos] != b'w' ||
      data[pos + 1] != b'v' ||
      data[pos + 2] != b'p' ||
      data[pos + 3] != b'k' {
      if pos == 0 {
        return Err("wavpack: missing wvpk header")
      }
      break
    }
    let ck_size = wavpack_u32le(data, pos + 4).reinterpret_as_int()
    let block_size = ck_size + 8
    if ck_size < 24 || block_size <= 0 || pos + block_size > data.length() {
      return Err("wavpack: invalid block size")
    }
    let block_samples = wavpack_u32le(data, pos + 20).reinterpret_as_int()
    let block_total = wavpack_u32le(data, pos + 12).reinterpret_as_int()
    if expected_total < 0 {
      expected_total = block_total.to_int64()
    }
    let (frame, left, right, block_rate) = match
      wavpack_decode_block(data[pos + 20:pos + block_size].to_owned()) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if block_samples != frame.samples {
      return Err("wavpack: inconsistent block samples")
    }
    if sample_rate == 0 {
      sample_rate = block_rate
      bits = ((frame.flags & 0x03U).reinterpret_as_int() + 1) * 8
      channels = if frame.stereo { 2 } else { 1 }
    } else if block_rate != sample_rate {
      return Err("wavpack: inconsistent sample rate")
    }
    for i = 0; i < frame.samples; i = i + 1 {
      out.push(left[i])
      if channels == 2 {
        out.push(right[i])
      }
    }
    total = total + frame.samples.to_int64()
    pos = pos + block_size
  }
  if sample_rate == 0 {
    return Err("wavpack: no decodable blocks")
  }
  if expected_total >= 0L && total != expected_total {
    return Err("wavpack: decoded \{total} of \{expected_total} samples")
  }
  Ok({ sample_rate, channels, bits, samples: out, })
}

///|
/// Interleaved PCM bytes matching FFmpeg's WavPack output format: S16 for
/// 16-bit streams and left-justified S32 for 24/32-bit streams.
pub fn WavpackAudio::pcm_bytes(self : WavpackAudio) -> Bytes {
  let out : Array[Byte] = []
  let wide = self.bits > 16
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
    if wide {
      out.push(((v >> 16) & 0xFF).to_byte())
      out.push(((v >> 24) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(out)
}
