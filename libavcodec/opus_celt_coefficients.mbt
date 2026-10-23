///|
/// CELT spectral completion and energy history from FFmpeg 9.0.2
/// opus/dec_celt.c. Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla
/// Corporation, 2016 Rostislav Pehlivanov. LGPL-2.1-or-later.
/// This layer ends before inverse MDCT/overlap-add and audio synthesis.
pub struct OpusCeltHistory {
  /// Last finalized energy, two channel-major 21-band rows.
  energy : Array[Float]
  /// Recent then older energy, each containing two channel-major rows.
  previous : Array[Float]
  seed : UInt32
}

///|
/// FFmpeg CELT flush state. A separate history belongs to each logical stream.
pub fn OpusCeltHistory::new() -> OpusCeltHistory {
  { energy: Array::make(42, 0.0), previous: Array::make(84, -28.0), seed: 0U }
}

///|
/// Final energy-scaled spectrum and next-frame history, without PCM synthesis.
pub struct OpusCeltCoefficients {
  start_band : Int32
  coefficients : Array[Array[Float]]
  collapse_masks : Array[Array[UInt32]]
  history : OpusCeltHistory
  silence : Bool
  transient : Bool
  blocks : Int32
  anticollapse : Bool
  postfilter_period : Int32
  postfilter_gains : Array[Float]
}

///|
// First 21 active entries of ff_celt_mean_energy (all exact binary fractions).
let opus_celt_mean_energy : FixedArray[Float] = [
  6.4375,6.25,5.75,5.3125,5.0625,4.8125,4.5,4.375,4.875,4.6875,
  4.5625,4.4375,4.875,4.625,4.3125,4.5,4.375,4.625,4.75,4.4375,3.75,
]

///|
fn opus_celt_exp2(value : Float) -> Float { Float::from_double(@math.pow(2.0, value.to_double())) }

///|
fn opus_celt_final_energy(rc : OpusRangeDecoder, setup : OpusCeltSetup) -> Unit raise CeltSpectrumError {
  let mut left = setup.framebits - rc.tell()
  for priority in 0..<2 {
    let mut band = setup.start_band
    while band < setup.end_band && left >= setup.channels {
      let bits = setup.allocation.fine_bits[band]
      if setup.allocation.fine_priority[band] == priority && bits < 8 {
        for channel in 0..<setup.channels {
          let raw = opus_celt_result(rc.get_raw(1))
          let offset : Float = (Float::from_uint(raw) - 0.5) * Float::from_int(1 << (14 - bits - 1)) / 16384.0
          setup.energy[channel * 21 + band] += offset
          left -= 1
        }
      }
      band += 1
    }
  }
}

///|
fn opus_celt_anticollapse(
  ctx : CeltBandContext, setup : OpusCeltSetup, spectrum : OpusCeltSpectrum, history : OpusCeltHistory,
) -> Unit {
  for channel in 0..<setup.channels {
    for band in setup.start_band..<setup.end_band {
      let width = opus_celt_freq_range[band]
      let n = width << setup.size
      let depth = (1 + setup.allocation.pvq_bits[band]) / n
      let product : Float = 0.125 * Float::from_int(depth)
      let threshold = opus_celt_exp2(Float::from_double(-1.0 - product.to_double()))
      let reciprocal : Float = 1.0 / Float::from_int(n).sqrt()
      let offset = opus_celt_freq_bands[band] << setup.size
      let x : CeltVector = { data: spectrum.coefficients[channel], offset }
      let mut prev0 = history.previous[channel * 21 + band]
      let mut prev1 = history.previous[42 + channel * 21 + band]
      if setup.channels == 1 {
        prev0 = prev0.max(history.previous[21 + band])
        prev1 = prev1.max(history.previous[63 + band])
      }
      let difference = (setup.energy[channel * 21 + band] - prev0.min(prev1)).max(0.0)
      let mut r = opus_celt_exp2(1.0 - difference)
      if setup.size == 3 { r = Float::from_double(r.to_double() * 1.41421356237309504880) }
      r = threshold.min(r) * reciprocal
      let mut renormalize = false
      for block in 0..<(1 << setup.size) {
        if (spectrum.collapse_masks[channel][band] & (1U << block)) == 0U {
          for j in 0..<width { x[(j << setup.size) + block] = if (ctx.rng() & 0x8000U) != 0U { r } else { -r } }
          renormalize = true
        }
      }
      if renormalize { opus_celt_renormalize(x, n, 1.0) }
    }
  }
}

