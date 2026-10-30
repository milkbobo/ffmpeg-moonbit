///|
/// Minimal H.264/HEVC + AAC MP4 writer with two tracks and an optional
/// mov-text (`tx3g`) subtitle track sharing one `mdat`. Video, audio and subtitle
/// samples occupy separate chunks; each track has its own sample table and
/// chunk offset.  Non-fragmented `moov` layout only.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct Mp4AvMuxer {
  width : Int32
  height : Int32
  avcc : Bytes
  /// Write an `hvc1`/`hvcC` video entry instead of `avc1`/`avcC`.
  hevc : Bool
  video_packets : Array[Bytes]
  video_durations : Array[Int32]
  video_keyframes : Array[Bool]
  /// Presentation offsets (PTS - DTS) per video sample.
  video_cts : Array[Int32]
  sample_rate : Int32
  channels : Int32
  /// AAC encoder delay in media samples, expressed as an audio `elst` edit.
  aac_priming : Int32
  /// Explicit audio sample entry (AC-3/E-AC-3); AAC builds its own `esds`.
  audio_entry : Array[Byte]?
  audio_packets : Array[Bytes]
  audio_durations : Array[Int32]
  cues : Array[Mp4SubtitleCue]
  tags : Array[(String, String)]
  chapters : Array[Mp4Chapter]
}

///|
pub fn mp4_av_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels : Int32,
  /// Leading AAC samples to skip via `edts`/`elst`.
  aac_priming~ : Int32 = 0,
  /// Explicit audio sample entry (e.g. `mp4_ac3_entry`); AAC when None.
  audio_entry~ : Array[Byte]? = None,
  /// Interpret `avcc` as an `hvcC` and write an `hvc1` entry.
  hevc~ : Bool = false,
) -> Result[Mp4AvMuxer, String] {
  if width <= 0 ||
    height <= 0 ||
    avcc.length() < 7 ||
    sample_rate <= 0 ||
    channels < 1 ||
    channels > 7 ||
    aac_priming < 0 {
    return Err("EINVAL: invalid MP4 A/V parameters")
  }
  match audio_entry {
    None => {
      let mut rate_ok = false
      for rate in mp4_mux_rates() {
        if rate == sample_rate {
          rate_ok = true
        }
      }
      if !rate_ok {
        return Err("EINVAL: unsupported AAC sample rate")
      }
    }
    Some(entry) =>
      if entry.length() == 0 || aac_priming != 0 {
        return Err("EINVAL: invalid MP4 audio entry")
      }
  }
  Ok({
    width,
    height,
    avcc,
    hevc,
    aac_priming,
    audio_entry,
    video_packets: [],
    video_durations: [],
    video_keyframes: [],
    video_cts: [],
    sample_rate,
    channels,
    audio_packets: [],
    audio_durations: [],
    cues: [],
    tags: [],
    chapters: [],
  })
}

///|
pub fn Mp4AvMuxer::write_video(
  self : Mp4AvMuxer,
  packet : Bytes,
  duration~ : Int32 = 3000,
  keyframe~ : Bool = false,
  cts~ : Int32 = 0,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: invalid MP4 video packet")
  }
  self.video_packets.push(packet)
  self.video_durations.push(duration)
  self.video_keyframes.push(keyframe)
  self.video_cts.push(cts)
  Ok(())
}

///|
pub fn Mp4AvMuxer::write_audio(
  self : Mp4AvMuxer,
  packet : Bytes,
  duration~ : Int32 = 1024,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: invalid MP4 audio packet")
  }
  self.audio_packets.push(packet)
  self.audio_durations.push(duration)
  Ok(())
}

///|
fn mp4_av_asc(rate : Int32, channels : Int32) -> Array[Byte] {
  let rates = mp4_mux_rates()
  let mut idx = 0
  for i in 0..<rates.length() {
    if rates[i] == rate {
      idx = i
    }
  }
  [
    ((2 << 3) | (idx >> 1)).to_byte(),
    (((idx & 1) << 7) | (channels << 3)).to_byte(),
  ]
}

