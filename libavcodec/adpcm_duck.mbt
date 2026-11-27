///|
/// Duck IMA DK3/DK4 framing and expansion from FFmpeg's LGPL-2.1-or-later
/// libavcodec/adpcm.c.
///
/// Count the PCM samples per channel in one Duck IMA DK3 or DK4 block.
///
/// ```mbt check
/// test {
///   assert_eq(
///     @libavcodec.adpcm_duck_block_samples("adpcm_ima_dk4", 4, 1).unwrap(),
///     1,
///   )
/// }
/// ```
pub fn adpcm_duck_block_samples(
  codec : String,
  size : Int32,
  channels : Int32,
) -> Result[Int32, String] {
  let count = match codec {
    "adpcm_ima_dk3" if channels == 2 && size >= 18 =>
      (size.to_int64() - 16L) * 2L / 3L * 2L
    "adpcm_ima_dk4" if (channels == 1 || channels == 2) && size >= 4 * channels =>
      1L +
      (size.to_int64() - 4L * channels.to_int64()) * 2L / channels.to_int64()
    _ => return Err("adpcm: invalid Duck IMA block or channel count")
  }
  if count * channels.to_int64() > 0x7FFFFFFFL {
    return Err("adpcm: Duck IMA block too large")
  }
  Ok(count.to_int())
}

///|
fn AdpcmDecoder::decode_duck(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let channels = self.channels
  let count = match
    adpcm_duck_block_samples(self.codec, block.length(), channels) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let dk3 = self.codec == "adpcm_ima_dk3"
  let pcm : Array[Int32] = []
  for c in 0..<channels {
    let (predictor, index) = if dk3 {
      (adpcm_le16(block, 10 + 2 * c), block[14 + c].to_int())
    } else {
      (adpcm_le16(block, 4 * c), adpcm_le16(block, 4 * c + 2))
    }
    if index < 0 || index > 88 {
      return Err("adpcm: invalid Duck IMA step index")
    }
    self.status[c].predictor = predictor
    self.status[c].step_index = index
    if !dk3 {
      pcm.push(predictor)
    }
  }
  if dk3 {
    // Each low-first three-nibble group advances sum, difference, then sum.
    let code = i => {
      let byte = block[16 + i / 2].to_int()
      (byte >> (4 * (i % 2))) & 15
    }
    for i in 0..<(count / 2) {
      let at = i * 3
      let first = adpcm_ima_expand_multiply(self.status[0], code(at))
      let diff = adpcm_ima_expand_multiply(self.status[1], code(at + 1))
      let second = adpcm_ima_expand_multiply(self.status[0], code(at + 2))
      // Decoder stores reconstructed channels as int16, with wrapping.
      pcm.push(adpcm_sign16((first + diff) & 0xFFFF))
      pcm.push(adpcm_sign16((first - diff) & 0xFFFF))
      pcm.push(adpcm_sign16((second + diff) & 0xFFFF))
      pcm.push(adpcm_sign16((second - diff) & 0xFFFF))
    }
  } else {
    for at in (4 * channels)..<block.length() {
      let byte = block[at].to_int()
      pcm.push(adpcm_ima_expand_multiply(self.status[0], byte >> 4))
      pcm.push(adpcm_ima_expand_multiply(self.status[channels - 1], byte & 15))
    }
  }
  Ok({ channels, samples: pcm, })
}
