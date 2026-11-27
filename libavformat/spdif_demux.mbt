///|
/// IEC 61937 burst framing adapted from FFmpeg `libavformat/spdifdec.c`
/// (LGPL-2.1-or-later, copyright 2010 Anssi Hannula).
fn spdif_swap_words(data : BytesView, size : Int32) -> Bytes {
  Bytes::makei(size, i => data[i ^ 1])
}

///|
fn spdif_frames(
  codec : String,
  coded : Bytes,
  burst_samples : Int32,
) -> (Int32, Int32, Array[RawAudioFrame])? {
  if codec == "dts" {
    guard @libavcodec.parse_dca_core_header(coded[:]) is Ok(header) &&
      ((header.frame_size + 1) & -2) == coded.length() &&
      header.samples == burst_samples else {
      return None
    }
    return Some(
      (
        header.sample_rate,
        header.channels,
        [
          {
            pos: 0L,
            size: header.frame_size,
            pts: 0L,
            duration: header.samples,
            is_keyframe: true,
          },
        ],
      ),
    )
  }
  guard ac3_open(coded, fixed_format=true) is Ok(track) &&
    track.codec == codec &&
    track.total_samples == burst_samples.to_int64() &&
    (codec != "ac3" || track.frames.length() == 1) else {
    return None
  }
  let mut end = 0L
  for frame in track.frames {
    guard frame.pos == end else { return None }
    end += frame.size.to_int64()
  }
  guard end == coded.length().to_int64() else { return None }
  Some((track.sample_rate, track.channels, track.frames))
}

///|
priv struct SpdifBurst {
  codec : String
  sample_rate : Int32
  channels : Int32
  period : Int32
  samples : Int32
  frames : Array[RawAudioFrame]
  big_endian : Bool
}

///|
fn spdif_burst_period(data_type : Int32) -> Int32? {
  match data_type & 0xff {
    0x01 => Some(6144)
    0x04 => Some(1536)
    0x05 | 0x06 | 0x0a => Some(4608)
    0x07 => Some(4096)
    0x08 => Some(3072)
    0x09 => Some(9216)
    0x0b => Some(2048)
    0x0c => Some(4096)
    0x0d => Some(8192)
    0x11 => {
      let subtype = (data_type >> 8) & 0x1f
      if subtype <= 5 { Some(2048 << subtype) } else { None }
    }
    0x13 => Some(8192)
    0x15 => Some(24576)
    0x33 => Some(16384)
    _ => None
  }
}

///|
fn spdif_preamble_endian(payload : BytesView, pos : Int) -> Bool? {
  match payload[pos:] {
    [0x72, 0xf8, 0x1f, 0x4e, _, _, _, _, ..] => Some(false)
    [0xf8, 0x72, 0x4e, 0x1f, _, _, _, _, ..] => Some(true)
    _ => None
  }
}

///|
fn spdif_read_burst(payload : BytesView, pos : Int32) -> SpdifBurst? {
  guard spdif_preamble_endian(payload, pos) is Some(big_endian) else { return None }
  let data_type = wav_u16(payload, pos + 4, big_endian)
  let kind = data_type & 0xff
  guard spdif_burst_period(data_type) is Some(period) else { return None }
  let length_code = wav_u16(payload, pos + 6, big_endian)
  let size = if kind == 0x11 || kind == 0x15 {
    (length_code + 1) & -2
  } else {
    (length_code + 15) / 16 * 2
  }
  let start = pos + 8
  guard size > 0 && size <= period - 8 && size <= payload.length() - start else {
    return None
  }
  let stored = payload[start:start + size]
  let coded = if big_endian {
    stored.to_owned()
  } else {
    spdif_swap_words(stored, size)
  }
  match kind {
    0x04 | 0x05 | 0x06 | 0x08 | 0x09 | 0x0a =>
      return spdif_mpeg_burst(coded, kind, period, big_endian)
    0x07 | 0x13 | 0x33 =>
      return spdif_aac_burst(coded, kind, period, big_endian)
    0x11 => return spdif_dtshd_core_burst(coded[:], period, big_endian)
    _ => ()
  }
  let (codec, samples) = match kind {
    0x01 => ("ac3", 1536)
    0x15 => ("eac3", 1536)
    _ => ("dts", period / 4)
  }
  guard spdif_frames(codec, coded, samples)
    is Some((sample_rate, channels, frames)) else {
    return None
  }
  Some({ codec, sample_rate, channels, period, samples, frames, big_endian, })
}

