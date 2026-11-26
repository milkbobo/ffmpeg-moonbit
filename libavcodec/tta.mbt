///|
/// TTA (The Lossless True Audio) decoder, ported from FFmpeg 9.0.2
/// `libavcodec/tta.c`, `ttadata.c` and `ttadsp.c`.
///
/// `ff_tta_decode` takes a complete native TTA file (`TTA1` header, seek
/// table and frames) and returns interleaved PCM in FFmpeg's output form:
/// U8 for 8-bit streams, S16 for 16-bit and left-justified S32 for 24-bit.
///
/// Scope: format 1 (unencrypted) with 8/16/24-bit samples. The bitstream
/// reader is little-endian, as in the C (`BITSTREAM_READER_LE`). Header,
/// seek-table and frame CRCs are not verified (like the FLAC port).
/// Encrypted streams (format 2) are rejected.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `ff_tta_shift_1`.
let tta_shift_1 : FixedArray[UInt32] = [
  0x00000001U, 0x00000002U, 0x00000004U, 0x00000008U, 0x00000010U, 0x00000020U, 0x00000040U,
  0x00000080U, 0x00000100U, 0x00000200U, 0x00000400U, 0x00000800U, 0x00001000U, 0x00002000U,
  0x00004000U, 0x00008000U, 0x00010000U, 0x00020000U, 0x00040000U, 0x00080000U, 0x00100000U,
  0x00200000U, 0x00400000U, 0x00800000U, 0x01000000U, 0x02000000U, 0x04000000U, 0x08000000U,
  0x10000000U, 0x20000000U, 0x40000000U, 0x80000000U, 0x80000000U, 0x80000000U, 0x80000000U,
  0x80000000U, 0x80000000U, 0x80000000U, 0x80000000U, 0x80000000U, 0xFFFFFFFFU,
]

///|
/// `ff_tta_shift_16` (`ff_tta_shift_1 + 4`).
fn tta_shift16(k : Int32) -> UInt32 {
  let idx = k + 4
  if idx < 0 || idx >= tta_shift_1.length() {
    0xFFFFFFFFU
  } else {
    tta_shift_1[idx]
  }
}

///|
/// `ff_tta_shift_1` with a bounds guard for corrupt adaptive states.
fn tta_shift1(k : Int32) -> UInt32 {
  if k < 0 || k >= tta_shift_1.length() {
    0xFFFFFFFFU
  } else {
    tta_shift_1[k]
  }
}

///|
/// `ff_tta_filter_configs` indexed by `bps - 1`.
let tta_filter_configs : FixedArray[Int32] = [10, 9, 10, 12]

///|
/// Little-endian `GetBitContext`.
priv struct TtaBits {
  data : BytesView
  mut pos : Int32
}

///|
fn TtaBits::new(data : BytesView) -> TtaBits {
  { data, pos: 0, }
}

///|
fn TtaBits::bits_left(self : TtaBits) -> Int32 {
  self.data.length() * 8 - self.pos
}

///|
/// One LSB-first bit; zero past the end.
fn TtaBits::bit(self : TtaBits) -> UInt32 {
  let p = self.pos
  self.pos = p + 1
  if p < 0 || p >= self.data.length() * 8 {
    return 0U
  }
  (self.data[p / 8].to_uint() >> (p % 8)) & 1U
}

///|
/// `get_bits` for the little-endian reader: the first bit is the LSB.
fn TtaBits::read(self : TtaBits, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = v | (self.bit() << i)
  }
  v
}

///|
/// `get_unary(gb, 0, limit)`: count 1-bits until a 0 (or `limit` bits).
fn tta_unary(gb : TtaBits, limit : Int32) -> Int32 {
  let mut n = 0
  while n < limit && gb.bit() == 1U {
    n = n + 1
  }
  n
}

///|
/// Per-channel hybrid filter state (`TTAFilter`).
priv struct TtaFilter {
  qm : FixedArray[Int32]
  dx : FixedArray[Int32]
  dl : FixedArray[Int32]
  mut error : Int32
  round : Int32
}

