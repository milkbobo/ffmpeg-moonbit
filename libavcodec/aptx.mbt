///|
/// aptX / aptX HD decoder, ported from FFmpeg 9.0.2 `libavcodec/aptx.c`,
/// `aptx.h` and `aptxdec.c`.
///
/// `ff_aptx_decode` takes a raw aptX stream (4-byte blocks: 2 channels ×
/// 16-bit codewords) or aptX HD stream (6-byte blocks: 2 × 24-bit) and returns
/// interleaved S32 PCM (`sample * 256`, matching FFmpeg's S32P output).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `ConstTables` for one sub-band.
priv struct AptxTables {
  intervals : FixedArray[Int32]
  invert_factors : FixedArray[Int32]
  offsets : FixedArray[Int32]
  factor_max : Int32
  order : Int32
}

///|
fn aptx_tables(hd : Bool, subband : Int32) -> AptxTables {
  if hd {
    if subband == 0 {
      {
        intervals: aptx_hd_quantize_intervals_LF,
        invert_factors: aptx_hd_invert_quantize_dither_factors_LF,
        offsets: aptx_hd_quantize_factor_select_offset_LF,
        factor_max: 0x11FF,
        order: 24,
      }
    } else if subband == 1 {
      {
        intervals: aptx_hd_quantize_intervals_MLF,
        invert_factors: aptx_hd_invert_quantize_dither_factors_MLF,
        offsets: aptx_hd_quantize_factor_select_offset_MLF,
        factor_max: 0x14FF,
        order: 12,
      }
    } else if subband == 2 {
      {
        intervals: aptx_hd_quantize_intervals_MHF,
        invert_factors: aptx_hd_invert_quantize_dither_factors_MHF,
        offsets: aptx_hd_quantize_factor_select_offset_MHF,
        factor_max: 0x16FF,
        order: 6,
      }
    } else {
      {
        intervals: aptx_hd_quantize_intervals_HF,
        invert_factors: aptx_hd_invert_quantize_dither_factors_HF,
        offsets: aptx_hd_quantize_factor_select_offset_HF,
        factor_max: 0x15FF,
        order: 12,
      }
    }
  } else if subband == 0 {
    {
      intervals: aptx_quantize_intervals_LF,
      invert_factors: aptx_invert_quantize_dither_factors_LF,
      offsets: aptx_quantize_factor_select_offset_LF,
      factor_max: 0x11FF,
      order: 24,
    }
  } else if subband == 1 {
    {
      intervals: aptx_quantize_intervals_MLF,
      invert_factors: aptx_invert_quantize_dither_factors_MLF,
      offsets: aptx_quantize_factor_select_offset_MLF,
      factor_max: 0x14FF,
      order: 12,
    }
  } else if subband == 2 {
    {
      intervals: aptx_quantize_intervals_MHF,
      invert_factors: aptx_invert_quantize_dither_factors_MHF,
      offsets: aptx_quantize_factor_select_offset_MHF,
      factor_max: 0x16FF,
      order: 6,
    }
  } else {
    {
      intervals: aptx_quantize_intervals_HF,
      invert_factors: aptx_invert_quantize_dither_factors_HF,
      offsets: aptx_quantize_factor_select_offset_HF,
      factor_max: 0x15FF,
      order: 12,
    }
  }
}

///|
fn aptx_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn aptx_sign_extend(v : Int32, bits : Int32) -> Int32 {
  if bits >= 32 {
    v
  } else {
    v << (32 - bits) >> (32 - bits)
  }
}

///|
/// `av_clip_intp2`: range `[-2^p, 2^p - 1]`.
fn aptx_clip_intp2(v : Int32, bits : Int32) -> Int32 {
  let limit = 1 << bits
  aptx_clip(v, -limit, limit - 1)
}

///|
/// `rshift32`: rounded right shift with the C's boundary correction.
fn aptx_rshift32(value : Int32, shift : Int32) -> Int32 {
  let rounding : Int32 = 1 << (shift - 1)
  let mask : Int32 = (1 << (shift + 1)) - 1
  ((value + rounding) >> shift) -
  (if (value & mask) == rounding { 1 } else { 0 })
}

