///|
/// Encode mono PCM into CAF GSM, resampling to 8 kHz and retaining the exact
/// presentation length. WAV49 stores two GSM frames per packet.
pub fn DecodedAudio::to_caf_gsm(
  self : DecodedAudio,
  wav49~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("CAF GSM requires mono PCM")
  }
  let audio = self.resample_to(8000)
  let plane = audio.samples[0]
  let frames = plane.length()
  guard frames > 0 else { raise DecodeError("caf: no GSM input samples") }
  let (tag, size, block) = if wav49 {
    ("ms\u00001", 65, 320)
  } else {
    ("agsm", 33, 160)
  }
  let count = (frames - 1) / block + 1
  guard count <= (0x7fffffff - 128) / size else {
    raise DecodeError("caf: GSM output is too large")
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
  caf_mux_fixed_compressed(
    audio,
    tag,
    Bytes::from_array(payload),
    size,
    block,
    0,
  )
}
