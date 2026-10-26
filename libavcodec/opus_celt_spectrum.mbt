///|
/// CELT normalized spectrum and time-block collapse masks, ported from
/// FFmpeg 9.0.2 opus/celt.c (ff_celt_quant_bands, decoder path).
/// Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla Corporation.
/// LGPL-2.1-or-later. Final energy, anti-collapse, denormalization and
/// synthesis are separate stages.
pub struct OpusCeltSpectrum {
  coefficients : Array[Array[Float]]
  collapse_masks : Array[Array[UInt32]]
  /// Updated folding/noise LCG; carried into anti-collapse.
  seed : UInt32
}

///|
fn opus_celt_quant_bands(
  rc : OpusRangeDecoder,
  setup : OpusCeltSetup,
  seed : UInt32,
  apply_phase_inv : Bool,
) -> OpusCeltSpectrum raise CeltSpectrumError {
  let ctx : CeltBandContext = {
    setup,
    seed,
    apply_phase_inv,
    remaining: setup.allocation.remaining,
    remaining2: 0,
  }
  let coefficients : Array[Array[Float]] = [
    for _ in 0..<setup.channels => Array::make(120 << setup.size, 0.0)
  ]
  let masks : Array[Array[UInt32]] = [
    for _ in 0..<setup.channels => Array::make(21, 0U)
  ]
  let norms : Array[Array[Float]] = [
    for _ in 0..<setup.channels => Array::make(800, 0.0)
  ]
  let totalbits = (setup.framebits << 3) - setup.allocation.anticollapse_bits
  let mut update_lowband = true
  let mut lowband_offset = 0
  let mut dual = setup.allocation.dual_stereo
  for band in setup.start_band..<setup.end_band {
    let collapse = Array::make(2, (1 << setup.blocks) - 1)
    let offset = opus_celt_freq_bands[band] << setup.size
    let n = opus_celt_freq_range[band] << setup.size
    let x : CeltVector = { data: coefficients[0], offset, }
    let y : CeltVector? = if setup.channels == 2 {
      Some({ data: coefficients[1], offset, })
    } else {
      None
    }
    let consumed = rc.tell_frac()
    let mut effective_lowband = -1
    let mut bits = 0
    if band != setup.start_band {
      ctx.remaining -= consumed
    }
    ctx.remaining2 = totalbits - consumed - 1
    if band < setup.allocation.coded_bands {
      let balance = ctx.remaining / (setup.allocation.coded_bands - band).min(3)
      bits = (ctx.remaining2 + 1)
        .min(setup.allocation.pvq_bits[band] + balance)
        .max(0)
        .min(16383)
    }
    if (
        opus_celt_freq_bands[band] - opus_celt_freq_range[band] >=
        opus_celt_freq_bands[setup.start_band] ||
        band == setup.start_band + 1
      ) &&
      (update_lowband || lowband_offset == 0) {
      lowband_offset = band
    }
    if band == setup.start_band + 1 {
      let count = (opus_celt_freq_range[band] - opus_celt_freq_range[band - 1]) <<
        setup.size
      for norm in norms {
        for i in 0..<count {
          norm[offset + i] = norm[offset - count + i]
        }
      }
    }
    if lowband_offset != 0 &&
      (
        setup.allocation.spread != 3 ||
        setup.blocks > 1 ||
        setup.tf_change[band] < 0
      ) {
      effective_lowband = opus_celt_freq_bands[setup.start_band].max(
        opus_celt_freq_bands[lowband_offset] - opus_celt_freq_range[band],
      )
      let mut fold_start = lowband_offset - 1
      while opus_celt_freq_bands[fold_start] > effective_lowband {
        fold_start -= 1
      }
      let mut fold_end = lowband_offset
      while fold_end < band &&
            opus_celt_freq_bands[fold_end] <
            effective_lowband + opus_celt_freq_range[band] {
        fold_end += 1
      }
      collapse[0] = 0
      collapse[1] = 0
      for j in fold_start..<fold_end {
        collapse[0] = collapse[0] | masks[0][j].reinterpret_as_int()
        collapse[1] = collapse[1] |
          masks[setup.channels - 1][j].reinterpret_as_int()
      }
    }
    if dual && band == setup.allocation.intensity_stereo {
      dual = false
      for j in (opus_celt_freq_bands[setup.start_band] << setup.size)..<offset {
        norms[0][j] = (norms[0][j] + norms[1][j]) / 2.0
      }
    }
    let low0 : CeltVector? = if effective_lowband < 0 {
      None
    } else {
      Some({ data: norms[0], offset: effective_lowband << setup.size, })
    }
    let low1 : CeltVector? = if effective_lowband < 0 {
      None
    } else {
      Some({
        data: norms[setup.channels - 1],
        offset: effective_lowband << setup.size,
      })
    }
    let output0 : CeltVector = { data: norms[0], offset, }
    if dual {
      masks[0][band] = opus_celt_band(
          ctx,
          rc,
          band,
          x,
          None,
          n,
          bits >> 1,
          setup.blocks,
          low0,
          setup.size,
          Some(output0),
          0,
          1.0,
          collapse[0],
        ) &
        255U
      let y = match y {
        Some(y) => y
        None => raise SpectrumError("opus: invalid CELT dual stereo")
      }
      let output1 : CeltVector = { data: norms[1], offset, }
      masks[1][band] = opus_celt_band(
          ctx,
          rc,
          band,
          y,
          None,
          n,
          bits >> 1,
          setup.blocks,
          low1,
          setup.size,
          Some(output1),
          0,
          1.0,
          collapse[1],
        ) &
        255U
    } else {
      let mask = opus_celt_band(
          ctx,
          rc,
          band,
          x,
          y,
          n,
          bits,
          setup.blocks,
          low0,
          setup.size,
          Some(output0),
          0,
          1.0,
          collapse[0] | collapse[1],
        ) &
        255U
      masks[0][band] = mask
      masks[setup.channels - 1][band] = mask
    }
    ctx.remaining += setup.allocation.pvq_bits[band] + consumed
    update_lowband = bits > n << 3
  }
  { coefficients, collapse_masks: masks, seed: ctx.seed, }
}

