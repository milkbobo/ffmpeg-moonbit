///|
/// Minimal Sun AU writer for signed big-endian PCM (8/16/24/32-bit),
/// following the encoding tags of FFmpeg's `libavformat/au.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AuMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  codec : String
  data : Array[Byte]
}

///|
fn au_mux_u32be(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push(((v >> 24) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push((v & 0xFFU).to_byte())
}

///|
pub fn au_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits~ : Int32 = 16,
  codec~ : String = "pcm",
) -> Result[AuMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 64 {
    return Err("EINVAL: invalid AU stream parameters")
  }
  if codec == "pcm_alaw" || codec == "pcm_mulaw" {
    return Ok({ sample_rate, channels, bits: 8, codec, data: [], })
  }
  if codec != "pcm" {
    return Err("EINVAL: unsupported AU codec \{codec}")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: AU muxer supports 8/16/24/32-bit PCM")
  }
  Ok({ sample_rate, channels, bits, codec, data: [], })
}

///|
pub fn AuMuxer::write_samples(
  self : AuMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  if self.codec == "pcm_alaw" {
    for b in @libavcodec.pcm_alaw_encode(samples) {
      self.data.push(b)
    }
    return
  }
  if self.codec == "pcm_mulaw" {
    for b in @libavcodec.pcm_mulaw_encode(samples) {
      self.data.push(b)
    }
    return
  }
  let bytes = self.bits / 8
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i = 0; i < bytes; i = i + 1 {
      self.data.push(((v >> (8 * (bytes - 1 - i))) & 0xFFU).to_byte())
    }
  }
}

///|
pub fn AuMuxer::finish(self : AuMuxer) -> Bytes {
  let out : Array[Byte] = [b'.', b's', b'n', b'd']
  au_mux_u32be(out, 24U) // header size
  au_mux_u32be(out, self.data.length().reinterpret_as_uint())
  let tag : UInt32 = if self.codec == "pcm_alaw" {
    27U
  } else if self.codec == "pcm_mulaw" {
    1U
  } else if self.bits == 8 {
    2U
  } else if self.bits == 16 {
    3U
  } else if self.bits == 24 {
    4U
  } else {
    5U
  }
  au_mux_u32be(out, tag)
  au_mux_u32be(out, self.sample_rate.reinterpret_as_uint())
  au_mux_u32be(out, self.channels.reinterpret_as_uint())
  out.append(self.data)
  Bytes::from_array(out)
}

///|
fn au_mux_telephony(
  payload : Bytes,
  rate : Int32,
  tag : UInt32,
) -> Bytes raise MediaError {
  guard !payload.is_empty() else { raise DecodeError("AU: no audio samples") }
  let out : Array[Byte] = [b'.', b's', b'n', b'd']
  au_mux_u32be(out, 32U)
  au_mux_u32be(out, payload.length().reinterpret_as_uint())
  au_mux_u32be(out, tag)
  au_mux_u32be(out, rate.reinterpret_as_uint())
  au_mux_u32be(out, 1U)
  for _ in 0..<8 {
    out.push(0)
  }
  for byte in payload {
    out.push(byte)
  }
  Bytes::from_array(out)
}

///|
/// Encode mono G.722 as Sun AU at 16 kHz.
pub fn DecodedAudio::to_au_g722(self : DecodedAudio) -> Bytes raise MediaError {
  au_mux_telephony(self.to_g722(), 16000, 24U)
}

///|
/// Encode mono G.726LE as Sun AU at 8 kHz. Each code width has its own tag.
pub fn DecodedAudio::to_au_g726le(
  self : DecodedAudio,
  bits : Int32,
) -> Bytes raise MediaError {
  let tag = match bits {
    2 => 0x37323632U
    3 => 25U
    4 => 23U
    5 => 26U
    _ => raise DecodeError("AU G.726LE: codeword width must be 2..=5")
  }
  au_mux_telephony(self.to_g726(bits, little_endian=true), 8000, tag)
}
