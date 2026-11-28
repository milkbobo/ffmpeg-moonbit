///|
/// Encode mono PCM into CAF GSM, resampling to 8 kHz and retaining the exact
/// presentation length. WAV49 stores two GSM frames per packet.
pub fn DecodedAudio::to_caf_gsm(
  self : DecodedAudio,
  wav49~ : Bool = false,
) -> Bytes raise MediaError {
  let audio = self.resample_to(8000)
  let payload = audio.encode_gsm(wav49)
  let (tag, size, block) = if wav49 {
    ("ms\u00001", 65, 320)
  } else {
    ("agsm", 33, 160)
  }
  caf_mux_fixed_compressed(audio, tag, payload, size, block, 0)
}

///|
fn DecodedAudio::encode_gsm(
  self : DecodedAudio,
  wav49 : Bool,
) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("GSM export requires mono PCM")
  }
  let plane = self.samples[0]
  let frames = plane.length()
  guard frames > 0 else { raise DecodeError("gsm: no input samples") }
  let (size, block) = if wav49 { (65, 320) } else { (33, 160) }
  let count = (frames - 1) / block + 1
  guard count <= (0x7fffffff - 128) / size else {
    raise DecodeError("gsm: output is too large")
  }
  let payload : Array[Byte] = Array(capacity=count * size)
  let encoder = @libavcodec.gsm_encoder_new()
  for i in 0..<count {
    let start = i * block
    let available = (frames - start).min(block)
    let pcm = Array::makei(block, j => {
      if j < available {
        playback_pcm_quantize(plane[start + j], 16)
      } else {
        0
      }
    })
    match encoder.encode_packet(pcm[:], wav49~) {
      Ok(packet) =>
        for byte in packet {
          payload.push(byte)
        }
      Err(error) => raise DecodeError(error)
    }
  }
  Bytes::from_array(payload)
}
