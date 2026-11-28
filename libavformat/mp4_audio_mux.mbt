///|
/// Minimal MP3-in-MP4 writer: one `mp4a` sample entry whose `esds` carries
/// objectTypeIndication 0x6B (MPEG-1 audio) or 0x69 (MPEG-2 audio) and no
/// DecoderSpecificInfo, plus the non-fragmented sample tables used by the
/// Opus/AAC writers.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4Mp3Muxer {
  sample_rate : Int32
  channels : Int32
  object_type : Int32
  timescale : Int32
  language : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_mp3_muxer_new(
  sample_rate : Int32,
  channels~ : Int32 = 2,
  object_type~ : Int32 = 0x6B,
  timescale~ : Int32 = 0,
  language~ : String = "und",
) -> Result[Mp4Mp3Muxer, String] {
  if sample_rate <= 0 ||
    channels < 1 ||
    channels > 2 ||
    (object_type != 0x69 && object_type != 0x6B) ||
    timescale < 0 {
    return Err("EINVAL: invalid MP3 MP4 stream parameters")
  }
  Ok({
    sample_rate,
    channels,
    object_type,
    timescale: if timescale == 0 {
      sample_rate
    } else {
      timescale
    },
    language: mp4_language_code(language),
    packets: [],
    durations: [],
  })
}

///|
pub fn Mp4Mp3Muxer::write_packet(
  self : Mp4Mp3Muxer,
  packet : Bytes,
  duration~ : Int32 = 1152,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: invalid MP3 frame")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  Ok(())
}

///|
fn mp4_mp3_esds(object_type : Int32) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, 0U) // version + flags
  body.push(b'\x03') // ES_Descriptor
  body.push(b'\x15') // length 21: 3 + (2 + 13) + 3
  mp4_u16(body, 1) // ES_ID
  body.push(b'\x00') // flags
  body.push(b'\x04') // DecoderConfigDescriptor
  body.push(b'\x0D') // length 13
  body.push(object_type.to_byte())
  body.push(b'\x15') // streamType audio (5) << 2 | reserved
  body.push(b'\x00')
  body.push(b'\x00')
  body.push(b'\x00') // bufferSizeDB
  mp4_u32(body, 0U) // maxBitrate
  mp4_u32(body, 0U) // avgBitrate
  body.push(b'\x06') // SLConfigDescriptor
  body.push(b'\x01')
  body.push(b'\x02') // predefined: MP4
  mp4_box("esds", body)
}

///|
fn mp4_mp3_entry(
  rate : Int32,
  channels : Int32,
  object_type : Int32,
) -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1) // data reference index
  mp4_u16(body, 0) // version
  mp4_u16(body, 0) // revision
  mp4_u32(body, 0U) // vendor
  mp4_u16(body, channels)
  mp4_u16(body, 16) // sample size
  mp4_u16(body, 0) // compression id
  mp4_u16(body, 0) // packet size
  mp4_u32(body, (rate << 16).reinterpret_as_uint())
  body.append(mp4_mp3_esds(object_type))
  mp4_box("mp4a", body)
}

