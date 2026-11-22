///|
/// Shorten lossless PCM decoder, ported from FFmpeg libavcodec/shorten.c
/// (LGPL-2.1-or-later). Input is a whole raw .shn stream.
priv suberror ShortenError {
  ShortenEof
  ShortenInvalid(String)
}

///|
/// Interleaved PCM. 8-bit values are unsigned, 16-bit values signed.
pub struct ShortenAudio {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Array[Int32]
}

///|
/// Interleaved U8 or S16LE bytes at the decoded sample depth.
pub fn ShortenAudio::pcm_bytes(self : ShortenAudio) -> Bytes {
  if self.bits == 8 {
    Bytes::makei(self.samples.length(), i => self.samples[i].to_byte())
  } else {
    Bytes::makei(self.samples.length() * 2, i => {
      (self.samples[i / 2] >> (i % 2 * 8)).to_byte()
    })
  }
}

///|
fn shorten_uvar(reader : BitReader, width : Int32) -> UInt32 raise ShortenError {
  let mut zeros = 0UL
  while reader.bits_left() > 0 {
    if reader.read1() == 1U {
      guard reader.bits_left() >= width else { raise ShortenEof }
      let value = (zeros << width) | reader.read(width).to_uint64()
      guard value <= 0xFFFFFFFFUL else {
        raise ShortenInvalid("Rice code overflows 32 bits")
      }
      return value.to_uint()
    }
    zeros += 1UL
  }
  raise ShortenEof
}

///|
fn shorten_svar(reader : BitReader, width : Int32) -> Int32 raise ShortenError {
  let value = shorten_uvar(reader, width + 1)
  (value >> 1).reinterpret_as_int() ^ -(value & 1U).reinterpret_as_int()
}

///|
fn shorten_uint(
  reader : BitReader,
  version : Int32,
  width : Int32,
) -> Int32 raise ShortenError {
  let width = if version == 0 {
    width
  } else {
    shorten_uvar(reader, 2).reinterpret_as_int()
  }
  guard width >= 0 && width <= 31 else {
    raise ShortenInvalid("invalid header integer width")
  }
  let value = shorten_uvar(reader, width).reinterpret_as_int()
  guard value >= 0 else { raise ShortenInvalid("invalid header integer") }
  value
}

///|
/// Read a bounded integer from the already validated verbatim header.
fn shorten_header_uint(
  data : Bytes,
  at : Int32,
  width : Int32,
  little : Bool,
) -> UInt64 {
  let mut out = 0UL
  for i in 0..<width {
    let shift = if little { i * 8 } else { (width - 1 - i) * 8 }
    out = out | (data[at + i].to_uint().to_uint64() << shift)
  }
  out
}

///|
fn shorten_header_format(
  data : Bytes,
) -> (Int32, Int32, Bool) raise ShortenError {
  let little = data[:4] == b"RIFF"[:]
  let form = data[8:12]
  let swap = !little && form == b"AIFC"[:]
  guard (little && form == b"WAVE"[:]) ||
    (data[:4] == b"FORM"[:] && (form == b"AIFF"[:] || swap)) else {
    raise ShortenInvalid("unsupported embedded PCM header")
  }
  let mut pos = 12
  while data.length() - pos >= 8 {
    let tag = data[pos:pos + 4]
    let size = shorten_header_uint(data, pos + 4, 4, little)
    pos += 8
    if (little && tag == b"fmt "[:]) || (!little && tag == b"COMM"[:]) {
      let needed = if little { 16 } else { 18 }
      guard size >= needed.to_uint64() && data.length() - pos >= needed else {
        raise ShortenInvalid("truncated PCM format chunk")
      }
      let (rate, bits) = if little {
        guard shorten_header_uint(data, pos, 2, true) == 1UL else {
          raise ShortenInvalid("embedded WAV is not PCM")
        }
        (
          shorten_header_uint(data, pos + 4, 4, true),
          shorten_header_uint(data, pos + 14, 2, true),
        )
      } else {
        let exp = shorten_header_uint(data, pos + 8, 2, false).to_int() - 16446
        let mantissa = shorten_header_uint(data, pos + 10, 8, false)
        guard exp < 0 && exp >= -63 else {
          raise ShortenInvalid("invalid AIFF sample rate")
        }
        let rate = (mantissa >> -exp) + ((mantissa >> (-exp - 1)) & 1UL)
        (rate, shorten_header_uint(data, pos + 6, 2, false))
      }
      guard rate > 0UL && rate <= 2147483647UL && (bits == 8UL || bits == 16UL) else {
        raise ShortenInvalid("unsupported PCM sample rate or depth")
      }
      return (rate.to_int(), bits.to_int(), swap)
    }
    let padded = size + (size & 1UL)
    guard padded <= (data.length() - pos).to_uint64() else { break }
    pos += padded.to_int()
  }
  raise ShortenInvalid("missing PCM format chunk")
}

