///|
/// MoonBit port of the AAC (MPEG-4 Audio / AAC-LC) individual channel
/// stream parsing from FFmpeg 9.0.2 `libavcodec/aac/aacdec.c`:
/// `decode_ics_info`, `decode_band_types` (section data),
/// `ff_aac_decode_tns` and the pulse / gain-control syntax of
/// ISO/IEC 14496-3 §4.6.2.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: the ICS syntax layer plus TNS. Spectral Huffman codebooks 1..11
/// (`aacdec.c: decode_spectrum_and_dequant`) are not ported yet: sections
/// using them are rejected explicitly. Scalefactor bands with codebook 0
/// carry no data, so an all-codebook-0 SCE frame decodes end to end.

///| Window sequences (spec 4.6.2.2): 0 ONLY_LONG, 1 LONG_START,

///|
/// 2 EIGHT_SHORT, 3 LONG_STOP. Long-start/stop windowing is pending. */
let aac_only_long : Int32 = 0

///|
let aac_eight_short : Int32 = 2

///|
/// `ics_info()` fields (spec 4.6.2.2 / FFmpeg `IndividualChannelStream`). */
pub struct AacIcsInfo {
  /// `max_sfb`: highest scalefactor band with data.
  max_sfb : Int32
  /// `window_sequence` (0..3, see the `aac_*` constants).
  window_sequence : Int32
  /// `window_shape`: 0 sine, 1 KBD (KBD windows not ported yet).
  window_shape : Int32
  /// `scale_factor_grouping` (only for EIGHT_SHORT).
  scale_factor_grouping : Int32
  /// `predictor_data_present` (must be 0 for AAC-LC).
  predictor_data_present : Int32
  /// Number of windows in the sequence (8 for EIGHT_SHORT, else 1).
  num_windows : Int32
  /// Number of window groups after `scale_factor_grouping`.
  num_window_groups : Int32
  /// Windows per group (`window_group_length[g]`).
  window_group_length : Array[Int32]
}

///|
/// One TNS filter of one window (spec 4.6.2.5 / FFmpeg `TemporalNoiseShaping`). */
pub struct AacTnsFilter {
  length : Int32
  order : Int32
  direction : Int32
  /// Quantised LPC coefficients (`ff_tns_tmp2_map` lookup applied).
  coef : Array[Double]
}

///|
/// TNS data of one ICS: filters per window (at most 8 windows). */
pub struct AacTns {
  /// `n_filt[w]`; 0 entries mean no filtering for that window.
  n_filt : Array[Int32]
  filters : Array[Array[AacTnsFilter]]
}

///|
/// A parsed `individual_channel_stream` (common window not covered). */
pub struct AacIcs {
  info : AacIcsInfo
  global_gain : Int32
  /// Section codebook per (group, sfb): -1 where not covered.
  sect_cb : Array[Array[Int32]]
  /// `scale_factors[g][sfb]` (raw, before `pow(4/3)`).
  scale_factors : Array[Array[Int32]]
  pulse_present : Int32
  tns_present : Int32
  tns : AacTns
  gain_control_present : Int32
}

///|
/// `ff_tns_tmp2_map_1_3[4]` (`aactab.c`). */
let aac_tns_tmp2_1_3 : Array[Double] = [
  0.00000000, -0.43388373, 0.64278758, 0.34202015,
]

///|
/// `ff_tns_tmp2_map_0_3[8]`. */
let aac_tns_tmp2_0_3 : Array[Double] = [
  0.00000000, -0.43388373, -0.78183150, -0.97492790, 0.98480773, 0.86602539, 0.64278758,
  0.34202015,
]

///|
/// `ff_tns_tmp2_map_1_4[8]`. */
let aac_tns_tmp2_1_4 : Array[Double] = [
  0.00000000, -0.20791170, -0.40673664, -0.58778524, 0.67369562, 0.52643216, 0.36124167,
  0.18374951,
]

///|
/// `ff_tns_tmp2_map_0_4[16]`. */
let aac_tns_tmp2_0_4 : Array[Double] = [
  0.00000000, -0.20791170, -0.40673664, -0.58778524, -0.74314481, -0.86602539, -0.95105654,
  -0.99452192, 0.99573416, 0.96182561, 0.89516330, 0.79801720, 0.67369562, 0.52643216,
  0.36124167, 0.18374951,
]

