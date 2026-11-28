///|
/// ADX block framing from FFmpeg adxdec.c and the ADX codec parser.
/// Copyright 2011 Justin Ruggles. LGPL-2.1-or-later.
pub struct AdxTrack {
  sample_rate : Int32
  channels : Int32
  extradata : Bytes
  frames : Array[RawAudioFrame]
  total_samples : Int64
}

///|
/// Index unencrypted, encoding-type-3 CRI ADX. The terminal marker is not
/// an audio block and is omitted from the frame index.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_adx_open(b"") is Err(_))
/// }
/// ```
pub fn av_adx_open(data : Bytes) -> Result[AdxTrack, String] {
  let header = match @libavcodec.parse_adx_header(data[:]) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let stride = 18 * header.channels
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for pos = header.header_bytes; pos < data.length(); pos = pos + stride {
    if (data[pos].to_int() & 0x80) != 0 && data.length() - pos >= 4 {
      break
    }
    if data.length() - pos < stride {
      return Err("adx: truncated channel block")
    }
    for ch in 1..<header.channels {
      if (data[pos + ch * 18].to_int() & 0x80) != 0 {
        return Err("adx: terminal marker splits a channel group")
      }
    }
    frames.push({
      pos: pos.to_int64(),
      size: stride,
      pts,
      duration: 32,
      is_keyframe: true,
    })
    pts += 32L
  }
  Ok({
    sample_rate: header.sample_rate,
    channels: header.channels,
    extradata: data[:header.header_bytes].to_owned(),
    frames,
    total_samples: pts,
  })
}

///|
fn probe_adx(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() < 24 || data[:2] != b"\x80\x00" {
    return 0
  }
  let offset = pb_be16(data, 2).reinterpret_as_int() + 4
  if offset >= 24 &&
    offset <= data.length() &&
    data[offset - 6:offset] == b"(c)CRI" {
    probe_score_max * 3 / 4
  } else {
    0
  }
}

///|
/// Encode mono or stereo as unencrypted CRI ADX v3. The last audio block
/// is padded with silence, followed by the standard terminal block.
pub fn DecodedAudio::to_adx(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("ADX export requires mono or stereo")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match
    @libavcodec.encode_adx_blocks(samples[:], self.sample_rate, self.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  let counted_blocks = (payload.length() + 18) / (self.channels * 18)
  let out : Array[Byte] = Array(capacity=54 + payload.length())
  aiff_mux_u16be(out, 0x8000)
  aiff_mux_u16be(out, 32)
  out.push(3)
  out.push(18)
  out.push(4)
  out.push(self.channels.to_byte())
  aiff_mux_u32be(out, self.sample_rate.reinterpret_as_uint())
  // FFmpeg's raw muxer derives this field from the file size, including EOF.
  aiff_mux_u32be(out, counted_blocks.reinterpret_as_uint() * 32U)
  aiff_mux_u16be(out, 500)
  out.push(3)
  for _ in 0..<11 {
    out.push(0)
  }
  aiff_mux_tag(out, "(c)CRI")
  for byte in payload {
    out.push(byte)
  }
  aiff_mux_u16be(out, 0x8001)
  aiff_mux_u16be(out, 14)
  for _ in 0..<14 {
    out.push(0)
  }
  Bytes::from_array(out)
}