///|
/// Decode all normalized CELT bands after `decode_celt_setup` on the same
/// range decoder. Supports recursive splitting, TF transforms, spectral
/// folding/noise, dual/intensity stereo and optional phase inversion.
/// Coefficients remain normalized until final energy and denormalization.
/// `seed` is the previous frame's range-derived noise seed (zero after flush).
/// Invalid setup parameters fail before entropy consumption. Other failures
/// consume this frame's entropy; discard its range decoder and retry fresh.
///
/// ```mbt check
/// test {
///   let rc = @libavcodec.opus_rc_init(b"\xff\xfe").unwrap()
///   let setup = rc.decode_celt_setup(1, 120, 0, 13).unwrap()
///   let spectrum = rc.decode_celt_spectrum(setup).unwrap()
///   assert_eq(spectrum.coefficients[0].length(), 120)
/// }
/// ```
pub fn OpusRangeDecoder::decode_celt_spectrum(
  self : OpusRangeDecoder,
  setup : OpusCeltSetup,
  seed~ : UInt32 = 0U,
  apply_phase_inv~ : Bool = true,
) -> Result[OpusCeltSpectrum, String] {
  if opus_celt_validate(
      self,
      setup.channels,
      setup.size,
      setup.start_band,
      setup.end_band,
      setup.framebits,
    )
    is Some(error) {
    return Err(error)
  }
  if setup.framebits != self.data.length() * 8 ||
    setup.blocks != (if setup.transient { 1 << setup.size } else { 1 }) {
    return Err("opus: invalid CELT spectrum setup")
  }
  if setup.tf_change.length() != 21 || setup.allocation.pvq_bits.length() != 21 {
    return Err("opus: invalid CELT spectrum band arrays")
  }
  let alloc = setup.allocation
  if alloc.spread < 0 ||
    alloc.spread > 3 ||
    alloc.coded_bands <= setup.start_band ||
    alloc.coded_bands > setup.end_band ||
    alloc.intensity_stereo < 0 ||
    alloc.intensity_stereo > alloc.coded_bands ||
    (alloc.dual_stereo && setup.channels != 2) ||
    alloc.remaining < 0 ||
    alloc.remaining > setup.framebits << 3 ||
    !(alloc.anticollapse_bits == 0 || alloc.anticollapse_bits == 8) {
    return Err("opus: invalid CELT spectrum allocation")
  }
  for i in setup.start_band..<setup.end_band {
    let tf = setup.tf_change[i]
    let table = (setup.size * 2 + (if setup.transient { 1 } else { 0 })) * 4
    let mut legal_tf = false
    for j in 0..<4 {
      legal_tf = legal_tf || tf == opus_celt_tf_select[table + j]
    }
    // Silence advances tell to framebits; C's one eighth-bit safety margin
    // can leave -1 in a band budget even though the canonical frame is valid.
    let minimum = if setup.silence { -1 } else { 0 }
    if !legal_tf ||
      (tf > 0 && setup.blocks >> tf == 0) ||
      alloc.pvq_bits[i] < minimum ||
      alloc.pvq_bits[i] > 16383 {
      return Err("opus: invalid CELT spectrum band parameters")
    }
  }
  try opus_celt_quant_bands(self, setup, seed, apply_phase_inv) catch {
    SpectrumError(error) => Err(error)
  } noraise {
    spectrum => Ok(spectrum)
  }
}
