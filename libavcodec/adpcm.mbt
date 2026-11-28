///|
/// ADPCM block decoders ported from FFmpeg 9.0.2 `libavcodec/adpcm.c` and
/// `adpcm_data.c`: IMA WAV, Microsoft ADPCM, Yamaha ADPCM, Dialogic OKI IMA,
/// Creative Technology and IMA QuickTime.
///
/// `AdpcmDecoder` keeps the per-channel predictor/step state across blocks
/// (Yamaha, OKI and Creative carry it between blocks; IMA/MS re-initialize it from
/// each block header). Output is interleaved S16, matching FFmpeg's decoded
/// PCM bit for bit (32-bit integer arithmetic throughout).
///
/// Scope: IMA WAV at 2-5 bits per code (the usual 4), MS ADPCM at 1-6
/// channels, Yamaha and OKI at 1-2 channels, IMA QuickTime at 1-8 channels.
/// Other ADPCM variants of the C file are not ported.
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
/// `oki_step_table` (Dialogic OKI IMA; the predictor is 12-bit).
let adpcm_oki_step_table : FixedArray[Int32] = [
  16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
  107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
  494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
]

///|
/// `ff_adpcm_ima_block_sizes` / `ff_adpcm_ima_block_samples`, indexed by
/// `bits_per_coded_sample - 2` (2-, 3-, 4- and 5-bit IMA WAV codes).
let adpcm_ima_block_sizes : FixedArray[Int32] = [4, 12, 4, 20]

///|
let adpcm_ima_block_samples : FixedArray[Int32] = [16, 32, 8, 32]

///|
/// Number of samples per channel in an IMA WAV or Microsoft ADPCM block.
/// A truncated header or invalid format yields zero.
pub fn adpcm_wav_block_samples(
  codec : String,
  bytes : Int32,
  channels : Int32,
  bits : Int32,
) -> Int32 {
  guard channels >= 1 && channels <= 8 else { return 0 }
  match codec {
    "adpcm_ima_wav" if bits >= 2 && bits <= 5 && bytes >= 4 * channels =>
      1 +
      (bytes - 4 * channels) /
      (adpcm_ima_block_sizes[bits - 2] * channels) *
      adpcm_ima_block_samples[bits - 2]
    "adpcm_ms" if channels <= 6 && bytes >= 7 * channels =>
      ((bytes - 7 * channels).to_int64() * 2L / channels.to_int64()).to_int() +
      2
    _ => 0
  }
}

///|
/// `adpcm_index_table2` / `adpcm_index_table3` / `adpcm_index_table5`: the
/// step index change per 2-, 3- and 5-bit code (the 4-bit one is
/// `adpcm_index_table`).
let adpcm_index_table2 : FixedArray[Int32] = [-1, 2, -1, 2]

///|
let adpcm_index_table3 : FixedArray[Int32] = [-1, -1, 1, 2, -1, -1, 1, 2]

