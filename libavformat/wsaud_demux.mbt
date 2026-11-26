///|
fn wsaud_u16(data : Bytes, offset : Int32) -> Int32 {
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
/// Match the header and first chunk marker used by FFmpeg's
/// libavformat/westwood_aud.c (LGPL-2.1-or-later).
fn probe_wsaud(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 20 else { return 0 }
  let rate = wsaud_u16(data, 0)
  if rate >= 8000 &&
    rate <= 48000 &&
    data[10].to_int() <= 3 &&
    (data[11] == 1 || data[11] == 99) &&
    data[16:20] == b"\xaf\xde\x00\x00"[:] {
    probe_score_extension
  } else {
    0
  }
}

///|
/// Open a Westwood AUD stream. Each indexed frame points to compressed audio
/// immediately after its eight-byte chunk preamble.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_wsaud_open(b"") is Err("wsaud: invalid header"))
/// }
/// ```
pub fn av_wsaud_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if probe_wsaud(ProbeData::new(data)) == 0 {
    return Err("wsaud: invalid header")
  }
  let channels = (data[10].to_int() & 1) + 1
  let rate = wsaud_u16(data, 0)
  let snd1 = data[11] == 1
  if snd1 && channels != 1 {
    return Err("wsaud: SND1 requires mono")
  }
  let frames : Array[RawAudioFrame] = []
  let mut offset = 12
  let mut pts = 0L
  while offset < data.length() {
    if data.length() - offset < 8 {
      return Err("wsaud: truncated chunk header")
    }
    if data[offset + 4:offset + 8] != b"\xaf\xde\x00\x00"[:] {
      return Err("wsaud: invalid chunk marker")
    }
    let size = wsaud_u16(data, offset)
    let start = offset + 8
    if size == 0 || size > data.length() - start {
      return Err("wsaud: invalid chunk size")
    }
    // Discard an incomplete stereo group, but advance past the full chunk.
    let usable = if snd1 { size } else { size / channels * channels }
    let duration = if snd1 {
      wsaud_u16(data, offset + 2)
    } else {
      usable / channels * 2
    }
    if duration == 0 {
      return Err("wsaud: invalid chunk sample count")
    }
    frames.push({
      pos: start.to_int64(),
      size: usable,
      pts,
      duration,
      is_keyframe: true,
    })
    pts += duration.to_int64()
    offset = start + size
  }
  Ok({
    codec: if snd1 {
      "ws_snd1"
    } else {
      "adpcm_ima_ws"
    },
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: 0,
    frames,
    total_samples: pts,
    bit_rate: if snd1 {
      0
    } else {
      channels * rate * 4
    },
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