///|
fn opus_celt_finish_coefficients(
  rc : OpusRangeDecoder, setup : OpusCeltSetup, spectrum : OpusCeltSpectrum,
  history : OpusCeltHistory, apply_phase_inv : Bool,
) -> OpusCeltCoefficients raise CeltSpectrumError {
  let anticollapse = if setup.allocation.anticollapse_bits != 0 { opus_celt_result(rc.get_raw(1)) != 0U } else { false }
  opus_celt_final_energy(rc, setup)
  if anticollapse {
    let ctx : CeltBandContext = { setup, seed: spectrum.seed, apply_phase_inv, remaining: 0, remaining2: 0 }
    opus_celt_anticollapse(ctx, setup, spectrum, history)
  }
  for channel in 0..<setup.channels {
    for band in setup.start_band..<setup.end_band {
      let offset = opus_celt_freq_bands[band] << setup.size
      let log_norm = setup.energy[channel * 21 + band] + opus_celt_mean_energy[band]
      let norm = opus_celt_exp2(log_norm.min(32.0))
      for j in 0..<(opus_celt_freq_range[band] << setup.size) {
        spectrum.coefficients[channel][offset + j] *= norm
      }
    }
  }
  if setup.silence {
    for i in 0..<42 { setup.energy[i] = -28.0 }
    for channel in spectrum.coefficients { for i in 0..<channel.length() { channel[i] = 0.0 } }
  }
  if setup.channels == 1 { for band in 0..<21 { setup.energy[21 + band] = setup.energy[band] } }
  let previous = history.previous.copy()
  for channel in 0..<2 {
    for band in 0..<21 {
      let index = channel * 21 + band
      if !setup.transient {
        previous[42 + index] = previous[index]
        previous[index] = setup.energy[index]
      } else { previous[index] = previous[index].min(setup.energy[index]) }
      if band < setup.start_band || band >= setup.end_band { previous[index] = -28.0; setup.energy[index] = 0.0 }
    }
  }
  let next : OpusCeltHistory = { energy: setup.energy, previous, seed: rc.range }
  { coefficients: spectrum.coefficients, collapse_masks: spectrum.collapse_masks, history: next,
    silence: setup.silence, transient: setup.transient, blocks: setup.blocks, anticollapse,
    start_band: setup.start_band,
    postfilter_period: setup.postfilter_period, postfilter_gains: setup.postfilter_gains }
}

///|
/// Decode a complete CELT frequency-domain frame and return its next energy
/// history. Includes setup, recursive bands/stereo/folding, final energy,
/// anti-collapse, energy scaling and silence/history updates. Input history
/// is never modified, including on error. Commit the returned history only
/// after accepting the frame. SILK, IMDCT/overlap-add, postfilter application
/// and deemphasis are not performed here; coefficients are not PCM samples.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\xff\xfe").unwrap()
///   let history = @libavcodec.OpusCeltHistory::new()
///   let frame = rc.decode_celt_coefficients(history, 1, 120, 0, 13).unwrap()
///   assert_eq(frame.silence, true)
///   for sample in frame.coefficients[0] { assert_eq(sample, 0.0) }
///   assert_eq(history.energy[0], 0.0)
/// }
/// ```
pub fn OpusRangeDecoder::decode_celt_coefficients(
  self : OpusRangeDecoder, history : OpusCeltHistory, channels : Int32,
  frame_size : Int32, start : Int32, end : Int32, apply_phase_inv? : Bool = true,
) -> Result[OpusCeltCoefficients, String] {
  if history.energy.length() != 42 || history.previous.length() != 84 { return Err("opus: invalid CELT spectral history") }
  for row in [history.energy, history.previous] {
    for value in row { if value.is_nan() || value.is_inf() { return Err("opus: nonfinite CELT spectral history") } }
  }
  let setup = match self.decode_celt_setup(channels, frame_size, start, end, previous_energy=history.energy) { Ok(v) => v; Err(e) => return Err(e) }
  let spectrum = match self.decode_celt_spectrum(setup, seed=history.seed, apply_phase_inv~) { Ok(v) => v; Err(e) => return Err(e) }
  try opus_celt_finish_coefficients(self, setup, spectrum, history, apply_phase_inv) catch {
    SpectrumError(error) => Err(error)
  } noraise { coefficients => Ok(coefficients) }
}
