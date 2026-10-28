///|
/// One ALAC-in-Matroska track: `A_ALAC` with the 36-byte magic cookie as
/// CodecPrivate (FFmpeg's matroska muxer stores ALAC extradata verbatim).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvAlacMuxer {
  cookie : Bytes
  sample_rate : Int32
  channels : Int32
  bits : Int32
  events : Array[MkvAudioEvent]
}

///|
pub fn mkv_alac_muxer_new(cookie : Bytes) -> Result[MkvAlacMuxer, String] {
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
  Ok({ cookie, sample_rate, channels, bits, events: [], })
}

///|
pub fn MkvAlacMuxer::write_packet(
  self : MkvAlacMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV/ALAC packet")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
pub fn MkvAlacMuxer::finish(self : MkvAlacMuxer) -> Bytes {
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
  )
}
