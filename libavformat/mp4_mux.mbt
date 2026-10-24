///|
/// Minimal in-memory AAC-in-MP4 writer.  Emits one audio track with a
/// non-fragmented `ftyp`/`mdat`/`moov` layout and the sample tables the
/// existing MOV demuxer consumes (`stsd`/`stts`/`stsc`/`stsz`/`stco`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4AacMuxer {
  sample_rate : Int32
  channels : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_aac_muxer_new(
  sample_rate : Int32,
  channels : Int32,
) -> Result[Mp4AacMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 7 {
    return Err("EINVAL: invalid AAC MP4 stream parameters")
  }
  let mut rate_ok = false
  for rate in mp4_mux_rates() {
    if rate == sample_rate {
      rate_ok = true
    }
  }
  if !rate_ok {
    return Err("EINVAL: unsupported AAC sample rate")
  }
  Ok({
    sample_rate,
    channels,
    packets: [],
    durations: [],
  })
}

///|
fn mp4_mux_rates() -> Array[Int32] {
  [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000,
    11025, 8000, 7350,
  ]
}

///|
fn mp4_mux_rate_index(rate : Int32) -> Int32 {
  let rates = mp4_mux_rates()
  for i in 0..<rates.length() {
    if rates[i] == rate {
      return i
    }
  }
  0
}

///|
fn mp4_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push(((v >> 8) & 0xFF).to_byte())
  dst.push((v & 0xFF).to_byte())
}