///|
/// The single-track audio layout: `ftyp`, one `mdat` holding every sample,
/// then `moov` with one `trak`. QuickTime can specify a shorter presentation.
fn mp4_audio_document(
  timescale : Int32,
  packets : Array[Bytes],
  durations : Array[Int32],
  entry : Array[Byte],
  language : Int32,
  quicktime_duration? : Int32,
) -> Bytes {
  let sample_count = packets.length()
  let mut total_duration = 0
  for d in durations {
    total_duration = total_duration + d
  }
  let presentation = quicktime_duration.unwrap_or(total_duration)
  let quicktime = quicktime_duration is Some(_)
  let data : Array[Byte] = []
  for packet in packets {
    for b in packet {
      data.push(b)
    }
  }
  let ftyp_body : Array[Byte] = []
  if quicktime {
    mp4_tag(ftyp_body, "qt  ")
    mp4_u32(ftyp_body, 0x200U)
    mp4_tag(ftyp_body, "qt  ")
  } else {
    mp4_tag(ftyp_body, "isom")
    mp4_u32(ftyp_body, 0x200U)
    for brand in ["isom", "iso2", "mp41"] {
      mp4_tag(ftyp_body, brand)
    }
  }
  let ftyp = mp4_box("ftyp", ftyp_body)
  let mdat = mp4_box("mdat", data)
  let chunk_offset = ftyp.length() + 8

  let mvhd_body : Array[Byte] = []
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, timescale.reinterpret_as_uint())
  mp4_u32(mvhd_body, presentation.reinterpret_as_uint())
  mp4_u32(mvhd_body, 0x00010000U)
  mp4_u16(mvhd_body, 0x0100)
  mp4_u16(mvhd_body, 0)
  for _ in 0..<2 {
    mp4_u32(mvhd_body, 0U)
  }
  mp4_matrix(mvhd_body)
  for _ in 0..<6 {
    mp4_u32(mvhd_body, 0U)
  }
  mp4_u32(mvhd_body, 2U)
  let mvhd = mp4_full_box("mvhd", 0, 0, mvhd_body)

  let tkhd_body : Array[Byte] = []
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 1U)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, presentation.reinterpret_as_uint())
  for _ in 0..<2 {
    mp4_u32(tkhd_body, 0U)
  }
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0x0100)
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  let tkhd = mp4_full_box("tkhd", 0, 7, tkhd_body)

  let mdhd_body : Array[Byte] = []
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, timescale.reinterpret_as_uint())
  mp4_u32(mdhd_body, total_duration.reinterpret_as_uint())
  mp4_u16(mdhd_body, language)
  mp4_u16(mdhd_body, 0)
  let mdhd = mp4_full_box("mdhd", 0, 0, mdhd_body)

  let hdlr_body : Array[Byte] = []
  if quicktime {
    mp4_tag(hdlr_body, "mhlr")
  } else {
    mp4_u32(hdlr_body, 0U)
  }
  mp4_tag(hdlr_body, "soun")
  for _ in 0..<3 {
    mp4_u32(hdlr_body, 0U)
  }
  if quicktime {
    hdlr_body.push(12) // Pascal string in QuickTime
  }
  mp4_tag(hdlr_body, "SoundHandler")
  if !quicktime {
    hdlr_body.push(b'\x00')
  }
  let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)

  let smhd_body : Array[Byte] = []
  mp4_u16(smhd_body, 0)
  mp4_u16(smhd_body, 0)
  let smhd = mp4_full_box("smhd", 0, 0, smhd_body)

  let url_body : Array[Byte] = []
  mp4_u32(url_body, 1U)
  let url = mp4_box("url ", url_body)
  let dref_body : Array[Byte] = []
  mp4_u32(dref_body, 1U)
  dref_body.append(url)
  let dref = mp4_full_box("dref", 0, 0, dref_body)
  let dinf = mp4_box("dinf", dref)

  let stsd_body : Array[Byte] = []
  mp4_u32(stsd_body, 1U)
  stsd_body.append(entry)
  let stsd = mp4_full_box("stsd", 0, 0, stsd_body)

  let runs : Array[(Int32, Int32)] = []
  for d in durations {
    if runs.length() > 0 && runs[runs.length() - 1].1 == d {
      runs[runs.length() - 1] = (runs[runs.length() - 1].0 + 1, d)
    } else {
      runs.push((1, d))
    }
  }
  let stts_body : Array[Byte] = []
  mp4_u32(stts_body, runs.length().reinterpret_as_uint())
  for run in runs {
    mp4_u32(stts_body, run.0.reinterpret_as_uint())
    mp4_u32(stts_body, run.1.reinterpret_as_uint())
  }
  let stts = mp4_full_box("stts", 0, 0, stts_body)

  let stsc_body : Array[Byte] = []
  mp4_u32(stsc_body, if sample_count > 0 { 1U } else { 0U })
  if sample_count > 0 {
    mp4_u32(stsc_body, 1U)
    mp4_u32(stsc_body, sample_count.reinterpret_as_uint())
    mp4_u32(stsc_body, 1U)
  }
  let stsc = mp4_full_box("stsc", 0, 0, stsc_body)

  let stsz_body : Array[Byte] = []
  mp4_u32(stsz_body, 0U)
  mp4_u32(stsz_body, sample_count.reinterpret_as_uint())
  for packet in packets {
    mp4_u32(stsz_body, packet.length().reinterpret_as_uint())
  }
  let stsz = mp4_full_box("stsz", 0, 0, stsz_body)

  let stco_body : Array[Byte] = []
  mp4_u32(stco_body, if sample_count > 0 { 1U } else { 0U })
  if sample_count > 0 {
    mp4_u32(stco_body, chunk_offset.reinterpret_as_uint())
  }
  let stco = mp4_full_box("stco", 0, 0, stco_body)

  let stbl = mp4_box("stbl", mp4_cat([stsd, stts, stsc, stsz, stco]))
  let minf = mp4_box("minf", mp4_cat([smhd, dinf, stbl]))
  let mdia = mp4_box("mdia", mp4_cat([mdhd, hdlr, minf]))
  let edts = if presentation < total_duration {
    mp4_edit_list_at(0, presentation)
  } else {
    []
  }
  let trak = mp4_box("trak", mp4_cat([tkhd, edts, mdia]))
  let moov = mp4_box("moov", mp4_cat([mvhd, trak]))
  Bytes::from_array(mp4_cat([ftyp, mdat, moov]))
}

