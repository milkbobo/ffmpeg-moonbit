///|
/// WavPack lossless integer writer. The word coder and metadata layout
/// follow FFmpeg's libavcodec/wavpackenc.c (LGPL-2.1-or-later).
priv struct WavpackBitWriter {
  data : Array[Byte]
  mut pending : UInt32
  mut bits : Int32
}

///|
fn WavpackBitWriter::new() -> WavpackBitWriter {
  { data: [], pending: 0U, bits: 0, }
}

///|
fn WavpackBitWriter::write(
  self : WavpackBitWriter,
  count : Int32,
  value : UInt32,
) -> Unit {
  let combined = self.pending.to_uint64() |
    ((value.to_uint64() & ((1UL << count) - 1UL)) << self.bits)
  let mut data = combined
  self.bits += count
  while self.bits >= 8 {
    self.data.push(data.to_byte())
    self.bits -= 8
    data = data >> 8
  }
  self.pending = data.to_uint()
}

///|
fn WavpackBitWriter::finish(self : WavpackBitWriter) -> Array[Byte] {
  if self.bits != 0 {
    self.data.push(self.pending.to_byte())
  }
  self.data
}

///|
/// Unary prefix followed by the low bits of a zero-run or escaped count.
fn WavpackBitWriter::write_count(
  self : WavpackBitWriter,
  count : Int32,
) -> Unit {
  let bits = if count == 0 { 0 } else { wavpack_log2(count) + 1 }
  self.write(bits + 1, (1U << bits) - 1U)
  if bits > 1 {
    self.write(bits - 1, count.reinterpret_as_uint())
  }
}

///|
priv struct WavpackWordsWriter {
  bits : WavpackBitWriter
  channels : FixedArray[WavpackChannel]
  mut zero_run : Int32
  mut unary_ones : Int32
  mut unary_zero : Bool
  mut tail : UInt32
  mut tail_bits : Int32
}

///|
fn WavpackWordsWriter::flush(self : WavpackWordsWriter) -> Unit {
  if self.zero_run != 0 {
    self.bits.write_count(self.zero_run)
    self.zero_run = 0
  }
  if self.unary_ones >= 16 {
    self.bits.write(17, 65535U)
    self.bits.write_count(self.unary_ones - 16)
  } else {
    self.bits.write(self.unary_ones, (1U << self.unary_ones) - 1U)
    if self.unary_zero {
      self.bits.write(1, 0U)
    }
  }
  self.bits.write(self.tail_bits, self.tail)
  self.unary_ones = 0
  self.unary_zero = false
  self.tail = 0U
  self.tail_bits = 0
}

///|
fn wavpack_encode_median(
  c : WavpackChannel,
  magnitude : Int32,
) -> (Int32, Int32, Int32) {
  let mut low = 0
  for i in 0..<2 {
    let width = wavpack_get_med(c, i)
    if magnitude - low < width {
      wavpack_dec_med(c, i)
      return (i, low, width)
    }
    wavpack_inc_med(c, i)
    low += width
  }
  let width = wavpack_get_med(c, 2)
  let multiple = (magnitude - low) / width
  if multiple == 0 {
    wavpack_dec_med(c, 2)
  } else {
    wavpack_inc_med(c, 2)
  }
  (2 + multiple, low + multiple * width, width)
}