///|
fn mp4_av_aac_entry(rate : Int32, channels : Int32) -> Array[Byte] {
  let asc = mp4_av_asc(rate, channels)
  let dcd_len = 15 + asc.length()
  let es_len = 8 + dcd_len
  let esds_body : Array[Byte] = []
  mp4_u32(esds_body, 0U)
  esds_body.push(b'\x03')
  esds_body.push(es_len.to_byte())
  mp4_u16(esds_body, 1)
  esds_body.push(b'\x00')
  esds_body.push(b'\x04')
  esds_body.push(dcd_len.to_byte())
  esds_body.push(b'\x40')
  esds_body.push(b'\x15')
  esds_body.push(b'\x00')
  esds_body.push(b'\x00')
  esds_body.push(b'\x00')
  for _ in 0..<8 {
    esds_body.push(b'\x00')
  }
  esds_body.push(b'\x05')
  esds_body.push(asc.length().to_byte())
  esds_body.append(asc)
  esds_body.push(b'\x06')
  esds_body.push(b'\x01')
  esds_body.push(b'\x02')
  let entry : Array[Byte] = []
  for _ in 0..<6 {
    entry.push(b'\x00')
  }
  mp4_u16(entry, 1)
  mp4_u16(entry, 0)
  mp4_u16(entry, 0)
  mp4_u32(entry, 0U)
  mp4_u16(entry, channels)
  mp4_u16(entry, 16)
  mp4_u16(entry, 0)
  mp4_u16(entry, 0)
  mp4_u32(entry, (rate << 16).reinterpret_as_uint())
  entry.append(mp4_box("esds", esds_body))
  mp4_box("mp4a", entry)
}

///|
fn mp4_av_stbl(
  entry : Array[Byte],
  packets : Array[Bytes],
  durations : Array[Int32],
  keyframes : Array[Bool],
  cts : Array[Int32],
  chunk_offset : Int32,
) -> Array[Byte] {
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
  let parts : Array[Array[Byte]] = [stsd, mp4_full_box("stts", 0, 0, stts_body)]
  match mp4_ctts_box(cts) {
    Some(box) => parts.push(box)
    None => ()
  }
  let sync : Array[Int32] = []
  for i in 0..<keyframes.length() {
    if keyframes[i] {
      sync.push(i + 1)
    }
  }
  if sync.length() > 0 {
    let body : Array[Byte] = []
    mp4_u32(body, sync.length().reinterpret_as_uint())
    for n in sync {
      mp4_u32(body, n.reinterpret_as_uint())
    }
    parts.push(mp4_full_box("stss", 0, 0, body))
  }
  let count = packets.length()
  let stsc_body : Array[Byte] = []
  mp4_u32(stsc_body, if count > 0 { 1U } else { 0U })
  if count > 0 {
    mp4_u32(stsc_body, 1U)
    mp4_u32(stsc_body, count.reinterpret_as_uint())
    mp4_u32(stsc_body, 1U)
  }
  parts.push(mp4_full_box("stsc", 0, 0, stsc_body))
  let stsz_body : Array[Byte] = []
  mp4_u32(stsz_body, 0U)
  mp4_u32(stsz_body, count.reinterpret_as_uint())
  for p in packets {
    mp4_u32(stsz_body, p.length().reinterpret_as_uint())
  }
  parts.push(mp4_full_box("stsz", 0, 0, stsz_body))
  let stco_body : Array[Byte] = []
  mp4_u32(stco_body, if count > 0 { 1U } else { 0U })
  if count > 0 {
    mp4_u32(stco_body, chunk_offset.reinterpret_as_uint())
  }
  parts.push(mp4_full_box("stco", 0, 0, stco_body))
  mp4_box("stbl", mp4_cat(parts))
}