///|
pub fn Mp4Mp3Muxer::finish(self : Mp4Mp3Muxer) -> Bytes {
  mp4_audio_document(
    self.timescale,
    self.packets,
    self.durations,
    mp4_mp3_entry(self.sample_rate, self.channels, self.object_type),
    self.language,
  )
}

///|
/// One FLAC-in-MP4 track: a `fLaC` audio sample entry whose `dfLa` box is a
/// FullBox holding the STREAMINFO metadata block (plus optional later
/// metadata blocks). Packets are FLAC frames.
pub struct Mp4FlacMuxer {
  streaminfo : Bytes
  headers : Array[Bytes]
  sample_rate : Int32
  channels : Int32
  bits : Int32
  timescale : Int32
  language : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_flac_muxer_new(
  streaminfo : Bytes,
  headers~ : Array[Bytes] = [],
  timescale~ : Int32 = 0,
  language~ : String = "und",
) -> Result[Mp4FlacMuxer, String] {
  if streaminfo.length() != 34 {
    return Err("EINVAL: invalid FLAC STREAMINFO")
  }
  let sample_rate = ogg_flac_bits(streaminfo, 80, 20).to_int()
  let channels = ogg_flac_bits(streaminfo, 100, 3).to_int() + 1
  let bits = ogg_flac_bits(streaminfo, 103, 5).to_int() + 1
  if sample_rate <= 0 || channels < 1 || channels > 8 || timescale < 0 {
    return Err("EINVAL: invalid FLAC MP4 stream parameters")
  }
  for block in headers {
    if block.length() < 4 {
      return Err("EINVAL: invalid FLAC metadata block")
    }
  }
  Ok({
    streaminfo,
    headers,
    sample_rate,
    channels,
    bits,
    timescale: if timescale == 0 {
      sample_rate
    } else {
      timescale
    },
    language: mp4_language_code(language),
    packets: [],
    durations: [],
  })
}

///|
pub fn Mp4FlacMuxer::write_packet(
  self : Mp4FlacMuxer,
  packet : Bytes,
  duration~ : Int32 = 4096,
) -> Result[Unit, String] {
  if packet.length() < 6 || duration <= 0 {
    return Err("EINVAL: invalid FLAC frame")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  Ok(())
}

///|
fn Mp4FlacMuxer::entry(self : Mp4FlacMuxer) -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, 0U)
  mp4_u16(body, self.channels)
  mp4_u16(body, self.bits)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, mp4_lossless_entry_rate(self.sample_rate))
  let dfla : Array[Byte] = []
  dfla.push(if self.headers.length() == 0 { b'\x80' } else { b'\x00' })
  dfla.push(b'\x00')
  dfla.push(b'\x00')
  dfla.push(b'"')
  for b in self.streaminfo {
    dfla.push(b)
  }
  for block in self.headers {
    for b in block {
      dfla.push(b)
    }
  }
  body.append(mp4_full_box("dfLa", 0, 0, dfla))
  mp4_box("fLaC", body)
}

