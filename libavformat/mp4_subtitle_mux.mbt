///|
/// Minimal mov-text (`tx3g`) subtitle-only MP4 writer, mirroring FFmpeg
/// 9.0.2 `movenc.c`'s subtitle track: timescale 1,000,000, one chunk of
/// samples (`u16` length + UTF-8 text), gaps and a trailing flush encoded as
/// empty samples.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One timed-text cue: start/end milliseconds and the UTF-8 text.
pub struct Mp4SubtitleCue {
  start_ms : Int64
  end_ms : Int64
  text : String
}

///|
/// Construct a cue for `Mp4SubtitleMuxer::write_cue`.
pub fn mp4_subtitle_cue_new(
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> Mp4SubtitleCue {
  { start_ms, end_ms, text, }
}

///|
/// One `tx3g` subtitle track.
pub struct Mp4SubtitleMuxer {
  cues : Array[Mp4SubtitleCue]
}

///|
/// New subtitle writer with an empty cue list.
pub fn mp4_subtitle_muxer_new() -> Mp4SubtitleMuxer {
  { cues: [], }
}

///|
/// Add one cue. Cues must be non-empty, `end_ms >= start_ms`, and must not
/// overlap the previous cue (MP4 sample timing is carried by durations).
pub fn Mp4SubtitleMuxer::write_cue(
  self : Mp4SubtitleMuxer,
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
  self.cues.push({ start_ms, end_ms, text, })
  Ok(())
}

///|
/// One `tx3g` sample payload: `u16` text length followed by the UTF-8 bytes.
fn mp4_tx3g_sample(text : String) -> Array[Byte] {
  let bytes = utf8_from_string(text)
  let out : Array[Byte] = []
  out.push(((bytes.length() >> 8) & 0xFF).to_byte())
  out.push((bytes.length() & 0xFF).to_byte())
  for b in bytes {
    out.push(b)
  }
  out
}

///|
/// `tx3g` sample entry: display flags, centre/bottom justification, opaque
/// black background, empty box record, default style and an Arial font table
/// (the layout FFmpeg writes).
fn mp4_tx3g_entry() -> Array[Byte] {
  let body : Array[Byte] = []
  for _ in 0..<6 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1) // data_reference_index
  mp4_u32(body, 0U) // displayFlags
  body.push(b'\x01') // horizontal justification: centre
  body.push(b'\xff') // vertical justification: bottom
  mp4_u32(body, 0xFFU) // background colour (opaque black)
  for _ in 0..<8 {
    body.push(b'\x00') // BoxRecord
  }
  mp4_u16(body, 1) // startChar
  mp4_u16(body, 0x10) // endChar
  mp4_u16(body, 0xFFFF) // font-ID
  body.push(b'\xff') // face-style flags
  body.push(b'\x12') // font size 18
  mp4_u32(body, 0U) // text colour
  // Font table: one entry, "Arial".
  mp4_u16(body, 1)
  mp4_u16(body, 1)
  body.push(b'\x05')
  for b in b"Arial" {
    body.push(b)
  }
  mp4_box("tx3g", body)
}