///|
fn WavpackWordsWriter::sample(
  self : WavpackWordsWriter,
  channel : Int32,
  sample : Int32,
) -> Unit {
  if self.channels[0].median[0] < 2 &&
    self.channels[1].median[0] < 2 &&
    !self.unary_zero {
    if sample == 0 {
      if self.zero_run == 0 {
        for ch in self.channels {
          ch.median.fill(0)
        }
      }
      self.zero_run += 1
      return
    }
    if self.zero_run > 0 {
      self.flush()
    } else {
      self.bits.write(1, 0U)
    }
  }
  let negative = sample < 0
  let magnitude = if negative { -1 - sample } else { sample }
  let (bucket, low, width) = wavpack_encode_median(
    self.channels[channel],
    magnitude,
  )
  let mut ones = bucket
  if self.unary_zero {
    if ones > 0 {
      self.unary_ones += 1
    }
    self.flush()
    self.unary_zero = ones > 0
    if ones > 0 {
      ones -= 1
    }
  } else {
    self.unary_zero = true
  }
  self.unary_ones = ones * 2
  if width > 1 {
    let bits = wavpack_log2(width - 1)
    let extra = (2 << bits) - width
    let index = magnitude - low
    if index < extra {
      self.tail = index.reinterpret_as_uint()
      self.tail_bits = bits
    } else {
      let code = index + extra
      self.tail = ((code >> 1) | ((code & 1) << bits)).reinterpret_as_uint()
      self.tail_bits = bits + 1
    }
  }
  if negative {
    self.tail = self.tail | (1U << self.tail_bits)
  }
  self.tail_bits += 1
  if !self.unary_zero {
    self.flush()
  }
}

///|
fn wavpack_write_le(out : Array[Byte], value : UInt32, bytes : Int32) -> Unit {
  for i in 0..<bytes {
    out.push((value >> (8 * i)).to_byte())
  }
}

///|
fn wavpack_write_metadata(
  out : Array[Byte],
  kind : Int32,
  data : Array[Byte],
) -> Unit {
  let words = (data.length() + 1) / 2
  let odd = (data.length() & 1) != 0
  let long = words > 255
  let tag = kind | (if odd { 0x40 } else { 0 }) | (if long { 0x80 } else { 0 })
  out.push(tag.to_byte())
  wavpack_write_le(out, words.reinterpret_as_uint(), if long { 3 } else { 1 })
  for byte in data {
    out.push(byte)
  }
  if odd {
    out.push(b'\x00')
  }
}