///|
/// Lossless sample descriptions carry the full rate in codec configuration
/// when it exceeds the integer portion of the legacy 16.16 field.
fn mp4_lossless_entry_rate(rate : Int32) -> UInt32 {
  let mut entry_rate = rate
  while entry_rate > 65535 {
    entry_rate = entry_rate >> 1
  }
  (entry_rate << 16).reinterpret_as_uint()
}

///|
pub fn Mp4FlacMuxer::finish(self : Mp4FlacMuxer) -> Bytes {
  mp4_audio_document(
    self.timescale,
    self.packets,
    self.durations,
    self.entry(),
    self.language,
  )
}

///|
/// Wrap native FLAC in MP4, preserving STREAMINFO and the coded audio.
pub fn av_mp4_mux_flac(data : Bytes) -> Result[Bytes, String] {
  let track = match av_flac_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard !track.frames.is_empty() &&
    track.total_samples <= 0xffffffffL &&
    data.length().to_int64() + track.frames.length().to_int64() * 12L <=
    0x7fffffffL - 1024L else {
    return Err("mp4: empty or oversized FLAC stream")
  }
  let mux = match mp4_flac_muxer_new(track.streaminfo) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for frame in track.frames {
    let start = frame.pos.to_int()
    let packet = data[start:start + frame.size].to_owned()
    if mux.write_packet(packet, duration=frame.duration) is Err(error) {
      return Err(error)
    }
  }
  Ok(mux.finish())
}

///|
/// Encode 16-, 24- or 32-bit FLAC in MP4.
pub fn DecodedAudio::to_mp4_flac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  let encoded = self.encode_flac_pcm(bits)
  guard self.channel_mask == 0U ||
    self.channel_mask == flac_default_channel_mask(encoded.channels) else {
    raise UnsupportedCodec(
      "MP4 FLAC export requires a standard FLAC channel layout",
    )
  }
  match av_mp4_mux_flac(encoded.file()) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}

