///|
/// Minimal fragmented-MP4 (fMP4) segment writer, one track per segment plus a
/// muxed H.264+AAC pair with one `traf` per track in a shared `moof`.
/// Emits a DASH/HLS-style initialization segment (`ftyp`+`moov` with
/// `mvex`/`trex`) and media segments (`styp`+`moof`+`mdat`) that the existing
/// MOV demuxer and FFmpeg's `mov` demuxer both accept.  Tracks cover H.264
/// (`avc1`), HEVC (`hvc1`), AV1 (`av01`), VP9 (`vp09`), AAC (`mp4a`) and Opus
/// (`Opus`), which is what the DASH SegmentTemplate writer addresses as one
/// Representation per track.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One sample inside a media segment.  `duration` is in the track timescale.
pub struct Fmp4Sample {
  data : Bytes
  duration : Int32
  keyframe : Bool
}

///|
pub fn fmp4_sample(
  data : Bytes,
  duration : Int32,
  keyframe : Bool,
) -> Fmp4Sample {
  { data, duration, keyframe, }
}

///|
fn fmp4_u64(dst : Array[Byte], v : Int64) -> Unit {
  for i in 0..<8 {
    dst.push(((v >> (56 - 8 * i)) & 0xFFL).to_int().to_byte())
  }
}

///|
fn fmp4_dinf() -> Array[Byte] {
  let url_body : Array[Byte] = []
  mp4_u32(url_body, 1U) // self-contained
  let dref_body : Array[Byte] = []
  mp4_u32(dref_body, 1U)
  dref_body.append(mp4_box("url ", url_body))
  mp4_box("dinf", mp4_full_box("dref", 0, 0, dref_body))
}

///|
/// `stbl` for an initialization segment: the sample description only, with
/// empty sample tables (the fragments carry the samples).
fn fmp4_stbl(entry : Array[Byte]) -> Array[Byte] {
  let stsd_body : Array[Byte] = []
  mp4_u32(stsd_body, 1U)
  stsd_body.append(entry)
  let stsd = mp4_full_box("stsd", 0, 0, stsd_body)
  let stts_body : Array[Byte] = []
  mp4_u32(stts_body, 0U)
  let stts = mp4_full_box("stts", 0, 0, stts_body)
  let stsc_body : Array[Byte] = []
  mp4_u32(stsc_body, 0U)
  let stsc = mp4_full_box("stsc", 0, 0, stsc_body)
  let stsz_body : Array[Byte] = []
  mp4_u32(stsz_body, 0U)
  mp4_u32(stsz_body, 0U)
  let stsz = mp4_full_box("stsz", 0, 0, stsz_body)
  let stco_body : Array[Byte] = []
  mp4_u32(stco_body, 0U)
  let stco = mp4_full_box("stco", 0, 0, stco_body)
  mp4_box("stbl", mp4_cat([stsd, stts, stsc, stsz, stco]))
}

///|
fn fmp4_ftyp() -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_tag(body, "isom")
  mp4_u32(body, 0x200U)
  for brand in ["isom", "iso6", "mp41", "dash"] {
    mp4_tag(body, brand)
  }
  mp4_box("ftyp", body)
}

///|
fn fmp4_mvhd(timescale : Int32, next_track_id : Int32) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, 0U)
  mp4_u32(body, 0U)
  mp4_u32(body, timescale.reinterpret_as_uint())
  mp4_u32(body, 0U) // duration: fragments carry it
  mp4_u32(body, 0x00010000U)
  mp4_u16(body, 0x0100)
  mp4_u16(body, 0)
  for _ in 0..<2 {
    mp4_u32(body, 0U)
  }
  mp4_matrix(body)
  for _ in 0..<6 {
    mp4_u32(body, 0U)
  }
  mp4_u32(body, next_track_id.reinterpret_as_uint())
  mp4_full_box("mvhd", 0, 0, body)
}