///|
fn tta_filter_new(shift : Int32) -> TtaFilter {
  {
    qm: FixedArray::make(8, 0),
    dx: FixedArray::make(8, 0),
    dl: FixedArray::make(8, 0),
    error: 0,
    round: tta_shift1(shift - 1).reinterpret_as_int(),
  }
}

///|
/// Per-channel Rice state (`TTARice`).
priv struct TtaRice {
  mut k0 : Int32
  mut k1 : Int32
  mut sum0 : UInt32
  mut sum1 : UInt32
}

///|
fn tta_rice_new() -> TtaRice {
  { k0: 10, k1: 10, sum0: tta_shift16(10), sum1: tta_shift16(10), }
}

///|
/// `tta_filter_process_c`.
fn tta_filter_process(
  f : TtaFilter,
  input : Int32,
  shift : Int32,
  round : Int32,
) -> Int32 {
  if f.error < 0 {
    for i = 0; i < 8; i = i + 1 {
      f.qm[i] = f.qm[i] - f.dx[i]
    }
  } else if f.error > 0 {
    for i = 0; i < 8; i = i + 1 {
      f.qm[i] = f.qm[i] + f.dx[i]
    }
  }
  let mut r = round
  for i = 0; i < 8; i = i + 1 {
    r = r + f.dl[i] * f.qm[i]
  }
  f.dx[0] = f.dx[1]
  f.dx[1] = f.dx[2]
  f.dx[2] = f.dx[3]
  f.dx[3] = f.dx[4]
  f.dl[0] = f.dl[1]
  f.dl[1] = f.dl[2]
  f.dl[2] = f.dl[3]
  f.dl[3] = f.dl[4]
  f.dx[4] = (f.dl[4] >> 30) | 1
  f.dx[5] = ((f.dl[5] >> 30) | 2) & -2
  f.dx[6] = ((f.dl[6] >> 30) | 2) & -2
  f.dx[7] = ((f.dl[7] >> 30) | 4) & -4
  f.error = input
  let out = input + (r >> shift)
  f.dl[4] = -f.dl[5]
  f.dl[5] = -f.dl[6]
  f.dl[6] = out - f.dl[7]
  f.dl[7] = out
  f.dl[5] = f.dl[5] + f.dl[6]
  f.dl[4] = f.dl[4] + f.dl[5]
  out
}

///|
/// `PRED(x, k)` from the C.
fn tta_pred(x : Int32, k : Int32) -> Int32 {
  ((x.to_int64() * ((1L << k) - 1)) >> k).to_int()
}

///|
/// Interleaved signed samples. 24-bit output is left-justified in 32 bits.
/// `pcm_bytes` adds the unsigned offset for 8-bit output.
pub struct TtaAudio {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Array[Int32]
}

///|
/// The stream parameters from the native TTA1 header.
pub struct TtaHeader {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  frame_samples : Int32
  total_samples : Int64
}

///|
fn tta_u16le(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() | (data[off + 1].to_int() << 8)
}

///|
fn tta_u32le(data : Bytes, off : Int32) -> UInt32 {
  data[off].to_uint() |
  (data[off + 1].to_uint() << 8) |
  (data[off + 2].to_uint() << 16) |
  (data[off + 3].to_uint() << 24)
}

