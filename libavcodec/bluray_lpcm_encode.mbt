///|
/// Blu-ray LPCM packing from FFmpeg 9.0.2 pcm-blurayenc.c.
/// Copyright (c) 2013 Christian Schmidt. LGPL-2.1-or-later.
pub struct BlurayLpcmEncoder {
  priv channels : Int32
  priv width : Int32
  priv assignment_and_rate : Byte
  priv depth : Byte
  priv slot_channels : FixedArray[Int32]
}

///|
/// Prepare LPCM for mono through 7.1 using a WAVE speaker mask.
/// A zero mask selects the standard Blu-ray layout for the channel count.
pub fn BlurayLpcmEncoder::new(
  channels : Int32,
  sample_rate : Int32,
  bits : Int32,
  channel_mask~ : UInt32 = 0U,
) -> Result[BlurayLpcmEncoder, String] {
  let rate_code = match sample_rate {
    48000 => 1
    96000 => 4
    192000 => 5
    _ => return Err("pcm_bluray: expected 48, 96 or 192 kHz")
  }
  let depth : Byte = match bits {
    16 => 0x40
    24 => 0xc0
    _ => return Err("pcm_bluray: expected 16 or 24 bits per sample")
  }
  let mut layout = 0
  for i in 1..<bluray_lpcm_channels.length() {
    if bluray_lpcm_channels[i] == channels &&
      (channel_mask == 0U || channel_mask == bluray_lpcm_masks[i]) {
      layout = i
      break
    }
  }
  guard layout != 0 && channels > 0 else {
    return Err("pcm_bluray: unsupported channel layout")
  }
  let slot_channels = FixedArray::make((channels + 1) & -2, -1)
  for ch in 0..<channels {
    slot_channels[bluray_lpcm_slot(layout, ch)] = ch
  }
  Ok({
    channels,
    width: bits / 8,
    assignment_and_rate: ((layout << 4) | rate_code).to_byte(),
    depth,
    slot_channels,
  })
}

///|
/// Encode one packet from interleaved signed PCM at the configured bit depth.
pub fn BlurayLpcmEncoder::encode(
  self : BlurayLpcmEncoder,
  pcm : ArrayView[Int32],
) -> Result[Bytes, String] {
  let channels = self.channels
  guard !pcm.is_empty() && pcm.length() % channels == 0 else {
    return Err("pcm_bluray: expected complete PCM frames")
  }
  let align = self.slot_channels.length() * self.width
  let frames = pcm.length() / channels
  guard frames <= 0xffff / align else {
    return Err("pcm_bluray: packet payload exceeds 65535 bytes")
  }
  let size = frames * align
  let out : Array[Byte] = Array(capacity=size + 4)
  out.append([
    (size >> 8).to_byte(),
    size.to_byte(),
    self.assignment_and_rate,
    self.depth,
  ])
  for start = 0; start < pcm.length(); start = start + channels {
    for ch in self.slot_channels {
      let sample = if ch >= 0 { pcm[start + ch] } else { 0 }
      for byte = self.width - 1; byte >= 0; byte = byte - 1 {
        out.push((sample >> (byte * 8)).to_byte())
      }
    }
  }
  Ok(Bytes::from_array(out))
}
