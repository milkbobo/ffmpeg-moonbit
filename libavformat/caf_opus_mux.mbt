///|
/// Write mono or stereo Opus packets in CAF. Counts are per channel at 48 kHz.
/// A valid frame count may trim the final packet and omit surplus packets.
pub fn av_caf_mux_opus(
  packets : Array[Bytes],
  channels : Int32,
  priming~ : Int32 = 0,
  valid_frames? : Int64,
) -> Result[Bytes, String] {
  guard (channels == 1 || channels == 2) && priming >= 0 && priming <= 65535 else {
    return Err("caf: invalid Opus channels or priming")
  }
  if valid_frames is Some(valid) && valid <= 0L {
    return Err("caf: invalid Opus presentation length")
  }
  let lengths : Array[Byte] = []
  let mut samples = 0L
  let mut size = 0L
  let mut count = 0
  for packet in packets {
    let parsed = match @libavcodec.opus_parse_packet(packet) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let duration = parsed.total_samples()
    size += packet.length().to_int64()
    guard duration > 0 && packet.length() <= 0xfffffff && size <= 0x7fffffffL else {
      return Err("caf: invalid Opus packet size or duration")
    }
    caf_mux_descr_len(lengths, packet.length())
    caf_mux_descr_len(lengths, duration)
    samples += duration.to_int64()
    count += 1
    if valid_frames is Some(valid) && samples - priming.to_int64() >= valid {
      break
    }
  }
  let available = samples - priming.to_int64()
  let valid = valid_frames.unwrap_or(available)
  guard valid > 0L && valid <= available else {
    return Err("caf: insufficient Opus samples for presentation")
  }
  guard count <= 16777216 &&
    size + lengths.length().to_int64() <= 0x7fffffffL - 135L else {
    return Err("caf: Opus output is too large")
  }
  let desc : Array[Byte] = []
  caf_mux_double(desc, 48000.0)
  caf_mux_tag(desc, "opus")
  caf_mux_u32be(desc, 0U)
  caf_mux_u32be(desc, 0U) // variable bytes per packet
  caf_mux_u32be(desc, 0U) // variable samples per packet
  caf_mux_u32be(desc, channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U)
  let table : Array[Byte] = []
  caf_mux_u64be(table, count.to_uint64())
  caf_mux_u64be(table, valid.reinterpret_as_uint64())
  caf_mux_u32be(table, priming.reinterpret_as_uint())
  caf_mux_u32be(table, (available - valid).to_int().reinterpret_as_uint())
  table.append(lengths)
  let out = b"caff\x00\x01\x00\x00".to_array()
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "kuki", caf_opus_head(channels, 48000, priming).to_array())
  caf_mux_chunk(out, "pakt", table)
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, (size + 4L).reinterpret_as_uint64())
  caf_mux_u32be(out, 0U)
  for i in 0..<count {
    for byte in packets[i] {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode mono or stereo PCM as 48 kHz CAF Opus, resampling when needed.
pub fn DecodedAudio::to_caf_opus(self : DecodedAudio) -> Bytes raise MediaError {
  let (packets, priming, count) = self.encode_opus()
  match
    av_caf_mux_opus(
      packets,
      self.channels,
      priming~,
      valid_frames=count.to_int64(),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}

///|
fn DecodedAudio::encode_opus(
  self : DecodedAudio,
  separate_trims~ : Bool = false,
) -> (Array[Bytes], Int32, Int32) raise MediaError {
  let channels = self.channels
  guard channels == 1 || channels == 2 else {
    raise UnsupportedCodec("Opus export requires mono or stereo")
  }
  let audio = self.resample_to(48000)
  let count = audio.samples[0].length()
  guard count > 0 else { raise DecodeError("opus: no input samples") }
  let encoder = match
    @libavcodec.opus_encoder_new(@libavcodec.opus_encode_config(channels, 0)) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  let block = encoder.frame_size
  let priming = encoder.initial_padding
  // Matroska readers may overwrite final padding metadata when injecting
  // priming on the first packet. Put the two trims on different packets
  // when the whole presentation would otherwise fit in one.
  let lead = if separate_trims && count < block - priming { block } else { 0 }
  let packets : Array[Bytes] = []
  // Feed silence past the final input until the encoder delay has cleared.
  let end = count.to_int64() + priming.to_int64()
  for offset = -lead.to_int64()
      offset < end
      offset = offset + block.to_int64() {
    let remaining = (count.to_int64() - offset).max(0L).to_int()
    let planes = audio.samples.map(plane => {
      Array::makei(block, i => {
        if offset >= 0L && i < remaining {
          Float::from_double(plane[offset.to_int() + i])
        } else {
          0.0F
        }
      })
    })
    match encoder.encode(planes) {
      Ok(Some(packet)) => packets.push(packet)
      Ok(None) => ()
      Err(error) => raise DecodeError(error)
    }
  }
  match encoder.flush() {
    Ok(tail) => packets.append(tail)
    Err(error) => raise DecodeError(error)
  }
  (packets, lead + priming, count)
}
