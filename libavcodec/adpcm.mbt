///|
/// ADPCM block decoders ported from FFmpeg 9.0.2 `libavcodec/adpcm.c` and
/// `adpcm_data.c`: IMA WAV (4-bit), Microsoft ADPCM and Yamaha ADPCM.
///
/// `AdpcmDecoder` keeps the per-channel predictor/step state across blocks
/// (Yamaha carries it between blocks; IMA/MS re-initialize it from each block
/// header). Output is interleaved S16, matching FFmpeg's decoded PCM.
///
/// Scope: IMA WAV at 4 bits per sample, MS ADPCM at 1-2 channels (the
/// interleaved layout) and Yamaha ADPCM at 1-2 channels. Other block layouts
/// and bit depths are rejected.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `ff_adpcm_index_table`.
let adpcm_index_table : FixedArray[Int32] = [
  -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
]

///|
/// `ff_adpcm_step_table`.
let adpcm_step_table : FixedArray[Int32] = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50,
  55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279,
  307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282,
  1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
  5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818,
  18500, 20350, 22385, 24623, 27086, 29794, 32767,
]

///|
/// `ff_adpcm_AdaptationTable`.
let adpcm_adaptation_table : FixedArray[Int32] = [
  230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230,
]

///|
/// `ff_adpcm_AdaptCoeff1` (already divided by 4).
let adpcm_coeff1 : FixedArray[Int32] = [64, 128, 0, 48, 60, 115, 98]

///|
/// `ff_adpcm_AdaptCoeff2` (already divided by 4).
let adpcm_coeff2 : FixedArray[Int32] = [0, -64, 0, 16, 0, -52, -58]

///|
/// `ff_adpcm_yamaha_indexscale`.
let adpcm_yamaha_indexscale : FixedArray[Int32] = [
  230, 230, 230, 230, 307, 409, 512, 614, 230, 230, 230, 230, 307, 409, 512, 614,
]

///|
/// `ff_adpcm_yamaha_difflookup`.
let adpcm_yamaha_difflookup : FixedArray[Int32] = [
  1, 3, 5, 7, 9, 11, 13, 15, -1, -3, -5, -7, -9, -11, -13, -15,
]

///|
/// C integer division truncates toward zero.
fn adpcm_div_trunc(a : Int32, b : Int32) -> Int32 {
  if a >= 0 {
    a / b
  } else {
    -(-a / b)
  }
}

///|
fn adpcm_clip_int16(v : Int32) -> Int32 {
  if v > 32767 {
    32767
  } else if v < -32768 {
    -32768
  } else {
    v
  }
}

///|
fn adpcm_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn adpcm_le16(data : Bytes, off : Int32) -> Int32 {
  let v = data[off].to_int() | (data[off + 1].to_int() << 8)
  if v >= 0x8000 {
    v - 0x10000
  } else {
    v
  }
}

///|
/// Per-channel predictor state shared by the three block formats.
pub struct AdpcmChannel {
  mut predictor : Int32
  mut step_index : Int32
  mut step : Int32
  mut sample1 : Int32
  mut sample2 : Int32
  mut coeff1 : Int32
  mut coeff2 : Int32
  mut idelta : Int32
}

///|
fn adpcm_channel_new() -> AdpcmChannel {
  {
    predictor: 0,
    step_index: 0,
    step: 0,
    sample1: 0,
    sample2: 0,
    coeff1: 0,
    coeff2: 0,
    idelta: 0,
  }
}

///|
/// One decoded ADPCM block: interleaved S16 values.
pub struct AdpcmAudio {
  channels : Int32
  samples : Array[Int32]
}

///|
/// Block decoder carrying the per-channel state across calls.
pub struct AdpcmDecoder {
  codec : String
  channels : Int32
  block_align : Int32
  status : Array[AdpcmChannel]
}

///|
/// `codec` is the WAV codec name: `adpcm_ima_wav`, `adpcm_ms` or
/// `adpcm_yamaha`. `block_align` caps each block's byte count when nonzero.
pub fn adpcm_decoder_new(
  codec : String,
  channels : Int32,
  block_align~ : Int32 = 0,
) -> Result[AdpcmDecoder, String] {
  if codec != "adpcm_ima_wav" && codec != "adpcm_ms" && codec != "adpcm_yamaha" {
    return Err("adpcm: unsupported codec \{codec}")
  }
  if channels < 1 || channels > 8 {
    return Err("adpcm: invalid channel count")
  }
  if (codec == "adpcm_ms" || codec == "adpcm_yamaha") && channels > 2 {
    return Err("adpcm: only 1-2 channels are supported")
  }
  if block_align < 0 {
    return Err("adpcm: invalid block align")
  }
  let status : Array[AdpcmChannel] = []
  for _ in 0..<channels {
    status.push(adpcm_channel_new())
  }
  Ok({ codec, channels, block_align, status, })
}