///|
/// `decode_ics_info` (spec 4.6.2.2).
pub fn aac_decode_ics_info(gb : BitReader) -> Result[AacIcsInfo, String] {
  let ics_reserved = gb.read1().reinterpret_as_int()
  if ics_reserved != 0 {
    return Err("ics_reserved bit set")
  }
  let window_sequence = gb.read(2).reinterpret_as_int()
  if window_sequence > 3 {
    return Err("invalid window_sequence")
  }
  let window_shape = gb.read1().reinterpret_as_int()
  let is8 = window_sequence == aac_eight_short
  let mut scale_factor_grouping = 0
  let num_windows = if is8 { 8 } else { 1 }
  let mut max_sfb = 0
  let mut predictor_data_present = 0
  if is8 {
    max_sfb = gb.read(4).reinterpret_as_int()
    scale_factor_grouping = gb.read(7).reinterpret_as_int()
  } else {
    max_sfb = gb.read(6).reinterpret_as_int()
    predictor_data_present = gb.read1().reinterpret_as_int()
    if predictor_data_present != 0 {
      // AAC-LC has no predictor data; MAIN/LTP are out of scope.
      return Err("predictor data is not supported (AAC MAIN/LTP)")
    }
  }
  if max_sfb > 64 {
    return Err("max_sfb too large")
  }
  // Window grouping (FFmpeg reads 7 bits: 1 keeps the window in the
  // current group, 0 starts a new one).
  let window_group_length : Array[Int32] = []
  if is8 {
    window_group_length.push(1)
    for i = 0; i < 7; i = i + 1 {
      if ((scale_factor_grouping >> (6 - i)) & 1) == 1 {
        window_group_length[window_group_length.length() - 1] = window_group_length[window_group_length.length() -
          1] +
          1
      } else {
        window_group_length.push(1)
      }
    }
  } else {
    window_group_length.push(1)
  }
  Ok({
    max_sfb,
    window_sequence,
    window_shape,
    scale_factor_grouping,
    predictor_data_present,
    num_windows,
    num_window_groups: window_group_length.length(),
    window_group_length,
  })
}

///|
/// `decode_band_types` / section data (spec 4.6.2.3.1): per window group a
/// run-length coded list of (sect_cb, length) pairs covering `max_sfb`
/// bands. Codebooks 1..11 (spectral data) and 12..15 (intensity) are
/// rejected until the spectral Huffman layer is ported.
fn aac_decode_section_data(
  gb : BitReader,
  info : AacIcsInfo,
) -> Result[Array[Array[Int32]], String] {
  let sect_cb : Array[Array[Int32]] = []
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let cbs : Array[Int32] = Array::make(info.max_sfb, -1)
    let mut end = 0
    while end < info.max_sfb {
      let cb = gb.read(4).reinterpret_as_int()
      if cb == 12 || cb == 13 {
        return Err("escaped section codebook")
      }
      let mut sect_len = 0
      let mut incr = 15
      while incr == 15 {
        incr = gb.read(4).reinterpret_as_int()
        sect_len = sect_len + incr
      }
      end = end + sect_len
      if end > info.max_sfb {
        return Err("section too long")
      }
      for k = end - sect_len; k < end; k = k + 1 {
        cbs[k] = cb
      }
    }
    sect_cb.push(cbs)
  }
  Ok(sect_cb)
}

///|
/// `decode_scalefactors` (spec 4.6.2.3.2). Only codebook-0 (silent) bands
/// are supported, which transmit no scalefactor data at all; anything else
/// needs the spectral layer.
fn aac_decode_scale_factors(
  gb : BitReader,
  info : AacIcsInfo,
  sect_cb : Array[Array[Int32]],
) -> Result[Array[Array[Int32]], String] {
  for g = 0; g < info.num_window_groups; g = g + 1 {
    for sfb = 0; sfb < info.max_sfb; sfb = sfb + 1 {
      if sect_cb[g][sfb] != 0 {
        return Err("spectral codebooks 1..11 are not supported yet")
      }
    }
  }
  ignore(gb)
  Ok(Array::make(info.num_window_groups, Array::make(info.max_sfb, 0)))
}

