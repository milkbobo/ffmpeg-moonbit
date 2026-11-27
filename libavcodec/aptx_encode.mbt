///|
/// aptX and aptX HD encoding from FFmpeg 9.0.2 `aptxenc.c` (LGPL-2.1-or-later).
/// Original code copyright (C) 2017 Aurelien Jacobs.
fn aptx_qmf_analyze_pair(
  signals : Array[AptxFilterSignal],
  coeffs : FixedArray[FixedArray[Int32]],
  first : Int32,
  second : Int32,
) -> (Int32, Int32) {
  aptx_filter_signal_push(signals[0], second)
  aptx_filter_signal_push(signals[1], first)
  let a = aptx_filter_convolution(signals[0], coeffs[0], 23)
  let b = aptx_filter_convolution(signals[1], coeffs[1], 23)
  (aptx_clip_intp2(a + b, 23), aptx_clip_intp2(a - b, 23))
}

///|
fn aptx_quantize_difference(
  quantize : AptxQuantize,
  difference : Int32,
  dither : Int32,
  factor : Int32,
  tables : AptxTables,
) -> Unit {
  let magnitude = difference.abs().min(0x7fffff)
  let intervals = tables.intervals
  let scaled = (magnitude >> 4).to_int64() << 24
  let mut index = 0
  for stride = intervals.length() >> 1; stride > 0; stride = stride >> 1 {
    if aptx_mul64(factor, intervals[index + stride]) <= scaled {
      index += stride
    }
  }
  let square_high = (aptx_mul64(dither, dither) >> 32).to_int()
  let d = aptx_clip_intp2(aptx_rshift32(square_high, 7), 23) - (1 << 23)
  let offset = aptx_rshift64(aptx_mul64(d, tables.encode_factors[index]), 23).to_int()
  let lower = intervals[index]
  let upper = intervals[index + 1]
  let mean = (lower + upper) / 2
  let sign = aptx_signbit(difference)
  let interval = (upper - lower) * (sign | 1)
  let dithered = aptx_rshift64_clip24(
    aptx_mul64(dither, interval) +
    (aptx_clip_intp2(mean + offset, 23).to_int64() << 32),
    32,
  )
  let error = (magnitude.to_int64() << 20) - aptx_mul64(dithered, factor)
  quantize.error = aptx_rshift64(error, 23).to_int().abs()
  let (code, alternate) = if error < 0L {
    (index - 1, index)
  } else {
    (index, index - 1)
  }
  quantize.quantized_sample = code ^ sign
  quantize.parity_change = alternate ^ sign
}

///|
fn aptx_encode_channel(
  channel : AptxChannel,
  pcm : ArrayView[Int32],
  offset : Int32,
  hd : Bool,
) -> Unit {
  let samples = FixedArray::makei(4, i => {
    if offset + i < pcm.length() {
      pcm[offset + i] >> 8
    } else {
      0
    }
  })
  let (low0, high0) = aptx_qmf_analyze_pair(
    channel.outer,
    aptx_qmf_outer_coeffs,
    samples[0],
    samples[1],
  )
  let (low1, high1) = aptx_qmf_analyze_pair(
    channel.outer,
    aptx_qmf_outer_coeffs,
    samples[2],
    samples[3],
  )
  let (lf, mlf) = aptx_qmf_analyze_pair(
    channel.inner[0],
    aptx_qmf_inner_coeffs,
    low0,
    low1,
  )
  let (mhf, hf) = aptx_qmf_analyze_pair(
    channel.inner[1],
    aptx_qmf_inner_coeffs,
    high0,
    high1,
  )
  let subbands : FixedArray[Int32] = [lf, mlf, mhf, hf]
  aptx_generate_dither(channel)
  for i in 0..<4 {
    let diff = aptx_clip_intp2(
      subbands[i] - channel.prediction[i].predicted_sample,
      23,
    )
    aptx_quantize_difference(
      channel.quantize[i],
      diff,
      channel.dither[i],
      channel.invert[i].quantization_factor,
      aptx_tables(hd, i),
    )
  }
}

///|
fn aptx_insert_sync(channels : Array[AptxChannel], sync_index : Int32) -> Unit {
  let expected = if sync_index == 7 { 1 } else { 0 }
  if aptx_stereo_parity(channels) != expected {
    let mut best = channels[1].quantize[1]
    // Preserve the reference tie order when two subbands have the same error.
    for channel in [channels[1], channels[0]] {
      for i in [1, 2, 0, 3] {
        let candidate = channel.quantize[i]
        if candidate.error < best.error {
          best = candidate
        }
      }
    }
    best.quantized_sample = best.parity_change
  }
}

///|
fn aptx_pack_channel(channel : AptxChannel, hd : Bool) -> Int32 {
  let q = channel.quantize
  let hf = (q[3].quantized_sample & -2) | aptx_quantized_parity(channel)
  if hd {
    ((hf & 0x1f) << 19) |
    ((q[2].quantized_sample & 0xf) << 15) |
    ((q[1].quantized_sample & 0x3f) << 9) |
    (q[0].quantized_sample & 0x1ff)
  } else {
    ((hf & 0x7) << 13) |
    ((q[2].quantized_sample & 0x3) << 11) |
    ((q[1].quantized_sample & 0xf) << 7) |
    (q[0].quantized_sample & 0x7f)
  }
}

///|
/// Encode stereo signed 32-bit planar PCM to raw aptX or aptX HD.
/// The encoder uses the high 24 bits and pads the final block with silence.
pub fn encode_aptx(
  left : ArrayView[Int32],
  right : ArrayView[Int32],
  hd~ : Bool = false,
) -> Result[Bytes, String] {
  guard left.length() == right.length() else {
    return Err("aptx: stereo planes must have the same length")
  }
  let channels = [aptx_channel_new(), aptx_channel_new()]
  let out : Array[Byte] = []
  let blocks = left.length() / 4 + (if left.length() % 4 == 0 { 0 } else { 1 })
  for block in 0..<blocks {
    let offset = block * 4
    aptx_encode_channel(channels[0], left, offset, hd)
    aptx_encode_channel(channels[1], right, offset, hd)
    aptx_insert_sync(channels, block & 7)
    for channel in channels {
      aptx_invert_quantize_and_prediction(channel, hd)
      let codeword = aptx_pack_channel(channel, hd)
      if hd {
        out.push((codeword >> 16).to_byte())
      }
      out.push((codeword >> 8).to_byte())
      out.push(codeword.to_byte())
    }
  }
  Ok(Bytes::from_array(out))
}