///|
/// One ALAC-in-MP4 track: an `alac` audio sample entry whose child box is the
/// 36-byte magic-cookie atom verbatim (`mov_write_extradata_tag`). Packets are
/// raw ALAC frames; durations are their decoded sample counts.
pub struct Mp4AlacMuxer {
  cookie : Bytes
  sample_rate : Int32
  channels : Int32
  bits : Int32
  timescale : Int32
  language : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
fn mp4_alac_byte(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int()
}

///|
fn mp4_alac_be32(data : Bytes, off : Int32) -> UInt32 {
  (mp4_alac_byte(data, off).reinterpret_as_uint() << 24) |
  (mp4_alac_byte(data, off + 1).reinterpret_as_uint() << 16) |
  (mp4_alac_byte(data, off + 2).reinterpret_as_uint() << 8) |
  mp4_alac_byte(data, off + 3).reinterpret_as_uint()
}

///|
pub fn mp4_alac_muxer_new(
  cookie : Bytes,
  timescale~ : Int32 = 0,
  language~ : String = "und",
) -> Result[Mp4AlacMuxer, String] {
  if cookie.length() < 36 ||
    cookie[4] != b'a' ||
    cookie[5] != b'l' ||
    cookie[6] != b'a' ||
    cookie[7] != b'c' {
    return Err("EINVAL: invalid ALAC magic cookie")
  }
  let sample_rate = mp4_alac_be32(cookie, 32).reinterpret_as_int()
  let channels = mp4_alac_byte(cookie, 21)
  let bits = mp4_alac_byte(cookie, 17)
  if sample_rate <= 0 ||
    channels < 1 ||
    channels > 8 ||
    (bits != 16 && bits != 20 && bits != 24 && bits != 32) ||
    timescale < 0 {
    return Err("EINVAL: invalid ALAC MP4 stream parameters")
  }
  Ok({
    cookie,
    sample_rate,
    channels,
    bits,
    timescale: if timescale == 0 {
      sample_rate
    } else {
      timescale
    },
    language: mp4_language_code(language),
    packets: [],
    durations: [],
  })
}

///|
pub fn Mp4AlacMuxer::write_packet(
  self : Mp4AlacMuxer,
  packet : Bytes,
  duration~ : Int32 = 4096,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: invalid ALAC frame")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  Ok(())
}

///|
fn Mp4AlacMuxer::entry(self : Mp4AlacMuxer) -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, 0U)
  mp4_u16(body, self.channels)
  mp4_u16(body, self.bits)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, mp4_lossless_entry_rate(self.sample_rate))
  for b in self.cookie {
    body.push(b)
  }
  mp4_box("alac", body)
}

///|
pub fn Mp4AlacMuxer::finish(self : Mp4AlacMuxer) -> Bytes {
  mp4_audio_document(
    self.timescale,
    self.packets,
    self.durations,
    self.entry(),
    self.language,
  )
}

///|
/// Encode mono or stereo PCM as 16-, 24- or 32-bit ALAC in MP4.
pub fn DecodedAudio::to_mp4_alac(
  self : DecodedAudio,
  bits~ : Int32 = 24,
) -> Bytes raise MediaError {
  let output = self.encode_alac_pcm(bits)
  let mux = match mp4_alac_muxer_new(output.cookie) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  for i, packet in output.frames {
    if mux.write_packet(packet, duration=alac_encoded_duration(output, i))
      is Err(error) {
      raise DecodeError(error)
    }
  }
  mux.finish()
}

///|
fn alac_encoded_duration(
  output : @libavcodec.AlacEncoded,
  index : Int32,
) -> Int32 {
  (output.total_samples.to_int() - index * output.frame_size).min(
    output.frame_size,
  )
}

///|
fn DecodedAudio::encode_alac_pcm(
  self : DecodedAudio,
  bits : Int32,
) -> @libavcodec.AlacEncoded raise MediaError {
  let channels = self.channels
  guard channels == 1 || channels == 2 else {
    raise UnsupportedCodec("ALAC export requires mono or stereo")
  }
  guard bits == 16 || bits == 24 || bits == 32 else {
    raise UnsupportedCodec("ALAC sample depth must be 16, 24 or 32 bits")
  }
  let count = self.samples[0].length()
  guard count > 0 && count <= 0x7fffffff / channels else {
    raise DecodeError("alac: invalid PCM length")
  }
  let pcm = Array::makei(count * channels, i => {
    playback_pcm_quantize(self.samples[i % channels][i / channels], bits)
  })
  let output = match
    @libavcodec.alac_encode(pcm, channels, self.sample_rate, bits) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  let mut bytes = 0L
  for packet in output.frames {
    bytes += packet.length().to_int64() + 32L
    guard bytes <= 0x7fffffffL - 1024L else {
      raise DecodeError("alac: output is too large")
    }
  }
  output
}