///|
fn wavpack_encode_block(
  out : Array[Byte],
  pcm : ArrayView[Int32],
  channels : Int32,
  bits : Int32,
  rate : Int32,
  rate_index : Int32,
  start : Int32,
  total : Int32,
) -> Unit {
  let words : WavpackWordsWriter = {
    bits: WavpackBitWriter::new(),
    channels: [wavpack_channel_new(), wavpack_channel_new()],
    zero_run: 0,
    unary_ones: 0,
    unary_zero: false,
    tail: 0U,
    tail_bits: 0,
  }
  let weights : FixedArray[Int32] = [0, 0]
  let previous : FixedArray[Int32] = [0, 0]
  let padded = bits == 32 && pcm.all(sample => (sample & 0xFF) == 0)
  let extra : Array[Byte] = [b'\x00', b'\x00', b'\x00', b'\x00']
  let mut crc = 0xFFFFFFFFU
  let mut extra_crc = 0xFFFFFFFFU
  let mut magnitude = 0
  let mut channel = 0
  for original in pcm {
    let sample = if bits == 32 { original >> 8 } else { original }
    let unsigned = sample.reinterpret_as_uint()
    crc = crc * 3U + unsigned
    if bits == 32 && !padded {
      let value = original.reinterpret_as_uint()
      extra_crc = extra_crc * 9U + (value & 65535U) * 3U + (value >> 16)
      extra.push(value.to_byte())
    }
    magnitude = magnitude | (if sample < 0 { -1 - sample } else { sample })
    // Term 1 uses the previous reconstructed sample with a delta of 2.
    let pred = previous[channel]
    let weight = weights[channel]
    let residual = sample -
      ((weight.to_int64() * pred.to_int64() + 512L) >> 10).to_int()
    if pred != 0 && residual != 0 {
      weights[channel] = weight + (if (pred ^ residual) < 0 { -2 } else { 2 })
    }
    previous[channel] = sample
    words.sample(channel, residual)
    channel += 1
    if channel == channels {
      channel = 0
    }
  }
  words.flush()
  let metadata : Array[Byte] = []
  if rate_index == 15 {
    let custom : Array[Byte] = []
    wavpack_write_le(custom, rate.reinterpret_as_uint(), 3)
    wavpack_write_metadata(metadata, 0x27, custom)
  }
  wavpack_write_metadata(metadata, 2, [b'\x46'])
  wavpack_write_metadata(metadata, 3, [])
  wavpack_write_metadata(metadata, 4, [])
  wavpack_write_metadata(metadata, 5, Array::make(6 * channels, b'\x00'))
  if bits == 32 {
    // Left-justified 24-bit source PCM can restore the low byte by shift.
    let int32_info = if padded {
      [b'\x00', b'\x08', b'\x00', b'\x00']
    } else {
      [b'\x08', b'\x00', b'\x00', b'\x00']
    }
    wavpack_write_metadata(metadata, 9, int32_info)
  }
  wavpack_write_metadata(metadata, 10, words.bits.finish())
  if bits == 32 && !padded {
    for i in 0..<4 {
      extra[i] = (extra_crc >> (8 * i)).to_byte()
    }
    wavpack_write_metadata(metadata, 12, extra)
  }
  for byte in b"wvpk" {
    out.push(byte)
  }
  let mag_bits = if magnitude == 0 { 0 } else { wavpack_log2(magnitude) + 1 }
  let flags = (bits / 8 - 1) |
    (if channels == 1 { 4 } else { 0 }) |
    (if bits == 32 { 0x100 } else { 0 }) |
    0x1800 |
    (mag_bits << 18) |
    (rate_index << 23)
  wavpack_write_le(out, (24 + metadata.length()).reinterpret_as_uint(), 4)
  wavpack_write_le(out, 0x410U, 4)
  wavpack_write_le(out, total.reinterpret_as_uint(), 4)
  wavpack_write_le(out, start.reinterpret_as_uint(), 4)
  wavpack_write_le(out, (pcm.length() / channels).reinterpret_as_uint(), 4)
  wavpack_write_le(out, flags.reinterpret_as_uint(), 4)
  wavpack_write_le(out, crc, 4)
  for byte in metadata {
    out.push(byte)
  }
}

///|
/// Encode a complete lossless WavPack file from interleaved signed PCM.
/// Pass right-justified samples for 16- and 24-bit input. 32-bit input
/// retains every bit. Accepts mono or stereo and independent blocks.
pub fn ff_wavpack_encode(
  samples : ArrayView[Int32],
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
  block_samples~ : Int32 = 4096,
) -> Result[Bytes, String] {
  if channels < 1 ||
    channels > 2 ||
    samples.is_empty() ||
    samples.length() % channels != 0 {
    return Err("wavpack: expected nonempty interleaved mono or stereo PCM")
  }
  if sample_rate <= 0 ||
    sample_rate > 0xFFFFFF ||
    block_samples < 1 ||
    block_samples > 32768 {
    return Err("wavpack: invalid sample rate or block size")
  }
  if bits != 16 && bits != 24 && bits != 32 {
    return Err("wavpack: expected 16-, 24- or 32-bit integer PCM")
  }
  if bits != 32 {
    let limit = 1 << (bits - 1)
    for sample in samples {
      if sample < -limit || sample >= limit {
        return Err("wavpack: sample exceeds declared bit depth")
      }
    }
  }
  let mut rate_index = 15
  for i in 0..<15 {
    if wavpack_rates[i] == sample_rate {
      rate_index = i
      break
    }
  }
  let total = samples.length() / channels
  let output : Array[Byte] = []
  let mut start = 0
  while start < total {
    let end = start + (total - start).min(block_samples)
    wavpack_encode_block(
      output,
      samples[start * channels:end * channels],
      channels,
      bits,
      sample_rate,
      rate_index,
      start,
      total,
    )
    start = end
  }
  Ok(Bytes::from_array(output))
}