///|
/// Decode one frame into interleaved `out` starting at `base` (sample index).
fn tta_decode_frame_into(
  frame : BytesView,
  channels : Int32,
  bps : Int32,
  frame_length : Int32,
  out : Array[Int32],
  base : Int32,
) -> Result[Unit, String] {
  if frame.length() < 5 || frame.length() > 0x0fffffff {
    return Err("tta: invalid frame size")
  }
  let gb = TtaBits::new(frame[:frame.length() - 4])
  let bps_bytes = (bps + 7) / 8
  let filter_shift = tta_filter_configs[bps_bytes - 1]
  let filters : Array[TtaFilter] = []
  let rices : Array[TtaRice] = []
  for ch = 0; ch < channels; ch = ch + 1 {
    filters.push(tta_filter_new(filter_shift))
    rices.push(tta_rice_new())
  }
  let predictors : Array[Int32] = Array::make(channels, 0)
  for g = 0; g < frame_length; g = g + 1 {
    for c = 0; c < channels; c = c + 1 {
      let rice = rices[c]
      let filter = filters[c]
      let left = gb.bits_left()
      let unary = tta_unary(gb, left)
      if unary == left {
        return Err("tta: truncated rice code")
      }
      let depth = if unary == 0 { 0 } else { 1 }
      let unary_val = if unary == 0 { 0 } else { unary - 1 }
      let k = if depth == 0 { rice.k0 } else { rice.k1 }
      if gb.bits_left() < k {
        return Err("tta: truncated rice code")
      }
      let mut value = if k > 0 {
        if k > 31 || unary_val > 2147483647 >> k {
          return Err("tta: invalid rice parameter")
        }
        (unary_val << k) + gb.read(k).reinterpret_as_int()
      } else {
        unary_val
      }
      if depth == 1 {
        rice.sum1 = rice.sum1 + value.reinterpret_as_uint() - (rice.sum1 >> 4)
        if rice.k1 > 0 && rice.sum1 < tta_shift16(rice.k1) {
          rice.k1 = rice.k1 - 1
        } else if rice.sum1 > tta_shift16(rice.k1 + 1) {
          rice.k1 = rice.k1 + 1
        }
        value = value + tta_shift1(rice.k0).reinterpret_as_int()
      }
      rice.sum0 = rice.sum0 + value.reinterpret_as_uint() - (rice.sum0 >> 4)
      if rice.k0 > 0 && rice.sum0 < tta_shift16(rice.k0) {
        rice.k0 = rice.k0 - 1
      } else if rice.sum0 > tta_shift16(rice.k0 + 1) {
        rice.k0 = rice.k0 + 1
      }
      value = 1 + ((value >> 1) ^ ((value & 1) - 1))
      value = tta_filter_process(filter, value, filter_shift, filter.round)
      value = value +
        (if bps_bytes == 1 {
          tta_pred(predictors[c], 4)
        } else if bps_bytes == 2 || bps_bytes == 3 {
          tta_pred(predictors[c], 5)
        } else {
          predictors[c]
        })
      predictors[c] = value
      out[base + g * channels + c] = value
    }
    // `predictor` is per channel; keep it in the output slot across groups.
    if channels > 1 {
      let p = base + g * channels + channels - 1
      out[p] = out[p] + out[p - 1] / 2
      let mut r = p - 1
      while r > p - channels {
        out[r] = out[r + 1] - out[r]
        r = r - 1
      }
    }
  }
  if gb.bits_left() >= 8 {
    return Err("tta: excess data after frame samples")
  }
  Ok(())
}

///|
/// Read the first 22 bytes of an unencrypted native TTA stream.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.tta_parse_header(b"TTA1") is Err(_))
/// }
/// ```
pub fn tta_parse_header(data : Bytes) -> Result[TtaHeader, String] {
  if data.length() < 22 ||
    data[0] != b'T' ||
    data[1] != b'T' ||
    data[2] != b'A' ||
    data[3] != b'1' {
    return Err("tta: missing TTA1 header")
  }
  let format = tta_u16le(data, 4)
  if format == 2 {
    return Err("tta: encrypted streams are not supported")
  }
  if format != 1 {
    return Err("tta: invalid format \{format}")
  }
  let channels = tta_u16le(data, 6)
  let bps = tta_u16le(data, 8)
  let sample_rate = tta_u32le(data, 10).reinterpret_as_int()
  let total_samples = tta_u32le(data, 14).to_int64()
  if channels < 1 || channels > 16 {
    return Err("tta: invalid channel count")
  }
  if sample_rate <= 0 || sample_rate > 0x7FFFFF {
    return Err("tta: invalid sample rate")
  }
  if total_samples == 0L {
    return Err("tta: invalid sample count")
  }
  if bps != 8 && bps != 16 && bps != 24 {
    return Err("tta: unsupported sample format")
  }
  Ok({
    sample_rate,
    channels,
    bits: bps,
    frame_samples: 256 * sample_rate / 245,
    total_samples,
  })
}