///|
priv struct ShortenChannel {
  buffer : FixedArray[Int32]
  means : FixedArray[Int32]
  mut mean_sum : Int32
  mut mean_index : Int32
  mut shift : Int32
}

///|
priv struct ShortenDecoder {
  reader : BitReader
  version : Int32
  rate : Int32
  bits : Int32
  swap : Bool
  channels : FixedArray[ShortenChannel]
  coeffs : FixedArray[Int32]
  wrap : Int32
  mean_count : Int32
  mut block_size : Int32
  mut shift : Int32
}

///|
fn ShortenDecoder::open(data : Bytes) -> ShortenDecoder raise ShortenError {
  guard data.length() >= 5 &&
    data.length() <= 268435455 &&
    data[:4] == b"ajkg"[:] else {
    raise ShortenInvalid("invalid stream signature or size")
  }
  let version = data[4].to_int()
  let reader = BitReader::new(data)
  reader.skip(40)
  let format = shorten_uint(reader, version, 4)
  let channels = shorten_uint(reader, version, 0)
  guard (format == 2 || format == 3 || format == 5) &&
    channels >= 1 &&
    channels <= 8 else {
    raise ShortenInvalid("unsupported PCM type or channel count")
  }
  let (block_size, max_lpc, mean_count) = if version == 0 {
    (256, 0, -1)
  } else {
    let block_size = shorten_uint(reader, version, 8)
    let max_lpc = shorten_uint(reader, version, 2)
    let mean_count = shorten_uint(reader, version, 0)
    let skip = shorten_uint(reader, version, 1)
    guard skip <= reader.bits_left() / 8 else { raise ShortenEof }
    reader.skip(skip * 8)
    (block_size, max_lpc, mean_count)
  }
  guard block_size >= 1 &&
    block_size <= 65535 &&
    max_lpc <= 1024 &&
    mean_count <= 32768 else {
    raise ShortenInvalid("invalid block size, predictor or mean window")
  }
  guard shorten_uvar(reader, 2) == 9U else {
    raise ShortenInvalid("missing verbatim PCM header")
  }
  let size = shorten_uvar(reader, 5)
  guard size >= 44U && size < 16384U else {
    raise ShortenInvalid("invalid verbatim PCM header size")
  }
  let header : Array[Byte] = Array(capacity=size.reinterpret_as_int())
  for _ in 0..<size.reinterpret_as_int() {
    header.push(shorten_uvar(reader, 8).to_byte())
  }
  let (rate, bits, swap) = shorten_header_format(Bytes::from_array(header))
  let initial_mean = if format == 2 { 128 } else { 0 }
  guard (format == 2) == (bits == 8) else {
    raise ShortenInvalid("PCM header and coded sample depth disagree")
  }
  let wrap = max_lpc.max(3)
  let state = FixedArray::makei(channels, _ => ShortenChannel::{
    buffer: FixedArray::make(wrap + block_size, 0),
    means: FixedArray::make(mean_count.max(1), initial_mean),
    mean_sum: initial_mean * mean_count.max(1),
    mean_index: 0,
    shift: 0,
  })
  {
    reader,
    version,
    rate,
    bits,
    swap,
    channels: state,
    coeffs: FixedArray::make(wrap, 0),
    wrap,
    mean_count,
    block_size,
    shift: 0,
  }
}

///|
fn ShortenDecoder::offset(
  self : ShortenDecoder,
  channel : ShortenChannel,
) -> Int32 {
  if self.mean_count < 0 {
    return 0
  }
  if self.mean_count == 0 {
    return channel.means[0]
  }
  let rounding = if self.version >= 2 { self.mean_count / 2 } else { 0 }
  let mean = (channel.mean_sum + rounding) / self.mean_count
  if self.version < 2 {
    mean
  } else {
    mean >> self.shift.min(31)
  }
}

///|
let shorten_fixed_lpc : ReadOnlyArray[ReadOnlyArray[Int32]] = [
  [],
  [1],
  [2, -1],
  [3, -3, 1],
]

