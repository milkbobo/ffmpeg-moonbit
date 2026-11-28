///|
/// ESDS FullBox body for the AAC magic cookie.
fn caf_mux_aac_cookie(asc : Bytes) -> Array[Byte] {
  // MPEG-4 Audio, audio stream, then zero buffer size and bitrates.
  let config = b"\x40\x15\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x05".to_array()
  caf_mux_descr_len(config, asc.length())
  config.append(asc.to_array())
  let es = b"\x00\x01\x00\x04".to_array()
  caf_mux_descr_len(es, config.length())
  es.append(config)
  es.append([0x06, 0x01, 0x02]) // SLConfigDescriptor
  let cookie = b"\x00\x00\x00\x00\x03".to_array()
  caf_mux_descr_len(cookie, es.length())
  cookie.append(es)
  cookie
}

///|
/// Write raw AAC-LC access units, one raw data block per packet, with their
/// AudioSpecificConfig. Presentation counts are PCM samples per channel.
pub fn av_caf_mux_aac(
  asc : Bytes,
  packets : Array[Bytes],
  priming~ : Int32 = 0,
  valid_frames? : Int64,
) -> Result[Bytes, String] {
  guard asc.length() <= 0x1ffffff &&
    !packets.is_empty() &&
    packets.length() <= 16777216 &&
    priming >= 0 else {
    return Err("caf: invalid AAC configuration, packet count or priming")
  }
  let config = match @libavcodec.aac_parse_audio_specific_config(asc) {
    Ok(parsed) => parsed.config
    Err(error) => return Err(error)
  }
  let frames = config.frame_length
  let available = packets.length().to_int64() * frames.to_int64() -
    priming.to_int64()
  let valid = valid_frames.unwrap_or(available)
  guard valid > 0L &&
    valid <= available &&
    available - valid < frames.to_int64() else {
    return Err("caf: invalid AAC presentation length")
  }
  let pakt : Array[Byte] = []
  caf_mux_u64be(pakt, packets.length().to_uint64())
  caf_mux_u64be(pakt, valid.reinterpret_as_uint64())
  caf_mux_u32be(pakt, priming.reinterpret_as_uint())
  caf_mux_u32be(pakt, (available - valid).to_int().reinterpret_as_uint())
  let mut size = 0L
  for packet in packets {
    guard packet.length() > 0 && packet.length() <= 0xfffffff else {
      return Err("caf: invalid AAC packet length")
    }
    size += packet.length().to_int64()
    caf_mux_descr_len(pakt, packet.length())
  }
  let cookie = caf_mux_aac_cookie(asc)
  guard size + pakt.length().to_int64() + cookie.length().to_int64() <=
    0x7fffffffL - 104L else {
    return Err("caf: AAC output is too large")
  }
  let desc : Array[Byte] = []
  caf_mux_double(desc, config.sample_rate.to_double())
  caf_mux_tag(desc, "aac ")
  caf_mux_u32be(desc, 0U)
  caf_mux_u32be(desc, 0U) // variable bytes per packet
  caf_mux_u32be(desc, frames.reinterpret_as_uint())
  caf_mux_u32be(desc, config.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U)
  let out = b"caff\x00\x01\x00\x00".to_array()
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "kuki", cookie)
  caf_mux_chunk(out, "pakt", pakt)
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, (size + 4L).reinterpret_as_uint64())
  caf_mux_u32be(out, 0U)
  for packet in packets {
    for byte in packet {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode mono or stereo PCM as AAC-LC CAF at the track's sample rate.
pub fn DecodedAudio::to_caf_aac(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("CAF AAC-LC export requires mono or stereo")
  }
  let packets : Array[Bytes] = []
  self.encode_aac_lc(payload => {
    packets.push(payload.to_owned())
    Ok(())
  })
  let asc = Bytes::from_array(mp4_av_asc(self.sample_rate, self.channels))
  match
    av_caf_mux_aac(
      asc,
      packets,
      priming=1024,
      valid_frames=self.samples[0].length().to_int64(),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
