///|
/// Psion 3 WVE header from FFmpeg 9.0.2 wvedec.c (LGPL-2.1-or-later).
let wve_magic : Bytes = b"ALawSoundFile**\x00\x0f\x10"

///|
let wve_header_suffix : Bytes = b"\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"

///|
fn probe_wve(pd : ProbeData) -> Int32 {
  let data = pd.buf
  if data.length() >= 32 &&
    data[:18] == wve_magic &&
    data[22:32] == wve_header_suffix {
    probe_score_max
  } else {
    0
  }
}

///|
fn wve_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_wve(ProbeData::new(data)) > 0 else {
    return Err("wve: invalid header")
  }
  let size = pb_be32(data, 18).to_int64()
  guard data.length() > 32 && size <= (data.length() - 32).to_int64() else {
    return Err("wve: missing or truncated A-law payload")
  }
  Ok(raw_pcm_track(data.length(), 32, "pcm_alaw", 8000, 1, 1))
}

///|
/// Write a mono 8 kHz Psion 3 WVE file with G.711 A-law samples.
pub fn DecodedAudio::to_wve(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 && self.sample_rate == 8000 else {
    raise UnsupportedCodec("WVE export requires mono audio at 8000 Hz")
  }
  let plane = self.samples[0]
  guard !plane.is_empty() && plane.length() <= 0x7fffffff - 32 else {
    raise DecodeError("wve: invalid A-law payload length")
  }
  let samples = plane.map(sample => playback_pcm_quantize(sample, 16))
  let payload = @libavcodec.pcm_alaw_encode(samples[:])
  let out : Array[Byte] = Array(capacity=32 + payload.length())
  for byte in wve_magic {
    out.push(byte)
  }
  aiff_mux_u32be(out, payload.length().reinterpret_as_uint())
  for byte in wve_header_suffix {
    out.push(byte)
  }
  for byte in payload {
    out.push(byte)
  }
  Bytes::from_array(out)
}