///|
/// One `trak` for an initialization segment.  `handler` is `"vide"` or
/// `"soun"`, `entry` the sample description built by the codec helpers.
fn fmp4_trak(
  track_id : Int32,
  timescale : Int32,
  handler : String,
  entry : Array[Byte],
  width : Int32,
  height : Int32,
) -> Array[Byte] {
  let tkhd_body : Array[Byte] = []
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, track_id.reinterpret_as_uint())
  mp4_u32(tkhd_body, 0U)
  mp4_u32(tkhd_body, 0U) // duration
  for _ in 0..<2 {
    mp4_u32(tkhd_body, 0U)
  }
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, 0)
  mp4_u16(tkhd_body, if handler == "soun" { 0x0100 } else { 0 })
  mp4_u16(tkhd_body, 0)
  mp4_matrix(tkhd_body)
  mp4_u32(tkhd_body, (width << 16).reinterpret_as_uint())
  mp4_u32(tkhd_body, (height << 16).reinterpret_as_uint())
  let tkhd = mp4_full_box("tkhd", 0, 7, tkhd_body)

  let mdhd_body : Array[Byte] = []
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, 0U)
  mp4_u32(mdhd_body, timescale.reinterpret_as_uint())
  mp4_u32(mdhd_body, 0U) // duration
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
    if handler == "soun" {
      "SoundHandler"
    } else {
      "VideoHandler"
    },
  )
  hdlr_body.push(b'\x00')
  let hdlr = mp4_full_box("hdlr", 0, 0, hdlr_body)

  let media_header = if handler == "soun" {
    let body : Array[Byte] = []
    mp4_u16(body, 0)
    mp4_u16(body, 0)
    mp4_full_box("smhd", 0, 0, body)
  } else {
    let body : Array[Byte] = []
    mp4_u16(body, 0)
    for _ in 0..<3 {
      mp4_u16(body, 0)
    }
    mp4_full_box("vmhd", 0, 1, body)
  }
  let minf = mp4_box(
    "minf",
    mp4_cat([media_header, fmp4_dinf(), fmp4_stbl(entry)]),
  )
  let mdia = mp4_box("mdia", mp4_cat([mdhd, hdlr, minf]))
  mp4_box("trak", mp4_cat([tkhd, mdia]))
}

///|
fn fmp4_trex(track_id : Int32) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, track_id.reinterpret_as_uint())
  mp4_u32(body, 1U) // default_sample_description_index
  mp4_u32(body, 0U) // default_sample_duration
  mp4_u32(body, 0U) // default_sample_size
  mp4_u32(body, 0U) // default_sample_flags
  mp4_full_box("trex", 0, 0, body)
}

///|
/// Build the initialization segment for one track.
fn fmp4_init_segment(
  track_id : Int32,
  timescale : Int32,
  handler : String,
  entry : Array[Byte],
  width : Int32,
  height : Int32,
) -> Bytes {
  let moov = mp4_box(
    "moov",
    mp4_cat([
      fmp4_mvhd(timescale, track_id + 1),
      fmp4_trak(track_id, timescale, handler, entry, width, height),
      mp4_box("mvex", fmp4_trex(track_id)),
    ]),
  )
  Bytes::from_array(mp4_cat([fmp4_ftyp(), moov]))
}

///|
/// Initialization segment for an H.264 track (`avc1`/`avcC`).
pub fn fmp4_h264_init_segment(
  width : Int32,
  height : Int32,
  timescale : Int32,
  avcc : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if width <= 0 ||
    height <= 0 ||
    timescale <= 0 ||
    track_id <= 0 ||
    avcc.length() < 7 {
    return Err("EINVAL: invalid H.264 fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      timescale,
      "vide",
      mp4_h264_entry(width, height, avcc),
      width,
      height,
    ),
  )
}

