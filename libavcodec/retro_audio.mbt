///|
// 8SVX delta tables from FFmpeg 8svx.c, copyright Jaikrishnan Menon and
// Stefano Sabatini. LGPL-2.1-or-later.
let svx_fibonacci : FixedArray[Int32] = [
  -34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21,
]

///|
let svx_exponential : FixedArray[Int32] = [
  -128, -64, -32, -16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16, 32, 64,
]

///|
/// Decode the complete planar BODY of an 8SVX or 16SV file to signed 16-bit
/// PCM planes. The compression seed is used for prediction only.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.decode_svx_body("8svx_fib", 1, b"") is Err(_))
/// }
/// ```
pub fn decode_svx_body(
  codec : String,
  channels : Int32,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  if channels < 1 || channels > 2 {
    return Err("svx: invalid channel count")
  }
  let plane = data.length() / channels
  match codec {
    "pcm_s8_planar" =>
      Ok(
        Array::makei(channels, ch => {
          Array::makei(plane, i => {
            (data[ch * plane + i].to_int() << 24 >> 24) * 256
          })
        }),
      )
    "pcm_s16be_planar" =>
      match decode_pcm_s16be_planar(channels, data) {
        Ok(pcm) => Ok(pcm)
        Err(_) => Err("svx: incomplete 16-bit plane")
      }
    "8svx_fib" | "8svx_exp" => {
      if plane < 3 || plane - 2 > 0x3fffffff {
        return Err("svx: incomplete delta plane")
      }
      let table = if codec == "8svx_fib" {
        svx_fibonacci
      } else {
        svx_exponential
      }
      Ok(
        Array::makei(channels, ch => {
          let base = ch * plane
          let mut value = (data[base + 1].to_int() + 128) & 255
          let pcm = Array(capacity=(plane - 2) * 2)
          for i in 2..<plane {
            let byte = data[base + i].to_int()
            value = (value + table[byte & 15]).max(0).min(255)
            pcm.push((value - 128) * 256)
            value = (value + table[byte >> 4]).max(0).min(255)
            pcm.push((value - 128) * 256)
          }
          pcm
        }),
      )
    }
    _ => Err("svx: unsupported codec")
  }
}

///|
/// Decode signed 16-bit big-endian PCM stored in contiguous channel planes.
pub fn decode_pcm_s16be_planar(
  channels : Int32,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  guard channels > 0 && channels <= 256 && data.length() % (2 * channels) == 0 else {
    return Err("pcm: invalid signed 16-bit planes")
  }
  let plane = data.length() / channels
  Ok(
    Array::makei(channels, ch => {
      Array::makei(plane / 2, i => {
        let pos = ch * plane + i * 2
        (data[pos].to_int() << 24 >> 16) | data[pos + 1].to_int()
      })
    }),
  )
}

///|
/// Stateful Creative Sound Blaster Pro ADPCM. The first packet carries a
/// raw sample per channel, and continuation packets retain the predictor.
/// Algorithm from FFmpeg adpcm.c (LGPL-2.1-or-later).
pub struct SbproDecoder {
  predictor : FixedArray[Int32]
  step : FixedArray[Int32]
  code_width : Int32
  mut started : Bool
}

///|
/// Initialize the 2-, 2.6- (three codes per byte), or 4-bit decoder.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.sbpro_decoder_new(2, 3) is Err(_))
/// }
/// ```
pub fn sbpro_decoder_new(
  channels : Int32,
  code_width : Int32,
) -> Result[SbproDecoder, String] {
  if channels < 1 || channels > 2 || (channels == 2 && code_width == 3) {
    return Err("sbpro: unsupported channel count")
  }
  if code_width < 2 || code_width > 4 {
    return Err("sbpro: invalid code width")
  }
  Ok({
    predictor: FixedArray::make(channels, 0),
    step: FixedArray::make(channels, 0),
    code_width,
    started: false,
  })
}

///|
fn SbproDecoder::expand(
  self : SbproDecoder,
  ch : Int32,
  code : Int32,
  bits : Int32,
  shift : Int32,
) -> Int32 {
  let sign = 1 << (bits - 1)
  let delta = code & (sign - 1)
  let diff = delta << (7 + self.step[ch] + shift)
  let sample = self.predictor[ch] +
    (if (code & sign) != 0 { -diff } else { diff })
  self.predictor[ch] = sample.max(-16384).min(16256)
  if delta >= 2 * bits - 3 {
    self.step[ch] = (self.step[ch] + 1).min(3)
  } else if delta == 0 {
    self.step[ch] = (self.step[ch] - 1).max(0)
  }
  self.predictor[ch]
}

///|
/// Decode a packet to interleaved signed 16-bit PCM.
pub fn SbproDecoder::decode_packet(
  self : SbproDecoder,
  data : Bytes,
) -> Result[Array[Int32], String] {
  let channels = self.predictor.length()
  let mut start = 0
  let out : Array[Int32] = []
  if !self.started {
    if data.length() < channels {
      return Err("sbpro: missing first sample")
    }
    for ch in 0..<channels {
      out.push((data[ch].to_int() - 128) * 128)
    }
    start = channels
    self.started = true
  }
  let right = channels - 1
  for i in start..<data.length() {
    let byte = data[i].to_int()
    match self.code_width {
      4 => {
        out.push(self.expand(0, byte >> 4, 4, 0))
        out.push(self.expand(right, byte & 15, 4, 0))
      }
      3 => {
        out.push(self.expand(0, byte >> 5, 3, 0))
        out.push(self.expand(0, (byte >> 2) & 7, 3, 0))
        out.push(self.expand(0, byte & 3, 2, 0))
      }
      _ => {
        out.push(self.expand(0, byte >> 6, 2, 2))
        out.push(self.expand(right, (byte >> 4) & 3, 2, 2))
        out.push(self.expand(0, (byte >> 2) & 3, 2, 2))
        out.push(self.expand(right, byte & 3, 2, 2))
      }
    }
  }
  Ok(out)
}
