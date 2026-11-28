///|
/// Nintendo AST layout from FFmpeg 9.0.2 astdec.c and astenc.c.
/// Copyright (c) 2012 Paul B Mahol and James Almer. LGPL-2.1-or-later.
fn probe_ast(pd : ProbeData) -> Int32 {
  let data = pd.buf
  guard data.length() >= 20 && data[:4] == b"STRM" else { return 0 }
  let channels = pb_be16(data, 12)
  let rate = pb_be32(data, 16)
  if pb_be16(data, 10) == 16U &&
    channels > 0U &&
    channels <= 256U &&
    rate > 0U &&
    rate <= 384000U {
    probe_score_max / 3 * 2
  } else {
    probe_score_max / 8
  }
}

///|
fn ast_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 64 && data[:4] == b"STRM" else {
    return Err("ast: invalid header")
  }
  let tag = pb_be16(data, 8)
  let channels = pb_be16(data, 12).reinterpret_as_int()
  let rate = pb_be32(data, 16).reinterpret_as_int()
  guard tag <= 1U &&
    pb_be16(data, 10) == 16U &&
    channels > 0 &&
    channels <= (if tag == 0U { 6 } else { 256 }) &&
    rate > 0 else {
    return Err("ast: unsupported audio parameters")
  }
  let declared = pb_be32(data, 4).to_int64()
  guard declared <= (data.length() - 64).to_int64() else {
    return Err("ast: truncated stream")
  }
  let end = if declared == 0L { data.length() } else { 64 + declared.to_int() }
  let afc = tag == 0U
  let stride = if afc { 9L } else { 2L }
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = 64; pos < end; {
    guard pos <= end - 32 && data[pos:pos + 4] == b"BLCK" else {
      return Err("ast: invalid audio block header")
    }
    let start = pos + 32
    let per_channel = pb_be32(data, pos + 4).to_int64()
    let size = per_channel * channels.to_int64()
    let samples = per_channel / stride * (if afc { 16L } else { 1L })
    guard size > 0L &&
      size <= (end - start).to_int64() &&
      per_channel % stride == 0L &&
      samples * channels.to_int64() <= 0x7fffffffL else {
      return Err("ast: invalid audio block extent")
    }
    frames.push({
      pos: start.to_int64(),
      size: size.to_int(),
      pts,
      duration: samples.to_int(),
      is_keyframe: !afc || frames.is_empty(),
    })
    pts += samples
    continue start + size.to_int()
  }
  guard !frames.is_empty() else { return Err("ast: no audio blocks") }
  Ok({
    codec: if afc {
      "adpcm_afc"
    } else {
      "pcm_s16be_planar"
    },
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: frames[0].duration,
    frames,
    total_samples: pts,
    bit_rate: (rate.to_int64() *
    channels.to_int64() *
    (if afc { 9L * 8L } else { 16L }) /
    (if afc { 16L } else { 1L }))
    .min(0x7fffffffL)
    .to_int(),
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Write Nintendo AST with signed 16-bit big-endian planar PCM and no loop.
pub fn DecodedAudio::to_ast(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels >= 1 && self.channels <= 256 && self.sample_rate > 0 else {
    raise DecodeError("ast: invalid sample rate or channel count")
  }
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("ast: no audio samples") }
  let packet_frames = 1024
  let packets = (frames - 1) / packet_frames + 1
  let size = frames.to_int64() * self.channels.to_int64() * 2L +
    packets.to_int64() * 32L
  guard size <= 0x7fffffffL - 64L else {
    raise DecodeError("ast: PCM exceeds output buffer limit")
  }
  let out : Array[Byte] = Array(capacity=64 + size.to_int())
  wav_mux_tag(out, "STRM")
  aiff_mux_u32be(out, size.to_int().reinterpret_as_uint())
  aiff_mux_u16be(out, 1)
  aiff_mux_u16be(out, 16)
  aiff_mux_u16be(out, self.channels)
  aiff_mux_u16be(out, 0)
  aiff_mux_u32be(out, self.sample_rate.reinterpret_as_uint())
  aiff_mux_u32be(out, frames.reinterpret_as_uint())
  aiff_mux_u32be(out, 0U)
  aiff_mux_u32be(out, frames.reinterpret_as_uint())
  aiff_mux_u32be(out, (frames.min(packet_frames) * 2).reinterpret_as_uint())
  aiff_mux_u32be(out, 0U)
  wav_mux_u32(out, 0x7fU)
  for _ in 44..<64 {
    out.push(0)
  }
  for start = 0; start < frames; {
    let count = (frames - start).min(packet_frames)
    wav_mux_tag(out, "BLCK")
    aiff_mux_u32be(out, (count * 2).reinterpret_as_uint())
    for _ in 0..<24 {
      out.push(0)
    }
    for plane in self.samples {
      for frame in start..<(start + count) {
        aiff_mux_u16be(out, playback_pcm_quantize(plane[frame], 16))
      }
    }
    continue start + count
  }
  Bytes::from_array(out)
}
