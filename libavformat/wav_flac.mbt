///|
fn wav_flac_demux(
  data : Bytes,
  fmt : WavFormat,
  data_offset : Int64,
  data_size : Int64,
  wave64~ : Bool,
) -> Result[WavDemux, String] {
  // Some writers carry the native FLAC marker and metadata block
  // header. Normalize both forms to the decoder's 34-byte STREAMINFO.
  guard flac_streaminfo_payload(fmt.extradata) is Some(streaminfo) else {
    return Err("wav: missing FLAC STREAMINFO")
  }
  let max_padding = if wave64 { 7 } else { 0 }
  let track = match
    flac_open_frames(
      data,
      data_offset.to_int(),
      (data_offset + data_size).to_int(),
      streaminfo,
      max_padding~,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let format : WavFormat = {
    ..fmt,
    sample_rate: track.sample_rate,
    channels: track.channels,
    bits_per_sample: track.bits,
    extradata: streaminfo,
    channel_mask: if fmt.channel_mask.popcnt() == track.channels {
      fmt.channel_mask
    } else if track.channels > 2 {
      flac_default_channel_mask(track.channels)
    } else {
      0U
    },
  }
  Ok(wav_indexed_demux(format, data_offset, track.frames, track.total_samples))
}

///|
/// Wrap native FLAC frames in RIFF/WAV or Wave64 without re-encoding.
/// A speaker bitmap can describe the stored channel order when it differs
/// from the default layout for the channel count.
pub fn av_wav_mux_flac(
  data : Bytes,
  channel_mask~ : UInt32 = 0U,
  wave64~ : Bool = false,
) -> Result[Bytes, String] {
  let flac = match av_flac_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard !flac.frames.is_empty() && flac.total_samples <= 0x7fffffffL else {
    return Err("wav: invalid FLAC sample count")
  }
  guard channel_mask == 0U ||
    (channel_mask <= 0x3ffffU && channel_mask.popcnt() == flac.channels) else {
    return Err("wav: invalid FLAC channel bitmap")
  }
  let start = flac.frames[0].pos.to_int()
  let size = data.length() - start
  guard size <= 0x7fffffff - 192 else {
    return Err("wav: FLAC payload is too large")
  }
  let average = size.to_int64() *
    flac.sample_rate.to_int64() /
    flac.total_samples
  guard average <= 0xffffffffL else {
    return Err("wav: FLAC byte rate is too large")
  }
  let extensible = channel_mask != 0U ||
    flac.channels > 2 ||
    flac.sample_rate > 48000
  let fmt : Array[Byte] = []
  wav_mux_u16(fmt, if extensible { 0xfffe } else { 0xf1ac })
  wav_mux_u16(fmt, flac.channels)
  wav_mux_u32(fmt, flac.sample_rate.reinterpret_as_uint())
  wav_mux_u32(fmt, average.to_int().reinterpret_as_uint())
  wav_mux_u16(fmt, flac.channels * ((flac.bits + 7) / 8))
  wav_mux_u16(fmt, flac.bits)
  wav_mux_u16(fmt, if extensible { 56 } else { 34 })
  if extensible {
    wav_mux_u16(fmt, flac.bits)
    wav_mux_u32(
      fmt,
      if channel_mask != 0U {
        channel_mask
      } else {
        flac_default_channel_mask(flac.channels)
      },
    )
    fmt.append(
      b"\xac\xf1\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71".to_array(),
    )
  }
  fmt.append(flac.streaminfo.to_array())
  let payload = data[start:].to_owned()
  let samples = flac.total_samples.to_int()
  Ok(
    if wave64 {
      w64_mux_fact_data(payload, fmt, samples, include_data_padding=false)
    } else {
      wav_mux_fact_data(payload, fmt, samples)
    },
  )
}

///|
/// Encode FLAC samples in RIFF/WAV or Wave64.
pub fn DecodedAudio::to_wav_flac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
  wave64~ : Bool = false,
) -> Bytes raise MediaError {
  let encoded = self.encode_flac_pcm(bits)
  match
    av_wav_mux_flac(encoded.file(), channel_mask=self.channel_mask, wave64~) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
