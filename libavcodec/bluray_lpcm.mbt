///|
/// Blu-ray LPCM parameters from FFmpeg pcm-bluray.c, copyright Christian
/// Schmidt (2009, 2013). LGPL-2.1-or-later.
pub struct BlurayLpcmHeader {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  layout : Int32
  payload_bytes : Int32
  samples : Int32
}

///|
let bluray_lpcm_channels : FixedArray[Int32] = [
  0, 1, 0, 2, 3, 3, 4, 4, 5, 6, 7, 8,
]

///|
/// Read a Blu-ray LPCM PES audio header. Supported PCM depths are 16 and 24.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_bluray_lpcm_header(b"") is Err(_))
/// }
/// ```
pub fn parse_bluray_lpcm_header(
  data : Bytes,
) -> Result[BlurayLpcmHeader, String] {
  if data.length() < 4 {
    return Err("pcm_bluray: truncated header")
  }
  let layout = data[2].to_int() >> 4
  let channels = if layout < bluray_lpcm_channels.length() {
    bluray_lpcm_channels[layout]
  } else {
    0
  }
  if channels == 0 {
    return Err("pcm_bluray: invalid channel layout")
  }
  let sample_rate = match data[2].to_int() & 15 {
    1 => 48000
    4 => 96000
    5 => 192000
    _ => return Err("pcm_bluray: invalid sample rate")
  }
  let bits = match data[3].to_int() >> 6 {
    1 => 16
    3 => 24
    _ => return Err("pcm_bluray: unsupported sample depth")
  }
  let payload_bytes = (data[0].to_int() << 8) | data[1].to_int()
  // Each sample frame has an even number of physical channel slots.
  let align = ((channels + 1) & -2) * (bits / 8)
  if payload_bytes == 0 || payload_bytes % align != 0 {
    return Err("pcm_bluray: incomplete sample frame")
  }
  Ok({
    sample_rate,
    channels,
    bits,
    layout,
    payload_bytes,
    samples: payload_bytes / align,
  })
}

///|
let bluray_lpcm_order_51 : FixedArray[Int32] = [0, 1, 2, 5, 3, 4]

///|
let bluray_lpcm_order_70 : FixedArray[Int32] = [0, 1, 2, 4, 5, 3, 6]

///|
let bluray_lpcm_order_71 : FixedArray[Int32] = [0, 1, 2, 7, 4, 5, 3, 6]

///|
/// Decode one LPCM PES payload to interleaved signed PCM in FFmpeg channel
/// order. 24-bit values are sign-extended without a left shift.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.decode_bluray_lpcm(b"") is Err(_))
/// }
/// ```
pub fn decode_bluray_lpcm(
  data : Bytes,
) -> Result[(BlurayLpcmHeader, Array[Int32]), String] {
  let header = match parse_bluray_lpcm_header(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if data.length() - 4 != header.payload_bytes {
    return Err("pcm_bluray: incorrect payload length")
  }
  let width = header.bits / 8
  let slots = (header.channels + 1) & -2
  let pcm = Array(capacity=header.samples * header.channels)
  for i in 0..<header.samples {
    for ch in 0..<header.channels {
      let slot = match header.layout {
        9 => bluray_lpcm_order_51[ch]
        10 => bluray_lpcm_order_70[ch]
        11 => bluray_lpcm_order_71[ch]
        _ => ch
      }
      let pos = 4 + (i * slots + slot) * width
      let high = data[pos].to_int() << 24 >> 24
      let word = (high << 8) | data[pos + 1].to_int()
      pcm.push(
        if width == 2 {
          word
        } else {
          (word << 8) | data[pos + 2].to_int()
        },
      )
    }
  }
  Ok((header, pcm))
}
