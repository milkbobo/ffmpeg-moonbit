///|
/// CELT half inverse MDCT, overlap/add, pitch postfilter and deemphasis.
/// Ported from FFmpeg 9.0.2 opus/dec_celt.c, opus/dsp.c and tx_template.c.
/// LGPL-2.1-or-later. The direct inverse transform is O(N^2).
priv struct CeltSynthesisChannel {
  buffer : Array[Float]
  mut old_period : Int32
  mut period : Int32
  mut old_gains : Array[Float]
  mut gains : Array[Float]
  mut emphasis : Float
}

///|
fn CeltSynthesisChannel::new() -> CeltSynthesisChannel {
  { buffer: Array::make(2048, 0.0), old_period: 0, period: 0,
    old_gains: Array::make(3, 0.0), gains: Array::make(3, 0.0), emphasis: 0.0 }
}

///|
fn CeltSynthesisChannel::copy(self : CeltSynthesisChannel) -> CeltSynthesisChannel {
  { buffer: self.buffer.copy(), old_period: self.old_period, period: self.period,
    old_gains: self.old_gains.copy(), gains: self.gains.copy(), emphasis: self.emphasis }
}

///|
// FFmpeg's half inverse returns N samples for N coefficients, scale=-1/32768.
// Transient input is interleaved by block; output is contiguous by block.
fn opus_celt_imdct(input : Array[Float], block : Int32, blocks : Int32) -> Array[Float] {
  let n = input.length() / blocks
  let half = n / 2
  let phase = 3.14159265358979323846 / (4.0 * n.to_double())
  let output : Array[Float] = Array::make(n, 0.0)
  for i in 0..<half {
    let down = phase * (2 * n - 2 * i - 1).to_double()
    let up = phase * (3 * n + 2 * i + 1).to_double()
    let mut sum_down = 0.0
    let mut sum_up = 0.0
    for j in 0..<n {
      let value = input[j * blocks + block].to_double()
      if value != 0.0 {
        let angle = (2 * j + 1).to_double()
        sum_down += @math.cos(angle * down) * value
        sum_up += @math.cos(angle * up) * value
      }
    }
    output[i] = Float::from_double(sum_down * (-1.0 / 32768.0))
    output[i + half] = Float::from_double(sum_up * (1.0 / 32768.0))
  }
  output
}

///|
fn opus_celt_overlap(buffer : Array[Float], offset : Int32) -> Unit {
  for i in 0..<60 {
    let j = 59 - i
    let a = buffer[offset + i]
    let b = buffer[offset + 60 + j]
    let wi = opus_celt_window_padded[8 + i]
    let wj = opus_celt_window_padded[8 + 60 + j]
    buffer[offset + i] = a * wj - b * wi
    buffer[offset + 60 + j] = a * wi + b * wj
  }
}

///|
fn opus_celt_filter_transition(state : CeltSynthesisChannel, offset : Int32) -> Unit {
  if state.gains[0] == 0.0 && state.old_gains[0] == 0.0 { return }
  let data = state.buffer
  let t0 = state.old_period
  let t1 = state.period
  let g00 = state.old_gains[0]
  let g01 = state.old_gains[1]
  let g02 = state.old_gains[2]
  let g10 = state.gains[0]
  let g11 = state.gains[1]
  let g12 = state.gains[2]
  let mut x1 = data[offset - t1 + 1]
  let mut x2 = data[offset - t1]
  let mut x3 = data[offset - t1 - 1]
  let mut x4 = data[offset - t1 - 2]
  for i in 0..<120 {
    let w = opus_celt_window2[i]
    let x0 = data[offset + i - t1 + 2]
    // C's 1.0 literal promotes the entire transition sum to double.
    let old = 1.0 - w.to_double()
    let correction = old * g00.to_double() * data[offset + i - t0].to_double() +
      old * g01.to_double() * (data[offset + i - t0 - 1] + data[offset + i - t0 + 1]).to_double() +
      old * g02.to_double() * (data[offset + i - t0 - 2] + data[offset + i - t0 + 2]).to_double() +
      (w * g10 * x2).to_double() + (w * g11 * (x1 + x3)).to_double() +
      (w * g12 * (x0 + x4)).to_double()
    data[offset + i] = Float::from_double(data[offset + i].to_double() + correction)
    x4 = x3; x3 = x2; x2 = x1; x1 = x0
  }
}

///|
fn opus_celt_filter_stationary(state : CeltSynthesisChannel, offset : Int32, length : Int32) -> Unit {
  let data = state.buffer
  let period = state.period
  let mut x4 = data[offset - period - 2]
  let mut x3 = data[offset - period - 1]
  let mut x2 = data[offset - period]
  let mut x1 = data[offset - period + 1]
  for i in 0..<length {
    let x0 = data[offset + i - period + 2]
    data[offset + i] += state.gains[0] * x2 + state.gains[1] * (x1 + x3) + state.gains[2] * (x0 + x4)
    x4 = x3; x3 = x2; x2 = x1; x1 = x0
  }
}

///|
fn opus_celt_synthesize(state : CeltSynthesisChannel, frame : OpusCeltCoefficients, channel : Int32) -> Array[Float] {
  let coeff = frame.coefficients[channel]
  let length = coeff.length()
  let blocksize = length / frame.blocks
  for block in 0..<frame.blocks {
    let offset = 1024 + block * blocksize
    let transformed = opus_celt_imdct(coeff, block, frame.blocks)
    for i, value in transformed { state.buffer[offset + 60 + i] = value }
    opus_celt_overlap(state.buffer, offset)
  }
  opus_celt_filter_transition(state, 1024)
  state.old_period = state.period
  state.old_gains = state.gains
  state.period = frame.postfilter_period
  state.gains = frame.postfilter_gains.copy()
  if length > 120 {
    opus_celt_filter_transition(state, 1144)
    if state.gains[0] > 0.00000011920928955078125 && length > 240 {
      opus_celt_filter_stationary(state, 1264, length - 240)
    }
    state.old_period = state.period
    state.old_gains = state.gains
  }
  for i in 0..<1084 { state.buffer[i] = state.buffer[i + length] }
  let output : Array[Float] = Array::make(length, 0.0)
  let weight : Float = 0.8500061035
  for i in 0..<length {
    state.emphasis = state.buffer[1024 - length + i] + state.emphasis * weight
    output[i] = state.emphasis
  }
  let magnitude = state.emphasis.to_double().abs()
  if magnitude < 1.1754943508222875e-38 || magnitude >= 3.402823669209385e38 || magnitude != magnitude {
    state.emphasis = 0.0
  }
  output
}