///|
fn SpdifBurst::same_format(self : SpdifBurst, other : SpdifBurst) -> Bool {
  self.codec == other.codec &&
  self.sample_rate == other.sample_rate &&
  self.channels == other.channels &&
  self.big_endian == other.big_endian
}

///|
priv enum SpdifStart {
  Regular(Int, SpdifBurst)
  Mat(Int, Bool)
}

///|
fn spdif_find_start(data : BytesView) -> SpdifStart? {
  for pos in 0..<data.length().min(32768) {
    if data[pos] == 0x72 || data[pos] == 0xf8 {
      if spdif_mat_endian(data, pos) is Some(big_endian) {
        return Some(Mat(pos, big_endian))
      }
      if spdif_read_burst(data, pos) is Some(burst) {
        return Some(Regular(pos, burst))
      }
    }
  }
  None
}

///|
fn probe_spdif(pd : ProbeData) -> Int32 {
  let data = pd.buf[:]
  let (pos, repeated) = match spdif_find_start(data) {
    Some(Regular(pos, first)) => (pos, first.period < data.length() - pos &&
      spdif_read_burst(data, pos + first.period) is Some(second) && first.same_format(second))
    Some(Mat(pos, big_endian)) => (pos, spdif_mat_burst_size < data.length() - pos &&
      spdif_mat_endian(data, pos + spdif_mat_burst_size) == Some(big_endian))
    None => return 0
  }
  if repeated {
    // A container signature should win over a burst inside its data chunk.
    if pos == 0 {
      probe_score_max
    } else {
      75
    }
  } else if pos == 0 {
    probe_score_extension + 10
  } else {
    0
  }
}

///|
/// An IEC 61937 compressed stream. Frame positions point to the first coded
/// word in the input, and timestamps are in samples at `sample_rate`.
pub struct SpdifTrack {
  codec : String
  sample_rate : Int32
  channels : Int32
  frames : Array[RawAudioFrame]
  total_samples : Int64
  /// Byte order of the burst header and carrier words.
  big_endian : Bool
  priv data_end : Int32
  priv mat_start : Int?
}

///|
/// Open raw IEC 61937 carrying AC-3, E-AC-3, DTS core,
/// MPEG audio, ADTS AAC, or TrueHD in Dolby MAT. DTS type IV exposes its core.
pub fn av_spdif_open(data : Bytes) -> Result[SpdifTrack, String] {
  let view = data[:]
  match spdif_find_start(view) {
    Some(Regular(start, first)) => spdif_index(view, start, first, wave_padding=None)
    Some(Mat(start, big_endian)) => spdif_index_mat(view, start, big_endian, wave_padding=None)
    None => Err("spdif: no valid IEC 61937 burst")
  }
}

///|
/// Read a frame from the input passed to `av_spdif_open`, in decoder byte order.
/// Reuse `SpdifTrack::packet_data` when reading multiple frames from one input.
pub fn spdif_packet_data(
  data : Bytes,
  frame : RawAudioFrame,
) -> Result[Bytes, String] {
  match spdif_find_start(data[:]) {
    Some(Mat(start, big_endian)) => spdif_mat_packet_data(data[:], start, big_endian, frame.pos, frame.size)
    Some(Regular(_, burst)) => spdif_read_payload(data, frame.pos, frame.size, burst.big_endian)
    None => spdif_read_payload(data, frame.pos, frame.size, false)
  }
}

