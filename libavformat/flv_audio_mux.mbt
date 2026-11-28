///|
let flv_audio_header : Bytes = b"FLV\x01\x04\x00\x00\x00\x09\x00\x00\x00\x00"

///|
fn flv_write_audio_tag(
  out : Array[Byte],
  pts : Int64,
  prefix : Bytes,
  payload : BytesView,
) -> Result[Unit, String] {
  guard pts >= 0L && pts <= 0x7fffffffL else {
    return Err("flv: audio timestamp out of range")
  }
  guard payload.length() <= 0xffffff - prefix.length() &&
    out.length().to_int64() +
    prefix.length().to_int64() +
    payload.length().to_int64() +
    15L <=
    0x7fffffffL else {
    return Err("flv: audio tag or file too large")
  }
  let size = prefix.length() + payload.length()
  let ms = pts.to_int()
  out.push(8)
  out.push((size >> 16).to_byte())
  out.push((size >> 8).to_byte())
  out.push(size.to_byte())
  out.push((ms >> 16).to_byte())
  out.push((ms >> 8).to_byte())
  out.push(ms.to_byte())
  out.push((ms >> 24).to_byte())
  for _ in 0..<3 {
    out.push(0)
  }
  for byte in prefix {
    out.push(byte)
  }
  for byte in payload {
    out.push(byte)
  }
  aiff_mux_u32be(out, (size + 11).reinterpret_as_uint())
  Ok(())
}

///|
/// Encode mono or stereo PCM as AAC-LC in audio-only FLV. The coded
/// output includes encoder delay and completion of the last AAC frame.
pub fn DecodedAudio::to_flv_aac(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("FLV AAC-LC export requires mono or stereo")
  }
  let out = flv_audio_header.to_array()
  let asc = Bytes::from_array(mp4_av_asc(self.sample_rate, self.channels))
  // AAC uses the fixed FLV SoundFormat/Rate/Size/Type byte. The real sample
  // rate and channel count come from AudioSpecificConfig.
  if flv_write_audio_tag(out, 0L, b"\xaf\x00", asc[:]) is Err(error) {
    raise DecodeError(error)
  }
  let rate = self.sample_rate.to_int64()
  let mut samples = 0L
  self.encode_aac_lc(payload => {
    let pts = @libavutil.av_rescale(samples, 1000L, rate)
    samples += 1024L
    flv_write_audio_tag(out, pts, b"\xaf\x01", payload)
  })
  Bytes::from_array(out)
}

///|
/// Wrap native FLAC in Enhanced FLV, preserving STREAMINFO and coded frames.
pub fn av_flv_mux_flac(data : Bytes) -> Result[Bytes, String] {
  let track = match av_flac_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard !track.frames.is_empty() else { return Err("flv: empty FLAC stream") }
  let out = flv_audio_header.to_array()
  if flv_write_audio_tag(out, 0L, b"\x90fLaC", track.streaminfo[:])
    is Err(error) {
    return Err(error)
  }
  let rate = track.sample_rate.to_int64()
  for frame in track.frames {
    let start = frame.pos.to_int()
    let pts = @libavutil.av_rescale(frame.pts, 1000L, rate)
    if flv_write_audio_tag(
        out,
        pts,
        b"\x91fLaC",
        data[start:start + frame.size],
      )
      is Err(error) {
      return Err(error)
    }
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode 16-, 24- or 32-bit FLAC in Enhanced FLV with standard FLAC layout.
pub fn DecodedAudio::to_flv_flac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  let encoded = self.encode_flac_pcm(bits)
  guard self.channel_mask == 0U ||
    self.channel_mask == flac_default_channel_mask(encoded.channels) else {
    raise UnsupportedCodec(
      "FLV FLAC export requires a standard FLAC channel layout",
    )
  }
  match av_flv_mux_flac(encoded.file()) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