///|
let adpcm_index_table5 : FixedArray[Int32] = [
  -1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16, -1, -1, -1, -1, -1,
  -1, -1, -1, 1, 2, 4, 6, 8, 10, 13, 16,
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
fn adpcm_sign16(v : Int32) -> Int32 {
  if v >= 0x8000 {
    v - 0x10000
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
  /// IMA WAV code width in bits (2..=5); unused by the other codecs.
  bits_per_coded_sample : Int32
  status : Array[AdpcmChannel]
}

///|
/// `codec` is the codec name: `adpcm_ima_wav`, `adpcm_ms`, `adpcm_yamaha`,
/// `adpcm_ct`, `adpcm_ima_oki`, `adpcm_ima_ws`, `adpcm_ima_dk3` or `adpcm_ima_dk4`.
/// `block_align` caps each block's byte
/// count when nonzero; `bits_per_coded_sample` is the IMA WAV code width
/// (`WAVEFORMAT`'s bits per sample, normally 4).
/// The optional `extradata` supplies initial predictor state for APM or APC.
pub fn adpcm_decoder_new(
  codec : String,
  channels : Int32,
  block_align~ : Int32 = 0,
  bits_per_coded_sample~ : Int32 = 4,
  extradata~ : Bytes? = None,
) -> Result[AdpcmDecoder, String] {
  if codec != "adpcm_ima_wav" &&
    codec != "adpcm_ms" &&
    codec != "adpcm_yamaha" &&
    codec != "adpcm_ima_oki" &&
    codec != "adpcm_ct" &&
    codec != "adpcm_ima_ssi" &&
    codec != "adpcm_ima_apm" &&
    codec != "adpcm_ima_apc" &&
    codec != "adpcm_ima_mtf" &&
    codec != "adpcm_ima_ws" &&
    codec != "adpcm_ima_dk3" &&
    codec != "adpcm_ima_dk4" {
    return Err("adpcm: unsupported codec \{codec}")
  }
  if channels < 1 || channels > 8 {
    return Err("adpcm: invalid channel count")
  }
  if (
      codec == "adpcm_yamaha" ||
      codec == "adpcm_ima_oki" ||
      codec == "adpcm_ct" ||
      codec == "adpcm_ima_ssi" ||
      codec == "adpcm_ima_apm" ||
      codec == "adpcm_ima_apc" ||
      codec == "adpcm_ima_mtf" ||
      codec == "adpcm_ima_ws" ||
      codec == "adpcm_ima_dk4"
    ) &&
    channels > 2 {
    return Err("adpcm: only 1-2 channels are supported")
  }
  if codec == "adpcm_ima_dk3" && channels != 2 {
    return Err("adpcm: Duck IMA DK3 requires stereo")
  }
  if codec == "adpcm_ms" && channels > 6 {
    return Err("adpcm: only 1-6 channels are supported")
  }
  if codec == "adpcm_ima_wav" &&
    (bits_per_coded_sample < 2 || bits_per_coded_sample > 5) {
    return Err("adpcm: IMA WAV bits per sample must be in 2..=5")
  }
  if block_align < 0 {
    return Err("adpcm: invalid block align")
  }
  let status : Array[AdpcmChannel] = []
  for _ in 0..<channels {
    let state = adpcm_channel_new()
    if codec == "adpcm_ct" {
      state.step = 511
    }
    status.push(state)
  }
  if codec == "adpcm_ima_apm" && extradata is Some(data) && data.length() >= 28 {
    for c in 0..<channels {
      let offset = if c == 0 { 16 } else { 4 }
      status[c].predictor = adpcm_clip(
        adpcm_predictor_le32(data, offset),
        -262144,
        262143,
      )
      status[c].step_index = adpcm_clip(
        adpcm_predictor_le32(data, offset + 4),
        0,
        88,
      )
    }
  }
  if codec == "adpcm_ima_apc" && extradata is Some(data) && data.length() >= 8 {
    for c in 0..<channels {
      status[c].predictor = adpcm_clip(
        adpcm_predictor_le32(data, c * 4),
        -262144,
        262143,
      )
    }
  }
  Ok({ codec, channels, block_align, bits_per_coded_sample, status, })
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
/// Multiply-and-shift IMA expansion used by Duck and Westwood ADPCM.
fn adpcm_ima_expand_multiply(state : AdpcmChannel, code : Int32) -> Int32 {
  let step = adpcm_step_table[state.step_index]
  let diff = ((2 * (code & 7) + 1) * step) >> 3
  let delta = if (code & 8) == 0 { diff } else { -diff }
  state.predictor = adpcm_clip_int16(state.predictor + delta)
  state.step_index = adpcm_clip(
    state.step_index + adpcm_index_table[code],
    0,
    88,
  )
  state.predictor
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
/// `adpcm_ima_oki_expand_nibble`: 12-bit predictor, 49-entry step table.
fn adpcm_oki_expand(cs : AdpcmChannel, nibble : Int32) -> Int32 {
  let step = adpcm_oki_step_table[cs.step_index]
  let step_index = adpcm_clip(cs.step_index + adpcm_index_table[nibble], 0, 48)
  let delta = nibble & 7
  let diff = ((2 * delta + 1) * step) >> 3
  let predictor = if (nibble & 8) != 0 {
    cs.predictor - diff
  } else {
    cs.predictor + diff
  }
  cs.predictor = adpcm_clip(predictor, -2048, 2047)
  cs.step_index = step_index
  16 * cs.predictor
}

///|
/// Creative ADPCM applies leakage to the predictor before adding the delta.
fn adpcm_ct_expand(cs : AdpcmChannel, nibble : Int32) -> Int32 {
  let magnitude = nibble & 7
  let diff = ((2 * magnitude + 1) * cs.step) >> 3
  let delta = if (nibble & 8) == 0 { diff } else { -diff }
  cs.predictor = adpcm_clip_int16(((cs.predictor * 254) >> 8) + delta)
  cs.step = adpcm_clip(
    (adpcm_adaptation_table[magnitude] * cs.step) >> 8,
    511,
    32767,
  )
  cs.predictor
}

///|
/// A little-endian bit reader (`get_bits_le`: the first bit is the least
/// significant bit of the first byte).
priv struct AdpcmLeBits {
  data : Bytes
  mut bit_pos : Int32
}

///|
fn AdpcmLeBits::read(self : AdpcmLeBits, n : Int32) -> Int32 {
  let mut v = 0
  for i = 0; i < n; i = i + 1 {
    let bit = (self.data[self.bit_pos >> 3].to_int() >> (self.bit_pos & 7)) & 1
    v = v | (bit << i)
    self.bit_pos = self.bit_pos + 1
  }
  v
}

///|
/// `adpcm_ima_wav_expand_nibble` for the 2-, 3- and 5-bit code widths.
fn adpcm_ima_expand_wide(
  cs : AdpcmChannel,
  gb : AdpcmLeBits,
  bps : Int32,
) -> Int32 {
  let shift = bps - 1
  let nibble = gb.read(bps)
  let step = adpcm_step_table[cs.step_index]
  let table = match bps {
    2 => adpcm_index_table2
    3 => adpcm_index_table3
    5 => adpcm_index_table5
    _ => adpcm_index_table
  }
  let step_index = adpcm_clip(cs.step_index + table[nibble], 0, 88)
  let sign = (nibble & (1 << shift)) != 0
  let delta = nibble & ((1 << shift) - 1)
  let mut diff = step >> shift
  for i = 0; i < shift; i = i + 1 {
    if (delta & (1 << i)) != 0 {
      diff = diff + (step >> (shift - 1 - i))
    }
  }
  let predictor = if sign { cs.predictor - diff } else { cs.predictor + diff }
  cs.predictor = adpcm_clip_int16(predictor)
  cs.step_index = step_index
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
  let bps = self.bits_per_coded_sample
  let bsize = adpcm_ima_block_sizes[bps - 2]
  let bsamples = adpcm_ima_block_samples[bps - 2]
  let nb_samples = adpcm_wav_block_samples(self.codec, block.length(), ch, bps)
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
  if bps != 4 {
    // `samples_per_block` codes per channel packed into `block_size` bytes
    // (4 bytes per channel per group), read as a little-endian bit stream.
    let groups = (nb_samples - 1) / bsamples
    let temp : Array[Byte] = Array::make(bsize, b'\x00')
    for n = 0; n < groups; n = n + 1 {
      for c = 0; c < ch; c = c + 1 {
        let cs = self.status[c]
        for j = 0; j < bsize; j = j + 1 {
          temp[j] = block[4 * ch +
            bsize * n * ch +
            j % 4 +
            j / 4 * (ch * 4) +
            c * 4]
        }
        let gb : AdpcmLeBits = { data: Bytes::from_array(temp), bit_pos: 0, }
        for m = 0; m < bsamples; m = m + 1 {
          planes[c][1 + n * bsamples + m] = adpcm_ima_expand_wide(cs, gb, bps)
        }
      }
    }
  } else {
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
  let nb_samples = adpcm_wav_block_samples(self.codec, block.length(), ch, 4)
  if nb_samples < 2 {
    return Err("adpcm: MS block too short")
  }
  if ch > 2 {
    return self.decode_ms_planar(block, nb_samples)
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
  if nb_samples < 1 {
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
/// `ADPCM_MS` with more than two channels: the C switches to planar
/// output, and each channel's block (7-byte header, then nibble pairs)
/// follows the previous one in the stream.
fn AdpcmDecoder::decode_ms_planar(
  self : AdpcmDecoder,
  block : Bytes,
  nb_samples : Int32,
) -> Result[AdpcmAudio, String] {
  let ch = self.channels
  let planes : Array[Array[Int32]] = []
  for _ in 0..<ch {
    planes.push(Array::make(nb_samples, 0))
  }
  let mut pos = 0
  for c = 0; c < ch; c = c + 1 {
    let cs = self.status[c]
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
    planes[c][0] = cs.sample2
    planes[c][1] = cs.sample1
    for n = 0; n < (nb_samples - 2) / 2; n = n + 1 {
      let byte = block[pos].to_int()
      pos = pos + 1
      planes[c][2 + n * 2] = adpcm_ms_expand(cs, byte >> 4)
      planes[c][3 + n * 2] = adpcm_ms_expand(cs, byte & 0x0F)
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
/// OKI, Creative, SSI and APC ADPCM store sample pairs high nibble first (and
/// for stereo the low nibble is the second channel's).
fn AdpcmDecoder::decode_high_nibble_first(
  self : AdpcmDecoder,
  block : Bytes,
  expand : (AdpcmChannel, Int32) -> Int32,
) -> Result[AdpcmAudio, String] {
  guard block.length() <= 0x3fffffff else {
    return Err("adpcm: packet too large")
  }
  let ch = self.channels
  let nb_samples = block.length() * 2 / ch
  if nb_samples < 1 {
    return Err("adpcm: \{self.codec} block too short")
  }
  let samples : Array[Int32] = Array::make(nb_samples * ch, 0)
  let cs0 = self.status[0]
  if ch == 1 {
    for n = 0; n < nb_samples / 2; n = n + 1 {
      let byte = block[n].to_int()
      samples[n * 2] = expand(cs0, byte >> 4)
      samples[n * 2 + 1] = expand(cs0, byte & 0x0F)
    }
  } else {
    let cs1 = self.status[1]
    for n = 0; n < nb_samples; n = n + 1 {
      let byte = block[n].to_int()
      samples[n * 2] = expand(cs0, byte >> 4)
      samples[n * 2 + 1] = expand(cs1, byte & 0x0F)
    }
  }
  Ok({ channels: ch, samples, })
}

///|
/// Decode one block. MS, IMA WAV and Duck IMA use up to `block_align`
/// bytes of `block` (their packets are block-aligned). Continuous ADPCM
/// decodes the whole packet, ignoring `block_align`.
pub fn AdpcmDecoder::decode_block(
  self : AdpcmDecoder,
  block : Bytes,
) -> Result[AdpcmAudio, String] {
  let size = self.packet_consumed(block.length())
  let usable = if size < block.length() {
    block[:size].to_owned()
  } else {
    block
  }
  match self.codec {
    "adpcm_ima_wav" => self.decode_ima_wav(usable)
    "adpcm_ms" => self.decode_ms(usable)
    "adpcm_ima_oki" => self.decode_high_nibble_first(usable, adpcm_oki_expand)
    "adpcm_ct" => self.decode_high_nibble_first(usable, adpcm_ct_expand)
    "adpcm_ima_ssi" => self.decode_high_nibble_first(usable, adpcm_ima_expand)
    "adpcm_ima_apc" =>
      self.decode_high_nibble_first(usable, adpcm_ima_expand_multiply)
    "adpcm_ima_apm" => self.decode_ima_channel_pairs(usable, adpcm_ima_expand)
    "adpcm_ima_mtf" =>
      self.decode_ima_channel_pairs(usable, adpcm_ima_mtf_expand)
    "adpcm_ima_ws" => self.decode_ima_ws(usable)
    "adpcm_ima_dk3" | "adpcm_ima_dk4" => self.decode_duck(usable)
    _ => self.decode_yamaha(usable)
  }
}

///|
/// Bytes one `decode_block` call consumes from the front of a packet of
/// `packet_size` bytes: MS, IMA WAV and Duck IMA take one `block_align` block (the
/// whole packet when shorter or when the block size is unknown); OKI and
/// Yamaha decode the whole packet in one frame.
pub fn AdpcmDecoder::packet_consumed(
  self : AdpcmDecoder,
  packet_size : Int32,
) -> Int32 {
  if (
      self.codec == "adpcm_ms" ||
      self.codec == "adpcm_ima_wav" ||
      self.codec == "adpcm_ima_dk3" ||
      self.codec == "adpcm_ima_dk4"
    ) &&
    self.block_align > 0 &&
    packet_size > self.block_align {
    self.block_align
  } else {
    packet_size
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

///|
/// IMA QuickTime (`ima4`) decoder: each 34-byte chunk holds a big-endian
/// 16-bit header (9-bit predictor with the low 7 bits cleared, 7-bit step
/// index) followed by 64 nibbles. Predictor/step state carries across blocks
/// when the step index is unchanged and the predictor moved by at most 0x7f.
pub struct AdpcmImaQtDecoder {
  channels : Int32
  status : Array[AdpcmChannel]
}

///|
pub fn adpcm_ima_qt_decoder_new(
  channels : Int32,
) -> Result[AdpcmImaQtDecoder, String] {
  if channels < 1 || channels > 8 {
    return Err("adpcm: invalid IMA QuickTime channel count")
  }
  let status : Array[AdpcmChannel] = []
  for ch = 0; ch < channels; ch = ch + 1 {
    status.push(adpcm_channel_new())
  }
  Ok({ channels, status, })
}

///|
pub fn AdpcmImaQtDecoder::decode_block(
  self : AdpcmImaQtDecoder,
  packet : Bytes,
) -> Result[Array[Int32], String] {
  if packet.length() < 34 * self.channels {
    return Err("adpcm: truncated IMA QuickTime block")
  }
  let planes : Array[Array[Int32]] = []
  for ch = 0; ch < self.channels; ch = ch + 1 {
    planes.push(Array::make(64, 0))
  }
  let mut pos = 0
  for ch = 0; ch < self.channels; ch = ch + 1 {
    let cs = self.status[ch]
    let header = (packet[pos].to_int() << 8) | packet[pos + 1].to_int()
    pos = pos + 2
    let predictor = adpcm_sign16(header) & -128
    let step_index = header & 0x7F
    if cs.step_index != step_index {
      cs.step_index = step_index
      cs.predictor = predictor
    } else {
      let diff = predictor - cs.predictor
      let abs_diff = if diff < 0 { -diff } else { diff }
      if abs_diff > 0x7F {
        cs.step_index = step_index
        cs.predictor = predictor
      }
    }
    if cs.step_index > 88 {
      return Err("adpcm: invalid IMA QuickTime step index")
    }
    for m = 0; m < 32; m = m + 1 {
      let byte = packet[pos].to_int()
      pos = pos + 1
      planes[ch][m * 2] = adpcm_ima_expand(cs, byte & 0x0F)
      planes[ch][m * 2 + 1] = adpcm_ima_expand(cs, byte >> 4)
    }
  }
  let samples : Array[Int32] = []
  for i = 0; i < 64; i = i + 1 {
    for ch = 0; ch < self.channels; ch = ch + 1 {
      samples.push(planes[ch][i])
    }
  }
  Ok(samples)
}
