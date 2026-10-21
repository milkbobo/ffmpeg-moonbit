///|
/// AAC-LC channel pairs from FFmpeg 9.0.2 libavcodec/aac/aacdec.c
/// (`decode_cpe`, `decode_mid_side_stereo`) and aacdec_dsp_template.c
/// (`apply_mid_side_stereo`, `apply_intensity_stereo`).
/// Copyright (c) 2005-2006 Oded Shimon
/// Copyright (c) 2006-2007 Maxim Gavrilov
/// Copyright (c) 2008-2013 Alex Converse <alex.converse@gmail.com>
/// Original FFmpeg code is LGPL-2.1-or-later.
///
/// Spectrum storage and channel window history remain separate: a shared
/// ICS describes the current frame only. Double arithmetic replaces the
/// C float DSP operations, as in the mono spectral path.
priv struct AacDecodedSpectrum {
  ics : AacIcs
  sf : Array[Array[Double]]
  coeffs : Array[Double]
}

///|
priv struct AacChannelPair {
  left : AacDecodedSpectrum
  right : AacDecodedSpectrum
  common_window : Bool
  ms_present : Int32
  ms_mask : Array[Array[Bool]]
}

///|
fn aac_validate_ics_bands(
  info : AacIcsInfo,
  swb : AacSwb,
) -> Result[Unit, String] {
  let limit = if info.window_sequence == aac_eight_short {
    swb.num_short
  } else {
    swb.num_long
  }
  if info.max_sfb > limit {
    return Err("max_sfb exceeds the scalefactor band count")
  }
  Ok(())
}

///|
/// Decode through pulse reconstruction, leaving TNS for after stereo.
fn AacDecoder::decode_spectrum(
  self : AacDecoder,
  gb : BitReader,
  common : AacIcsInfo?,
) -> Result[AacDecodedSpectrum, String] {
  let ics = match aac_decode_ics_with_info(gb, common) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  match aac_validate_ics_bands(ics.info, self.swb) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let positions = match aac_resolve_pulses(ics.pulse, self.swb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let sf = aac_sf_dequant(ics.info, ics.sect_cb, ics.scale_factors)
  let coeffs = Array::make(1024, 0.0)
  match
    aac_decode_spectrum(
      gb,
      ics.info,
      self.swb,
      ics.sect_cb,
      sf,
      self.noise,
      coeffs,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if gb.bits_left() < 0 {
    return Err("truncated spectral data")
  }
  aac_apply_pulses(coeffs, ics.pulse, positions, self.swb, ics.sect_cb, sf)
  Ok({ ics, sf, coeffs, })
}

///|
fn aac_decode_ms_mask(
  gb : BitReader,
  info : AacIcsInfo,
  ms_present : Int32,
) -> Result[Array[Array[Bool]], String] {
  if ms_present == 3 {
    return Err("ms_present = 3 is reserved")
  }
  if ms_present == 1 && gb.bits_left() < info.num_window_groups * info.max_sfb {
    return Err("truncated mid-side mask")
  }
  let mask : Array[Array[Bool]] = []
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let row = Array::make(info.max_sfb, false)
    for band = 0; band < info.max_sfb; band = band + 1 {
      row[band] = ms_present == 2 || (ms_present == 1 && gb.read1() != 0)
    }
    mask.push(row)
  }
  Ok(mask)
}

///|
fn AacDecoder::decode_pair(
  self : AacDecoder,
  gb : BitReader,
) -> Result[AacChannelPair, String] {
  if gb.bits_left() < 1 {
    return Err("missing CPE common_window")
  }
  let common_window = gb.read1() != 0
  let mut common : AacIcsInfo? = None
  let mut ms_present = 0
  let mut ms_mask : Array[Array[Bool]] = []
  if common_window {
    let info = match aac_decode_ics_info(gb) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    match aac_validate_ics_bands(info, self.swb) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if gb.bits_left() < 2 {
      return Err("missing mid-side mode")
    }
    ms_present = gb.read(2).reinterpret_as_int()
    ms_mask = match aac_decode_ms_mask(gb, info, ms_present) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    common = Some(info)
  }
  let left = match self.decode_spectrum(gb, common) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let right = match self.decode_spectrum(gb, common) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pair = { left, right, common_window, ms_present, ms_mask, }
  aac_apply_stereo(pair, self.swb)
  Ok(pair)
}

///|
/// `apply_mid_side_stereo` then `apply_intensity_stereo`, before TNS.
fn aac_apply_stereo(pair : AacChannelPair, swb : AacSwb) -> Unit {
  let left = pair.left
  let right = pair.right
  if pair.common_window && pair.ms_present != 0 {
    let info = left.ics.info
    let offsets = if info.window_sequence == aac_eight_short {
      swb.offsets_short
    } else {
      swb.offsets_long
    }
    let mut base = 0
    for g = 0; g < info.num_window_groups; g = g + 1 {
      for band = 0; band < info.max_sfb; band = band + 1 {
        if pair.ms_mask[g][band] &&
          left.ics.sect_cb[g][band] < 13 &&
          right.ics.sect_cb[g][band] < 13 {
          for w = 0; w < info.window_group_length[g]; w = w + 1 {
            for k = offsets[band].reinterpret_as_int()
                k < offsets[band + 1].reinterpret_as_int()
                k = k + 1 {
              let i = base + w * 128 + k
              let mid = left.coeffs[i]
              let side = right.coeffs[i]
              left.coeffs[i] = mid + side
              right.coeffs[i] = mid - side
            }
          }
        }
      }
      base = base + info.window_group_length[g] * 128
    }
  }
  let info = right.ics.info
  let offsets = if info.window_sequence == aac_eight_short {
    swb.offsets_short
  } else {
    swb.offsets_long
  }
  let mut base = 0
  for g = 0; g < info.num_window_groups; g = g + 1 {
    for band = 0; band < info.max_sfb; band = band + 1 {
      let cb = right.ics.sect_cb[g][band]
      if cb == 14 || cb == 15 {
        let mut sign = if cb == 14 { -1.0 } else { 1.0 }
        if pair.ms_present != 0 && pair.ms_mask[g][band] {
          sign = -sign
        }
        let scale = sign * right.sf[g][band]
        for w = 0; w < info.window_group_length[g]; w = w + 1 {
          for k = offsets[band].reinterpret_as_int()
              k < offsets[band + 1].reinterpret_as_int()
              k = k + 1 {
            let i = base + w * 128 + k
            right.coeffs[i] = left.coeffs[i] * scale
          }
        }
      }
    }
    base = base + info.window_group_length[g] * 128
  }
}
