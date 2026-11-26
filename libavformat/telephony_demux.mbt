///|
/// G.722 and G.726 have no signature. A matching extension outranks weak
/// byte patterns, while a stronger container signature still wins.
fn probe_telephony(pd : ProbeData, format : FormatId) -> Int32 {
  if probe_match_ext(pd.filename, format.extensions()) {
    probe_score_extension
  } else {
    0
  }
}

///|
/// Fixed-size raw reads from FFmpeg's g722.c and g726.c. A 1020-byte
/// G.726 packet ends on a codeword boundary at every supported width.
fn telephony_open(
  data : Bytes,
  format : FormatId,
  g726_bits : Int32,
) -> Result[RawAudioTrack, String] {
  let (codec, bits, rate, packet_size) = match format {
    G722 => ("adpcm_g722", 4, 16000, 1024)
    G726 => ("adpcm_g726", g726_bits, 8000, 1020)
    G726Le => ("adpcm_g726le", g726_bits, 8000, 1020)
    _ => return Err("unsupported raw telephony format")
  }
  if bits < 2 || bits > 5 {
    return Err("g726: code width must be 2, 3, 4 or 5 bits")
  }
  if data.is_empty() {
    return Err("empty raw telephony stream")
  }
  let frames : Array[RawAudioFrame] = []
  let mut pos = 0
  let mut pts = 0L
  while pos < data.length() {
    let size = packet_size.min(data.length() - pos)
    let duration = size * 8 / bits
    frames.push({
      pos: pos.to_int64(),
      size,
      pts,
      duration,
      is_keyframe: true,
    })
    pos += size
    pts += duration.to_int64()
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels: 1,
    frame_size: packet_size * 8 / bits,
    frames,
    total_samples: pts,
    bit_rate: rate * bits,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}
