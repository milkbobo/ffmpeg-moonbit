///|
/// LOAS framing from FFmpeg 9.0.2 latmenc.c (LGPL-2.1-or-later).
pub struct LoasAacMuxer {
  priv asc : Bytes
  priv asc_bits : Int32
  priv config_interval : Int32
  priv mut until_config : Int32
  priv output : Array[Byte]
}

///|
/// Create a LOAS muxer for fixed AAC-LC with an explicit channel configuration.
pub fn LoasAacMuxer::new(
  asc : Bytes,
  config_interval~ : Int32 = 20,
) -> Result[LoasAacMuxer, String] {
  guard config_interval >= 1 && config_interval <= 65535 else {
    return Err("latm: config interval must be in 1..=65535")
  }
  let parsed = match @libavcodec.aac_parse_audio_specific_config(asc) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard parsed.config.chan_config != 0 else {
    return Err("latm: muxing requires an explicit channel configuration")
  }
  Ok({
    asc,
    asc_bits: parsed.bits_consumed,
    config_interval,
    until_config: 0,
    output: [],
  })
}

///|
/// Add a raw AAC access unit, without its ADTS header.
pub fn LoasAacMuxer::write_packet(
  self : LoasAacMuxer,
  payload : BytesView,
) -> Result[Unit, String] {
  let size = payload.length()
  guard size > 0 && size <= 0x1fff else {
    return Err("latm: invalid AAC packet size")
  }
  let bits = @libavcodec.BitWriter::new()
  let config = self.until_config == 0
  bits.put_bit(if config { 0 } else { 1 })
  if config {
    bits.put_bit(0) // audioMuxVersion
    bits.put_bit(1) // allStreamsSameTimeFraming
    bits.put(0U, 6 + 4 + 3) // one subframe, program, and layer
    let asc = @libavcodec.BitReader::new(self.asc)
    for _ in 0..<self.asc_bits {
      bits.put(asc.read1(), 1)
    }
    bits.put(0U, 3) // frameLengthType
    bits.put(255U, 8) // latmBufferFullness
    bits.put(0U, 2) // otherDataPresent, crcCheckPresent
  }
  for _ in 0..<(size / 255) {
    bits.put(255U, 8)
  }
  bits.put((size % 255).reinterpret_as_uint(), 8)
  // Like FFmpeg, clear the byte-aligned flag on a leading AAC data-stream
  // element when moving it from a byte-aligned access unit into LATM.
  let first = payload[0].to_int()
  bits.put(
    (if (first & 0xe1) == 0x81 { first & 0xfe } else { first }).reinterpret_as_uint(),
    8,
  )
  for i in 1..<size {
    bits.put(payload[i].to_int().reinterpret_as_uint(), 8)
  }
  let frame = bits.finish()
  let len = frame.length()
  guard len <= 0x1fff && self.output.length() <= 0x7fffffff - len - 3 else {
    return Err("latm: LOAS frame or stream exceeds its size limit")
  }
  self.output.push(0x56)
  self.output.push((0xe0 | (len >> 8)).to_byte())
  self.output.push(len.to_byte())
  for byte in frame {
    self.output.push(byte)
  }
  self.until_config = if config {
    self.config_interval - 1
  } else {
    self.until_config - 1
  }
  Ok(())
}

///|
pub fn LoasAacMuxer::finish(self : LoasAacMuxer) -> Bytes {
  Bytes::from_array(self.output)
}

///|
/// Remux continuous AAC-LC ADTS frames to LOAS without re-encoding.
pub fn av_loas_from_adts(data : Bytes) -> Result[Bytes, String] {
  let mut pos = id3_skip(data)
  let mut config = None
  let mut mux = None
  while pos < data.length() {
    let header_size = @libavcodec.av_aac_adts_header_size
    guard data.length() - pos >= header_size else {
      return Err("latm: truncated ADTS header")
    }
    let header = match
      @libavcodec.ff_adts_header_parse_buf(
        data[pos:pos + header_size].to_owned(),
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let skip = header_size + (if header.crc_absent == 0 { 2 } else { 0 })
    guard header.object_type == 2 &&
      header.chan_config != 0 &&
      header.num_aac_frames == 1 else {
      return Err(
        "latm: expected one AAC-LC block with an explicit ADTS channel configuration",
      )
    }
    guard header.frame_length > skip &&
      header.frame_length <= data.length() - pos else {
      return Err("latm: missing or truncated ADTS payload")
    }
    let key = (header.sampling_index, header.chan_config)
    if mux is None {
      let (rate, ch) = key
      let asc = Bytes::from_array([
        (0x10 | (rate >> 1)).to_byte(),
        (((rate & 1) << 7) | (ch << 3)).to_byte(),
      ])
      match LoasAacMuxer::new(asc) {
        Ok(value) => mux = Some(value)
        Err(error) => return Err(error)
      }
      config = Some(key)
    }
    guard config == Some(key) else {
      return Err("latm: changing ADTS configuration")
    }
    let end = pos + header.frame_length
    match mux.unwrap().write_packet(data[pos + skip:end]) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    pos = end
  }
  match mux {
    Some(value) => Ok(value.finish())
    None => Err("latm: missing ADTS frames")
  }
}

///|
/// Encode mono or stereo PCM as AAC-LC in LOAS, including AAC priming and
/// the final zero padding required to complete a 1024-sample block.
pub fn DecodedAudio::to_loas(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("LOAS AAC-LC export requires mono or stereo")
  }
  let asc = Bytes::from_array(mp4_av_asc(self.sample_rate, self.channels))
  let mux = match LoasAacMuxer::new(asc) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  self.encode_aac_lc(payload => mux.write_packet(payload))
  mux.finish()
}

///|
fn DecodedAudio::encode_aac_lc(
  self : DecodedAudio,
  write : (BytesView) -> Result[Unit, String],
) -> Unit raise MediaError {
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("aac: no PCM samples") }
  let encoder = match
    @libavcodec.aac_encoder_new(
      @libavcodec.aac_encode_config_perceptual(
        self.sample_rate,
        self.channels,
        64000 * self.channels,
      ),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  let emit = fn(packet : Bytes) {
    // The encoder produces a single raw block and a CRC-free ADTS header.
    write(packet[@libavcodec.av_aac_adts_header_size:])
  }
  for start = 0; start < frames; {
    let count = (frames - start).min(1024)
    let block = self.samples.map(plane => {
      Array::makei(1024, i => if i < count { plane[start + i] } else { 0.0 })
    })
    match encoder.encode_frame(block) {
      Ok(Some(packet)) =>
        if emit(packet) is Err(error) {
          raise DecodeError(error)
        }
      Ok(None) => ()
      Err(error) => raise DecodeError(error)
    }
    continue start + count
  }
  match encoder.flush() {
    Ok(packets) =>
      for packet in packets {
        if emit(packet) is Err(error) {
          raise DecodeError(error)
        }
      }
    Err(error) => raise DecodeError(error)
  }
}
