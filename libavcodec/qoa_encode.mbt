// QOA encoder adapted from https://github.com/phoboslab/qoa
// Copyright (c) 2023 Dominic Szablewski
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

///|
let qoa_reciprocal : FixedArray[Int32] = [
  65536, 9363, 3121, 1457, 781, 475, 311, 216, 156, 117, 90, 71, 57, 47, 39, 32,
]

///|
let qoa_quant : FixedArray[Int32] = [
  7, 7, 7, 5, 5, 3, 3, 1, 0, 0, 2, 2, 4, 4, 6, 6, 6,
]

///|
priv struct QoaLms {
  history : FixedArray[Int32]
  weights : FixedArray[Int32]
}

///|
fn QoaLms::copy_from(self : QoaLms, other : QoaLms) -> Unit {
  for tap in 0..<4 {
    self.history[tap] = other.history[tap]
    self.weights[tap] = other.weights[tap]
  }
}

///|
fn qoa_quantize(residual : Int32, scale : Int32) -> Int32 {
  let rounded = (residual * qoa_reciprocal[scale] + 32768) >> 16
  let scaled = rounded + residual.compare(0) - rounded.compare(0)
  qoa_quant[adpcm_clip(scaled, -8, 8) + 8]
}

///|
fn qoa_encode_slice(
  pcm : FixedArray[Int32],
  len : Int32,
  state : QoaLms,
  trial : QoaLms,
  best : QoaLms,
  previous_scale : Int32,
) -> (UInt64, Int32) {
  let mut best_rank = 0x7fffffffffffffffL
  let mut best_slice = 0UL
  let mut best_scale = 0
  for candidate in 0..<16 {
    let scale = (previous_scale + candidate) & 15
    trial.copy_from(state)
    let mut bits = scale.to_uint64()
    let mut rank = 0L
    for i in 0..<len {
      let predicted = qoa_predict(trial.history, trial.weights, 0)
      let code = qoa_quantize(pcm[i] - predicted, scale)
      let magnitude = qoa_dequant[scale * 4 + (code >> 1)]
      let residual = if (code & 1) == 0 { magnitude } else { -magnitude }
      let sample = clip_int16(predicted + residual)
      let error = (pcm[i] - sample).to_int64()
      let mut weight_power = 0
      for weight in trial.weights {
        weight_power += weight * weight
      }
      let penalty = ((weight_power >> 18) - 0x8ff).max(0).to_int64()
      rank += error * error + penalty * penalty
      if rank > best_rank {
        break
      }
      qoa_update(trial.history, trial.weights, 0, sample, residual)
      bits = (bits << 3) | code.to_uint64()
    }
    if rank < best_rank {
      best_rank = rank
      best_slice = bits
      best_scale = scale
      best.copy_from(trial)
    }
  }
  state.copy_from(best)
  (best_slice << ((20 - len) * 3), best_scale)
}

///|
fn qoa_write_be(out : Array[Byte], value : UInt64, bytes : Int32) -> Unit {
  for i in 0..<bytes {
    out.push((value >> ((bytes - 1 - i) * 8)).to_int().to_byte())
  }
}

///|
/// Encode a fixed-format QOA file from interleaved 16-bit PCM. The partial
/// final slice contains only the remaining samples and zero padding bits.
pub fn encode_qoa(
  samples : ArrayView[Int32],
  sample_rate : Int32,
  channels : Int32,
) -> Result[Bytes, String] {
  guard channels >= 1 &&
    channels <= 8 &&
    sample_rate > 0 &&
    sample_rate <= 0xffffff else {
    return Err("qoa: invalid sample rate or channel count")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("qoa: expected complete PCM frames")
  }
  let total = samples.length() / channels
  let out : Array[Byte] = [b'q', b'o', b'a', b'f']
  qoa_write_be(out, total.to_uint64(), 4)
  let states : Array[QoaLms] = Array::makei(channels, _ => {
    history: FixedArray::make(4, 0),
    weights: [0, 0, -8192, 16384],
  })
  let trial : QoaLms = {
    history: FixedArray::make(4, 0),
    weights: FixedArray::make(4, 0),
  }
  let best : QoaLms = {
    history: FixedArray::make(4, 0),
    weights: FixedArray::make(4, 0),
  }
  let previous_scale = FixedArray::make(channels, 0)
  let pcm = FixedArray::make(20, 0)
  for first = 0; first < total; {
    let count = (total - first).min(5120)
    let slices = (count + 19) / 20
    let size = 8 + channels * (16 + slices * 8)
    out.push(channels.to_byte())
    qoa_write_be(out, sample_rate.to_uint64(), 3)
    qoa_write_be(out, count.to_uint64(), 2)
    qoa_write_be(out, size.to_uint64(), 2)
    for ch, state in states {
      previous_scale[ch] = 0
      for sample in state.history {
        qoa_write_be(out, (sample & 65535).to_uint64(), 2)
      }
      for weight in state.weights {
        qoa_write_be(out, (weight & 65535).to_uint64(), 2)
      }
    }
    for slice in 0..<slices {
      let offset = slice * 20
      let len = (count - offset).min(20)
      for ch, state in states {
        for i in 0..<len {
          pcm[i] = clip_int16(samples[(first + offset + i) * channels + ch])
        }
        let (bits, scale) = qoa_encode_slice(
          pcm,
          len,
          state,
          trial,
          best,
          previous_scale[ch],
        )
        qoa_write_be(out, bits, 8)
        previous_scale[ch] = scale
      }
    }
    continue first + count
  }
  Ok(Bytes::from_array(out))
}
