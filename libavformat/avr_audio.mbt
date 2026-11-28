///|
/// Audio Visual Research PCM layout from FFmpeg 9.0.2 and SoX avr.c.
let avr_header_size = 128

///|
fn probe_avr(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() < 16 || data[:4] != b"2BIT" {
    return 0
  }
  let channel_flag = pb_be16(data, 12)
  let bits = pb_be16(data, 14)
  if (channel_flag == 0U || channel_flag == 0xffffU) &&
    (bits == 8U || bits == 16U) {
    probe_score_extension
  } else {
    probe_score_extension / 2
  }
}

///|
fn avr_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() > avr_header_size && data[:4] == b"2BIT" else {
    return Err("avr: missing header or PCM payload")
  }
  let channels = match pb_be16(data, 12) {
    0U => 1
    0xffffU => 2
    _ => return Err("avr: unsupported channel flag")
  }
  let bits = pb_be16(data, 14)
  let codec = match (bits, pb_be16(data, 16)) {
    (8U, 0U) => "pcm_u8"
    (8U, 0xffffU) => "pcm_s8"
    (16U, 0U) => "pcm_u16be"
    (16U, 0xffffU) => "pcm_s16be"
    _ => return Err("avr: unsupported PCM depth or signedness")
  }
  let rate = (pb_be32(data, 22) & 0xffffffU).reinterpret_as_int()
  let width = bits.reinterpret_as_int() / 8
  guard rate > 0 && (data.length() - avr_header_size) % (channels * width) == 0 else {
    return Err("avr: invalid sample rate or incomplete PCM frame")
  }
  Ok(
    raw_pcm_track(data.length(), avr_header_size, codec, rate, channels, width),
  )
}

///|
/// Write AVR PCM in mono or stereo, with looping disabled.
pub fn DecodedAudio::to_avr(
  self : DecodedAudio,
  bits~ : Int32 = 16,
  signed~ : Bool = true,
) -> Bytes raise MediaError {
  let channels = self.channels
  let rate = self.sample_rate
  guard (bits == 8 || bits == 16) &&
    (channels == 1 || channels == 2) &&
    rate > 0 &&
    rate <= 0xffffff else {
    raise UnsupportedCodec(
      "AVR export requires 8- or 16-bit mono/stereo PCM and a 24-bit sample rate",
    )
  }
  let frames = self.samples[0].length()
  let size = frames.to_int64() * channels.to_int64() * (bits / 8).to_int64()
  guard frames > 0 && size <= (0x7fffffff - avr_header_size).to_int64() else {
    raise DecodeError("avr: invalid PCM payload length")
  }
  let out : Array[Byte] = Array(capacity=avr_header_size + size.to_int())
  wav_mux_tag(out, "2BIT")
  for _ in 0..<8 {
    out.push(0)
  } // sample name
  aiff_mux_u16be(out, if channels == 2 { 0xffff } else { 0 })
  aiff_mux_u16be(out, bits)
  aiff_mux_u16be(out, if signed { 0xffff } else { 0 })
  aiff_mux_u16be(out, 0) // no loop
  aiff_mux_u16be(out, 0xffff) // no MIDI note
  aiff_mux_u32be(out, rate.reinterpret_as_uint())
  aiff_mux_u32be(out, frames.reinterpret_as_uint())
  aiff_mux_u32be(out, 0U)
  aiff_mux_u32be(out, frames.reinterpret_as_uint())
  for _ in out.length()..<avr_header_size {
    out.push(0)
  }
  let offset = if signed { 0 } else { 1 << (bits - 1) }
  for frame in 0..<frames {
    for plane in self.samples {
      let sample = playback_pcm_quantize(plane[frame], bits) + offset
      if bits == 8 {
        out.push(sample.to_byte())
      } else {
        aiff_mux_u16be(out, sample)
      }
    }
  }
  Bytes::from_array(out)
}