///|
fn mp4_av_trak(
  track_id : Int32,
  volume : Int32,
  width : Int32,
  height : Int32,
  media_timescale : Int32,
  media_duration : Int32,
  movie_duration : Int32,
  handler : String,
  media_header : Array[Byte],
  entry : Array[Byte],
  edts : Array[Byte],
  packets : Array[Bytes],
  durations : Array[Int32],
  keyframes : Array[Bool],
  cts : Array[Int32],
  chunk_offset : Int32,
) -> Array[Byte] {
  let tkhd_body : Array[Byte] = []
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, track_id.reinterpret_as_uint())
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, movie_duration.reinterpret_as_uint())
  for _ in 0..<2 {
    mp4_u32(tkhd_body, 0U)
  }
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, volume)
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, (width << 16).reinterpret_as_uint())
  mp4_u32(tkhd_body, (height << 16).reinterpret_as_uint())
  let tkhd = mp4_full_box("tkhd", 0, 7, tkhd_body)

  let mdhd_body : Array[Byte] = []
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, media_timescale.reinterpret_as_uint())
  mp4_u32(mdhd_body, media_duration.reinterpret_as_uint())
  mp4_u16(mdhd_body, 0x55C4)
  mp4_u16(mdhd_body, 0)
  let mdhd = mp4_full_box("mdhd", 0, 0, mdhd_body)

  let hdlr_body : Array[Byte] = []
  mp4_u32(hdlr_body, 0U)
  mp4_tag(hdlr_body, handler)
  for _ in 0..<3 {
    mp4_u32(hdlr_body, 0U)
  }
  mp4_tag(
    hdlr_body,
    if handler == "vide" {
      "VideoHandler"
    } else if handler == "soun" {
      "SoundHandler"
    } else {
      "SubtitleHandler"
    },
  )
  hdlr_body.push(b'\x00')
  let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)

  let url_body : Array[Byte] = []
  mp4_u32(url_body, 1U)
  let url = mp4_box("url ", url_body)
  let dref_body : Array[Byte] = []
  mp4_u32(dref_body, 1U)
  dref_body.append(url)
  let dinf = mp4_box("dinf", mp4_full_box("dref", 0, 0, dref_body))
  let stbl = mp4_av_stbl(
    entry, packets, durations, keyframes, cts, chunk_offset,
  )
  let minf = mp4_box("minf", mp4_cat([media_header, dinf, stbl]))
  let mdia = mp4_box("mdia", mp4_cat([mdhd, hdlr, minf]))
  mp4_box("trak", mp4_cat([tkhd, edts, mdia]))
}

///|
/// Set the file-level iTunes tags (`udta/meta/ilst`).
pub fn Mp4AvMuxer::set_tags(
  self : Mp4AvMuxer,
  tags : Array[(String, String)],
) -> Unit {
  self.tags.clear()
  for pair in tags {
    self.tags.push(pair)
  }
}

///|
/// Set the file-level `chpl` chapters.
pub fn Mp4AvMuxer::set_chapters(
  self : Mp4AvMuxer,
  chapters : Array[Mp4Chapter],
) -> Unit {
  self.chapters.clear()
  for chapter in chapters {
    self.chapters.push(chapter)
  }
}