///|
/// Initialization segment for an AAC track (`mp4a`/`esds`).  The media
/// timescale is the sample rate, as in the plain MP4 AAC writer.
pub fn fmp4_aac_init_segment(
  sample_rate : Int32,
  channels : Int32,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if sample_rate <= 0 || channels < 1 || channels > 7 || track_id <= 0 {
    return Err("EINVAL: invalid AAC fMP4 stream parameters")
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
  Ok(
    fmp4_init_segment(
      track_id,
      sample_rate,
      "soun",
      mp4_aac_entry(sample_rate, channels),
      0,
      0,
    ),
  )
}

///|
/// Initialization segment for a HEVC track (`hvc1`/`hvcC`).
pub fn fmp4_hevc_init_segment(
  width : Int32,
  height : Int32,
  timescale : Int32,
  hvcc : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if width <= 0 ||
    height <= 0 ||
    timescale <= 0 ||
    track_id <= 0 ||
    hvcc.length() < 4 {
    return Err("EINVAL: invalid HEVC fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      timescale,
      "vide",
      mp4_hevc_entry(width, height, hvcc),
      width,
      height,
    ),
  )
}

///|
/// Initialization segment for an AV1 track (`av01`/`av1C`).
pub fn fmp4_av1_init_segment(
  width : Int32,
  height : Int32,
  timescale : Int32,
  av1c : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if width <= 0 ||
    height <= 0 ||
    timescale <= 0 ||
    track_id <= 0 ||
    av1c.length() < 4 {
    return Err("EINVAL: invalid AV1 fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      timescale,
      "vide",
      mp4_av1_entry(width, height, av1c),
      width,
      height,
    ),
  )
}

///|
/// Initialization segment for a VP9 track (`vp09`/`vpcC`).
pub fn fmp4_vp9_init_segment(
  width : Int32,
  height : Int32,
  timescale : Int32,
  vpcc : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if width <= 0 ||
    height <= 0 ||
    timescale <= 0 ||
    track_id <= 0 ||
    vpcc.length() < 4 {
    return Err("EINVAL: invalid VP9 fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      timescale,
      "vide",
      mp4_vp9_entry(width, height, vpcc),
      width,
      height,
    ),
  )
}

///|
/// Initialization segment for an Opus track (`Opus`/`dOps`).  The media
/// timescale is normally 48000, the Opus decoder rate.
pub fn fmp4_opus_init_segment(
  channels : Int32,
  pre_skip : Int32,
  input_sample_rate : Int32,
  timescale : Int32,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  if channels < 1 ||
    channels > 2 ||
    pre_skip < 0 ||
    input_sample_rate <= 0 ||
    timescale <= 0 ||
    track_id <= 0 {
    return Err("EINVAL: invalid Opus fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      timescale,
      "soun",
      mp4_opus_entry(channels, pre_skip, input_sample_rate),
      0,
      0,
    ),
  )
}

///|
/// Initialization segment carrying one H.264 and one AAC track in the same
/// `moov` (progressive A/V fMP4 or a DASH Representation with muxed A/V).
/// The video track keeps `video_timescale`; the audio timescale is the AAC
/// sample rate, as in the single-track writer.
pub fn fmp4_av_init_segment(
  width : Int32,
  height : Int32,
  video_timescale : Int32,
  avcc : Bytes,
  sample_rate : Int32,
  channels : Int32,
  video_track_id~ : Int32 = 1,
  audio_track_id~ : Int32 = 2,
) -> Result[Bytes, String] {
  if width <= 0 ||
    height <= 0 ||
    video_timescale <= 0 ||
    video_track_id <= 0 ||
    audio_track_id <= 0 ||
    video_track_id == audio_track_id ||
    avcc.length() < 7 {
    return Err("EINVAL: invalid A/V fMP4 stream parameters")
  }
  if sample_rate <= 0 || channels < 1 || channels > 7 {
    return Err("EINVAL: invalid A/V fMP4 stream parameters")
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
  let next_track_id = if video_track_id > audio_track_id {
    video_track_id + 1
  } else {
    audio_track_id + 1
  }
  let moov = mp4_box(
    "moov",
    mp4_cat([
      fmp4_mvhd(video_timescale, next_track_id),
      fmp4_trak(
        video_track_id,
        video_timescale,
        "vide",
        mp4_h264_entry(width, height, avcc),
        width,
        height,
      ),
      fmp4_trak(
        audio_track_id,
        sample_rate,
        "soun",
        mp4_aac_entry(sample_rate, channels),
        0,
        0,
      ),
      mp4_box(
        "mvex",
        mp4_cat([fmp4_trex(video_track_id), fmp4_trex(audio_track_id)]),
      ),
    ]),
  )
  Ok(Bytes::from_array(mp4_cat([fmp4_ftyp(), moov])))
}

///|
fn fmp4_styp() -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_tag(body, "msdh")
  mp4_u32(body, 0U)
  for brand in ["msdh", "msix", "cmfs"] {
    mp4_tag(body, brand)
  }
  mp4_box("styp", body)
}

///|
fn fmp4_mfhd(sequence_number : Int32) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, sequence_number.reinterpret_as_uint())
  mp4_full_box("mfhd", 0, 0, body)
}