///|
/// `rshift64`.
fn aptx_rshift64(value : Int64, shift : Int32) -> Int64 {
  let rounding : Int64 = 1L << (shift - 1)
  let mask : Int64 = (1L << (shift + 1)) - 1L
  ((value + rounding) >> shift) -
  (if (value & mask) == rounding { 1L } else { 0L })
}

///|
/// `rshift64_clip24`.
fn aptx_rshift64_clip24(value : Int64, shift : Int32) -> Int32 {
  aptx_clip_intp2(aptx_rshift64(value, shift).to_int(), 23)
}

///|
fn aptx_mul64(a : Int32, b : Int32) -> Int64 {
  a.to_int64() * b.to_int64()
}

///|
fn aptx_ffdiffsign(a : Int32, b : Int32) -> Int32 {
  if a > b {
    1
  } else if a < b {
    -1
  } else {
    0
  }
}

///|
fn aptx_signbit(v : Int32) -> Int32 {
  v >> 31
}

///|
/// One QMF polyphase FIR history (`FilterSignal`).
priv struct AptxFilterSignal {
  mut pos : Int32
  buffer : FixedArray[Int32]
}

///|
fn aptx_filter_signal_new() -> AptxFilterSignal {
  { pos: 0, buffer: FixedArray::make(32, 0), }
}

///|
fn aptx_filter_signal_push(sig : AptxFilterSignal, sample : Int32) -> Unit {
  sig.buffer[sig.pos] = sample
  sig.buffer[sig.pos + 16] = sample
  sig.pos = (sig.pos + 1) & 15
}

///|
fn aptx_filter_convolution(
  sig : AptxFilterSignal,
  coeffs : FixedArray[Int32],
  shift : Int32,
) -> Int32 {
  let mut e : Int64 = 0
  for i = 0; i < 16; i = i + 1 {
    e = e + aptx_mul64(sig.buffer[sig.pos + i], coeffs[i])
  }
  aptx_rshift64_clip24(e, shift)
}

///|
/// `aptx_qmf_polyphase_synthesis`.
fn aptx_qmf_polyphase_synthesis(
  signals : Array[AptxFilterSignal],
  coeffs : FixedArray[FixedArray[Int32]],
  shift : Int32,
  low : Int32,
  high : Int32,
  samples : FixedArray[Int32],
  offset : Int32,
) -> Unit {
  let sub0 = low + high
  let sub1 = low - high
  for i = 0; i < 2; i = i + 1 {
    aptx_filter_signal_push(signals[i], if i == 0 { sub1 } else { sub0 })
    samples[offset + i] = aptx_filter_convolution(signals[i], coeffs[i], shift)
  }
}

///|
/// `Quantize`.
priv struct AptxQuantize {
  mut quantized_sample : Int32
}

///|
/// `InvertQuantize`.
priv struct AptxInvertQuantize {
  mut quantization_factor : Int32
  mut factor_select : Int32
  mut reconstructed_difference : Int32
}

///|
/// `Prediction`.
priv struct AptxPrediction {
  prev_sign : FixedArray[Int32]
  s_weight : FixedArray[Int32]
  d_weight : FixedArray[Int32]
  mut pos : Int32
  reconstructed_differences : FixedArray[Int32]
  mut previous_reconstructed_sample : Int32
  mut predicted_difference : Int32
  mut predicted_sample : Int32
}

///|
fn aptx_prediction_new() -> AptxPrediction {
  {
    prev_sign: [1, 1],
    s_weight: FixedArray::make(2, 0),
    d_weight: FixedArray::make(24, 0),
    pos: 0,
    reconstructed_differences: FixedArray::make(48, 0),
    previous_reconstructed_sample: 0,
    predicted_difference: 0,
    predicted_sample: 0,
  }
}

///|
/// `Channel`.
priv struct AptxChannel {
  mut codeword_history : Int32
  mut dither_parity : Int32
  dither : FixedArray[Int32]
  outer : Array[AptxFilterSignal]
  inner : Array[Array[AptxFilterSignal]]
  quantize : Array[AptxQuantize]
  invert : Array[AptxInvertQuantize]
  prediction : Array[AptxPrediction]
}

