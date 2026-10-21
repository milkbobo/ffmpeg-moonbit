///|
/// AAC-LC coupling from FFmpeg 9.0.2 aac/aacdec_proc_template.c
/// (decode_cce), aacdec.c (apply_channel_coupling) and
/// aacdec_float_coupling.h. Copyright (c) 2005-2006 Oded Shimon,
/// 2006-2007 Maxim Gavrilov, 2008-2013 Alex Converse.
/// LGPL-2.1-or-later. Float DSP arithmetic is evaluated in Double.
priv struct AacCouplingTarget {
  kind : Int32
  tag : Int32
  select : Int32
  gain : Int32
}

///|
priv struct AacCoupling {
  tag : Int32
  point : Int32
  targets : Array[AacCouplingTarget]
  gains : Array[Array[Double]]
  spectrum : AacDecodedSpectrum
}

///|
fn AacDecoder::decode_coupling(
  self : AacDecoder,
  gb : BitReader,
  tag : Int32,
) -> Result[AacCoupling, String] {
  if gb.bits_left() < 4 {
    return Err("truncated CCE header")
  }
  let independent = gb.read1() != 0
  let count = gb.read(3).reinterpret_as_int() + 1
  let targets : Array[AacCouplingTarget] = []
  let mut num_gain = 0
  for _i = 0; _i < count; _i = _i + 1 {
    if gb.bits_left() < 5 {
      return Err("truncated CCE target")
    }
    let kind = gb.read1().reinterpret_as_int()
    let id = gb.read(4).reinterpret_as_int()
    let select = if kind == 1 {
      if gb.bits_left() < 2 {
        return Err("truncated CCE channel selection")
      }
      gb.read(2).reinterpret_as_int()
    } else {
      2
    }
    targets.push({ kind, tag: id, select, gain: num_gain, })
    num_gain = num_gain + (if select == 3 { 2 } else { 1 })
  }
  if gb.bits_left() < 4 {
    return Err("truncated CCE gain configuration")
  }
  let after_tns = gb.read1() != 0
  let point = if independent { 3 } else if after_tns { 1 } else { 0 }
  let sign = gb.read1() != 0
  let scale = gb.read(2).reinterpret_as_int()
  let spectrum = match self.decode_spectrum(gb, None) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let info = spectrum.ics.info
  let gains : Array[Array[Double]] = []
  for c = 0; c < num_gain; c = c + 1 {
    let mut common = true
    let mut gain = 0
    let mut cache = 1.0
    if c != 0 {
      if point != 3 {
        if gb.bits_left() < 1 {
          return Err("truncated CCE common gain flag")
        }
        common = gb.read1() != 0
      }
      if common {
        gain = match aac_coupling_gain_delta(gb) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        cache = aac_coupling_gain(scale, gain)
      }
    }
    let values : Array[Double] = []
    if point == 3 {
      values.push(cache)
    } else {
      for g = 0; g < info.num_window_groups; g = g + 1 {
        for band = 0; band < info.max_sfb; band = band + 1 {
          if spectrum.ics.sect_cb[g][band] != 0 {
            if !common {
              let delta = match aac_coupling_gain_delta(gb) {
                Ok(v) => v
                Err(e) => return Err(e)
              }
              if delta != 0 {
                gain = gain + delta
                let exponent = if sign { gain >> 1 } else { gain }
                cache = aac_coupling_gain(scale, exponent) *
                  (if sign && (gain & 1) != 0 { -1.0 } else { 1.0 })
              }
            }
            values.push(cache)
          } else {
            values.push(0.0)
          }
        }
      }
    }
    gains.push(values)
  }
  Ok({ tag, point, targets, gains, spectrum, })
}

///|
fn aac_coupling_gain_delta(gb : BitReader) -> Result[Int32, String] {
  let value = aac_vlc_scalefactors.decode(gb)
  if value < 0 {
    return Err("invalid or truncated CCE gain")
  }
  Ok(value - 60)
}

///|
/// cce_scale = 2^(1/8), 2^(1/4), sqrt(2), 2; GET_GAIN = scale^(-gain).
fn aac_coupling_gain(scale : Int32, gain : Int32) -> Double {
  @math.pow(2.0, (0 - gain).to_double() * (1 << scale).to_double() / 8.0)
}

///|
/// Gain index for a single target channel. ch_select: 0 both/same gain,
/// 1 right, 2 left (or SCE), 3 both/separate gains.
fn aac_coupling_target_gain(target : AacCouplingTarget, key : Int32) -> Int32? {
  if key / 32 != target.kind || key % 32 / 2 != target.tag {
    return None
  }
  let right = (key & 1) != 0
  if (!right && target.select == 1) || (right && target.select == 2) {
    return None
  }
  Some(target.gain + (if right && target.select == 3 { 1 } else { 0 }))
}

///|
fn aac_apply_dependent_coupling(
  dest : Array[Double],
  coupling : AacCoupling,
  gain_index : Int32,
  swb : AacSwb,
) -> Unit {
  let info = coupling.spectrum.ics.info
  let offsets = if info.window_sequence == aac_eight_short {
    swb.offsets_short
  } else {
    swb.offsets_long
  }
  let mut window = 0
  let mut index = 0
  for g = 0; g < info.num_window_groups; g = g + 1 {
    for band = 0; band < info.max_sfb; band = band + 1 {
      if coupling.spectrum.ics.sect_cb[g][band] != 0 {
        let gain = coupling.gains[gain_index][index]
        for w = 0; w < info.window_group_length[g]; w = w + 1 {
          for k = offsets[band].reinterpret_as_int()
              k < offsets[band + 1].reinterpret_as_int()
              k = k + 1 {
            let pos = (window + w) * 128 + k
            dest[pos] = dest[pos] + gain * coupling.spectrum.coeffs[pos]
          }
        }
      }
      index = index + 1
    }
    window = window + info.window_group_length[g]
  }
}

///|
fn aac_apply_spectral_couplings(
  dest : Array[Double],
  key : Int32,
  couplings : Array[AacCoupling],
  point : Int32,
  swb : AacSwb,
) -> Unit {
  for coupling in couplings {
    if coupling.point == point {
      for target in coupling.targets {
        if aac_coupling_target_gain(target, key) is Some(index) {
          aac_apply_dependent_coupling(dest, coupling, index, swb)
        }
      }
    }
  }
}
