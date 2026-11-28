///|
/// One ALAC-in-Matroska track: `A_ALAC` with the 24-byte ALACSpecificConfig
/// extracted from the magic cookie and stored in CodecPrivate.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvAlacMuxer {
  cookie : Bytes
  sample_rate : Int32
  channels : Int32
  bits : Int32
  language : String
  events : Array[MkvAudioEvent]
}

///|
pub fn mkv_alac_muxer_new(
  cookie : Bytes,
  language~ : String = "und",
) -> Result[MkvAlacMuxer, String] {
  if cookie.length() < 36 ||
    cookie[4] != b'a' ||
    cookie[5] != b'l' ||
    cookie[6] != b'a' ||
    cookie[7] != b'c' {
    return Err("EINVAL: invalid ALAC magic cookie")
  }
  let sample_rate = caf_u32be(cookie, 32).reinterpret_as_int()
  let channels = cookie[21].to_int()
  let bits = cookie[17].to_int()
  if sample_rate <= 0 || channels < 1 || channels > 8 {
    return Err("EINVAL: invalid Matroska ALAC parameters")
  }
  Ok({
    cookie,
    sample_rate,
    channels,
    bits,
    language: if language == "" {
      "und"
    } else {
      language
    },
    events: [],
  })
}

///|
pub fn MkvAlacMuxer::write_packet(
  self : MkvAlacMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration_ms < 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV/ALAC packet")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
pub fn MkvAlacMuxer::finish(self : MkvAlacMuxer) -> Bytes {
  self.serialize(None)
}

///|
fn MkvAlacMuxer::serialize(self : MkvAlacMuxer, duration_ms : Double?) -> Bytes {
  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, self.sample_rate.to_double())
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )
  webm_uint_elem(audio, 0x6264, 2, self.bits.reinterpret_as_uint().to_uint64())
  // Matroska stores only the 24-byte ALACSpecificConfig.
  mkv_audio_document(
    "A_ALAC",
    self.cookie[12:36].to_owned(),
    audio,
    self.events,
    language=self.language,
    duration_ms?,
  )
}

///|
/// Encode mono or stereo PCM as ALAC in Matroska.
pub fn DecodedAudio::to_mkv_alac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  let output = self.encode_alac_pcm(bits)
  let mux = match mkv_alac_muxer_new(output.cookie) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  let rate = output.sample_rate.to_int64()
  for i, packet in output.frames {
    let start = i.to_int64() * output.frame_size.to_int64()
    let pts = @libavutil.av_rescale(start, 1000L, rate)
    let end = @libavutil.av_rescale(
      start + alac_encoded_duration(output, i).to_int64(),
      1000L,
      rate,
    )
    if mux.write_packet(packet, pts, (end - pts).to_int()) is Err(error) {
      raise DecodeError(error)
    }
  }
  mux.serialize(
    Some(output.total_samples.to_double() * 1000.0 / rate.to_double()),
  )
}
