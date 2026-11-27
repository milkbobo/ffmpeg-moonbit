///|
/// Persistent predictor state for AIFF-C SDX2 and CBD2.
struct AiffDpcmDecoder {
  predictors : FixedArray[Int32]
  cubic : Bool
}

///|
/// Open a mono or stereo SDX2 or CBD2 decoder.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.aiff_dpcm_decoder_new("sdx2_dpcm", 1).unwrap()
///   assert_eq(decoder.decode_packet(b"\x02\x03").unwrap(), [8, 26])
/// }
/// ```
pub fn aiff_dpcm_decoder_new(
  codec : String,
  channels : Int32,
) -> Result[AiffDpcmDecoder, String] {
  let cubic = match codec {
    "cbd2_dpcm" => true
    "sdx2_dpcm" => false
    _ => return Err("aiff dpcm: unsupported codec")
  }
  if channels != 1 && channels != 2 {
    return Err("aiff dpcm: expected one or two channels")
  }
  Ok({ cubic, predictors: FixedArray::make(channels, 0), })
}

///|
/// Decode complete interleaved codewords to signed 16-bit PCM.
/// Even codes set an absolute value. Odd codes add a signed delta.
pub fn AiffDpcmDecoder::decode_packet(
  self : AiffDpcmDecoder,
  data : Bytes,
) -> Result[Array[Int32], String] {
  let channels = self.predictors.length()
  if data.is_empty() || data.length() % channels != 0 {
    return Err("aiff dpcm: incomplete sample frame")
  }
  let output = Array::make(data.length(), 0)
  for i in 0..<data.length() {
    let code = data[i].to_int() << 24 >> 24
    let square = code * code
    // FFmpeg's LGPL-2.1-or-later dpcm.c expands a signed square or cube.
    let delta = if self.cubic {
      square * code / 64
    } else if code < 0 {
      -2 * square
    } else {
      2 * square
    }
    let channel = i % channels
    let previous = if (code & 1) == 0 { 0 } else { self.predictors[channel] }
    let sample = adpcm_clip_int16(previous + delta)
    self.predictors[channel] = sample
    output[i] = sample
  }
  Ok(output)
}

///|
/// Interleaved Westwood IMA (ADP4). Each channel byte carries two samples.
fn AdpcmDecoder::decode_ima_ws(
  self : AdpcmDecoder,
  data : Bytes,
) -> Result[AdpcmAudio, String] {
  let channels = self.channels
  if data.is_empty() ||
    data.length() % channels != 0 ||
    data.length() > 0x3FFFFFFF {
    return Err("adpcm: invalid Westwood IMA packet size")
  }
  let samples = Array::make(data.length() * 2, 0)
  for group in 0..<(data.length() / channels) {
    let offset = group * channels
    for c in 0..<channels {
      let byte = data[offset + c].to_int()
      let state = self.status[c]
      samples[2 * offset + c] = adpcm_ima_expand_multiply(state, byte & 15)
      samples[2 * offset + channels + c] = adpcm_ima_expand_multiply(
        state,
        byte >> 4,
      )
    }
  }
  Ok({ channels, samples, })
}