///|
/// Assemble the `ftyp` + `mdat` + `moov` document. Each cue becomes a text
/// sample, a gap before the next cue an empty sample, and the stream ends
/// with a zero-duration empty sample (FFmpeg's flush sample).
fn mp4_subtitle_document(
  samples : Array[Bytes],
  durations : Array[Int64],
) -> Bytes {
  let sample_count = samples.length()
  let mut total_duration = 0L
  for d in durations {
    total_duration = total_duration + d
  }
  let data : Array[Byte] = []
  for sample in samples {
    for b in sample {
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
  mp4_u32(mvhd_body, 1000000U)
  mp4_u32(mvhd_body, total_duration.to_int().reinterpret_as_uint())
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
  mp4_u32(tkhd_body, total_duration.to_int().reinterpret_as_uint())
  for _ in 0..<2 {
    mp4_u32(tkhd_body, 0U)
  }
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  let tkhd = mp4_full_box("tkhd", 0, 3, tkhd_body)

  let mdhd_body : Array[Byte] = []
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 1000000U)
  mp4_u32(mdhd_body, total_duration.to_int().reinterpret_as_uint())
  mp4_u16(mdhd_body, 0x55C4)
  mp4_u16(mdhd_body, 0)
  let mdhd = mp4_full_box("mdhd", 0, 0, mdhd_body)

  let hdlr_body : Array[Byte] = []
  mp4_u32(hdlr_body, 0U)
  mp4_tag(hdlr_body, "sbtl")
  for _ in 0..<3 {
    mp4_u32(hdlr_body, 0U)
  }
  mp4_tag(hdlr_body, "SubtitleHandler")
  hdlr_body.push(b'\x00')
  let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)

  let nmhd = mp4_full_box("nmhd", 0, 0, [])

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
  stsd_body.append(mp4_tx3g_entry())
  let stsd = mp4_full_box("stsd", 0, 0, stsd_body)

  let stts_body : Array[Byte] = []
  mp4_u32(stts_body, durations.length().reinterpret_as_uint())
  for d in durations {
    mp4_u32(stts_body, 1U)
    mp4_u32(stts_body, d.to_int().reinterpret_as_uint())
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
  for sample in samples {
    mp4_u32(stsz_body, sample.length().reinterpret_as_uint())
  }
  let stsz = mp4_full_box("stsz", 0, 0, stsz_body)

  let stco_body : Array[Byte] = []
  mp4_u32(stco_body, if sample_count > 0 { 1U } else { 0U })
  if sample_count > 0 {
    mp4_u32(stco_body, chunk_offset.reinterpret_as_uint())
  }
  let stco = mp4_full_box("stco", 0, 0, stco_body)

  let stbl = mp4_box("stbl", mp4_cat([stsd, stts, stsc, stsz, stco]))
  let minf = mp4_box("minf", mp4_cat([nmhd, dinf, stbl]))
  let mdia = mp4_box("mdia", mp4_cat([mdhd, hdlr, minf]))
  let trak = mp4_box("trak", mp4_cat([tkhd, mdia]))
  let moov = mp4_box("moov", mp4_cat([mvhd, trak]))
  Bytes::from_array(mp4_cat([ftyp, mdat, moov]))
}

///|
/// mov-text samples and their durations in microseconds: a text sample per
/// cue, an empty sample for each gap and a zero-duration flush sample at the
/// end (FFmpeg's movenc layout).
pub fn mp4_subtitle_samples(
  cues : Array[Mp4SubtitleCue],
) -> (Array[Bytes], Array[Int64]) {
  let samples : Array[Bytes] = []
  let durations : Array[Int64] = []
  let empty = mp4_tx3g_sample("")
  let mut cur : Int64 = 0L
  for cue in cues {
    let start_us = cue.start_ms * 1000L
    let end_us = cue.end_ms * 1000L
    if start_us > cur {
      samples.push(Bytes::from_array(empty))
      durations.push(start_us - cur)
      cur = start_us
    }
    samples.push(Bytes::from_array(mp4_tx3g_sample(cue.text)))
    durations.push(end_us - start_us)
    cur = end_us
  }
  samples.push(Bytes::from_array(empty))
  durations.push(0L)
  (samples, durations)
}

///|
/// `tx3g` sample entry used by the standalone and the A/V subtitle tracks.
pub fn mp4_tx3g_sample_entry() -> Array[Byte] {
  mp4_tx3g_entry()
}

///|
/// Build the complete MP4: cue samples with gap/flush empty samples, timed in
/// microseconds (the mov-text track timescale).
pub fn Mp4SubtitleMuxer::finish(
  self : Mp4SubtitleMuxer,
) -> Result[Bytes, String] {
  let (samples, durations) = mp4_subtitle_samples(self.cues)
  let mut total = 0L
  for d in durations {
    total = total + d
  }
  if total > 4294967295L {
    return Err("EINVAL: subtitle duration exceeds the MP4 version-0 range")
  }
  Ok(mp4_subtitle_document(samples, durations))
}
