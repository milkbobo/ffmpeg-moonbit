///|
/// FFmpeg's default FLAC speaker masks in channel-count order.
fn caf_flac_channel_mask(channels : Int32) -> UInt32 {
  let masks : FixedArray[UInt32] = [
    4U, 3U, 7U, 0x33U, 0x607U, 0x60fU, 0x70fU, 0x63fU,
  ]
  masks[channels - 1]
}

///|
/// Wrap native FLAC frames in CAF, retaining STREAMINFO and the coded frames.
/// Supply a speaker bitmap when the source uses a non-default channel layout.
pub fn av_caf_mux_flac(
  data : Bytes,
  channel_mask~ : UInt32 = 0U,
) -> Result[Bytes, String] {
  let track = match av_flac_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard !track.frames.is_empty() else { return Err("caf: no FLAC frames") }
  guard channel_mask == 0U ||
    (channel_mask <= 0x3ffffU && channel_mask.popcnt() == track.channels) else {
    return Err("caf: invalid FLAC channel bitmap")
  }
  let start = track.frames[0].pos.to_int()
  let size = data.length() - start
  let pakt : Array[Byte] = []
  caf_mux_u64be(pakt, track.frames.length().to_uint64())
  caf_mux_u64be(pakt, track.total_samples.reinterpret_as_uint64())
  caf_mux_u32be(pakt, 0U)
  caf_mux_u32be(pakt, 0U)
  for frame in track.frames {
    caf_mux_descr_len(pakt, frame.size)
    caf_mux_descr_len(pakt, frame.duration)
  }
  // Header plus chunk overhead, including the optional channel bitmap.
  guard size.to_int64() + pakt.length().to_int64() <= 0x7fffffffL - 166L else {
    return Err("caf: FLAC output is too large")
  }
  let desc : Array[Byte] = []
  caf_mux_double(desc, track.sample_rate.to_double())
  caf_mux_tag(desc, "flac")
  caf_mux_u32be(desc, 0U)
  caf_mux_u32be(desc, 0U) // variable bytes per packet
  caf_mux_u32be(desc, 0U) // variable samples per packet
  caf_mux_u32be(desc, track.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U)
  let cookie = b"\x00\x00\x00\x00dfLa\x00\x00\x00\x00\x80\x00\x00\x22".to_array()
  cookie.append(track.streaminfo.to_array())
  let out = b"caff\x00\x01\x00\x00".to_array()
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "kuki", cookie)
  if channel_mask != 0U {
    let chan : Array[Byte] = []
    caf_mux_u32be(chan, 0x10000U)
    caf_mux_u32be(chan, channel_mask)
    caf_mux_u32be(chan, 0U)
    caf_mux_chunk(out, "chan", chan)
  }
  caf_mux_chunk(out, "pakt", pakt)
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, size.to_uint64() + 4UL)
  caf_mux_u32be(out, 0U)
  for byte in data[start:] {
    out.push(byte)
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode the track as 16-, 24- or 32-bit FLAC in CAF.
pub fn DecodedAudio::to_caf_flac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  guard bits == 16 || bits == 24 || bits == 32 else {
    raise UnsupportedCodec("CAF FLAC sample depth must be 16, 24 or 32 bits")
  }
  let channels = self.channels
  guard channels >= 1 && channels <= 8 else {
    raise UnsupportedCodec("CAF FLAC export requires 1–8 channels")
  }
  let frames = self.samples[0].length()
  guard frames > 0 && frames <= 0x7fffffff / channels else {
    raise DecodeError("caf: invalid FLAC PCM length")
  }
  let pcm = Array::makei(frames * channels, i => {
    playback_pcm_quantize(self.samples[i % channels][i / channels], bits)
  })
  let encoded = match
    @libavcodec.flac_encode(pcm, channels, self.sample_rate, bits) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  match av_caf_mux_flac(encoded.file(), channel_mask=self.channel_mask) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
