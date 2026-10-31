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
  /// Encoder delay in media samples, expressed as an `elst` edit.
  priming : Int32
  /// The `stsd` sample entry (AAC, AC-3, E-AC-3, ...).
  entry : Array[Byte]
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn mp4_aac_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  /// Leading samples (AAC encoder delay) to skip via `edts`/`elst`.
  priming~ : Int32 = 0,
) -> Result[Mp4AacMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 7 || priming < 0 {
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
  mp4_audio_muxer_new(
    mp4_aac_entry(sample_rate, channels),
    sample_rate,
    channels,
    priming~,
  )
}

///|
/// Generic one-track MP4 audio muxer: `entry` is a complete sample entry
/// (built by `mp4_aac_entry`, `mp4_ac3_entry`, `mp4_eac3_entry`, ...).
pub fn mp4_audio_muxer_new(
  entry : Array[Byte],
  sample_rate : Int32,
  channels : Int32,
  priming~ : Int32 = 0,
) -> Result[Mp4AacMuxer, String] {
  if sample_rate <= 0 || channels < 1 || entry.length() == 0 || priming < 0 {
    return Err("EINVAL: invalid MP4 audio stream parameters")
  }
  Ok({ sample_rate, channels, priming, entry, packets: [], durations: [], })
}

///|
fn mp4_mux_rates() -> Array[Int32] {
  [
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025,
    8000, 7350,
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
/// Pack a 3-letter ISO 639-2/T code into the `mdhd` language field (pad bit
/// clear). Anything unrecognised becomes "und" (0x55C4), like movenc.
fn mp4_language_code(lang : String) -> Int32 {
  if lang.length() != 3 {
    return 0x55C4
  }
  let mut v = 0
  for i in 0..<3 {
    let c = lang[i].to_int() - 0x60
    if c < 1 || c > 26 {
      return 0x55C4
    }
    v = (v << 5) | c
  }
  v
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
fn mp4_full_box(
  tag : String,
  version : Int32,
  flags : Int32,
  body : Array[Byte],
) -> Array[Byte] {
  let full : Array[Byte] = []
  mp4_u32(
    full,
    (version << 24).reinterpret_as_uint() | flags.reinterpret_as_uint(),
  )
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
/// `edts`/`elst` with a single edit that skips `priming` leading media
/// samples (AAC encoder delay), mirroring the edit list `movenc` writes for
/// `initial_padding`. `movie_timescale` is the enclosing movie time base,
/// `media_timescale` the track media one.
fn mp4_edit_list(
  priming : Int32,
  media_duration : Int32,
  movie_timescale : Int32,
  media_timescale : Int32,
) -> Array[Byte] {
  let skip = if priming < media_duration { priming } else { media_duration }
  let kept = media_duration - skip
  // Round the edit duration up: a truncated movie-timescale duration would
  // make demuxers trim the tail of the last kept frame.
  let movie_duration = (
      kept.to_int64() * movie_timescale.to_int64() +
      media_timescale.to_int64() -
      1L
    ) /
    media_timescale.to_int64()
  let body : Array[Byte] = []
  mp4_u32(body, 1U) // entry_count
  mp4_u32(body, movie_duration.to_int().reinterpret_as_uint())
  mp4_u32(body, skip.reinterpret_as_uint()) // media_time
  mp4_u32(body, 0x00010000U) // media_rate 1.0
  mp4_box("edts", mp4_full_box("elst", 0, 0, body))
}

///|
/// One-edit `edts` that starts playback at `media_time` (media timescale) and
/// presents `movie_duration` (movie timescale) units.
fn mp4_edit_list_at(media_time : Int32, movie_duration : Int32) -> Array[Byte] {
  let body : Array[Byte] = []
  mp4_u32(body, 1U) // entry_count
  mp4_u32(body, movie_duration.reinterpret_as_uint())
  mp4_u32(body, media_time.reinterpret_as_uint())
  mp4_u32(body, 0x00010000U)
  mp4_box("edts", mp4_full_box("elst", 0, 0, body))
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
  duration~ : Int32 = 1024,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: empty audio packet or duration")
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
  let priming = if self.priming < total_duration {
    self.priming
  } else {
    total_duration
  }
  let display_duration = total_duration - priming
  let edts : Array[Byte] = if priming > 0 {
    mp4_edit_list(priming, total_duration, self.sample_rate, self.sample_rate)
  } else {
    []
  }

  let mvhd_body : Array[Byte] = []
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, 0U)
  mp4_u32(mvhd_body, self.sample_rate.reinterpret_as_uint())
  mp4_u32(mvhd_body, display_duration.reinterpret_as_uint())
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
  mp4_u32(tkhd_body, display_duration.reinterpret_as_uint())
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
  stsd_body.append(self.entry)
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
  let trak = mp4_box("trak", mp4_cat([tkhd, edts, mdia]))
  let moov = mp4_box("moov", mp4_cat([mvhd, trak]))
  Bytes::from_array(mp4_cat([ftyp, mdat, moov]))
}

///|
/// `ff_ac3_bitrate_tab` in kbit/s, for the `dac3` bit_rate_code.
let mp4_ac3_bitrates : FixedArray[Int32] = [
  32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576,
  640,
]

///|
fn mp4_bits_push(bits : Array[Int32], value : Int32, count : Int32) -> Unit {
  for i = 0; i < count; i = i + 1 {
    bits.push((value >> (count - 1 - i)) & 1)
  }
}

///|
fn mp4_bits_to_bytes(bits : Array[Int32]) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut acc = 0
  let mut n = 0
  for bit in bits {
    acc = (acc << 1) | bit
    n = n + 1
    if n == 8 {
      out.push(acc.to_byte())
      acc = 0
      n = 0
    }
  }
  if n > 0 {
    out.push((acc << (8 - n)).to_byte())
  }
  out
}

///|
/// `dac3` (AC3SpecificBox) from the parsed frame header. */
fn mp4_dac3(hdr : @libavcodec.Ac3Header) -> Array[Byte] {
  let mut bit_rate_code = 0
  for i = 0; i < mp4_ac3_bitrates.length(); i = i + 1 {
    if mp4_ac3_bitrates[i] * 1000 == hdr.bit_rate {
      bit_rate_code = i
    }
  }
  let bits : Array[Int32] = []
  mp4_bits_push(bits, hdr.sr_code, 2)
  mp4_bits_push(bits, hdr.bitstream_id, 5)
  mp4_bits_push(bits, hdr.bitstream_mode, 3)
  mp4_bits_push(bits, hdr.channel_mode, 3)
  mp4_bits_push(bits, if hdr.lfe_on { 1 } else { 0 }, 1)
  mp4_bits_push(bits, bit_rate_code, 5)
  mp4_bits_push(bits, 0, 5)
  mp4_box("dac3", mp4_bits_to_bytes(bits))
}

///|
/// `dec3` (EC3SpecificBox) for one independent substream, no dependent
/// substreams and no type-A extension.
fn mp4_dec3(hdr : @libavcodec.Ac3Header) -> Array[Byte] {
  let bits : Array[Int32] = []
  mp4_bits_push(bits, hdr.bit_rate / 1000, 13)
  mp4_bits_push(bits, 0, 3) // num_ind_sub - 1
  mp4_bits_push(bits, hdr.sr_code, 2)
  mp4_bits_push(bits, hdr.bitstream_id, 5)
  mp4_bits_push(bits, 0, 1) // reserved
  mp4_bits_push(bits, 0, 1) // asvc
  mp4_bits_push(bits, hdr.bitstream_mode, 3)
  mp4_bits_push(bits, hdr.channel_mode, 3)
  mp4_bits_push(bits, if hdr.lfe_on { 1 } else { 0 }, 1)
  mp4_bits_push(bits, 0, 3) // reserved
  mp4_bits_push(bits, 0, 4) // num_dep_sub
  mp4_bits_push(bits, 0, 1) // reserved
  mp4_box("dec3", mp4_bits_to_bytes(bits))
}

///|
fn mp4_audio_sample_entry(
  fourcc : String,
  sample_rate : Int32,
  channels : Int32,
  child : Array[Byte],
) -> Array[Byte] {
  let body : Array[Byte] = []
  for i = 0; i < 6; i = i + 1 {
    body.push(b'\x00')
  }
  mp4_u16(body, 1) // data_reference_index
  mp4_u16(body, 0) // version
  mp4_u16(body, 0) // revision
  mp4_u32(body, 0U) // vendor
  mp4_u16(body, channels)
  mp4_u16(body, 16) // sample size
  mp4_u16(body, 0) // compression id
  mp4_u16(body, 0) // packet size
  mp4_u32(body, (sample_rate << 16).reinterpret_as_uint())
  body.append(child)
  mp4_box(fourcc, body)
}

///|
/// `ac-3` sample entry with a `dac3` child. */
pub fn mp4_ac3_entry(hdr : @libavcodec.Ac3Header) -> Array[Byte] {
  mp4_audio_sample_entry("ac-3", hdr.sample_rate, hdr.channels, mp4_dac3(hdr))
}

///|
/// `ec-3` sample entry with a `dec3` child. */
pub fn mp4_eac3_entry(hdr : @libavcodec.Ac3Header) -> Array[Byte] {
  mp4_audio_sample_entry("ec-3", hdr.sample_rate, hdr.channels, mp4_dec3(hdr))
}

///|
/// One-track AC-3-in-MP4 muxer.  `first_frame` supplies the sample rate,
/// channel count and `dac3` fields; the caller writes every frame (including
/// this one) with a 1536-sample duration.
pub fn mp4_ac3_muxer_new(first_frame : Bytes) -> Result[Mp4AacMuxer, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id > 10 {
    return Err("EINVAL: E-AC-3 frame in an AC-3 muxer")
  }
  mp4_audio_muxer_new(mp4_ac3_entry(hdr), hdr.sample_rate, hdr.channels)
}

///|
/// One-track E-AC-3-in-MP4 muxer (independent frames, one substream). */
pub fn mp4_eac3_muxer_new(first_frame : Bytes) -> Result[Mp4AacMuxer, String] {
  let hdr = match @libavcodec.ac3_parse_header(first_frame) {
    Ok(h) => h
    Err(e) => return Err("EINVAL: \{e}")
  }
  if hdr.bitstream_id <= 10 || hdr.frame_type == 1 {
    return Err("EINVAL: frame is not an independent E-AC-3 frame")
  }
  mp4_audio_muxer_new(mp4_eac3_entry(hdr), hdr.sample_rate, hdr.channels)
}

///|
/// `ctts` box for per-sample PTS-DTS offsets: consecutive equal offsets are
/// run-length merged, version 1 is used when any offset is negative, and
/// `None` means every offset is zero (box omitted).
fn mp4_ctts_box(cts : Array[Int32]) -> Array[Byte]? {
  let mut has_cts = false
  for c in cts {
    if c != 0 {
      has_cts = true
    }
  }
  if !has_cts {
    return None
  }
  let mut version = 0
  for c in cts {
    if c < 0 {
      version = 1
    }
  }
  let runs : Array[(Int32, Int32)] = []
  for c in cts {
    if runs.length() > 0 && runs[runs.length() - 1].1 == c {
      runs[runs.length() - 1] = (runs[runs.length() - 1].0 + 1, c)
    } else {
      runs.push((1, c))
    }
  }
  let body : Array[Byte] = []
  mp4_u32(body, runs.length().reinterpret_as_uint())
  for run in runs {
    mp4_u32(body, run.0.reinterpret_as_uint())
    mp4_u32(body, run.1.reinterpret_as_uint())
  }
  Some(mp4_full_box("ctts", version, 0, body))
}

///|
/// Video `edts` for a sample list with composition offsets: when the first
/// displayed PTS is positive (B-frame reorder delay), trim it so presentation
/// starts at 0. `total_duration` is the full media duration in the track
/// timescale (single-track writers use it as the movie timescale too).
fn mp4_video_edts(
  durations : Array[Int32],
  cts : Array[Int32],
  total_duration : Int32,
) -> Array[Byte] {
  let mut first_pts = 0L
  let mut dts = 0L
  for i in 0..<durations.length() {
    let c = if i < cts.length() { cts[i].to_int64() } else { 0L }
    let pts = dts + c
    if i == 0 || pts < first_pts {
      first_pts = pts
    }
    dts = dts + durations[i].to_int64()
  }
  if first_pts <= 0L || first_pts >= total_duration.to_int64() {
    return []
  }
  mp4_edit_list_at(first_pts.to_int(), total_duration)
}
