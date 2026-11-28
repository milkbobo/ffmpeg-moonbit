///|
/// GameCube RSD audio demuxing based on FFmpeg 9.0.2 rsd.c.
/// LGPL-2.1-or-later.
fn probe_rsd(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 20 &&
    data[:3] == b"RSD" &&
    data[3] >= b'2' &&
    data[3] <= b'6' else {
    return 0
  }
  let channels = wav_u32(data[:], 8, false)
  let rate = wav_u32(data[:], 16, false)
  if channels > 0L && channels <= 256L && rate > 0L && rate <= 384000L {
    probe_score_max
  } else {
    probe_score_max / 8
  }
}

///|
fn rsd_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 24 && probe_rsd(ProbeData::new(data)) > 0 else {
    return Err("rsd: invalid header")
  }
  let src = data[:]
  let channels = wav_u32(src, 8, false)
  let rate = wav_u32(src, 16, false)
  guard channels > 0L && channels <= 2L && rate > 0L && rate <= 0x7fffffffL else {
    return Err("rsd: invalid sample rate or unsupported channel count")
  }
  let ch = channels.to_int()
  let (codec, size, frames_per_block, explicit_offset) = match src[4:8] {
    [b'V', b'A', b'G', b' '] => ("adpcm_psx", 16 * ch, 28, false)
    [b'R', b'A', b'D', b'P'] => ("adpcm_ima_rad", 20 * ch, 32, false)
    [b'X', b'A', b'D', b'P'] => ("adpcm_ima_wav", 36 * ch, 65, data[3] == b'2')
    [b'W', b'A', b'D', b'P'] =>
      ("adpcm_thp", if ch == 1 { 1024 } else { 16 }, 14, false)
    [b'G', b'A', b'D', b'P'] if ch == 1 => ("adpcm_thp_le", 1024, 14, true)
    [b'P', b'C', b'M', b' '] => ("pcm_s16le", 1024, 0, data[3] != b'4')
    [b'P', b'C', b'M', b'B'] => ("pcm_s16be", 1024, 0, data[3] != b'4')
    _ => return Err("rsd: unsupported audio codec")
  }
  if explicit_offset && data.length() < 28 {
    return Err("rsd: missing audio offset")
  }
  let offset = if explicit_offset { wav_u32(src, 24, false) } else { 2048L }
  let header_size = if codec == "adpcm_thp_le" {
    60L
  } else if explicit_offset {
    28L
  } else {
    24L
  }
  guard offset >= header_size && offset < data.length().to_int64() else {
    return Err("rsd: invalid audio offset")
  }
  let start = offset.to_int()
  let dsp = codec == "adpcm_thp" || codec == "adpcm_thp_le"
  let alignment = if dsp {
    ch * 8
  } else if frames_per_block == 0 {
    ch * 2
  } else {
    size
  }
  guard (data.length() - start) % alignment == 0 else {
    return Err("rsd: incomplete audio block")
  }
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = start; pos < data.length(); {
    let bytes = (data.length() - pos).min(size)
    let duration = if dsp {
      bytes / alignment * 14
    } else if frames_per_block == 0 {
      bytes / alignment
    } else {
      frames_per_block
    }
    frames.push({
      pos: pos.to_int64(),
      size: bytes,
      pts,
      duration,
      is_keyframe: true,
    })
    pts += duration.to_int64()
    continue pos + bytes
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate.to_int(),
    channels: ch,
    frame_size: frames[0].duration,
    frames,
    total_samples: pts,
    bit_rate: 0,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
fn rsd_dsp_extradata(data : Bytes, codec : String, channels : Int32) -> Bytes? {
  match codec {
    "adpcm_thp_le" => Some(data[28:60].to_owned())
    "adpcm_thp" =>
      Some(Bytes::makei(channels * 32, i => data[0x1a4 + i / 32 * 40 + i % 32]))
    _ => None
  }
}