///|
/// `ff_aac_decode_tns` (spec 4.6.2.5): filters per window, coefficients
/// dequantised through `ff_tns_tmp2_map`.
pub fn aac_decode_tns(
  gb : BitReader,
  info : AacIcsInfo,
) -> Result[AacTns, String] {
  let is8 = info.window_sequence == aac_eight_short
  // LC: max order 12 long, 7 short.
  let tns_max_order = if is8 { 7 } else { 12 }
  let n_filt : Array[Int32] = Array::make(info.num_windows, 0)
  let filters : Array[Array[AacTnsFilter]] = []
  for w = 0; w < info.num_windows; w = w + 1 {
    let flist : Array[AacTnsFilter] = []
    let nf = gb.read(2 - (if is8 { 1 } else { 0 })).reinterpret_as_int()
    n_filt[w] = nf
    let mut coef_res = 0
    if nf != 0 {
      coef_res = gb.read1().reinterpret_as_int()
    }
    for _filt = 0; _filt < nf; _filt = _filt + 1 {
      let length = gb
        .read(6 - 2 * (if is8 { 1 } else { 0 }))
        .reinterpret_as_int()
      let order = gb
        .read(5 - 2 * (if is8 { 1 } else { 0 }))
        .reinterpret_as_int()
      if order > tns_max_order {
        return Err("TNS filter order too large")
      }
      let mut direction = 0
      let coef : Array[Double] = []
      if order != 0 {
        direction = gb.read1().reinterpret_as_int()
        let coef_compress = gb.read1().reinterpret_as_int()
        let coef_len = coef_res + 3 - coef_compress
        let table = if coef_compress == 0 && coef_res == 0 {
          aac_tns_tmp2_0_3
        } else if coef_compress == 0 && coef_res == 1 {
          aac_tns_tmp2_0_4
        } else if coef_compress == 1 && coef_res == 0 {
          aac_tns_tmp2_1_3
        } else {
          aac_tns_tmp2_1_4
        }
        for _i = 0; _i < order; _i = _i + 1 {
          let idx = gb.read(coef_len).reinterpret_as_int()
          if idx >= table.length() {
            return Err("TNS coefficient index out of range")
          }
          coef.push(table[idx])
        }
      }
      flist.push({ length, order, direction, coef, })
    }
    filters.push(flist)
  }
  Ok({ n_filt, filters, })
}

///|
/// No-filter TNS placeholder. */
fn aac_tns_none(num_windows : Int32) -> AacTns {
  {
    n_filt: Array::make(num_windows, 0),
    filters: Array::make(
      num_windows,
      Array::make(0, { length: 0, order: 0, direction: 0, coef: [], }),
    ),
  }
}

///|
/// `decode_ics` for an SCE (single channel element): global gain, ICS info,
/// section/scalefactor data, pulse data, TNS data and gain control, in the
/// order of spec 4.6.2.1. Spectral data itself (codebooks 1..11) follows
/// and is not parsed yet.
pub fn aac_decode_ics(gb : BitReader) -> Result[AacIcs, String] {
  let global_gain = gb.read(8).reinterpret_as_int()
  let info = match aac_decode_ics_info(gb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let sect_cb = match aac_decode_section_data(gb, info) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let scale_factors = match aac_decode_scale_factors(gb, info, sect_cb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pulse_present = gb.read1().reinterpret_as_int()
  if pulse_present != 0 {
    return Err("pulse data is not supported")
  }
  let tns_present = gb.read1().reinterpret_as_int()
  let tns = if tns_present != 0 {
    match aac_decode_tns(gb, info) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  } else {
    aac_tns_none(info.num_windows)
  }
  let gain_control_present = gb.read1().reinterpret_as_int()
  if gain_control_present != 0 {
    return Err("gain control is not supported")
  }
  Ok({
    info,
    global_gain,
    sect_cb,
    scale_factors,
    pulse_present,
    tns_present,
    tns,
    gain_control_present,
  })
}

///|
/// The TNS lattice filter application on spectral coefficients
/// (`apply_tns_filt`, spec 4.6.6): an order-`order` all-zero filter over
/// `coef[start:stop]`, applied top-down or bottom-up depending on
/// `direction`. The coefficients are updated in place.
pub fn aac_apply_tns_filter(
  coef : Array[Double],
  start : Int32,
  stop : Int32,
  filter : AacTnsFilter,
) -> Unit {
  if filter.order == 0 || stop - start <= 1 {
    return
  }
  let m = filter.order
  let lpc : Array[Double] = Array::make(m, 0.0)
  for i = 0; i < m; i = i + 1 {
    lpc[i] = if filter.direction != 0 {
      -filter.coef[i]
    } else {
      filter.coef[i]
    }
  }
  let state : Array[Double] = Array::make(m, 0.0)
  if filter.direction == 0 {
    // top-down: j from stop-2 down to start
    for j = stop - 2; j >= start; j = j - 1 {
      let mut acc = coef[j]
      for b = 0; b < m; b = b + 1 {
        acc = acc + lpc[b] * state[b]
      }
      for b = m - 1; b > 0; b = b - 1 {
        state[b] = state[b - 1]
      }
      state[0] = coef[j]
      coef[j] = acc
    }
  } else {
    // bottom-up: j from start+1 up to stop-1
    for j = start + 1; j < stop; j = j + 1 {
      let mut acc = coef[j]
      for b = 0; b < m; b = b + 1 {
        acc = acc + lpc[b] * state[b]
      }
      for b = m - 1; b > 0; b = b - 1 {
        state[b] = state[b - 1]
      }
      state[0] = coef[j]
      coef[j] = acc
    }
  }
}
