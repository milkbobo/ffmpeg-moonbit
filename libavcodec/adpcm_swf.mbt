///|
/// Flash ADPCM step-index adjustments from FFmpeg libavcodec/adpcm.c.
/// LGPL-2.1-or-later.
let swf_adpcm_index : FixedArray[FixedArray[Int32]] = [
  [-1, 2],
  [-1, -1, 2, 4],
  [-1, -1, -1, -1, 2, 4, 6, 8],
  [-1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16],
]

///|
fn swf_adpcm_geometry(
  data : BytesView,
  channels : Int32,
) -> Result[(Int32, Int32), String] {
  if channels != 1 && channels != 2 {
    return Err("adpcm_swf: expected one or two channels")
  }
  let header_bits = 22 * channels
  if data.length() < (2 + header_bits + 7) / 8 || data.length() > 0x0FFFFFFF {
    return Err("adpcm_swf: invalid packet size")
  }
  let bits = (data[0].to_int() >> 6) + 2
  let frame_bits = bits * channels
  let block_bits = header_bits + 4095 * frame_bits
  let audio_bits = data.length() * 8 - 2
  let left = audio_bits % block_bits
  let tail = if left >= header_bits {
    1 + (left - header_bits) / frame_bits
  } else {
    0
  }
  Ok((bits, audio_bits / block_bits * 4096 + tail))
}

///|
/// Count the PCM samples per channel in a Flash ADPCM packet.
///
/// ```mbt check
/// test {
///   let packet = b"\x80\x00\x00"
///   assert_eq(@libavcodec.swf_adpcm_samples(packet[:], 1).unwrap(), 1)
/// }
/// ```
pub fn swf_adpcm_samples(
  data : BytesView,
  channels : Int32,
) -> Result[Int32, String] {
  match swf_adpcm_geometry(data, channels) {
    Ok((_, count)) => Ok(count)
    Err(e) => Err(e)
  }
}

///|
/// Decode one Flash ADPCM packet to interleaved signed 16-bit PCM.
/// Each block supplies its own predictors and step indexes.
///
/// ```mbt check
/// test {
///   assert_eq(@libavcodec.decode_swf_adpcm(b"\x80\x00\x00", 1).unwrap(), [0])
/// }
/// ```
pub fn decode_swf_adpcm(
  data : Bytes,
  channels : Int32,
) -> Result[Array[Int32], String] {
  let (bits, count) = match swf_adpcm_geometry(data[:], channels) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let reader = BitReader::new(data)
  reader.skip(2)
  let pcm : Array[Int32] = Array::make(count * channels, 0)
  let predictors = FixedArray::make(channels, 0)
  let indexes = FixedArray::make(channels, 0)
  let sign = 1 << (bits - 1)
  let adjustment = swf_adpcm_index[bits - 2]
  for start = 0; start < count; start = start + 4096 {
    for c in 0..<channels {
      let sample = reader.read(16).reinterpret_as_int() << 16 >> 16
      pcm[start * channels + c] = sample
      predictors[c] = sample
      indexes[c] = reader.read(6).reinterpret_as_int()
    }
    for i in (start + 1)..<(start + 4096).min(count) {
      for c in 0..<channels {
        let code = reader.read(bits).reinterpret_as_int()
        let magnitude = code & (sign - 1)
        let step = adpcm_step_table[indexes[c]]
        let mut diff = step >> (bits - 1)
        for j in 0..<(bits - 1) {
          if (magnitude & (sign >> (j + 1))) != 0 {
            diff += step >> j
          }
        }
        let delta = if (code & sign) == 0 { diff } else { -diff }
        let sample = adpcm_clip_int16(predictors[c] + delta)
        indexes[c] = adpcm_clip(indexes[c] + adjustment[magnitude], 0, 88)
        predictors[c] = sample
        pcm[i * channels + c] = sample
      }
    }
  }
  Ok(pcm)
}
