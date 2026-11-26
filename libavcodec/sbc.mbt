///|
/// SBC framing, bit allocation and synthesis from FFmpeg's sbc_parser.c,
/// sbc.c and sbcdec.c. Copyright Aurelien Jacobs, Intel, Nokia, Marcel
/// Holtmann, Henryk Ploetz and Brad Midgley. LGPL-2.1-or-later.
pub struct SbcHeader {
  sample_rate : Int32
  channels : Int32
  subbands : Int32
  blocks : Int32
  frame_bytes : Int32
  msbc : Bool
  frequency_index : Int32
  mode : Int32
  snr : Bool
  bitpool : Int32
}

///|
fn sbc_header_crc(data : BytesView, protected_bits : Int32) -> Int32 {
  let mut crc = 0x0f
  for i in 8..<(32 + protected_bits) {
    // The CRC byte itself is excluded.
    if i >= 24 && i < 32 {
      continue
    }
    let bit = (data[i >> 3].to_int() >> (7 - (i & 7))) & 1
    let top = (crc >> 7) ^ bit
    crc = ((crc << 1) & 255) ^ (top * 0x1d)
  }
  crc
}

///|
/// Read the frame parameters and validate the protected header bits. The
/// caller can use `frame_bytes` to check for a complete payload.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_sbc_header(b""[:]) is Err(_))
/// }
/// ```
pub fn parse_sbc_header(data : BytesView) -> Result[SbcHeader, String] {
  if data.length() < 4 {
    return Err("sbc: truncated header")
  }
  let flags = data[1].to_int()
  let msbc = data[0] == b'\xad'
  if (msbc && (flags != 0 || data[2] != b'\x00')) ||
    (!msbc && data[0] != b'\x9c') {
    return Err("sbc: invalid sync or mSBC header")
  }
  let frequency_index = flags >> 6
  let sample_rate = [16000, 32000, 44100, 48000][frequency_index]
  let mode = (flags >> 2) & 3
  let snr = (flags & 2) != 0
  let blocks = if msbc { 15 } else { ((flags >> 4) & 3) * 4 + 4 }
  let channels = if mode == 0 { 1 } else { 2 }
  let subbands = if msbc || (flags & 1) != 0 { 8 } else { 4 }
  let bitpool = if msbc { 26 } else { data[2].to_int() }
  let independent = mode < 2
  if bitpool > subbands * (if independent { 16 } else { 32 }) {
    return Err("sbc: invalid bitpool")
  }
  let joint_bits = if mode == 3 { subbands } else { 0 }
  let protected_bits = joint_bits + 4 * channels * subbands
  if data.length() < 4 + (protected_bits + 7) / 8 {
    return Err("sbc: truncated scale factors")
  }
  if sbc_header_crc(data, protected_bits) != data[3].to_int() {
    return Err("sbc: header CRC mismatch")
  }
  let audio_bits = blocks * bitpool * (if independent { channels } else { 1 })
  let frame_bytes = 4 + (protected_bits + audio_bits + 7) / 8
  Ok({
    sample_rate,
    channels,
    subbands,
    blocks,
    frame_bytes,
    msbc,
    frequency_index,
    mode,
    snr,
    bitpool,
  })
}

///|
let sbc_loudness_offsets4 : FixedArray[Int32] = [
  -1, 0, 0, 0, -2, 0, 0, 1, -2, 0, 0, 1, -2, 0, 0, 1,
]

///|
let sbc_loudness_offsets8 : FixedArray[Int32] = [
  -2, 0, 0, 0, 0, 0, 0, 1, -3, 0, 0, 0, 0, 0, 1, 2, -4, 0, 0, 0, 0, 0, 1, 2, -4,
  0, 0, 0, 0, 0, 1, 2,
]

///|
/// Allocate a single bitpool, in the order used for distributing leftover
/// bits. Stereo shares its pool in subband-major, channel-minor order.
fn sbc_allocate_pool(
  needs : FixedArray[Int32],
  pool : Int32,
) -> FixedArray[Int32] {
  let mut slice = needs.fold(init=0, (max, need) => max.max(need)) + 1
  let mut used = 0
  let mut pending = 0
  for ;; {
    slice -= 1
    used += pending
    pending = 0
    for need in needs {
      let delta = need - slice
      if delta == 1 {
        pending += 2
      } else if delta > 1 && delta < 16 {
        pending += 1
      }
    }
    if used + pending >= pool {
      break
    }
  }
  if used + pending == pool {
    used += pending
    slice -= 1
  }
  let bits = FixedArray::makei(needs.length(), i => {
    let delta = needs[i] - slice
    if delta < 2 {
      0
    } else {
      delta.min(16)
    }
  })
  for i in 0..<bits.length() {
    if used >= pool {
      break
    }
    if bits[i] >= 2 && bits[i] < 16 {
      bits[i] += 1
      used += 1
    } else if needs[i] == slice + 1 && pool - used >= 2 {
      bits[i] = 2
      used += 2
    }
  }
  for i in 0..<bits.length() {
    if used >= pool {
      break
    }
    if bits[i] < 16 {
      bits[i] += 1
      used += 1
    }
  }
  bits
}