///|
/// `ff_adpcm_ima_qt_expand_nibble`, used by IMA WAV's 4-bit blocks.
fn adpcm_ima_expand(cs : AdpcmChannel, nibble : Int32) -> Int32 {
  let step = adpcm_step_table[cs.step_index]
  let step_index = adpcm_clip(cs.step_index + adpcm_index_table[nibble], 0, 88)
  let mut diff = step >> 3
  if (nibble & 4) != 0 {
    diff = diff + step
  }
  if (nibble & 2) != 0 {
    diff = diff + (step >> 1)
  }
  if (nibble & 1) != 0 {
    diff = diff + (step >> 2)
  }
  let predictor = if (nibble & 8) != 0 {
    cs.predictor - diff
  } else {
    cs.predictor + diff
  }
  cs.predictor = adpcm_clip_int16(predictor)
  cs.step_index = step_index
  cs.predictor
}

///|
/// `adpcm_ms_expand_nibble`.
fn adpcm_ms_expand(cs : AdpcmChannel, nibble : Int32) -> Int32 {
  let mut predictor = adpcm_div_trunc(
    cs.sample1 * cs.coeff1 + cs.sample2 * cs.coeff2,
    64,
  )
  let delta = if (nibble & 8) != 0 { nibble - 16 } else { nibble }
  predictor = predictor + delta * cs.idelta
  cs.sample2 = cs.sample1
  cs.sample1 = adpcm_clip_int16(predictor)
  let mut idelta = (adpcm_adaptation_table[nibble] * cs.idelta) >> 8
  if idelta < 16 {
    idelta = 16
  }
  if idelta > 2796202 {
    idelta = 2796202
  }
  cs.idelta = idelta
  cs.sample1
}

///|
/// `adpcm_yamaha_expand_nibble`.
fn adpcm_yamaha_expand(cs : AdpcmChannel, nibble : Int32) -> Int32 {
  if cs.step == 0 {
    cs.predictor = 0
    cs.step = 127
  }
  cs.predictor = adpcm_clip_int16(
    cs.predictor + adpcm_div_trunc(cs.step * adpcm_yamaha_difflookup[nibble], 8),
  )
  cs.step = adpcm_clip(
    (cs.step * adpcm_yamaha_indexscale[nibble]) >> 8,
    127,
    24576,
  )
  cs.predictor
}

///|
fn AdpcmDecoder::decode_ima_wav(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let ch = self.channels
  if block.length() < 4 * ch {
    return Err("adpcm: truncated IMA block header")
  }
  let nb_samples = 1 + (block.length() - 4 * ch) / (4 * ch) * 8
  let planes : Array[Array[Int32]] = []
  for _ in 0..<ch {
    planes.push(Array::make(nb_samples, 0))
  }
  let mut pos = 0
  for c = 0; c < ch; c = c + 1 {
    let cs = self.status[c]
    cs.predictor = adpcm_le16(block, pos)
    cs.step_index = block[pos + 2].to_int()
    pos = pos + 4
    if cs.step_index > 88 {
      return Err("adpcm: invalid IMA step index")
    }
    planes[c][0] = cs.predictor
  }
  let groups = (nb_samples - 1) / 8
  for n = 0; n < groups; n = n + 1 {
    for c = 0; c < ch; c = c + 1 {
      let cs = self.status[c]
      for m = 0; m < 4; m = m + 1 {
        let v = block[pos].to_int()
        pos = pos + 1
        let base = 1 + n * 8 + m * 2
        planes[c][base] = adpcm_ima_expand(cs, v & 0x0F)
        planes[c][base + 1] = adpcm_ima_expand(cs, v >> 4)
      }
    }
  }
  let samples : Array[Int32] = []
  for i = 0; i < nb_samples; i = i + 1 {
    for c = 0; c < ch; c = c + 1 {
      samples.push(planes[c][i])
    }
  }
  Ok({ channels: ch, samples, })
}