///|
fn tta_scale_samples(out : Array[Int32], bits : Int32) -> Unit {
  if bits == 24 {
    for i in 0..<out.length() {
      out[i] = (out[i].reinterpret_as_uint() << 8).reinterpret_as_int()
    }
  }
}

///|
/// Decode one TTA packet, including its four trailing CRC bytes. `pts` is
/// the native frame's starting sample index, which determines its length.
pub fn TtaHeader::decode_frame(
  self : TtaHeader,
  frame : Bytes,
  pts : Int64,
) -> Result[TtaAudio, String] {
  if pts < 0L ||
    pts >= self.total_samples ||
    pts % self.frame_samples.to_int64() != 0L {
    return Err("tta: invalid frame timestamp")
  }
  let count = (self.total_samples - pts)
    .min(self.frame_samples.to_int64())
    .to_int()
  // Every coded sample uses at least one bit, before the trailing CRC.
  if count.to_int64() * self.channels.to_int64() >
    (frame.length() - 4).to_int64() * 8L {
    return Err("tta: frame too short")
  }
  let samples = Array::make(count * self.channels, 0)
  match
    tta_decode_frame_into(frame[:], self.channels, self.bits, count, samples, 0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  tta_scale_samples(samples, self.bits)
  Ok({
    sample_rate: self.sample_rate,
    channels: self.channels,
    bits: self.bits,
    samples,
  })
}

///|
/// Decode a complete native TTA file into interleaved PCM.
pub fn ff_tta_decode(data : Bytes) -> Result[TtaAudio, String] {
  let header = match tta_parse_header(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let {
    channels,
    bits,
    sample_rate,
    frame_samples: frame_length,
    total_samples,
  } = header
  if total_samples > 100000000L {
    return Err("tta: unsupported sample format")
  }
  let data_length = total_samples.to_int()
  let last_frame_length = data_length % frame_length
  let total_frames = data_length / frame_length +
    (if last_frame_length != 0 { 1 } else { 0 })
  let seek_end = 22 + 4 * total_frames
  if data.length() < seek_end + 4 {
    return Err("tta: truncated seek table")
  }
  let mut frame_pos = seek_end + 4
  if total_samples * channels.to_int64() >
    (data.length() - frame_pos).to_int64() * 8L {
    return Err("tta: truncated frame data")
  }
  let out : Array[Int32] = Array::make(data_length * channels, 0)
  let mut decoded = 0
  for f = 0; f < total_frames; f = f + 1 {
    let size = tta_u32le(data, 22 + 4 * f).reinterpret_as_int()
    if size <= 0 || size > data.length() - frame_pos {
      return Err("tta: invalid frame size")
    }
    let count = frame_length.min(data_length - decoded)
    match
      tta_decode_frame_into(
        data[frame_pos:frame_pos + size],
        channels,
        bits,
        count,
        out,
        decoded * channels,
      ) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    decoded = decoded + count
    frame_pos = frame_pos + size
  }
  tta_scale_samples(out, bits)
  Ok({ sample_rate, channels, bits, samples: out, })
}

///|
/// Interleaved PCM bytes matching FFmpeg's TTA output format: U8 (offset by
/// 0x80 for 8-bit), S16 little-endian, or left-justified S32 for 24-bit.
pub fn TtaAudio::pcm_bytes(self : TtaAudio) -> Bytes {
  let out : Array[Byte] = []
  for v in self.samples {
    if self.bits == 8 {
      out.push(((v + 0x80) & 0xFF).to_byte())
    } else {
      out.push((v & 0xFF).to_byte())
      out.push(((v >> 8) & 0xFF).to_byte())
      if self.bits == 24 {
        out.push(((v >> 16) & 0xFF).to_byte())
        out.push(((v >> 24) & 0xFF).to_byte())
      }
    }
  }
  Bytes::from_array(out)
}