///|
/// Add a mov-text cue; the subtitle track is written only when at least one
/// cue exists. Cues must not overlap (MP4 sample timing is duration-based).
pub fn Mp4AvMuxer::write_subtitle(
  self : Mp4AvMuxer,
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> Result[Unit, String] {
  if start_ms < 0L || end_ms < start_ms || text == "" {
    return Err("EINVAL: invalid subtitle cue")
  }
  if utf8_from_string(text).length() > 65535 {
    return Err("EINVAL: subtitle cue text exceeds 65535 bytes")
  }
  if self.cues.length() > 0 &&
    start_ms < self.cues[self.cues.length() - 1].end_ms {
    return Err("EINVAL: overlapping subtitle cues")
  }
  self.cues.push(({ start_ms, end_ms, text, } : Mp4SubtitleCue))
  Ok(())
}

///|
pub fn Mp4AvMuxer::finish(self : Mp4AvMuxer) -> Bytes {
  let ftyp_body : Array[Byte] = []
  mp4_tag(ftyp_body, "isom")
  mp4_u32(ftyp_body, 0x200U)
  for brand in ["isom", "iso2", "avc1", "mp41"] {
    mp4_tag(ftyp_body, brand)
  }
  let ftyp = mp4_box("ftyp", ftyp_body)
  let vdata : Array[Byte] = []
  for p in self.video_packets {
    for b in p {
      vdata.push(b)
    }
  }
  let adata : Array[Byte] = []
  for p in self.audio_packets {
    for b in p {
      adata.push(b)
    }
  }
  let has_subs = self.cues.length() > 0
  let (sub_samples, sub_us) = if has_subs {
    mp4_subtitle_samples(self.cues)
  } else {
    ([], [])
  }
  let sdata : Array[Byte] = []
  for p in sub_samples {
    for b in p {
      sdata.push(b)
    }
  }
  let mdat_body : Array[Byte] = []
  mdat_body.append(vdata)
  mdat_body.append(adata)
  mdat_body.append(sdata)
  let mdat = mp4_box("mdat", mdat_body)
  let video_offset = ftyp.length() + 8
  let audio_offset = video_offset + vdata.length()
  let sub_offset = audio_offset + adata.length()

  let mut vdur = 0
  for d in self.video_durations {
    vdur = vdur + d
  }
  // First displayed frame: trims the B-frame reorder delay with an edit
  // list so the video presentation starts at 0 like the decoded source.
  let mut vfirst_pts = 0L
  let mut dts_acc = 0L
  for i in 0..<self.video_durations.length() {
    let c = if i < self.video_cts.length() {
      self.video_cts[i].to_int64()
    } else {
      0L
    }
    let pts = dts_acc + c
    if i == 0 || pts < vfirst_pts {
      vfirst_pts = pts
    }
    dts_acc = dts_acc + self.video_durations[i].to_int64()
  }
  if vfirst_pts < 0L {
    vfirst_pts = 0L
  }
  let mut adur = 0
  for d in self.audio_durations {
    adur = adur + d
  }
  let aprim = if self.aac_priming < adur { self.aac_priming } else { adur }
  let a_display = adur - aprim
  let vms = vdur.to_int64() * 1000L / 90000L
  let ams = a_display.to_int64() * 1000L / self.sample_rate.to_int64()
  let mut sub_ms = 0L
  let sub_durations : Array[Int32] = []
  for d in sub_us {
    // Cue millisecond grid: the microsecond durations divide exactly.
    sub_ms = sub_ms + d / 1000L
    sub_durations.push((d / 1000L).to_int())
  }
  let mut movie_ms = if vms > ams { vms } else { ams }
  if sub_ms > movie_ms {
    movie_ms = sub_ms
  }
  let movie_ms = movie_ms.to_int()
  // Trim the B-frame reorder delay while keeping the full presentation
  // length, matching the edit list FFmpeg writes for such sources.
  let vedts : Array[Byte] = if vfirst_pts > 0L && vfirst_pts < vdur.to_int64() {
    mp4_edit_list_at(vfirst_pts.to_int(), movie_ms)
  } else {
    []
  }
  let aedts : Array[Byte] = if aprim > 0 {
    mp4_edit_list(aprim, adur, 1000, self.sample_rate)
  } else {
    []
  }
  let mvhd_body : Array[Byte] = []
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, 1000U)
  mp4_u32(mvhd_body, movie_ms.reinterpret_as_uint())
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
  mp4_u32(mvhd_body, if has_subs { 4U } else { 3U })
  let mvhd = mp4_full_box("mvhd", 0, 0, mvhd_body)

  let ventry = if self.hevc {
    mp4_hevc_entry(self.width, self.height, self.avcc)
  } else {
    let h264 = mp4_h264_muxer_new(
      self.width,
      self.height,
      self.avcc,
      timescale=90000,
    ).unwrap()
    h264.video_entry()
  }
  let vmhd_body : Array[Byte] = []
  mp4_u16(vmhd_body, 0)
  for _ in 0..<3 {
    mp4_u16(vmhd_body, 0)
  }
  let vmhd = mp4_full_box("vmhd", 0, 1, vmhd_body)
  let vtrack = mp4_av_trak(
    1,
    0,
    self.width,
    self.height,
    90000,
    vdur,
    vms.to_int(),
    "vide",
    vmhd,
    ventry,
    vedts,
    self.video_packets,
    self.video_durations,
    self.video_keyframes,
    self.video_cts,
    video_offset,
  )

  let aentry = match self.audio_entry {
    Some(entry) => entry
    None => mp4_av_aac_entry(self.sample_rate, self.channels)
  }
  let smhd_body : Array[Byte] = []
  mp4_u16(smhd_body, 0)
  mp4_u16(smhd_body, 0)
  let smhd = mp4_full_box("smhd", 0, 0, smhd_body)
  let empty_keys : Array[Bool] = []
  for _ in 0..<self.audio_packets.length() {
    empty_keys.push(false)
  }
  let atrack = mp4_av_trak(
    2,
    0x0100,
    0,
    0,
    self.sample_rate,
    adur,
    ams.to_int(),
    "soun",
    smhd,
    aentry,
    aedts,
    self.audio_packets,
    self.audio_durations,
    empty_keys,
    [],
    audio_offset,
  )
  let nmhd = mp4_full_box("nmhd", 0, 0, [])
  let empty_sub_keys : Array[Bool] = []
  for _ in 0..<sub_samples.length() {
    empty_sub_keys.push(false)
  }
  let strack = if has_subs {
    mp4_av_trak(
      3,
      0,
      0,
      0,
      1000,
      sub_ms.to_int(),
      sub_ms.to_int(),
      "sbtl",
      nmhd,
      mp4_tx3g_sample_entry(),
      [],
      sub_samples,
      sub_durations,
      empty_sub_keys,
      [],
      sub_offset,
    )
  } else {
    []
  }
  let udta = if self.tags.length() > 0 || self.chapters.length() > 0 {
    mp4_udta_box(self.tags, self.chapters)
  } else {
    []
  }
  let children = if has_subs {
    mp4_cat([mvhd, vtrack, atrack, strack, udta])
  } else {
    mp4_cat([mvhd, vtrack, atrack, udta])
  }
  let moov = mp4_box("moov", children)
  Bytes::from_array(mp4_cat([ftyp, mdat, moov]))
}

///|
/// H.264 + AC-3 A/V MP4 muxer.  `first_audio_frame` supplies the `dac3`
/// fields and the audio sample rate/channel count.
pub fn mp4_av_ac3_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  first_audio_frame : Bytes,
) -> Result[Mp4AvMuxer, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_audio_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id > 10 {
    return Err("EINVAL: E-AC-3 frame in an AC-3 muxer")
  }
  mp4_av_muxer_new(
    width,
    height,
    avcc,
    hdr.sample_rate,
    hdr.channels,
    audio_entry=Some(mp4_ac3_entry(hdr)),
  )
}

///|
/// H.264 + E-AC-3 A/V MP4 muxer.
pub fn mp4_av_eac3_muxer_new(
  width : Int32,
  height : Int32,
  avcc : Bytes,
  first_audio_frame : Bytes,
) -> Result[Mp4AvMuxer, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_audio_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id <= 10 || hdr.frame_type == 1 {
    return Err("EINVAL: frame is not an independent E-AC-3 frame")
  }
  mp4_av_muxer_new(
    width,
    height,
    avcc,
    hdr.sample_rate,
    hdr.channels,
    audio_entry=Some(mp4_eac3_entry(hdr)),
  )
}
