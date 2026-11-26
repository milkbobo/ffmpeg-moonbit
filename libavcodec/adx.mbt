///|
/// CRI ADX parameters and second-order ADPCM synthesis from FFmpeg's
/// adx.c and adxdec.c. Copyright BERO and Justin Ruggles. LGPL-2.1-or-later.
pub struct AdxHeader {
  header_bytes : Int32
  sample_rate : Int32
  channels : Int32
  cutoff : Int32
}

///|
/// Parse the complete header of an unencrypted, encoding-type-3 ADX stream.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_adx_header(b""[:]) is Err(_))
/// }
/// ```
pub fn parse_adx_header(data : BytesView) -> Result[AdxHeader, String] {
  if data.length() < 24 || data[0] != b'\x80' || data[1] != b'\x00' {
    return Err("adx: invalid header signature")
  }
  let header_bytes = ((data[2].to_int() << 8) | data[3].to_int()) + 4
  if header_bytes < 24 ||
    header_bytes > data.length() ||
    data[header_bytes - 6:header_bytes] != b"(c)CRI" {
    return Err("adx: invalid copyright offset")
  }
  if data[4:7] != b"\x03\x12\x04" || data[19] != b'\x00' {
    return Err("adx: unsupported encoding or encryption")
  }
  let channels = data[7].to_int()
  if channels < 1 || channels > 6 {
    return Err("adx: invalid channel count")
  }
  let sample_rate = (data[8].to_int() << 24) |
    (data[9].to_int() << 16) |
    (data[10].to_int() << 8) |
    data[11].to_int()
  if sample_rate < 1 || sample_rate > 0x7fffffff / (channels * 18 * 8) {
    return Err("adx: invalid sample rate")
  }
  let cutoff = (data[16].to_int() << 8) | data[17].to_int()
  Ok({ header_bytes, sample_rate, channels, cutoff, })
}

///|
/// A stateful ADX predictor. Keep one decoder for consecutive packets.
pub struct AdxDecoder {
  header : AdxHeader
  coeff1 : Int32
  coeff2 : Int32
  last : FixedArray[Int32]
  penultimate : FixedArray[Int32]
}

///|
/// Initialize the ADX predictor from the container's codec header.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.adx_decoder_new(b"") is Err(_))
/// }
/// ```
pub fn adx_decoder_new(extradata : Bytes) -> Result[AdxDecoder, String] {
  let header = match parse_adx_header(extradata[:]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let root2 = 2.0.sqrt()
  let b = root2 - 1.0
  let angle = 2.0 *
    @math.PI *
    header.cutoff.to_double() /
    header.sample_rate.to_double()
  let a = root2 - @math.cos(angle)
  let c = (a - ((a + b) * (a - b)).sqrt()) / b
  // The coefficient calculation is double until the lrintf argument.
  let coeff1 = aac_lrintf(Float::from_double(c * 2.0 * 4096.0).to_double())
  let coeff2 = aac_lrintf(Float::from_double(-(c * c) * 4096.0).to_double())
  Ok({
    header,
    coeff1,
    coeff2,
    last: FixedArray::make(header.channels, 0),
    penultimate: FixedArray::make(header.channels, 0),
  })
}

///|
/// Decode whole channel-block groups to planar signed 16-bit PCM. ADX
/// terminal blocks are removed by the demuxer.
pub fn AdxDecoder::decode_packet(
  self : AdxDecoder,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  let channels = self.header.channels
  let stride = channels * 18
  if data.is_empty() || data.length() % stride != 0 {
    return Err("adx: incomplete channel block")
  }
  let groups = data.length() / stride
  // Check all scales before updating history so a rejected packet can be retried.
  for block in 0..<(groups * channels) {
    if (data[block * 18].to_int() & 0x80) != 0 {
      return Err("adx: terminal marker in PCM block group")
    }
  }
  Ok(
    Array::makei(channels, ch => {
      let pcm = Array(capacity=groups * 32)
      let mut last = self.last[ch]
      let mut penultimate = self.penultimate[ch]
      for group in 0..<groups {
        let offset = group * stride + ch * 18
        let scale = (data[offset].to_int() << 8) | data[offset + 1].to_int()
        for sample in 0..<32 {
          let byte = data[offset + 2 + sample / 2].to_int()
          let nibble = if sample % 2 == 0 { byte >> 4 } else { byte & 15 }
          let delta = (nibble << 28 >> 28) * scale
          let prediction = (self.coeff1 * last + self.coeff2 * penultimate) >>
            12
          penultimate = last
          last = clip_int16(delta + prediction)
          pcm.push(last)
        }
      }
      self.last[ch] = last
      self.penultimate[ch] = penultimate
      pcm
    }),
  )
}