///|
fn aptx_channel_new() -> AptxChannel {
  let outer : Array[AptxFilterSignal] = []
  for _ in 0..<2 {
    outer.push(aptx_filter_signal_new())
  }
  let inner : Array[Array[AptxFilterSignal]] = []
  for _ in 0..<2 {
    let row : Array[AptxFilterSignal] = []
    for _ in 0..<2 {
      row.push(aptx_filter_signal_new())
    }
    inner.push(row)
  }
  let quantize : Array[AptxQuantize] = []
  let invert : Array[AptxInvertQuantize] = []
  let prediction : Array[AptxPrediction] = []
  for _ in 0..<4 {
    quantize.push({ quantized_sample: 0, })
    invert.push({
      quantization_factor: 0,
      factor_select: 0,
      reconstructed_difference: 0,
    })
    prediction.push(aptx_prediction_new())
  }
  {
    codeword_history: 0,
    dither_parity: 0,
    dither: FixedArray::make(4, 0),
    outer,
    inner,
    quantize,
    invert,
    prediction,
  }
}

///|
/// Decoded aptX audio: interleaved S32 samples (`sample * 256`).
pub struct AptxAudio {
  samples : Array[Int32]
}

///|
/// `aptx_update_codeword_history` + `ff_aptx_generate_dither`.
fn aptx_generate_dither(channel : AptxChannel) -> Unit {
  let cw = ((channel.quantize[0].quantized_sample & 3) << 0) +
    ((channel.quantize[1].quantized_sample & 2) << 1) +
    ((channel.quantize[2].quantized_sample & 1) << 3)
  channel.codeword_history = (cw << 8) + (channel.codeword_history << 4)
  let m = 5184443L * (channel.codeword_history >> 7).to_int64()
  let d = (m * 4L + (m >> 22)).to_int()
  for subband = 0; subband < 4; subband = subband + 1 {
    channel.dither[subband] = d << (23 - 5 * subband)
  }
  channel.dither_parity = (d >> 25) & 1
}

///|
fn aptx_quantized_parity(channel : AptxChannel) -> Int32 {
  let mut parity = channel.dither_parity
  for subband = 0; subband < 4; subband = subband + 1 {
    parity = parity ^ channel.quantize[subband].quantized_sample
  }
  parity & 1
}

///|
/// `aptx_invert_quantization`.
fn aptx_invert_quantization(
  iq : AptxInvertQuantize,
  quantized_sample : Int32,
  dither : Int32,
  tables : AptxTables,
) -> Unit {
  let idx = (quantized_sample ^ (if quantized_sample < 0 { -1 } else { 0 })) + 1
  let mut qr = tables.intervals[idx] / 2
  if quantized_sample < 0 {
    qr = -qr
  }
  let sum = (qr.to_int64() << 32) +
    aptx_mul64(dither, tables.invert_factors[idx])
  qr = aptx_rshift64_clip24(sum, 32)
  iq.reconstructed_difference = (aptx_mul64(iq.quantization_factor, qr) >> 19).to_int()
  let fs = aptx_rshift32(
    32620 * iq.factor_select + (tables.offsets[idx] << 15),
    15,
  )
  iq.factor_select = aptx_clip(fs, 0, tables.factor_max)
  let fidx = (iq.factor_select & 0xFF) >> 3
  let shift = (tables.factor_max - iq.factor_select) >> 8
  iq.quantization_factor = aptx_quantization_factors[fidx] << 11 >> shift
}

///|
/// `aptx_reconstructed_differences_update`: returns the index of the newest
/// difference in the ring buffer.
fn aptx_reconstructed_differences_update(
  prediction : AptxPrediction,
  reconstructed_difference : Int32,
  order : Int32,
) -> Int32 {
  let rd = prediction.reconstructed_differences
  let p = prediction.pos
  rd[p] = rd[order + p]
  let p2 = (p + 1) % order
  prediction.pos = p2
  rd[order + p2] = reconstructed_difference
  order + p2
}

