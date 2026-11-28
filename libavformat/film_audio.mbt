///|
/// Sega FILM/CPK audio indexing based on FFmpeg 9.0.2 segafilm.c.
/// LGPL-2.1-or-later.
fn probe_film(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 20 && data[:4] == b"FILM" && data[16:20] == b"FDSC" {
    probe_score_max
  } else {
    0
  }
}

///|
fn film_audio_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_film(ProbeData::new(data)) > 0 else {
    return Err("film: invalid header")
  }
  let data_offset = pb_be32(data, 4).to_int64()
  let old = pb_be32(data, 8) == 0U
  let table = if old { 36 } else { 48 }
  guard data.length() >= table + 16 && data[table:table + 4] == b"STAB" else {
    return Err("film: missing sample table")
  }
  let channels = if old { 1 } else { data[37].to_int() }
  let rate = if old { 22050 } else { pb_be16(data, 40).reinterpret_as_int() }
  let bits = if old { 8 } else { data[38].to_int() }
  guard channels >= 1 && channels <= 2 && rate > 0 else {
    return Err("film: missing audio or unsupported audio parameters")
  }
  let adx = !old && data[39] == 2
  let codec = if adx {
    "adpcm_adx"
  } else if old {
    "pcm_s8"
  } else if bits == 8 {
    "pcm_s8_planar"
  } else if bits == 16 {
    "pcm_s16be_planar"
  } else {
    return Err("film: unsupported PCM size")
  }
  let records = table + 16
  let count = pb_be32(data, table + 12).to_int64()
  guard data_offset >= records.to_int64() + count * 16L &&
    data_offset <= data.length().to_int64() else {
    return Err("film: invalid sample table extent")
  }
  let frames : Array[RawAudioFrame] = []
  let stride = channels * (bits / 8)
  let mut pts = 0L
  let mut audio_bytes = 0L
  for i in 0..<count.to_int() {
    let entry = records + i * 16
    if pb_be32(data, entry + 8) != 0xffffffffU {
      continue
    }
    let offset = data_offset + pb_be32(data, entry).to_int64()
    let size = pb_be32(data, entry + 4).to_int64()
    guard size > 0L && offset + size <= data.length().to_int64() else {
      return Err("film: invalid audio packet extent")
    }
    guard adx || size % stride.to_int64() == 0L else {
      return Err("film: incomplete PCM frame")
    }
    audio_bytes += size
    guard audio_bytes <= data.length().to_int64() else {
      return Err("film: overlapping audio samples exceed file size")
    }
    let duration = if adx { 0 } else { size.to_int() / stride }
    frames.push({
      pos: offset,
      size: size.to_int(),
      pts,
      duration,
      is_keyframe: true,
    })
    pts += duration.to_int64()
  }
  guard !frames.is_empty() else { return Err("film: no audio packets") }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: frames[0].duration,
    frames,
    total_samples: pts,
    bit_rate: if adx {
      0
    } else {
      rate * channels * bits
    },
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// ADX blocks can span FILM sample records. Reassemble just the audio
/// before passing it to the regular ADX header and frame parser.
fn film_adx_payload(data : Bytes, track : RawAudioTrack) -> Bytes {
  let bytes : Array[Byte] = []
  for frame in track.frames {
    let start = frame.pos.to_int()
    for byte in data[start:start + frame.size] {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes)
}
