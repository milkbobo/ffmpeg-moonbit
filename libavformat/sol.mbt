///|
/// Sierra SOL from FFmpeg 9.0.2 sol.c, Copyright Konstantin Shishkov.
/// LGPL-2.1-or-later.
fn probe_sol(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 6 && data[2:6] == b"SOL\x00" else { return 0 }
  match wav_u16(data[:], 0, false) {
    0x0b8d | 0x0c0d | 0x0c8d => probe_score_max
    _ => 0
  }
}

///|
fn sol_dpcm_mode(data : Bytes) -> Int32 {
  let flags = data[8].to_int()
  let magic = wav_u16(data[:], 0, false)
  if (flags & 1) == 0 {
    0
  } else if magic == 0x0b8d {
    1
  } else if (flags & 4) != 0 {
    3
  } else if magic == 0x0c8d {
    1
  } else {
    2
  }
}

///|
fn sol_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_sol(ProbeData::new(data)) > 0 else {
    return Err("sol: invalid header")
  }
  let old = wav_u16(data[:], 0, false) == 0x0b8d
  let start = if old { 13 } else { 14 }
  guard data.length() > start else { return Err("sol: missing audio payload") }
  let rate = wav_u16(data[:], 6, false)
  guard rate > 0 else { return Err("sol: invalid sample rate") }
  let flags = data[8].to_int()
  let channels = if !old && (flags & 16) != 0 { 2 } else { 1 }
  let (codec, bits) = match sol_dpcm_mode(data) {
    0 if !old && (flags & 4) != 0 => ("pcm_s16le", 16)
    0 => ("pcm_u8", 8)
    3 => ("sol_dpcm", 8)
    _ => ("sol_dpcm", 4)
  }
  let frame_bits = bits * channels
  let alignment = (frame_bits / 8).max(1)
  guard (data.length() - start) % alignment == 0 else {
    return Err("sol: incomplete channel frame")
  }
  let frames : Array[RawAudioFrame] = []
  for pos = start; pos < data.length(); {
    let size = (data.length() - pos).min(4096)
    frames.push({
      pos: pos.to_int64(),
      size,
      pts: (pos - start).to_int64() * 8L / frame_bits.to_int64(),
      duration: size * 8 / frame_bits,
      is_keyframe: codec != "sol_dpcm" || pos == start,
    })
    continue pos + size
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: 4096 * 8 / frame_bits,
    frames,
    total_samples: (data.length() - start).to_int64() *
    8L /
    frame_bits.to_int64(),
    bit_rate: frame_bits * rate,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