///|
/// `aptx_prediction_filtering`.
fn aptx_prediction_filtering(
  prediction : AptxPrediction,
  reconstructed_difference : Int32,
  order : Int32,
) -> Unit {
  let reconstructed_sample = aptx_clip_intp2(
    reconstructed_difference + prediction.predicted_sample,
    23,
  )
  let predictor = aptx_clip_intp2(
    ((
      aptx_mul64(
        prediction.s_weight[0],
        prediction.previous_reconstructed_sample,
      ) +
      aptx_mul64(prediction.s_weight[1], reconstructed_sample)
    ) >>
    22).to_int(),
    23,
  )
  prediction.previous_reconstructed_sample = reconstructed_sample
  let idx = aptx_reconstructed_differences_update(
    prediction, reconstructed_difference, order,
  )
  let rd = prediction.reconstructed_differences
  let srd0 = aptx_ffdiffsign(reconstructed_difference, 0) * (1 << 23)
  let mut predicted : Int64 = 0
  for i = 0; i < order; i = i + 1 {
    let srd = aptx_signbit(rd[idx - i - 1]) | 1
    prediction.d_weight[i] = prediction.d_weight[i] -
      aptx_rshift32(prediction.d_weight[i] - srd * srd0, 8)
    predicted = predicted + aptx_mul64(rd[idx - i], prediction.d_weight[i])
  }
  prediction.predicted_difference = aptx_clip_intp2(
    (predicted >> 22).to_int(),
    23,
  )
  prediction.predicted_sample = aptx_clip_intp2(
    predictor + prediction.predicted_difference,
    23,
  )
}

///|
/// `aptx_process_subband`.
fn aptx_process_subband(
  iq : AptxInvertQuantize,
  prediction : AptxPrediction,
  quantized_sample : Int32,
  dither : Int32,
  tables : AptxTables,
) -> Unit {
  aptx_invert_quantization(iq, quantized_sample, dither, tables)
  let sign = aptx_ffdiffsign(
    iq.reconstructed_difference,
    -prediction.predicted_difference,
  )
  let same_sign0 = sign * prediction.prev_sign[0]
  let same_sign1 = sign * prediction.prev_sign[1]
  prediction.prev_sign[0] = prediction.prev_sign[1]
  prediction.prev_sign[1] = sign | 1
  let mut range = 0x100000
  let mut sw1 = aptx_rshift32(-same_sign1 * prediction.s_weight[1], 1)
  sw1 = (aptx_clip(sw1, -range, range) & -16) * 16
  range = 0x300000
  let weight0 = 254 * prediction.s_weight[0] + 0x800000 * same_sign0 + sw1
  prediction.s_weight[0] = aptx_clip(aptx_rshift32(weight0, 8), -range, range)
  range = 0x3C0000 - prediction.s_weight[0]
  let weight1 = 255 * prediction.s_weight[1] + 0xC00000 * same_sign1
  prediction.s_weight[1] = aptx_clip(aptx_rshift32(weight1, 8), -range, range)
  aptx_prediction_filtering(
    prediction,
    iq.reconstructed_difference,
    tables.order,
  )
}

///|
/// `ff_aptx_invert_quantize_and_prediction`.
fn aptx_invert_quantize_and_prediction(
  channel : AptxChannel,
  hd : Bool,
) -> Unit {
  for subband = 0; subband < 4; subband = subband + 1 {
    aptx_process_subband(
      channel.invert[subband],
      channel.prediction[subband],
      channel.quantize[subband].quantized_sample,
      channel.dither[subband],
      aptx_tables(hd, subband),
    )
  }
}

///|
/// `aptx_qmf_tree_synthesis`.
fn aptx_qmf_tree_synthesis(
  channel : AptxChannel,
  subband_samples : FixedArray[Int32],
  samples : FixedArray[Int32],
) -> Unit {
  let intermediate : FixedArray[Int32] = FixedArray::make(4, 0)
  for i = 0; i < 2; i = i + 1 {
    aptx_qmf_polyphase_synthesis(
      channel.inner[i],
      aptx_qmf_inner_coeffs,
      22,
      subband_samples[2 * i],
      subband_samples[2 * i + 1],
      intermediate,
      2 * i,
    )
  }
  for i = 0; i < 2; i = i + 1 {
    aptx_qmf_polyphase_synthesis(
      channel.outer,
      aptx_qmf_outer_coeffs,
      21,
      intermediate[0 + i],
      intermediate[2 + i],
      samples,
      2 * i,
    )
  }
}