///|
/// Read an indexed frame using the byte order determined when opening the track.
pub fn SpdifTrack::packet_data(
  self : SpdifTrack,
  data : Bytes,
  frame : RawAudioFrame,
) -> Result[Bytes, String] {
  if self.mat_start is Some(start) {
    return spdif_mat_packet_data(data[:], start, self.big_endian, frame.pos, frame.size)
  }
  spdif_read_payload(data, frame.pos, frame.size, self.big_endian)
}

///|
fn spdif_read_payload(
  data : Bytes,
  start : Int64,
  size : Int32,
  big_endian : Bool,
) -> Result[Bytes, String] {
  let stored_size = (size.to_int64() + 1L) & -2L
  guard start >= 0L &&
    size >= 0 &&
    start <= data.length().to_int64() - stored_size else {
    return Err("spdif: packet extends past end of file")
  }
  let pos = start.to_int()
  if big_endian {
    Ok(data[pos:pos + size].to_owned())
  } else {
    Ok(spdif_swap_words(data[pos:(start + stored_size).to_int()], size))
  }
}

///|
fn spdif_index(
  payload : BytesView,
  start : Int32,
  first : SpdifBurst,
  wave_padding~ : Int32?,
) -> Result[SpdifTrack, String] {
  let frames : Array[RawAudioFrame] = []
  let mut burst_count = 0
  let mut pos = start
  let mut pts = 0L
  let mut burst = first
  while true {
    let remaining = payload.length() - pos
    if wave_padding is Some(_) && burst.period > remaining {
      return Err("spdif: incomplete burst period")
    }
    for frame in burst.frames {
      frames.push({
        ..frame,
        pos: pos.to_int64() + 8L + frame.pos,
        pts: pts + frame.pts,
      })
    }
    burst_count += 1
    pts += burst.samples.to_int64()
    // A raw capture may stop after the last coded word, before all padding.
    pos += burst.period.min(remaining)
    if pos == payload.length() ||
      (
        wave_padding is Some(limit) &&
        payload.length() - pos <= limit &&
        payload[pos:].iter().all(byte => byte == 0)
      ) {
      break
    }
    guard spdif_read_burst(payload, pos) is Some(next) else {
      return Err("spdif: invalid or truncated burst")
    }
    guard first.same_format(next) else {
      return Err("spdif: changing stream format")
    }
    burst = next
  }
  if wave_padding is Some(_) && burst_count < 2 {
    return Err("spdif: expected at least two WAV bursts")
  }
  Ok({
    codec: first.codec,
    sample_rate: first.sample_rate,
    channels: first.channels,
    frames,
    total_samples: pts,
    big_endian: first.big_endian,
    data_end: pos,
    mat_start: None,
  })
}

///|
fn wav_probe_spdif(
  payload : BytesView,
  fmt : WavFormat,
  data_offset : Int64,
  wave64~ : Bool,
) -> WavDemux? {
  let tail_padding = if wave64 { 7 } else { 0 }
  // Require two validated bursts at their predicted boundaries before
  // changing the PCM codec. Wave64 can include terminal alignment bytes.
  let big_endian = fmt.codec == "pcm_s16be"
  let indexed = if spdif_mat_endian(payload, 0) == Some(big_endian) {
    spdif_index_mat(payload, 0, big_endian, wave_padding=Some(tail_padding))
  } else {
    guard spdif_read_burst(payload, 0) is Some(first) && first.big_endian == big_endian else {
      return None
    }
    spdif_index(payload, 0, first, wave_padding=Some(tail_padding))
  }
  guard indexed is Ok(track) else {
    return None
  }
  let format = {
    ..fmt,
    codec: track.codec,
    sample_rate: track.sample_rate,
    channels: track.channels,
    channel_mask: 0U,
  }
  let demux = wav_indexed_demux(
    format,
    data_offset,
    track.frames,
    track.total_samples,
    frame_offset=data_offset,
    spdif_big_endian=Some(track.big_endian),
  )
  Some({ ..demux, data_size: track.data_end.to_int64(), })
}
