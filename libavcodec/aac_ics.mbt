///|
/// MoonBit port of the AAC (MPEG-4 Audio / AAC-LC) individual channel
/// stream parsing from FFmpeg 9.0.2 `libavcodec/aac/aacdec.c`:
/// `decode_ics_info`, `decode_band_types` (section data),
/// `ff_aac_decode_tns` and the pulse / gain-control syntax of
/// ISO/IEC 14496-3 §4.6.2.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: AAC-LC ICS syntax, pulse, TNS and gain control. Spectral
/// Huffman decoding and pulse reconstruction live in aac_spectrum.mbt.

///| Window sequences (spec 4.6.2.2): 0 ONLY_LONG, 1 LONG_START,

///|
/// 2 EIGHT_SHORT, 3 LONG_STOP. */
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
  /// `window_shape`: 0 sine, 1 KBD.
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
/// Pulse syntax (FFmpeg `Pulse`). Keep the encoded band and offset deltas
/// until the decoder supplies the sampling-rate-specific SWB
/// table; this lets the ICS syntax parser stay independent of that table.
pub struct AacPulse {
  start_sfb : Int32
  offsets : Array[Int32]
  amp : Array[Int32]
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
  pulse : AacPulse
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
/// bands. `sect_cb` 12 is reserved (`RESERVED_BT`) and rejected like the C.
fn aac_decode_section_data(
  gb : BitReader,
  info : AacIcsInfo,
) -> Result[Array[Array[Int32]], String] {
  let sect_cb : Array[Array[Int32]] = []
  // The section-length escape width depends on the window sequence.
  let bits = if info.window_sequence == aac_eight_short { 3 } else { 5 }
  let escape = (1 << bits) - 1
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let cbs : Array[Int32] = Array::make(info.max_sfb, -1)
    let mut end = 0
    while end < info.max_sfb {
      let cb = gb.read(4).reinterpret_as_int()
      if cb == 12 {
        return Err("invalid band type")
      }
      let mut sect_len = 0
      let mut incr = escape
      while incr == escape {
        incr = gb.read(bits).reinterpret_as_int()
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
/// Scalefactors are decoded by `aac_decode_scalefactors`
/// (`aac_spectrum.mbt`); this keeps `decode_ics` self-contained.

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
/// order of spec 4.6.2.1. Spectral data (codebooks 1..11) follows and is
/// decoded separately. Pulse positions are validated against the SWB
/// table by the frame decoder before it reads spectral data.
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
  let scale_factors = match
    aac_decode_scalefactors(gb, info, sect_cb, global_gain) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let pulse_present = gb.read1().reinterpret_as_int()
  let pulse = if pulse_present != 0 {
    if info.window_sequence == aac_eight_short {
      return Err("pulse data is not allowed in short windows")
    }
    if gb.bits_left() < 8 {
      return Err("truncated pulse data")
    }
    let n = gb.read(2).reinterpret_as_int() + 1
    let start_sfb = gb.read(6).reinterpret_as_int()
    if gb.bits_left() < 9 * n {
      return Err("truncated pulse data")
    }
    let offsets : Array[Int32] = []
    let amp : Array[Int32] = []
    for _i = 0; _i < n; _i = _i + 1 {
      offsets.push(gb.read(5).reinterpret_as_int())
      amp.push(gb.read(4).reinterpret_as_int())
    }
    { start_sfb, offsets, amp, }
  } else {
    { start_sfb: 0, offsets: [], amp: [], }
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
    // `decode_gain_control` parses and discards the tool (the C carries
    // the same FIXME); only the syntax must be consumed.
    let gain_mode_wd = [[1, 0, 5], [2, 1, 2], [8, 0, 2], [2, 1, 5]]
    let mode = info.window_sequence
    let max_band = gb.read(2).reinterpret_as_int()
    for _bd = 0; _bd < max_band; _bd = _bd + 1 {
      for wd = 0; wd < gain_mode_wd[mode][0]; wd = wd + 1 {
        let adjust_num = gb.read(3).reinterpret_as_int()
        for _ad = 0; _ad < adjust_num; _ad = _ad + 1 {
          let bits = 4 +
            (if wd == 0 && gain_mode_wd[mode][1] != 0 {
              4
            } else {
              gain_mode_wd[mode][2]
            })
          gb.skip(bits)
        }
      }
    }
  }
  Ok({
    info,
    global_gain,
    sect_cb,
    scale_factors,
    pulse_present,
    pulse,
    tns_present,
    tns,
    gain_control_present,
  })
}