///|
/// `aptx_decode_channel`.
fn aptx_decode_channel(
  channel : AptxChannel,
  samples : FixedArray[Int32],
) -> Unit {
  let subband_samples : FixedArray[Int32] = FixedArray::make(4, 0)
  for subband = 0; subband < 4; subband = subband + 1 {
    subband_samples[subband] = channel.prediction[subband].previous_reconstructed_sample
  }
  aptx_qmf_tree_synthesis(channel, subband_samples, samples)
}

///|
/// Decoder state across blocks.
priv struct AptxDecoder {
  hd : Bool
  mut sync_idx : Int32
  channels : Array[AptxChannel]
}

///|
fn aptx_decoder_new(hd : Bool) -> AptxDecoder {
  { hd, sync_idx: 0, channels: [aptx_channel_new(), aptx_channel_new()], }
}

///|
/// Decode one block into 8 interleaved samples.
fn AptxDecoder::decode_block(
  self : AptxDecoder,
  block : Bytes,
) -> Result[Array[Int32], String] {
  let samples : Array[FixedArray[Int32]] = [
    FixedArray::make(4, 0),
    FixedArray::make(4, 0),
  ]
  for ch = 0; ch < 2; ch = ch + 1 {
    let channel = self.channels[ch]
    aptx_generate_dither(channel)
    if self.hd {
      let cw = (block[3 * ch].to_int() << 16) |
        (block[3 * ch + 1].to_int() << 8) |
        block[3 * ch + 2].to_int()
      channel.quantize[0].quantized_sample = aptx_sign_extend(cw >> 0, 9)
      channel.quantize[1].quantized_sample = aptx_sign_extend(cw >> 9, 6)
      channel.quantize[2].quantized_sample = aptx_sign_extend(cw >> 15, 4)
      channel.quantize[3].quantized_sample = aptx_sign_extend(cw >> 19, 5)
      channel.quantize[3].quantized_sample = (
          channel.quantize[3].quantized_sample & -2
        ) |
        aptx_quantized_parity(channel)
    } else {
      let cw = (block[2 * ch].to_int() << 8) | block[2 * ch + 1].to_int()
      channel.quantize[0].quantized_sample = aptx_sign_extend(cw >> 0, 7)
      channel.quantize[1].quantized_sample = aptx_sign_extend(cw >> 7, 4)
      channel.quantize[2].quantized_sample = aptx_sign_extend(cw >> 11, 2)
      channel.quantize[3].quantized_sample = aptx_sign_extend(cw >> 13, 3)
      channel.quantize[3].quantized_sample = (
          channel.quantize[3].quantized_sample & -2
        ) |
        aptx_quantized_parity(channel)
    }
    aptx_invert_quantize_and_prediction(channel, self.hd)
  }
  let parity = aptx_quantized_parity(self.channels[0]) ^
    aptx_quantized_parity(self.channels[1])
  let eighth = self.sync_idx == 7
  self.sync_idx = (self.sync_idx + 1) & 7
  if (parity ^ (if eighth { 1 } else { 0 })) != 0 {
    return Err("aptx: synchronization error")
  }
  for ch = 0; ch < 2; ch = ch + 1 {
    aptx_decode_channel(self.channels[ch], samples[ch])
  }
  let out : Array[Int32] = []
  for i = 0; i < 4; i = i + 1 {
    out.push(samples[0][i] * 256)
    out.push(samples[1][i] * 256)
  }
  Ok(out)
}

///|
/// Decode a raw aptX (`hd = false`, 4-byte blocks) or aptX HD (`hd = true`,
/// 6-byte blocks) stream.
pub fn ff_aptx_decode(
  data : Bytes,
  hd~ : Bool = false,
) -> Result[AptxAudio, String] {
  let block_size = if hd { 6 } else { 4 }
  let decoder = aptx_decoder_new(hd)
  let out : Array[Int32] = []
  let mut pos = 0
  while pos + block_size <= data.length() {
    let block = data[pos:pos + block_size].to_owned()
    let samples = match decoder.decode_block(block) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    for s in samples {
      out.push(s)
    }
    pos = pos + block_size
  }
  Ok({ samples: out, })
}

///|
/// Interleaved S32 little-endian PCM bytes.
pub fn AptxAudio::pcm_bytes(self : AptxAudio) -> Bytes {
  let out : Array[Byte] = []
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
    out.push(((v >> 16) & 0xFF).to_byte())
    out.push(((v >> 24) & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}
