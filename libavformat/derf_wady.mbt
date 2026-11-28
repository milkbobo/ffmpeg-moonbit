///|
/// Xilam DERF and Marble WADY from FFmpeg 9.0.2 derf.c and wady.c.
/// Copyright (c) 2020, 2023 Paul B Mahol. LGPL-2.1-or-later.
fn probe_derf(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 8 &&
    data[:4] == b"DERF" &&
    wav_u32(data[:], 4, false) is (1L | 2L) {
    probe_score_max / 3 * 2
  } else {
    0
  }
}

///|
fn probe_wady(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 12 && data[:4] == b"WADY" else { return 0 }
  let rate = wav_u32(data[:], 8, false)
  if data[4] == 0 &&
    data[5] != 0 &&
    wav_u16(data[:], 6, false) is (1 | 2) &&
    rate > 0L &&
    rate <= 0x7fffffffL {
    probe_score_max / 3 * 2
  } else {
    0
  }
}

///|
fn derf_wady_open(data : Bytes, wady~ : Bool) -> Result[RawAudioTrack, String] {
  let start = if wady { 48 } else { 12 }
  let probe = if wady { probe_wady } else { probe_derf }
  guard data.length() > start && probe(ProbeData::new(data)) > 0 else {
    return Err("DERF/WADY: missing header or audio payload")
  }
  let (codec, rate, channels, sample_count, align) = if wady {
    let channels = wav_u16(data[:], 6, false)
    (
      "wady_dpcm",
      wav_u32(data[:], 8, false).to_int(),
      channels,
      wav_u32(data[:], 16, false),
      channels,
    )
  } else {
    let channels = wav_u32(data[:], 4, false).to_int()
    (
      "derf_dpcm",
      22050,
      channels,
      wav_u32(data[:], 8, false) / channels.to_int64(),
      1,
    )
  }
  guard (data.length() - start) % channels == 0 else {
    return Err("DERF/WADY: incomplete channel frame")
  }
  let packet_size = wav_pcm_default_packet_size(align, codec, rate, channels, 0)
  let frames : Array[RawAudioFrame] = []
  for pos = start; pos < data.length(); {
    let size = (data.length() - pos).min(packet_size)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: (pos - start).to_int64() / channels.to_int64(),
      duration: size / channels,
      is_keyframe: pos == start,
    })
    continue pos + size
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: packet_size / channels,
    frames,
    total_samples: sample_count,
    bit_rate: (rate.to_int64() * channels.to_int64() * 8L)
    .min(0x7fffffffL)
    .to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
