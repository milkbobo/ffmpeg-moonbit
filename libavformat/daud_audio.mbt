///|
/// D-Cinema audio from FFmpeg 9.0.2 dauddec.c and daudenc.c.
/// Copyright (c) 2005 Reimar Döffinger. LGPL-2.1-or-later.
let daud_sample_rate = 96000

///|
let daud_channels = 6

///|
let daud_channel_mask = 0x60fU

///|
fn daud_open(data : Bytes) -> Result[RawAudioTrack, String] {
  let align = daud_channels * 3
  let packets : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = 0; pos < data.length(); {
    guard pos <= data.length() - 4 else {
      return Err("daud: truncated packet header")
    }
    let size = pb_be16(data, pos).reinterpret_as_int()
    let start = pos + 4
    guard size > 0 && size % align == 0 else {
      return Err("daud: invalid packet size")
    }
    guard size <= data.length() - start else {
      return Err("daud: truncated packet")
    }
    let duration = size / align
    packets.push({
      pos: start.to_int64(),
      size,
      pts,
      duration,
      is_keyframe: true,
    })
    pts += duration.to_int64()
    continue start + size
  }
  guard !packets.is_empty() else { return Err("daud: missing audio packets") }
  Ok({
    codec: "pcm_s24daud",
    profile: "",
    sample_rate: daud_sample_rate,
    channels: daud_channels,
    frame_size: packets[0].duration,
    frames: packets,
    total_samples: pts,
    bit_rate: daud_sample_rate * align * 8,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Write 96 kHz, six-channel D-Cinema PCM with an unpadded final packet.
pub fn DecodedAudio::to_daud(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.sample_rate == daud_sample_rate && self.channels == daud_channels else {
    raise UnsupportedCodec(
      "D-Cinema audio export requires six channels at 96000 Hz",
    )
  }
  let packet_frames = 2000
  let frames = self.samples[0].length()
  guard frames > 0 else { raise DecodeError("daud: no audio samples") }
  let packets = (frames - 1) / packet_frames + 1
  let length = frames.to_int64() * 18L + packets.to_int64() * 4L
  guard length <= 0x7fffffffL else {
    raise DecodeError("daud: PCM exceeds output buffer limit")
  }
  let out : Array[Byte] = Array(capacity=length.to_int())
  for start = 0; start < frames; {
    let count = (frames - start).min(packet_frames)
    let samples = Array::makei(count * daud_channels, i => {
      let sample = self.samples[i % daud_channels][start + i / daud_channels]
      playback_pcm_quantize(sample, 16)
    })
    let payload = @libavcodec.encode_pcm_daud(samples[:])
    aiff_mux_u16be(out, payload.length())
    aiff_mux_u16be(out, 0x8010)
    for byte in payload {
      out.push(byte)
    }
    continue start + count
  }
  Bytes::from_array(out)
}