///|
fn AdpcmDecoder::decode_ms(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let ch = self.channels
  if block.length() < 7 * ch {
    return Err("adpcm: truncated MS block header")
  }
  let nb_samples = (block.length() - 6 * ch) * 2 / ch
  if nb_samples < 2 {
    return Err("adpcm: MS block too short")
  }
  let samples : Array[Int32] = Array::make(nb_samples * ch, 0)
  let mut pos = 0
  if ch == 1 {
    let cs = self.status[0]
    let predictor = block[pos].to_int()
    pos = pos + 1
    if predictor > 6 {
      return Err("adpcm: invalid MS block predictor")
    }
    cs.coeff1 = adpcm_coeff1[predictor]
    cs.coeff2 = adpcm_coeff2[predictor]
    cs.idelta = adpcm_le16(block, pos)
    pos = pos + 2
    cs.sample1 = adpcm_le16(block, pos)
    pos = pos + 2
    cs.sample2 = adpcm_le16(block, pos)
    pos = pos + 2
    samples[0] = cs.sample2
    samples[1] = cs.sample1
    for n = 0; n < (nb_samples - 2) / 2; n = n + 1 {
      let byte = block[pos].to_int()
      pos = pos + 1
      samples[2 + n * 2] = adpcm_ms_expand(cs, byte >> 4)
      samples[3 + n * 2] = adpcm_ms_expand(cs, byte & 0x0F)
    }
  } else {
    let cs0 = self.status[0]
    let cs1 = self.status[1]
    let p0 = block[pos].to_int()
    pos = pos + 1
    let p1 = block[pos].to_int()
    pos = pos + 1
    if p0 > 6 || p1 > 6 {
      return Err("adpcm: invalid MS block predictor")
    }
    cs0.coeff1 = adpcm_coeff1[p0]
    cs0.coeff2 = adpcm_coeff2[p0]
    cs1.coeff1 = adpcm_coeff1[p1]
    cs1.coeff2 = adpcm_coeff2[p1]
    cs0.idelta = adpcm_le16(block, pos)
    cs1.idelta = adpcm_le16(block, pos + 2)
    pos = pos + 4
    cs0.sample1 = adpcm_le16(block, pos)
    cs1.sample1 = adpcm_le16(block, pos + 2)
    pos = pos + 4
    cs0.sample2 = adpcm_le16(block, pos)
    cs1.sample2 = adpcm_le16(block, pos + 2)
    pos = pos + 4
    samples[0] = cs0.sample2
    samples[1] = cs1.sample2
    samples[2] = cs0.sample1
    samples[3] = cs1.sample1
    for n = 0; n < nb_samples - 2; n = n + 1 {
      let byte = block[pos].to_int()
      pos = pos + 1
      samples[4 + n * 2] = adpcm_ms_expand(cs0, byte >> 4)
      samples[5 + n * 2] = adpcm_ms_expand(cs1, byte & 0x0F)
    }
  }
  Ok({ channels: ch, samples, })
}

///|
fn AdpcmDecoder::decode_yamaha(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let ch = self.channels
  let nb_samples = block.length() * 2 / ch
  if nb_samples < 2 {
    return Err("adpcm: Yamaha block too short")
  }
  let samples : Array[Int32] = Array::make(nb_samples * ch, 0)
  let cs0 = self.status[0]
  if ch == 1 {
    for n = 0; n < nb_samples / 2; n = n + 1 {
      let byte = block[n].to_int()
      samples[n * 2] = adpcm_yamaha_expand(cs0, byte & 0x0F)
      samples[n * 2 + 1] = adpcm_yamaha_expand(cs0, byte >> 4)
    }
  } else {
    let cs1 = self.status[1]
    for n = 0; n < nb_samples; n = n + 1 {
      let byte = block[n].to_int()
      samples[n * 2] = adpcm_yamaha_expand(cs0, byte & 0x0F)
      samples[n * 2 + 1] = adpcm_yamaha_expand(cs1, byte >> 4)
    }
  }
  Ok({ channels: ch, samples, })
}

///|
/// Decode one block. `block` may be longer than `block_align`; only the first
/// `block_align` bytes are used in that case, as FFmpeg's decoder does.
pub fn AdpcmDecoder::decode_block(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let usable = if self.block_align > 0 && block.length() > self.block_align {
    block[:self.block_align].to_owned()
  } else {
    block
  }
  match self.codec {
    "adpcm_ima_wav" => self.decode_ima_wav(usable)
    "adpcm_ms" => self.decode_ms(usable)
    _ => self.decode_yamaha(usable)
  }
}

///|
/// Interleaved S16 PCM bytes.
pub fn AdpcmAudio::pcm_bytes(self : AdpcmAudio) -> Bytes {
  let out : Array[Byte] = []
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}
