///|
/// Write an audio-only FLV with 4-bit Flash ADPCM. This mirrors FFmpeg's
/// FLV audio tags with the optional metadata tag disabled.
pub fn DecodedAudio::to_flv_adpcm(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("Flash ADPCM export requires mono or stereo")
  }
  let rate_code = match self.sample_rate {
    5512 => 0
    11025 => 1
    22050 => 2
    44100 => 3
    _ =>
      raise DecodeError("Flash ADPCM requires 5512, 11025, 22050 or 44100 Hz")
  }
  let pcm = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let packets = match @libavcodec.encode_swf_adpcm(pcm[:], self.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  let out = b"FLV\x01\x04\x00\x00\x00\x09\x00\x00\x00\x00".to_array()
  let flags = (0x12 | (rate_code << 2) | (self.channels - 1)).to_byte()
  let rate = self.sample_rate.to_int64()
  for i, packet in packets {
    let size = packet.length() + 1
    let timestamp = (i.to_int64() * 4096000L + rate / 2L) / rate
    guard timestamp <= 0x7fffffffL else {
      raise DecodeError("Flash ADPCM exceeds FLV timestamp range")
    }
    let ms = timestamp.to_int()
    out.push(8)
    out.push((size >> 16).to_byte())
    out.push((size >> 8).to_byte())
    out.push(size.to_byte())
    out.push((ms >> 16).to_byte())
    out.push((ms >> 8).to_byte())
    out.push(ms.to_byte())
    out.push((ms >> 24).to_byte())
    for _ in 0..<3 {
      out.push(0)
    }
    out.push(flags)
    for byte in packet {
      out.push(byte)
    }
    aiff_mux_u32be(out, (size + 11).reinterpret_as_uint())
  }
  Bytes::from_array(out)
}