///|
fn ShortenDecoder::decode_channel(
  self : ShortenDecoder,
  channel : ShortenChannel,
  cmd : Int32,
) -> Unit raise ShortenError {
  let buffer = channel.buffer
  let first = self.wrap
  let end = first + self.block_size
  if cmd == 8 {
    for i in first..<end {
      buffer[i] = 0
    }
  } else {
    let residual = shorten_uvar(self.reader, 3).reinterpret_as_int() -
      (if self.version == 0 { 1 } else { 0 })
    guard residual >= 0 && residual <= 30 else {
      raise ShortenInvalid("invalid residual width")
    }
    let lpc = cmd == 7
    let order = if lpc {
      let order = shorten_uvar(self.reader, 2)
      guard order <= self.wrap.reinterpret_as_uint() else {
        raise ShortenInvalid("invalid LPC order")
      }
      let order = order.reinterpret_as_int()
      for i in 0..<order {
        self.coeffs[i] = shorten_svar(self.reader, 5)
      }
      order
    } else {
      for i in 0..<cmd {
        self.coeffs[i] = shorten_fixed_lpc[cmd][i]
      }
      cmd
    }
    let offset = self.offset(channel)
    if lpc {
      for i in (first - order)..<first {
        buffer[i] -= offset
      }
    }
    let initial = if order == 0 {
      offset
    } else if lpc && self.version >= 2 {
      32
    } else {
      0
    }
    let q = if lpc { 5 } else { 0 }
    for i in first..<end {
      let mut prediction = initial
      for j in 0..<order {
        prediction += self.coeffs[j] * buffer[i - j - 1]
      }
      buffer[i] = shorten_svar(self.reader, residual) + (prediction >> q)
    }
    if lpc {
      for i in first..<end {
        buffer[i] += offset
      }
    }
  }
  if self.mean_count > 0 {
    let mut sum = if self.version >= 2 {
      self.block_size.to_int64() / 2L
    } else {
      0L
    }
    for i in first..<end {
      sum += buffer[i].to_int64()
    }
    let mean = (sum / self.block_size.to_int64()).to_int()
    let mean = if self.version < 2 {
      mean
    } else if self.shift == 32 {
      0
    } else {
      mean << self.shift
    }
    let index = channel.mean_index
    channel.mean_sum += mean - channel.means[index]
    channel.means[index] = mean
    channel.mean_index = (index + 1) % self.mean_count
  }
  // Copy in increasing order so overlapping history remains valid.
  for i in 0..<first {
    buffer[i] = buffer[self.block_size + i]
  }
  channel.shift = self.shift
}

///|
fn ShortenDecoder::decode_block(
  self : ShortenDecoder,
  output : Array[Int32],
  budget : Int64?,
) -> Bool raise ShortenError {
  let mut ch = 0
  while ch < self.channels.length() {
    match shorten_uvar(self.reader, 2) {
      0U | 1U | 2U | 3U | 7U | 8U as cmd => {
        if budget is Some(limit) &&
          output.length().to_int64() +
          self.block_size.to_int64() * self.channels.length().to_int64() >
          limit {
          raise ShortenInvalid("decoded audio sample budget exceeded")
        }
        self.decode_channel(self.channels[ch], cmd.reinterpret_as_int())
        ch += 1
      }
      4U => {
        guard ch == 0 else { raise ShortenInvalid("incomplete channel group") }
        return false
      }
      5U => {
        let mut width = 0
        while self.block_size >> (width + 1) != 0 {
          width += 1
        }
        let block_size = shorten_uint(self.reader, self.version, width)
        guard ch == 0 && block_size > 0 && block_size <= self.block_size else {
          raise ShortenInvalid("invalid block size change")
        }
        self.block_size = block_size
      }
      6U => {
        let shift = shorten_uvar(self.reader, 2)
        guard shift <= 32U else { raise ShortenInvalid("invalid sample shift") }
        self.shift = shift.reinterpret_as_int()
      }
      9U => {
        let size = shorten_uvar(self.reader, 5)
        guard size <= (self.reader.bits_left() / 9).reinterpret_as_uint() else {
          raise ShortenEof
        }
        for _ in 0..<size.reinterpret_as_int() {
          let _ = shorten_uvar(self.reader, 8)
        }
      }
      _ => raise ShortenInvalid("unknown audio command")
    }
  }
  for i in self.wrap..<(self.wrap + self.block_size) {
    for channel in self.channels {
      let value = if channel.shift == 32 {
        0
      } else {
        channel.buffer[i] << channel.shift
      }
      if self.bits == 8 {
        output.push(value.max(0).min(255))
      } else {
        let value = value.max(-32768).min(32767)
        if self.swap {
          let swapped = ((value & 255) << 8) | ((value >> 8) & 255)
          output.push(swapped << 16 >> 16)
        } else {
          output.push(value)
        }
      }
    }
  }
  true
}

///|
/// Decode raw Shorten PCM. By default the stream must contain a quit command.
/// Set allow_truncated to recover complete blocks from a cut-off stream.
/// The optional budget counts interleaved samples across all channels.
pub fn ff_shorten_decode(
  data : Bytes,
  allow_truncated~ : Bool = false,
  sample_budget? : Int64,
) -> Result[ShortenAudio, String] {
  let samples : Array[Int32] = []
  try {
    let decoder = ShortenDecoder::open(data)
    for ;; {
      let more = decoder.decode_block(samples, sample_budget) catch {
        ShortenEof if allow_truncated && !samples.is_empty() => false
        e => raise e
      }
      if !more {
        break
      }
    }
    Ok({
      sample_rate: decoder.rate,
      channels: decoder.channels.length(),
      bits: decoder.bits,
      samples,
    })
  } catch {
    ShortenInvalid(message) => Err("shorten: \{message}")
    ShortenEof => Err("shorten: truncated stream")
  }
}