///|
/// One `traf` with an explicit `trun` data offset.  `data_offset` is relative
/// to the enclosing `moof` start (`default-base-is-moof`) and points past the
/// 8-byte `mdat` header.
fn fmp4_traf(
  track_id : Int32,
  base_decode_time : Int64,
  samples : Array[Fmp4Sample],
  data_offset : UInt32,
) -> Array[Byte] {
  let tfhd_body : Array[Byte] = []
  mp4_u32(tfhd_body, track_id.reinterpret_as_uint())
  let tfhd = mp4_full_box("tfhd", 0, 0x020000, tfhd_body)

  let tfdt_body : Array[Byte] = []
  fmp4_u64(tfdt_body, base_decode_time)
  let tfdt = mp4_full_box("tfdt", 1, 0, tfdt_body)

  let trun_body : Array[Byte] = []
  mp4_u32(trun_body, samples.length().reinterpret_as_uint())
  mp4_u32(trun_body, data_offset)
  for sample in samples {
    mp4_u32(trun_body, sample.duration.reinterpret_as_uint())
    mp4_u32(trun_body, sample.data.length().reinterpret_as_uint())
    mp4_u32(trun_body, if sample.keyframe { 0x02000000U } else { 0x01010000U })
  }
  let trun = mp4_full_box("trun", 0, 0x0701, trun_body)
  mp4_box("traf", mp4_cat([tfhd, tfdt, trun]))
}

///|
fn fmp4_payload(samples : Array[Fmp4Sample]) -> Array[Byte] {
  let data : Array[Byte] = []
  for sample in samples {
    for b in sample.data {
      data.push(b)
    }
  }
  data
}

///|
/// Initialization segment for an AC-3 track (`ac-3`/`dac3`).  `first_frame`
/// supplies the sample rate, channel count and `dac3` fields; media samples
/// are whole AC-3 frames with 1536-sample durations.
pub fn fmp4_ac3_init_segment(
  first_frame : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id > 10 || track_id <= 0 {
    return Err("EINVAL: invalid AC-3 fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      hdr.sample_rate,
      "soun",
      mp4_ac3_entry(hdr),
      0,
      0,
    ),
  )
}

///|
/// Initialization segment for an E-AC-3 track (`ec-3`/`dec3`).  Media
/// samples are independent E-AC-3 frames (one substream).
pub fn fmp4_eac3_init_segment(
  first_frame : Bytes,
  track_id~ : Int32 = 1,
) -> Result[Bytes, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id <= 10 || hdr.frame_type == 1 || track_id <= 0 {
    return Err("EINVAL: invalid E-AC-3 fMP4 stream parameters")
  }
  Ok(
    fmp4_init_segment(
      track_id,
      hdr.sample_rate,
      "soun",
      mp4_eac3_entry(hdr),
      0,
      0,
    ),
  )
}

///|
/// Build one media segment (`styp`+`moof`+`mdat`).  `base_decode_time` is the
/// decode time of the first sample in the track timescale; `sequence_number`
/// goes into `mfhd`.
pub fn fmp4_media_segment(
  track_id : Int32,
  sequence_number : Int32,
  base_decode_time : Int64,
  samples : Array[Fmp4Sample],
) -> Result[Bytes, String] {
  if track_id <= 0 || sequence_number < 0 || base_decode_time < 0L {
    return Err("EINVAL: invalid fMP4 media segment parameters")
  }
  if samples.length() == 0 {
    return Err("EINVAL: empty fMP4 media segment")
  }
  for sample in samples {
    if sample.data.length() == 0 || sample.duration <= 0 {
      return Err("EINVAL: empty fMP4 sample or duration")
    }
  }
  let mfhd = fmp4_mfhd(sequence_number)
  // The field width does not change with the value, so sizing the `moof`
  // with a zero offset first gives the final offset for every sample.
  let traf_ph = fmp4_traf(track_id, base_decode_time, samples, 0U)
  let moof_ph = mp4_box("moof", mp4_cat([mfhd, traf_ph]))
  let data_offset = moof_ph.length() + 8
  let moof = mp4_box(
    "moof",
    mp4_cat([
      mfhd,
      fmp4_traf(
        track_id,
        base_decode_time,
        samples,
        data_offset.reinterpret_as_uint(),
      ),
    ]),
  )
  Ok(
    Bytes::from_array(
      mp4_cat([fmp4_styp(), moof, mp4_box("mdat", fmp4_payload(samples))]),
    ),
  )
}

