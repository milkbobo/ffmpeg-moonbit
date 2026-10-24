///|
/// Minimal in-memory H.264-in-MP4 writer.  The caller supplies an `avcC`
/// record and length-prefixed access units; the writer emits one video track
/// with `avc1`/`avcC` and the non-fragmented sample tables used by the MOV
/// demuxer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4H264Muxer {
  width : Int32
  height : Int32
  timescale : Int32
  avcc : Bytes
  packets : Array[Bytes]
  durations : Array[Int32]
  keyframes : Array[Bool]
}

///|
pub fn mp4_h264_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  timescale? : Int32 = 90000,
) -> Result[Mp4H264Muxer, String] {
  if width <= 0 || height <= 0 || timescale <= 0 || avcc.length() < 7 {
    return Err("EINVAL: invalid H.264 MP4 stream parameters")
  }
  Ok({
    width,
    height,
    timescale,
    avcc,
    packets: [],
    durations: [],
    keyframes: [],
  })
}

///|
/// Append one length-prefixed H.264 access unit.
pub fn Mp4H264Muxer::write_packet(
  self : Mp4H264Muxer,
  packet : Bytes,
  duration? : Int32 = 3000,
  keyframe? : Bool = false,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: empty H.264 packet or duration")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  self.keyframes.push(keyframe)
  Ok(())
}

///|
/// `VisualSampleEntry` with one decoder-config child, shared by the plain and
/// fragmented video writers.
fn mp4_visual_entry(
  width : Int32,
  height : Int32,
  tag : String,
  config_tag : String,
  config : Bytes,
) -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1) // data_reference_index
  mp4_u16(body, 0) // pre_defined
  mp4_u16(body, 0) // reserved
  for _ in 0..<3 {
    mp4_u32(body, 0U)
  }
  mp4_u16(body, width)
  mp4_u16(body, height)
  mp4_u32(body, 0x00480000U) // 72 dpi
  mp4_u32(body, 0x00480000U)
  mp4_u32(body, 0U)
  mp4_u16(body, 1) // frame_count
  for _ in 0..<32 {
    body.push(b'\x00') // compressorname
  }
  mp4_u16(body, 0x0018) // depth
  mp4_u16(body, 0xFFFF) // pre_defined = -1
  let config_body : Array[Byte] = []
  for b in config {
    config_body.push(b)
  }
  body.append(mp4_box(config_tag, config_body))
  mp4_box(tag, body)
}

///|
fn mp4_h264_entry(width : Int32, height : Int32, avcc : Bytes) -> Array[Byte] {
  mp4_visual_entry(width, height, "avc1", "avcC", avcc)
}

///|
fn mp4_hevc_entry(width : Int32, height : Int32, hvcc : Bytes) -> Array[Byte] {
  mp4_visual_entry(width, height, "hvc1", "hvcC", hvcc)
}

///|
fn mp4_av1_entry(width : Int32, height : Int32, av1c : Bytes) -> Array[Byte] {
  mp4_visual_entry(width, height, "av01", "av1C", av1c)
}

///|
fn mp4_vp9_entry(width : Int32, height : Int32, vpcc : Bytes) -> Array[Byte] {
  mp4_visual_entry(width, height, "vp09", "vpcC", vpcc)
}

///|
fn Mp4H264Muxer::video_entry(self : Mp4H264Muxer) -> Array[Byte] {
  mp4_h264_entry(self.width, self.height, self.avcc)
}

///|
pub fn Mp4H264Muxer::finish(self : Mp4H264Muxer) -> Bytes {
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
  for brand in ["isom", "iso2", "avc1", "mp41"] {
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
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, (self.width << 16).reinterpret_as_uint())
  mp4_u32(tkhd_body, (self.height << 16).reinterpret_as_uint())
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
  mp4_tag(hdlr_body, "vide")
  for _ in 0..<3 {
    mp4_u32(hdlr_body, 0U)
  }
  mp4_tag(hdlr_body, "VideoHandler")
  hdlr_body.push(b'\x00')
  let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)

  let vmhd_body : Array[Byte] = []
  mp4_u16(vmhd_body, 0)
  for _ in 0..<3 {
    mp4_u16(vmhd_body, 0)
  }
  let vmhd = mp4_full_box("vmhd", 0, 1, vmhd_body)

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
  stsd_body.append(self.video_entry())
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

  let sync : Array[Int32] = []
  for i in 0..<self.keyframes.length() {
    if self.keyframes[i] {
      sync.push(i + 1)
    }
  }
  let stss = if sync.length() > 0 {
    let body : Array[Byte] = []
    mp4_u32(body, sync.length().reinterpret_as_uint())
    for n in sync {
      mp4_u32(body, n.reinterpret_as_uint())
    }
    Some(mp4_full_box("stss", 0, 0, body))
  } else {
    None
  }

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

  let stbl_parts : Array[Array[Byte]] = [stsd, stts]
  match stss {
    Some(box) => stbl_parts.push(box)
    None => ()
  }
  stbl_parts.push(stsc)
  stbl_parts.push(stsz)
  stbl_parts.push(stco)
  let stbl = mp4_box("stbl", mp4_cat(stbl_parts))
  let minf = mp4_box("minf", mp4_cat([vmhd, dinf, stbl]))
  let mdia = mp4_box("mdia", mp4_cat([mdhd, hdlr, minf]))
  let trak = mp4_box("trak", mp4_cat([tkhd, mdia]))
  let moov = mp4_box("moov", mp4_cat([mvhd, trak]))
  Bytes::from_array(mp4_cat([ftyp, mdat, moov]))
}
