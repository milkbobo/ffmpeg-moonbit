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
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_mp3_muxer_new(
  sample_rate : Int32,
  channels~ : Int32 = 2,
  object_type~ : Int32 = 0x6B,
  timescale~ : Int32 = 0,
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
/// The single-track audio MP4 layout shared with the Opus writer: `ftyp`,
/// one `mdat` holding every sample, then `moov` with one `trak`.
fn mp4_audio_document(
  timescale : Int32,
  packets : Array[Bytes],
  durations : Array[Int32],
  entry : Array[Byte],
) -> Bytes {
  let sample_count = packets.length()
  let mut total_duration = 0
  for d in durations {
    total_duration = total_duration + d
  }
  let data : Array[Byte] = []
  for packet in packets {
    for b in packet {
      data.push(b)
    }
  }
  let ftyp_body : Array[Byte] = []
  mp4_tag(ftyp_body, "isom")
  mp4_u32(ftyp_body, 0x200U)
  for brand in ["isom", "iso2", "mp41"] {
    mp4_tag(ftyp_body, brand)
  }
  let ftyp = mp4_box("ftyp", ftyp_body)
  let mdat = mp4_box("mdat", data)
  let chunk_offset = ftyp.length() + 8

  let mvhd_body : Array[Byte] = []
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, timescale.reinterpret_as_uint())
  mp4_u32(mvhd_body, total_duration.reinterpret_as_uint())
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
  mp4_u32(tkhd_body, total_duration.reinterpret_as_uint())
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
  mp4_u16(mdhd_body, 0x55C4)
  mp4_u16(mdhd_body, 0)
  let mdhd = mp4_full_box("mdhd", 0, 0, mdhd_body)

  let hdlr_body : Array[Byte] = []
  mp4_u32(hdlr_body, 0U)
  mp4_tag(hdlr_body, "soun")
  for _ in 0..<3 {
    mp4_u32(hdlr_body, 0U)
  }
  mp4_tag(hdlr_body, "SoundHandler")
  hdlr_body.push(b'\x00')
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
  let trak = mp4_box("trak", mp4_cat([tkhd, mdia]))
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
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_flac_muxer_new(
  streaminfo : Bytes,
  headers~ : Array[Bytes] = [],
  timescale~ : Int32 = 0,
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
  mp4_u32(body, (self.sample_rate << 16).reinterpret_as_uint())
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
pub fn Mp4FlacMuxer::finish(self : Mp4FlacMuxer) -> Bytes {
  mp4_audio_document(self.timescale, self.packets, self.durations, self.entry())
}