///|
/// Build one media segment carrying both a video and an audio fragment in a
/// single `moof`.  The `mdat` holds the video payloads followed by the audio
/// payloads; each `traf` points at its own run.
pub fn fmp4_av_media_segment(
  sequence_number : Int32,
  video_samples : Array[Fmp4Sample],
  audio_samples : Array[Fmp4Sample],
  video_track_id~ : Int32 = 1,
  audio_track_id~ : Int32 = 2,
  video_base_decode_time~ : Int64 = 0L,
  audio_base_decode_time~ : Int64 = 0L,
) -> Result[Bytes, String] {
  if video_track_id <= 0 ||
    audio_track_id <= 0 ||
    video_track_id == audio_track_id ||
    sequence_number < 0 ||
    video_base_decode_time < 0L ||
    audio_base_decode_time < 0L {
    return Err("EINVAL: invalid A/V fMP4 media segment parameters")
  }
  if video_samples.length() == 0 || audio_samples.length() == 0 {
    return Err("EINVAL: empty fMP4 media segment")
  }
  for samples in [video_samples, audio_samples] {
    for sample in samples {
      if sample.data.length() == 0 || sample.duration <= 0 {
        return Err("EINVAL: empty fMP4 sample or duration")
      }
    }
  }
  let mfhd = fmp4_mfhd(sequence_number)
  let video_ph = fmp4_traf(
    video_track_id, video_base_decode_time, video_samples, 0U,
  )
  let audio_ph = fmp4_traf(
    audio_track_id, audio_base_decode_time, audio_samples, 0U,
  )
  let moof_ph = mp4_box("moof", mp4_cat([mfhd, video_ph, audio_ph]))
  let video_offset = moof_ph.length() + 8
  let video_payload = fmp4_payload(video_samples)
  let audio_offset = video_offset + video_payload.length()
  let moof = mp4_box(
    "moof",
    mp4_cat([
      mfhd,
      fmp4_traf(
        video_track_id,
        video_base_decode_time,
        video_samples,
        video_offset.reinterpret_as_uint(),
      ),
      fmp4_traf(
        audio_track_id,
        audio_base_decode_time,
        audio_samples,
        audio_offset.reinterpret_as_uint(),
      ),
    ]),
  )
  let data = video_payload
  for sample in audio_samples {
    for b in sample.data {
      data.push(b)
    }
  }
  Ok(Bytes::from_array(mp4_cat([fmp4_styp(), moof, mp4_box("mdat", data)])))
}

///|
/// One `sidx` reference: a media subsegment (`moof`+`mdat`) and its duration
/// in the track timescale.
pub struct Fmp4SidxRef {
  size : Int32
  duration : Int64
}

///|
pub fn Fmp4SidxRef::new(size : Int32, duration : Int64) -> Fmp4SidxRef {
  { size, duration, }
}

///|
/// A global `sidx` box (version 1, as `movenc.c` writes for fragmented
/// output) indexing consecutive media subsegments that start right after the
/// box. `earliest_presentation_time` is in `timescale` units.
pub fn fmp4_sidx(
  track_id : Int32,
  timescale : Int32,
  earliest_presentation_time : Int64,
  refs : ArrayView[Fmp4SidxRef],
) -> Result[Bytes, String] {
  if track_id <= 0 || timescale <= 0 || earliest_presentation_time < 0L {
    return Err("EINVAL: invalid sidx parameters")
  }
  if refs.length() > 65535 {
    return Err("EINVAL: too many sidx references")
  }
  for r in refs {
    if r.size < 0 || r.duration < 0L || r.duration > 0xFFFFFFFFL {
      return Err("EINVAL: invalid sidx reference")
    }
  }
  let body : Array[Byte] = []
  mp4_u32(body, track_id.reinterpret_as_uint()) // reference_ID
  mp4_u32(body, timescale.reinterpret_as_uint())
  fmp4_u64(body, earliest_presentation_time)
  fmp4_u64(body, 0L) // first_offset: first moof follows the sidx
  mp4_u16(body, 0) // reserved
  mp4_u16(body, refs.length())
  for r in refs {
    mp4_u32(body, r.size.reinterpret_as_uint() & 0x7FFFFFFFU) // media ref
    mp4_u32(body, r.duration.to_int().reinterpret_as_uint())
    mp4_u32(body, 0x80000000U) // starts_with_SAP, SAP_type 0
  }
  Ok(Bytes::from_array(mp4_full_box("sidx", 1, 0, body)))
}