///|
fn sbc_allocate_bits(
  h : SbcHeader,
  scale : FixedArray[Int32],
) -> FixedArray[Int32] {
  let bands = h.subbands
  let offsets = if bands == 4 {
    sbc_loudness_offsets4
  } else {
    sbc_loudness_offsets8
  }
  let needs = FixedArray::makei(scale.length(), i => {
    let factor = scale[i]
    if h.snr {
      factor
    } else if factor == 0 {
      -5
    } else {
      let loudness = factor - offsets[h.frequency_index * bands + i % bands]
      if loudness > 0 {
        loudness / 2
      } else {
        loudness
      }
    }
  })
  let widths = FixedArray::make(scale.length(), 0)
  if h.mode < 2 {
    for ch in 0..<h.channels {
      let pool = sbc_allocate_pool(
        FixedArray::makei(bands, sb => needs[ch * bands + sb]),
        h.bitpool,
      )
      for sb in 0..<bands {
        widths[ch * bands + sb] = pool[sb]
      }
    }
  } else {
    let pool = sbc_allocate_pool(
      FixedArray::makei(needs.length(), i => needs[i % 2 * bands + i / 2]),
      h.bitpool,
    )
    for i in 0..<pool.length() {
      widths[i % 2 * bands + i / 2] = pool[i]
    }
  }
  widths
}

///|
/// Stateful synthesis filter. Use one decoder per stream.
pub struct SbcDecoder {
  history : FixedArray[FixedArray[Int32]]
  offsets : FixedArray[FixedArray[Int32]]
  mut subbands : Int32
}

///|
/// Create a decoder with zero synthesis history.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.sbc_decoder_new().decode_frame(b"") is Err(_))
/// }
/// ```
pub fn sbc_decoder_new() -> SbcDecoder {
  {
    history: FixedArray::makei(2, _ => FixedArray::make(169, 0)),
    offsets: FixedArray::makei(2, _ => FixedArray::makei(16, i => 10 * (i + 1))),
    subbands: 0,
  }
}

///|
fn SbcDecoder::synthesize(
  self : SbcDecoder,
  ch : Int32,
  bands : Int32,
  samples : FixedArray[Int32],
  pcm : Array[Int32],
) -> Unit {
  let history = self.history[ch]
  let offset = self.offsets[ch]
  let matrix = if bands == 4 { synmatrix4 } else { synmatrix8 }
  let ring = bands * 20
  for i in 0..<(bands * 2) {
    offset[i] -= 1
    if offset[i] < 0 {
      offset[i] = ring - 1
      for j in 0..<9 {
        history[ring + j] = history[j]
      }
    }
    // The C uses unsigned products and then an arithmetic shift of the
    // wrapped 32-bit sum. MoonBit Int32 arithmetic has the same wrap.
    let mut sum = 0
    for sb in 0..<bands {
      sum += matrix[i * bands + sb] * samples[ch * bands + sb]
    }
    history[offset[i]] = sum >> 15
  }
  let even = if bands == 4 { sbc_proto_4_40m0 } else { sbc_proto_8_80m0 }
  let odd = if bands == 4 { sbc_proto_4_40m1 } else { sbc_proto_8_80m1 }
  for i in 0..<bands {
    let mut sum = 0
    for j in 0..<5 {
      sum += history[offset[i] + 2 * j] * even[5 * i + j]
      sum += history[offset[i + bands] + 2 * j + 1] * odd[5 * i + j]
    }
    pcm.push(clip_int16(sum >> 15))
  }
}

///|
/// Decode one complete SBC or mSBC frame to signed 16-bit PCM by channel.
pub fn SbcDecoder::decode_frame(
  self : SbcDecoder,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  let h = match parse_sbc_header(data[:]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if data.length() != h.frame_bytes {
    return Err("sbc: incorrect frame size")
  }
  if self.subbands != 0 && self.subbands != h.subbands {
    return Err("sbc: subband count changed")
  }
  let bits = BitReader::new(data)
  bits.skip(32)
  let joint = if h.mode == 3 {
    bits.read(h.subbands).reinterpret_as_int()
  } else {
    0
  }
  let scale = FixedArray::makei(h.channels * h.subbands, _ => {
    bits.read(4).reinterpret_as_int()
  })
  let widths = sbc_allocate_bits(h, scale)
  let levels = FixedArray::makei(scale.length(), i => (1L << widths[i]) - 1L)
  let samples = FixedArray::make(scale.length(), 0)
  let pcm = Array::makei(h.channels, _ => Array(capacity=h.blocks * h.subbands))
  self.subbands = h.subbands
  for _ in 0..<h.blocks {
    for i in 0..<samples.length() {
      samples[i] = if levels[i] == 0L {
        0
      } else {
        let shift = scale[i] + 3
        let code = bits.read(widths[i]).to_int64()
        (((code * 2L + 1L) << shift) / levels[i] - (1L << shift)).to_int()
      }
    }
    if h.mode == 3 {
      for sb in 0..<(h.subbands - 1) {
        if (joint & (1 << (h.subbands - 1 - sb))) != 0 {
          let left = samples[sb]
          let right = samples[h.subbands + sb]
          samples[sb] = left + right
          samples[h.subbands + sb] = left - right
        }
      }
    }
    for ch in 0..<h.channels {
      self.synthesize(ch, h.subbands, samples, pcm[ch])
    }
  }
  Ok(pcm)
}