///|
fn mp4_u32(dst : Array[Byte], v : UInt32) -> Unit {
  for i in 0..<4 {
    dst.push(((v >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
}

///|
fn mp4_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
fn mp4_box(tag : String, body : Array[Byte]) -> Array[Byte] {
  let out : Array[Byte] = []
  mp4_u32(out, (8 + body.length()).reinterpret_as_uint())
  mp4_tag(out, tag)
  out.append(body)
  out
}

///|
fn mp4_full_box(tag : String, version : Int32, flags : Int32, body : Array[Byte]) -> Array[Byte] {
  let full : Array[Byte] = []
  mp4_u32(full, (version << 24).reinterpret_as_uint() | flags.reinterpret_as_uint())
  full.append(body)
  mp4_box(tag, full)
}

///|
fn mp4_cat(parts : Array[Array[Byte]]) -> Array[Byte] {
  let out : Array[Byte] = []
  for p in parts {
    out.append(p)
  }
  out
}

///|
fn mp4_matrix(dst : Array[Byte]) -> Unit {
  let matrix : Array[UInt32] = [
    0x00010000U, 0U, 0U, 0U, 0x00010000U, 0U, 0U, 0U, 0x40000000U,
  ]
  for v in matrix {
    mp4_u32(dst, v)
  }
}

///|
fn mp4_asc(sample_rate : Int32, channels : Int32) -> Array[Byte] {
  let sr = mp4_mux_rate_index(sample_rate)
  [
    ((2 << 3) | (sr >> 1)).to_byte(),
    (((sr & 1) << 7) | (channels << 3)).to_byte(),
  ]
}

///|
fn mp4_esds(sample_rate : Int32, channels : Int32) -> Array[Byte] {
  let asc = mp4_asc(sample_rate, channels)
  let dcd_len = 15 + asc.length()
  let es_len = 8 + dcd_len
  let body : Array[Byte] = []
  mp4_u32(body, 0U) // version/flags
  body.push(b'\x03') // ES_Descriptor
  body.push(es_len.to_byte())
  mp4_u16(body, 1) // ES_ID
  body.push(b'\x00') // flags
  body.push(b'\x04') // DecoderConfigDescriptor
  body.push(dcd_len.to_byte())
  body.push(b'\x40') // MPEG-4 Audio
  body.push(b'\x15') // audio stream type
  body.push(b'\x00')
  body.push(b'\x00')
  body.push(b'\x00') // buffer size
  for _ in 0..<8 {
    body.push(b'\x00') // max/avg bitrate
  }
  body.push(b'\x05') // DecoderSpecificInfo
  body.push(asc.length().to_byte())
  body.append(asc)
  body.push(b'\x06')
  body.push(b'\x01')
  body.push(b'\x02') // SLConfigDescriptor
  mp4_box("esds", body)
}

///|
/// `AudioSampleEntry` with an `esds` child, shared by the plain and
/// fragmented AAC writers.
fn mp4_aac_entry(sample_rate : Int32, channels : Int32) -> Array[Byte] {
  let entry_body : Array[Byte] = []
  for _ in 0..<6 {
    entry_body.push(b'\x00')
  }
  mp4_u16(entry_body, 1) // data_reference_index
  mp4_u16(entry_body, 0) // version
  mp4_u16(entry_body, 0) // revision
  mp4_u32(entry_body, 0U) // vendor
  mp4_u16(entry_body, channels)
  mp4_u16(entry_body, 16) // sample size
  mp4_u16(entry_body, 0) // compression id
  mp4_u16(entry_body, 0) // packet size
  mp4_u32(entry_body, (sample_rate << 16).reinterpret_as_uint())
  entry_body.append(mp4_esds(sample_rate, channels))
  mp4_box("mp4a", entry_body)
}

///|
/// Append one raw AAC access unit. `duration` is in the media timescale
/// (typically 1024 samples).
pub fn Mp4AacMuxer::write_packet(
  self : Mp4AacMuxer,
  packet : Bytes,
  duration? : Int32 = 1024,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: empty AAC packet or duration")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  Ok(())
}

///|
pub fn Mp4AacMuxer::finish(self : Mp4AacMuxer) -> Bytes {
  let sample_count = self.packets.length()
  let mut total_duration = 0
  for d in self.durations {
    total_duration = total_duration + d
  }
  let data : Array[Byte] = []
  for packet in self.packets {
    for b in packet {
      data.push(b)
    }
  }
  // ftyp is 32 bytes, so the mdat payload starts at 40.
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
  mp4_u32(mvhd_body, self.sample_rate.reinterpret_as_uint())
  mp4_u32(mvhd_body, total_duration.reinterpret_as_uint())
  mp4_u32(mvhd_body, 0x00010000U) // rate
  mp4_u16(mvhd_body, 0x0100) // volume
  mp4_u16(mvhd_body, 0)
  for _ in 0..<2 {
    mp4_u32(mvhd_body, 0U)
  }
  mp4_matrix(mvhd_body)
  for _ in 0..<6 {
    mp4_u32(mvhd_body, 0U)
  }
  mp4_u32(mvhd_body, 2U) // next_track_id
  let mvhd = mp4_full_box("mvhd", 0, 0, mvhd_body)

  let tkhd_body : Array[Byte] = []
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 1U) // track_id
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, total_duration.reinterpret_as_uint())
  for _ in 0..<2 {
    mp4_u32(tkhd_body, 0U)
  }
  mp4_u16(tkhd_body, 0) // layer
  mp4_u16(tkhd_body, 0) // alternate_group
  mp4_u16(tkhd_body, 0x0100) // volume
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, 0U) // width
  mp4_u32(tkhd_body, 0U) // height
  let tkhd = mp4_full_box("tkhd", 0, 7, tkhd_body)

  let mdhd_body : Array[Byte] = []
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, self.sample_rate.reinterpret_as_uint())
  mp4_u32(mdhd_body, total_duration.reinterpret_as_uint())
  mp4_u16(mdhd_body, 0x55C4) // "und"
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
  mp4_u32(url_body, 1U) // self-contained
  let url = mp4_box("url ", url_body)
  let dref_body : Array[Byte] = []
  mp4_u32(dref_body, 1U)
  dref_body.append(url)
  let dref = mp4_full_box("dref", 0, 0, dref_body)
  let dinf = mp4_box("dinf", dref)

  let stsd_body : Array[Byte] = []
  mp4_u32(stsd_body, 1U)
  stsd_body.append(mp4_aac_entry(self.sample_rate, self.channels))
  let stsd = mp4_full_box("stsd", 0, 0, stsd_body)

  let stts_body : Array[Byte] = []
  let runs : Array[(Int32, Int32)] = []
  for d in self.durations {
    if runs.length() > 0 && runs[runs.length() - 1].1 == d {
      runs[runs.length() - 1] = (runs[runs.length() - 1].0 + 1, d)
    } else {
      runs.push((1, d))
    }
  }
  mp4_u32(stts_body, runs.length().reinterpret_as_uint())
  for run in runs {
    mp4_u32(stts_body, run.0.reinterpret_as_uint())
    mp4_u32(stts_body, run.1.reinterpret_as_uint())
  }
  let stts = mp4_full_box("stts", 0, 0, stts_body)

  let stsc_body : Array[Byte] = []
  mp4_u32(stsc_body, if sample_count > 0 { 1U } else { 0U })
  if sample_count > 0 {
    mp4_u32(stsc_body, 1U) // first_chunk
    mp4_u32(stsc_body, sample_count.reinterpret_as_uint())
    mp4_u32(stsc_body, 1U) // sample_description_index
  }
  let stsc = mp4_full_box("stsc", 0, 0, stsc_body)

  let stsz_body : Array[Byte] = []
  mp4_u32(stsz_body, 0U)
  mp4_u32(stsz_body, sample_count.reinterpret_as_uint())
  for packet in self.packets {
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
