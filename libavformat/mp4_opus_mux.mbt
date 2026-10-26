///|
/// Minimal in-memory Opus-in-MP4 writer: one `Opus` sample entry with a
/// `dOps` box and the same non-fragmented sample tables as the AAC writer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4OpusMuxer {
  channels : Int32
  pre_skip : Int32
  input_sample_rate : Int32
  timescale : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_opus_muxer_new(
  channels~ : Int32 = 2,
  pre_skip~ : Int32 = 0,
  input_sample_rate~ : Int32 = 48000,
  timescale~ : Int32 = 48000,
) -> Result[Mp4OpusMuxer, String] {
  if channels < 1 ||
    channels > 2 ||
    pre_skip < 0 ||
    input_sample_rate <= 0 ||
    timescale <= 0 {
    return Err("EINVAL: invalid Opus MP4 stream parameters")
  }
  Ok({
    channels,
    pre_skip,
    input_sample_rate,
    timescale,
    packets: [],
    durations: [],
  })
}

///|
pub fn Mp4OpusMuxer::write_packet(
  self : Mp4OpusMuxer,
  packet : Bytes,
) -> Result[Unit, String] {
  if packet.length() == 0 {
    return Err("EINVAL: empty Opus packet")
  }
  let parsed = match @libavcodec.opus_parse_packet(packet) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  self.packets.push(packet)
  self.durations.push(parsed.total_samples())
  Ok(())
}

///|
/// `dOps` (OpusSpecificBox) for a mapping-family-0 stream.
fn mp4_opus_dops(
  channels : Int32,
  pre_skip : Int32,
  input_sample_rate : Int32,
) -> Array[Byte] {
  let body : Array[Byte] = [0]
  body.push(channels.to_byte())
  // OpusSpecificBox fields are big-endian.
  body.push(((pre_skip >> 8) & 0xFF).to_byte())
  body.push((pre_skip & 0xFF).to_byte())
  for i in 0..<4 {
    body.push(((input_sample_rate >> (24 - 8 * i)) & 0xFF).to_byte())
  }
  body.push(b'\x00')
  body.push(b'\x00') // output gain
  body.push(b'\x00') // mapping family 0
  mp4_box("dOps", body)
}

///|
/// `AudioSampleEntry` with a `dOps` child, shared by the plain and fragmented
/// Opus writers.
fn mp4_opus_entry(
  channels : Int32,
  pre_skip : Int32,
  input_sample_rate : Int32,
) -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, 0U)
  mp4_u16(body, channels)
  mp4_u16(body, 16)
  mp4_u16(body, 0)
  mp4_u16(body, 0)
  mp4_u32(body, (input_sample_rate << 16).reinterpret_as_uint())
  body.append(mp4_opus_dops(channels, pre_skip, input_sample_rate))
  mp4_box("Opus", body)
}

///|
fn Mp4OpusMuxer::entry(self : Mp4OpusMuxer) -> Array[Byte] {
  mp4_opus_entry(self.channels, self.pre_skip, self.input_sample_rate)
}

///|
pub fn Mp4OpusMuxer::finish(self : Mp4OpusMuxer) -> Bytes {
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
  mp4_u32(mvhd_body, self.timescale.reinterpret_as_uint())
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
  mp4_u32(mdhd_body, self.timescale.reinterpret_as_uint())
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
  stsd_body.append(self.entry())
  let stsd = mp4_full_box("stsd", 0, 0, stsd_body)

  let runs : Array[(Int32, Int32)] = []
  for d in self.durations {
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
