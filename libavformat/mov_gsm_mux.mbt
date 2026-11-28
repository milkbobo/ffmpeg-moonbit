///|
/// Wrap native mono 8 kHz GSM frames in QuickTime. The edit list can trim
/// silence from the last coded frame to an exact PCM sample count.
pub fn av_mov_mux_gsm(
  data : Bytes,
  valid_samples? : Int32,
) -> Result[Bytes, String] {
  let track = match av_gsm_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard track.total_samples <= 0x7fffffffL else {
    return Err("mov: GSM duration is too large")
  }
  let total = track.total_samples.to_int()
  let valid = valid_samples.unwrap_or(total)
  guard valid > 0 && valid <= total && total - valid < 160 else {
    return Err("mov: invalid GSM presentation length")
  }
  let body = b"\x00\x00\x00\x00\x00\x00".to_array()
  mp4_u16(body, 1) // data reference
  mp4_u16(body, 1) // QuickTime SoundDescription version
  mp4_u16(body, 0) // revision
  mp4_u32(body, 0U) // vendor
  mp4_u16(body, 1) // channels
  mp4_u16(body, 16) // decoded sample depth
  mp4_u16(body, 0xfffe) // packetized compression
  mp4_u16(body, 0)
  mp4_u32(body, 8000U << 16)
  mp4_u32(body, 160U) // samples per packet
  mp4_u32(body, 33U) // bytes per packet
  mp4_u32(body, 33U) // bytes per frame
  mp4_u32(body, 2U) // bytes per decoded sample
  let packets = track.frames.map(frame => {
    let start = frame.pos.to_int()
    data[start:start + frame.size].to_owned()
  })
  Ok(
    mp4_audio_document(
      8000,
      packets,
      Array::make(packets.length(), 160),
      mp4_box("agsm", body),
      mp4_language_code("und"),
      quicktime_duration=valid,
    ),
  )
}

///|
/// Encode mono GSM in MOV at 8 kHz with exact presentation duration.
pub fn DecodedAudio::to_mov_gsm(self : DecodedAudio) -> Bytes raise MediaError {
  let audio = self.resample_to(8000)
  let payload = audio.encode_gsm(false)
  match av_mov_mux_gsm(payload, valid_samples=audio.samples[0].length()) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
