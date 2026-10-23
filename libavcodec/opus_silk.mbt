///|
/// MoonBit port of the FFmpeg 9.0.2 SILK decoder, `libavcodec/opus/silk.c`.
/// Copyright (c) 2012 Andrew D'Addesio, 2013-2014 Mozilla Corporation.
/// LGPL-2.1-or-later.
///
/// Covers the LP layer end to end: NLSF decode/stabilize/LPC conversion
/// (including the RFC 8251 stability check), subframe gain decoding, excitation
/// PVQ with LSB expansion and sign modeling, LTP/LPC synthesis, mid-only side
/// channel handling and stereo unmixing. `model_pitch_lowbits_nb/_wb` are
/// `#define` aliases in tab.h for `model_lcg_seed`/`model_gain_lowbits`, so
/// those tables are referenced directly. The C's `redundancy[1]` is read
/// uninitialized for mono streams; this port treats it as zero (the value is
/// never observable for mono).

///|
let silk_history : Int = 322

///|
let silk_max_lag : Int = 288 + 5 / 2

///|
let silk_ltp_order : Int = 5

///|
fn silk_clipf(value : Float, low : Float, high : Float) -> Float {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
fn silk_clip(value : Int, low : Int, high : Int) -> Int {
  if value < low {
    low
  } else if value > high {
    high
  } else {
    value
  }
}

///|
/// `av_clip_uintp2(value, p)`: clip to [0, 2^p - 1].
fn silk_clip_uintp2(value : Int, p : Int) -> Int {
  let limit = (1 << p) - 1
  if value < 0 {
    0
  } else if value > limit {
    limit
  } else {
    value
  }
}

///|
fn silk_sat_sub32(a : Int, b : Int) -> Int {
  let r = a.to_int64() - b.to_int64()
  if r > 2147483647L {
    2147483647
  } else if r < -2147483648L {
    -2147483648
  } else {
    r.to_int()
  }
}

///|
/// `ROUND_MULL(a, b, s) = ((MUL64(a,b) >> (s-1)) + 1) >> 1` on Int64.
fn silk_round_mull64(a : Int64, b : Int64, s : Int) -> Int64 {
  (((a * b) >> (s - 1)) + 1L) >> 1
}

///|
fn silk_round_mull(a : Int, b : Int, s : Int) -> Int {
  silk_round_mull64(a.to_int64(), b.to_int64(), s).to_int()
}

///|
/// C `int16_t` assignment: truncate to 16 bits with wrap-around.
fn wrap_i16(value : Int) -> Int {
  ((value + 32768) & 65535) - 32768
}

///|
/// One SILK frame's (channel's) synthesis state.
priv struct SilkFrame {
  mut coded : Bool
  mut log_gain : Int
  nlsf : FixedArray[Int]
  lpc : FixedArray[Float]
  output : FixedArray[Float]
  lpc_history : FixedArray[Float]
  mut primarylag : Int
  mut prev_voiced : Bool
}

///|
fn SilkFrame::new() -> SilkFrame {
  {
    coded: false,
    log_gain: 0,
    nlsf: FixedArray::make(16, 0),
    lpc: FixedArray::make(16, 0.0),
    output: FixedArray::make(2 * silk_history, 0.0),
    lpc_history: FixedArray::make(2 * silk_history, 0.0),
    primarylag: 0,
    prev_voiced: false,
  }
}

///|
/// The SILK LP-layer decoder, one instance per logical Opus stream.
pub struct OpusSilkDecoder {
  priv output_channels : Int
  priv mut midonly : Int
  priv mut subframes : Int
  priv mut sflength : Int
  priv mut flength : Int
  priv mut nlsf_interp_factor : Int
  priv mut bandwidth : Int
  priv mut wb : Bool
  priv frames : Array[SilkFrame]
  priv prev_stereo_weights : FixedArray[Float]
  priv stereo_weights : FixedArray[Float]
  priv mut prev_coded_channels : Int
}

///|
/// Create a mono or stereo SILK decoder with cleared history.
pub fn OpusSilkDecoder::new(output_channels : Int) -> OpusSilkDecoder {
  let decoder = {
    output_channels,
    midonly: 0,
    subframes: 0,
    sflength: 0,
    flength: 0,
    nlsf_interp_factor: 4,
    bandwidth: 0,
    wb: false,
    frames: [SilkFrame::new(), SilkFrame::new()],
    prev_stereo_weights: FixedArray::make(2, 0.0),
    stereo_weights: FixedArray::make(2, 0.0),
    prev_coded_channels: 0,
  }
  decoder.flush()
  decoder
}

///|
/// Clear the synthesis history (`ff_silk_flush`).
pub fn OpusSilkDecoder::flush(self : OpusSilkDecoder) -> Unit {
  for frame in self.frames {
    silk_flush_frame(frame)
  }
  self.prev_stereo_weights[0] = 0.0
  self.prev_stereo_weights[1] = 0.0
}

///|
fn silk_flush_frame(frame : SilkFrame) -> Unit {
  if !frame.coded {
    return
  }
  frame.output.fill(0.0)
  frame.lpc_history.fill(0.0)
  frame.lpc.fill(0.0)
  frame.nlsf.fill(0)
  frame.log_gain = 0
  frame.primarylag = 0
  frame.prev_voiced = false
  frame.coded = false
}

///|
/// NLSF stabilization (`silk_stabilize_lsf`): iterative minimum-distance
/// repair, then the fall-back sort-and-push method.
fn silk_stabilize_lsf(nlsf : FixedArray[Int], order : Int, min_delta : Array[Int32]) -> Unit {
  for _pass in 0..<20 {
    let mut min_diff = 0
    let mut k = 0
    for i in 0..<=order {
      let low = if i != 0 { nlsf[i - 1] } else { 0 }
      let high = if i != order { nlsf[i] } else { 32768 }
      let diff = high - low - min_delta[i]
      if diff < min_diff {
        min_diff = diff
        k = i
      }
    }
    if min_diff == 0 {
      return
    }
    if k == 0 {
      nlsf[0] = min_delta[0]
    } else if k == order {
      nlsf[order - 1] = 32768 - min_delta[order]
    } else {
      let mut min_center = 0
      let mut max_center = 32768
      for i in 0..<k {
        min_center += min_delta[i]
      }
      min_center += min_delta[k] >> 1
      let mut i = order
      while i > k {
        max_center -= min_delta[i]
        i -= 1
      }
      max_center -= min_delta[k] >> 1
      let mut center_val = nlsf[k - 1] + nlsf[k]
      center_val = (center_val >> 1) + (center_val & 1)
      center_val = silk_clip(center_val, min_center, max_center)
      nlsf[k - 1] = center_val - (min_delta[k] >> 1)
      nlsf[k] = nlsf[k - 1] + min_delta[k]
    }
  }
  // Insertion sort; the LSFs should already be nearly sorted.
  for i in 1..<order {
    let value = nlsf[i]
    let mut j = i - 1
    while j >= 0 && nlsf[j] > value {
      nlsf[j + 1] = nlsf[j]
      j -= 1
    }
    nlsf[j + 1] = value
  }
  if nlsf[0] < min_delta[0] {
    nlsf[0] = min_delta[0]
  }
  for i in 1..<order {
    let bound = silk_clip(nlsf[i - 1] + min_delta[i], -2147483648, 32767)
    if nlsf[i] < bound {
      nlsf[i] = bound
    }
  }
  if nlsf[order - 1] > 32768 - min_delta[order] {
    nlsf[order - 1] = 32768 - min_delta[order]
  }
  let mut i = order - 2
  while i >= 0 {
    if nlsf[i] > nlsf[i + 1] - min_delta[i + 1] {
      nlsf[i] = nlsf[i + 1] - min_delta[i + 1]
    }
    i -= 1
  }
}

///|
/// RFC 8251 section 6 LPC stability check (`silk_is_lpc_stable`). Q24
/// coefficients, Q31 reflection coefficients, exact C integer pipeline.
fn silk_is_lpc_stable(lpc : FixedArray[Int], order : Int) -> Bool {
  let lpc32 : Array[FixedArray[Int]] = [FixedArray::make(16, 0), FixedArray::make(16, 0)]
  let mut totalinvgain = 1 << 30
  let mut row_idx = 0
  let mut dc_resp = 0
  for k in 0..<order {
    dc_resp += lpc[k]
    lpc32[0][k] = lpc[k] * 4096
  }
  if dc_resp >= 4096 {
    return false
  }
  let mut k = order - 1
  for ;; {
    let head = lpc32[row_idx][k]
    let head_abs = if head < 0 { -head } else { head }
    if head_abs > 16773022 {
      return false
    }
    let rc = -(head * 128)
    let gaindiv = (1 << 30) - mulh(rc, rc)
    totalinvgain = mulh(totalinvgain, gaindiv) << 2
    if k == 0 {
      return totalinvgain >= 107374
    }
    let fbits = opus_rc_ilog(gaindiv.reinterpret_as_uint())
    let gain = ((1 << 29) - 1) / (gaindiv >> (fbits + 1 - 16))
    let error = (1 << 29) - mull(gaindiv << (15 + 16 - fbits), gain, 16)
    let gain = (gain << 16) + ((error * gain) >> 13)
    let prev_idx = row_idx
    row_idx = k & 1
    for j in 0..<k {
      let x = silk_sat_sub32(lpc32[prev_idx][j], silk_round_mull(lpc32[prev_idx][k - j - 1], rc, 31))
      let tmp = silk_round_mull64(x.to_int64(), gain.to_int64(), fbits)
      if tmp < -2147483648L || tmp > 2147483647L {
        return false
      }
      lpc32[row_idx][j] = tmp.to_int()
    }
    k -= 1
  }
}

///|
/// `silk_lsp2poly`: LSP to polynomial conversion, Q16.
fn silk_lsp2poly(lsp : FixedArray[Int], offset : Int, pol : FixedArray[Int], half_order : Int) -> Unit {
  pol[0] = 65536
  pol[1] = -lsp[offset]
  for i in 1..<half_order {
    pol[i + 1] = pol[i - 1] * 2 - silk_round_mull(lsp[offset + 2 * i], pol[i], 16)
    let mut j = i
    while j > 1 {
      pol[j] += pol[j - 2] - silk_round_mull(lsp[offset + 2 * i], pol[j - 1], 16)
      j -= 1
    }
    pol[1] -= lsp[offset + 2 * i]
  }
}

///|
/// NLSF (Q15) to LPC (Q12) conversion with bandwidth expansion
/// (`silk_lsf2lpc`); the result is normalized to floats by /4096. The C's
/// polynomial split takes even-indexed LSPs into `p` and odd-indexed into
/// `q` of the k2-scattered array.
fn silk_lsf2lpc(nlsf : FixedArray[Int], lpcf : FixedArray[Float], order : Int) -> Unit {
  let lsp : FixedArray[Int] = FixedArray::make(16, 0)
  let p : FixedArray[Int] = FixedArray::make(9, 0)
  let q : FixedArray[Int] = FixedArray::make(9, 0)
  let lpc32 : FixedArray[Int] = FixedArray::make(16, 0)
  let lpc : FixedArray[Int] = FixedArray::make(16, 0)
  for k in 0..<order {
    let index = nlsf[k] >> 8
    let offset = nlsf[k] & 255
    let k2 = if order == 10 {
      silk_lsf_ordering_nbmb[k]
    } else {
      silk_lsf_ordering_wb[k]
    }
    let mut value = silk_cosine[index] * 256
    value += (silk_cosine[index + 1] - silk_cosine[index]) * offset
    lsp[k2] = (value + 4) >> 3
  }
  silk_lsp2poly(lsp, 0, p, order >> 1)
  silk_lsp2poly(lsp, 1, q, order >> 1)
  for k in 0..<(order >> 1) {
    let p_tmp = p[k + 1] + p[k]
    let q_tmp = q[k + 1] - q[k]
    lpc32[k] = -q_tmp - p_tmp
    lpc32[order - k - 1] = q_tmp - p_tmp
  }
  // Limit the range of the LPC coefficients to each fit within an int16.
  // C scans lazily — `x = FFABS(lpc32[k])` reads the previous argmax slot,
  // not the current index, so maxabs effectively tracks |lpc32[0]| — and the
  // Q12 store truncates to int16. Both quirks are reproduced verbatim.
  let mut attempt = 0
  for _ in 0..<10 {
    attempt += 1
    let mut maxabs : UInt = 0U
    let mut kbest = 0
    for j in 0..<order {
      let current = lpc32[kbest]
      let x = if current < 0 { (-current).reinterpret_as_uint() } else { current.reinterpret_as_uint() }
      if x > maxabs {
        maxabs = x
        kbest = j
      }
    }
    let mut maxabs = (maxabs + 16U) >> 5
    if maxabs > 32767U {
      if maxabs > 163838U {
        maxabs = 163838U
      }
      let denom = ((maxabs * (kbest + 1).reinterpret_as_uint()) >> 2).reinterpret_as_int()
      let numer = ((maxabs - 32767U) << 14).reinterpret_as_int()
      let chirp_base : UInt = 65470U - (numer / denom).reinterpret_as_uint()
      let mut chirp : UInt = chirp_base
      for k in 0..<order {
        lpc32[k] = silk_round_mull(lpc32[k], chirp.reinterpret_as_int(), 16)
        chirp = (chirp_base * chirp + 32768U) >> 16
      }
    } else {
      attempt -= 1
      break
    }
  }
  if attempt == 10 {
    for k in 0..<order {
      let x = (lpc32[k] + 16) >> 5
      lpc[k] = clip_int16(x)
      lpc32[k] = lpc[k] << 5
    }
  } else {
    for k in 0..<order {
      lpc[k] = wrap_i16((lpc32[k] + 16) >> 5)
    }
  }
  // Further bandwidth expansion if the prediction gain is unstable.
  let mut i = 1
  while i <= 16 && !silk_is_lpc_stable(lpc, order) {
    let chirp_base : UInt = 65536U - (1U << i)
    let mut chirp : UInt = chirp_base
    for k in 0..<order {
      lpc32[k] = silk_round_mull(lpc32[k], chirp.reinterpret_as_int(), 16)
      lpc[k] = wrap_i16((lpc32[k] + 16) >> 5)
      chirp = (chirp_base * chirp + 32768U) >> 16
    }
    i += 1
  }
  for i in 0..<order {
    lpcf[i] = Float::from_int(lpc[i]) / 4096.0
  }
}

///|
/// Sub-table view into `silk_model_pulse_location`: the cdf for splitting
/// `total` pulses between two children, laid out by the same triangular
/// offset formula as the C. The scan stops at the terminating 256 bound.
fn silk_pulse_cdf(model : Int, total : Int) -> Result[ArrayView[Int], String] {
  if total <= 0 {
    return Err("opus: pulse split with zero total")
  }
  let offset = ((total - 1 + 5) * (total - 1)) >> 1
  let start = model * 168 + offset
  if start >= silk_model_pulse_location.length() {
    return Err("opus: pulse location table out of range")
  }
  let mut end = start + 1
  while end < silk_model_pulse_location.length() && silk_model_pulse_location[end] != 256 {
    end += 1
  }
  if end >= silk_model_pulse_location.length() {
    return Err("opus: unterminated pulse location table")
  }
  Ok(silk_model_pulse_location[start:end + 1])
}

///|
fn silk_count_children(
  rc : OpusRangeDecoder,
  model : Int,
  total : Int,
) -> Result[(Int, Int), String] {
  if total != 0 {
    let cdf = match silk_pulse_cdf(model, total) {
      Ok(view) => view
      Err(error) => return Err(error)
    }
    match rc.decode_cdf(cdf) {
      Ok(first) => Ok((first, total - first))
      Err(error) => Err(error)
    }
  } else {
    Ok((0, 0))
  }
}

///|
/// Excitation decoding (`silk_decode_excitation`): shell block pulse counts,
/// PVQ pulse locations, LSB expansion, sign modeling and the pseudorandom
/// inversion, producing floats at `excitationf[silk_max_lag ..]`.
fn OpusSilkDecoder::decode_excitation(
  self : OpusSilkDecoder,
  rc : OpusRangeDecoder,
  excitationf : Array[Float],
  qoffset_high : Int,
  active : Int,
  voiced : Int,
) -> Result[Unit, String] {
  let excitation : FixedArray[Int] = FixedArray::make(320, 0)
  let pulsecount : FixedArray[Int] = FixedArray::make(20, 0)
  let lsbcount : FixedArray[Int] = FixedArray::make(20, 0)
  let mut seed : UInt = match rc.decode_cdf(silk_model_lcg_seed[:]) {
    Ok(value) => value.reinterpret_as_uint()
    Err(error) => return Err(error)
  }
  let shellblocks = silk_shell_blocks[self.bandwidth * 2 + (self.subframes >> 2)]
  let ratelevel = match rc.decode_cdf(silk_model_exc_rate[voiced * 10:voiced * 10 + 10]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  for i in 0..<shellblocks {
    let mut count = match rc.decode_cdf(silk_model_pulse_count[ratelevel * 19:ratelevel * 19 + 19]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if count == 17 {
      lsbcount[i] += 1
      while count == 17 && lsbcount[i] != 10 {
        match rc.decode_cdf(silk_model_pulse_count[9 * 19:9 * 19 + 19]) {
          Ok(value) => count = value
          Err(error) => return Err(error)
        }
        if count == 17 {
          lsbcount[i] += 1
        }
      }
      if lsbcount[i] == 10 {
        match rc.decode_cdf(silk_model_pulse_count[10 * 19:10 * 19 + 19]) {
          Ok(value) => count = value
          Err(error) => return Err(error)
        }
      }
    }
    pulsecount[i] = count
  }
  // Decode pulse locations using PVQ (unrolled tail recursion over four
  // binary levels; branch[2]/branch[3] are per-node scratch, as in the C).
  for i in 0..<shellblocks {
    if pulsecount[i] != 0 {
      let location_base = 16 * i
      let branch0 = pulsecount[i]
      let b1 : FixedArray[Int] = FixedArray::make(2, 0)
      let b2 : FixedArray[Int] = FixedArray::make(2, 0)
      let b3 : FixedArray[Int] = FixedArray::make(2, 0)
      match silk_count_children(rc, 0, branch0) {
        Ok((c0, c1)) => {
          b1[0] = c0
          b1[1] = c1
        }
        Err(error) => return Err(error)
      }
      for b in 0..<2 {
        match silk_count_children(rc, 1, b1[b]) {
          Ok((c0, c1)) => {
            b2[0] = c0
            b2[1] = c1
          }
          Err(error) => return Err(error)
        }
        for c in 0..<2 {
          match silk_count_children(rc, 2, b2[c]) {
            Ok((d0, d1)) => {
              b3[0] = d0
              b3[1] = d1
            }
            Err(error) => return Err(error)
          }
          for d in 0..<2 {
            match silk_count_children(rc, 3, b3[d]) {
              Ok((e0, e1)) => {
                excitation[location_base + (b * 4 + c * 2 + d) * 2] = e0
                excitation[location_base + (b * 4 + c * 2 + d) * 2 + 1] = e1
              }
              Err(error) => return Err(error)
            }
          }
        }
      }
    }
  }
  // Decode least significant bits.
  for i in 0..<(shellblocks << 4) {
    for _bit in 0..<lsbcount[i >> 4] {
      match rc.decode_cdf(silk_model_excitation_lsb[:]) {
        Ok(bit) => excitation[i] = (excitation[i] << 1) | bit
        Err(error) => return Err(error)
      }
    }
  }
  // Decode signs.
  for i in 0..<(shellblocks << 4) {
    if excitation[i] != 0 {
      let pc = if pulsecount[i >> 4] < 6 { pulsecount[i >> 4] } else { 6 }
      let base = ((active + voiced) * 2 + qoffset_high) * 21 + pc * 3
      match rc.decode_cdf(silk_model_excitation_sign[base:base + 3]) {
        Ok(sign) => {
          if sign == 0 {
            excitation[i] = -excitation[i]
          }
        }
        Err(error) => return Err(error)
      }
    }
  }
  // Assemble the excitation.
  for i in 0..<(shellblocks << 4) {
    let value = excitation[i]
    excitation[i] = (value * 256) | silk_quant_offset[voiced * 2 + qoffset_high]
    if value < 0 {
      excitation[i] += 20
    } else if value > 0 {
      excitation[i] -= 20
    }
    seed = 196314165U * seed + 907633515U
    if (seed & 0x80000000U) != 0U {
      excitation[i] = -excitation[i]
    }
    seed += value.reinterpret_as_uint()
    excitationf[silk_max_lag + i] = Float::from_int(excitation[i]) / 8388608.0
  }
  Ok(())
}

///|
/// LPC decoding (`silk_decode_lpc`): stage-1/2 LSF indices, residual
/// prediction, NLSF reconstruction, stabilization and the lead-in
/// interpolation. Writes `lpc_leadin`/`lpc_body` floats, sets
/// `has_lpc_leadin`/`order`, and updates the frame's stored NLSF/LPC.
fn OpusSilkDecoder::decode_lpc(
  self : OpusSilkDecoder,
  frame : SilkFrame,
  rc : OpusRangeDecoder,
  lpc_leadin : FixedArray[Float],
  lpc_body : FixedArray[Float],
  has_lpc_leadin : Ref[Bool],
  order_out : Ref[Int],
  voiced : Int,
) -> Result[Unit, String] {
  let order = if self.wb { 16 } else { 10 }
  order_out.val = order
  let s1_base = (self.wb.to_int() * 2 + voiced) * 33
  let lsf_i1 = match rc.decode_cdf(silk_model_lsf_s1[s1_base:s1_base + 33]) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lsf_i2 : FixedArray[Int] = FixedArray::make(16, 0)
  let lsf_res : FixedArray[Int] = FixedArray::make(16, 0)
  let nlsf : FixedArray[Int] = FixedArray::make(16, 0)
  for i in 0..<order {
    let index = if self.wb {
      silk_lsf_s2_model_sel_wb[lsf_i1 * 16 + i]
    } else {
      silk_lsf_s2_model_sel_nbmb[lsf_i1 * 10 + i]
    }
    let mut value = match rc.decode_cdf(silk_model_lsf_s2[index * 10:index * 10 + 10]) {
      Ok(value) => value - 4
      Err(error) => return Err(error)
    }
    if value == -4 {
      match rc.decode_cdf(silk_model_lsf_s2_ext[:]) {
        Ok(ext) => value -= ext
        Err(error) => return Err(error)
      }
    } else if value == 4 {
      match rc.decode_cdf(silk_model_lsf_s2_ext[:]) {
        Ok(ext) => value += ext
        Err(error) => return Err(error)
      }
    }
    lsf_i2[i] = value
  }
  // Reverse the backwards-prediction step.
  let mut i = order - 1
  while i >= 0 {
    let qstep = if self.wb { 9830 } else { 11796 }
    let mut res = lsf_i2[i] * 1024
    if lsf_i2[i] < 0 {
      res += 102
    } else if lsf_i2[i] > 0 {
      res -= 102
    }
    res = (res * qstep) >> 16
    if i + 1 < order {
      let weight = if self.wb {
        silk_lsf_pred_weights_wb[silk_lsf_weight_sel_wb[lsf_i1 * 15 + i] * 15 + i]
      } else {
        silk_lsf_pred_weights_nbmb[silk_lsf_weight_sel_nbmb[lsf_i1 * 9 + i] * 9 + i]
      }
      res += (lsf_res[i + 1] * weight) >> 8
    }
    lsf_res[i] = res
    i -= 1
  }
  // Reconstruct the NLSF coefficients from the supplied indices.
  for i in 0..<order {
    let cur = if self.wb {
      silk_lsf_codebook_wb[lsf_i1 * 16 + i]
    } else {
      silk_lsf_codebook_nbmb[lsf_i1 * 10 + i]
    }
    let weight = if self.wb {
      silk_model_lsf_weight_wb[lsf_i1 * 16 + i]
    } else {
      silk_model_lsf_weight_nbmb[lsf_i1 * 10 + i]
    }
    let value = cur * 128 + (lsf_res[i] * 16384) / weight
    nlsf[i] = silk_clip_uintp2(value, 15)
  }
  silk_stabilize_lsf(nlsf, order, if self.wb { silk_lsf_min_spacing_wb } else { silk_lsf_min_spacing_nbmb })
  // Produce an interpolation for the first 2 subframes, then convert both
  // NLSF sets to LPC coefficients.
  has_lpc_leadin.val = false
  if self.subframes == 4 {
    let mut offset = match rc.decode_cdf(silk_model_lsf_interpolation_offset[:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if offset != 4 && frame.coded {
      has_lpc_leadin.val = true
      if offset != 0 {
        let nlsf_leadin : FixedArray[Int] = FixedArray::make(16, 0)
        for i in 0..<order {
          nlsf_leadin[i] = wrap_i16(frame.nlsf[i] + (((nlsf[i] - frame.nlsf[i]) * offset) >> 2))
        }
        silk_lsf2lpc(nlsf_leadin, lpc_leadin, order)
      } else {
        for i in 0..<16 {
          lpc_leadin[i] = frame.lpc[i]
        }
      }
    } else {
      offset = 4
    }
    self.nlsf_interp_factor = offset
    silk_lsf2lpc(nlsf, lpc_body, order)
  } else {
    self.nlsf_interp_factor = 4
    silk_lsf2lpc(nlsf, lpc_body, order)
  }
  for i in 0..<order {
    frame.nlsf[i] = nlsf[i]
    frame.lpc[i] = lpc_body[i]
  }
  Ok(())
}

///|
/// One SILK frame (`silk_decode_frame`): stereo weights, frame type, subframe
/// gains, LPC, pitch and excitation, followed by LTP/LPC synthesis into the
/// frame history.
fn OpusSilkDecoder::decode_frame(
  self : OpusSilkDecoder,
  rc : OpusRangeDecoder,
  frame_num : Int,
  channel : Int,
  coded_channels : Int,
  active : Int,
  active1 : Int,
  redundant : Bool,
) -> Result[Unit, String] {
  let frame = self.frames[channel]
  let sf_gain : FixedArray[Float] = FixedArray::make(4, 0.0)
  let sf_pitchlag : FixedArray[Int] = FixedArray::make(4, 0)
  let sf_ltptaps : Array[FixedArray[Float]] = [
    FixedArray::make(5, 0.0),
    FixedArray::make(5, 0.0),
    FixedArray::make(5, 0.0),
    FixedArray::make(5, 0.0),
  ]
  // Obtain stereo weights.
  if coded_channels == 2 && channel == 0 {
    let n = match rc.decode_cdf(silk_model_stereo_s1[:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let wi : FixedArray[Int] = FixedArray::make(2, 0)
    let ws : FixedArray[Int] = FixedArray::make(2, 0)
    match rc.decode_cdf(silk_model_stereo_s2[:]) {
      Ok(value) => wi[0] = value + 3 * (n / 5)
      Err(error) => return Err(error)
    }
    match rc.decode_cdf(silk_model_stereo_s3[:]) {
      Ok(value) => ws[0] = value
      Err(error) => return Err(error)
    }
    match rc.decode_cdf(silk_model_stereo_s2[:]) {
      Ok(value) => wi[1] = value + 3 * (n % 5)
      Err(error) => return Err(error)
    }
    match rc.decode_cdf(silk_model_stereo_s3[:]) {
      Ok(value) => ws[1] = value
      Err(error) => return Err(error)
    }
    let w : FixedArray[Int] = FixedArray::make(2, 0)
    for i in 0..<2 {
      let base = silk_stereo_weights[wi[i]]
      let next = silk_stereo_weights[wi[i] + 1]
      w[i] = base + (((next - base) * 6554) >> 16) * (ws[i] * 2 + 1)
    }
    self.stereo_weights[0] = Float::from_double((w[0] - w[1]).to_double() / 8192.0)
    self.stereo_weights[1] = Float::from_double(w[1].to_double() / 8192.0)
    self.midonly = if active1 != 0 {
      0
    } else {
      match rc.decode_cdf(silk_model_mid_only[:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    }
  }
  // Obtain frame type.
  let mut voiced = 0
  let qoffset_high = if active == 0 {
    match rc.decode_cdf(silk_model_frame_type_inactive[:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
  } else {
    let frame_type = match rc.decode_cdf(silk_model_frame_type_active[:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    voiced = frame_type >> 1
    frame_type & 1
  }
  // Obtain subframe quantization gains.
  for i in 0..<self.subframes {
    let log_gain = if i == 0 && (frame_num == 0 || !frame.coded) {
      let x = match rc.decode_cdf(silk_model_gain_highbits[(active + voiced) * 9:(active + voiced) * 9 + 9]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let low = match rc.decode_cdf(silk_model_gain_lowbits[:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let mut value = (x << 3) | low
      if frame.coded {
        let floor_gain = frame.log_gain - 16
        if floor_gain > value {
          value = floor_gain
        }
      }
      value
    } else {
      let delta_gain = match rc.decode_cdf(silk_model_gain_delta[:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let a = (delta_gain << 1) - 16
      let b = frame.log_gain + delta_gain - 4
      silk_clip_uintp2(if a > b { a } else { b }, 6)
    }
    frame.log_gain = log_gain
    let scaled = ((log_gain * 1907825) >> 16) + 2090
    let ipart = scaled >> 7
    let fpart = scaled & 127
    let lingain = (1 << ipart) + (((-174 * fpart * (128 - fpart)) >> 16) + fpart) * ((1 << ipart) >> 7)
    sf_gain[i] = Float::from_int(lingain) / 65536.0
  }
  // Obtain LPC filter coefficients.
  let lpc_leadin : FixedArray[Float] = FixedArray::make(16, 0.0)
  let lpc_body : FixedArray[Float] = FixedArray::make(16, 0.0)
  let has_lpc_leadin = Ref(false)
  let order = Ref(0)
  match self.decode_lpc(frame, rc, lpc_leadin, lpc_body, has_lpc_leadin, order, voiced) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // Obtain pitch lags, if this is a voiced frame.
  let mut ltpscale : Float = 15565.0 / 16384.0
  if voiced != 0 {
    let mut lag_absolute = frame_num == 0 || !frame.prev_voiced
    let mut primarylag = 0
    if !lag_absolute {
      let delta = match rc.decode_cdf(silk_model_pitch_delta[:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if delta != 0 {
        primarylag = frame.primarylag + delta - 9
      } else {
        lag_absolute = true
      }
    }
    if lag_absolute {
      let highbits = match rc.decode_cdf(silk_model_pitch_highbits[:]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      // model_pitch_lowbits_nb is #define-aliased to model_lcg_seed and
      // model_pitch_lowbits_wb to model_gain_lowbits in tab.h.
      let lowbits_model = match self.bandwidth {
        0 => silk_model_lcg_seed[:]
        1 => silk_model_pitch_lowbits_mb[:]
        _ => silk_model_gain_lowbits[:]
      }
      let lowbits = match rc.decode_cdf(lowbits_model) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      primarylag = silk_pitch_min_lag[self.bandwidth] +
        highbits * silk_pitch_scale[self.bandwidth] + lowbits
    }
    frame.primarylag = primarylag
    let offsets = if self.subframes == 2 {
      if self.bandwidth == 0 {
        match rc.decode_cdf(silk_model_pitch_contour_nb10ms[:]) {
          Ok(value) => silk_pitch_offset_nb10ms[value * 2:value * 2 + 2]
          Err(error) => return Err(error)
        }
      } else {
        match rc.decode_cdf(silk_model_pitch_contour_mbwb10ms[:]) {
          Ok(value) => silk_pitch_offset_mbwb10ms[value * 2:value * 2 + 2]
          Err(error) => return Err(error)
        }
      }
    } else if self.bandwidth == 0 {
      match rc.decode_cdf(silk_model_pitch_contour_nb20ms[:]) {
        Ok(value) => silk_pitch_offset_nb20ms[value * 4:value * 4 + 4]
        Err(error) => return Err(error)
      }
    } else {
      match rc.decode_cdf(silk_model_pitch_contour_mbwb20ms[:]) {
        Ok(value) => silk_pitch_offset_mbwb20ms[value * 4:value * 4 + 4]
        Err(error) => return Err(error)
      }
    }
    for i in 0..<self.subframes {
      sf_pitchlag[i] = silk_clip(primarylag + offsets[i],
        silk_pitch_min_lag[self.bandwidth],
        silk_pitch_max_lag[self.bandwidth])
    }
    // Obtain LTP filter coefficients.
    let ltpfilter = match rc.decode_cdf(silk_model_ltp_filter[:]) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let filter_sel : Array[ArrayView[Int]] = [
      silk_model_ltp_filter0_sel[:], silk_model_ltp_filter1_sel[:], silk_model_ltp_filter2_sel[:],
    ]
    let filter_taps : Array[Array[Int32]] = [
      silk_ltp_filter0_taps, silk_ltp_filter1_taps, silk_ltp_filter2_taps,
    ]
    for i in 0..<self.subframes {
      let index = match rc.decode_cdf(filter_sel[ltpfilter]) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      for j in 0..<5 {
        sf_ltptaps[i][j] = Float::from_int(filter_taps[ltpfilter][index * 5 + j]) / 128.0
      }
    }
    if frame_num == 0 {
      match rc.decode_cdf(silk_model_ltp_scale_index[:]) {
        Ok(value) => ltpscale = Float::from_int(silk_ltp_scale_factor[value]) / 16384.0
        Err(error) => return Err(error)
      }
    }
  }
  // Generate the excitation signal for the entire frame.
  let residual : Array[Float] = Array::make(silk_max_lag + silk_history, 0.0)
  match self.decode_excitation(rc, residual, qoffset_high, active, voiced) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  // Skip synthesizing the output if we do not need it.
  if self.output_channels == channel || redundant {
    return Ok(())
  }
  // Generate the output signal.
  for i in 0..<self.subframes {
    let lpc_coeff = if i < 2 && has_lpc_leadin.val { lpc_leadin } else { lpc_body }
    let out_base = silk_history + i * self.sflength
    let res_base = silk_max_lag + i * self.sflength
    let lpc_base = silk_history + i * self.sflength
    if voiced != 0 {
      let (out_end, scale) = if i < 2 || self.nlsf_interp_factor == 4 {
        (-i * self.sflength, ltpscale)
      } else {
        (-(i - 2) * self.sflength, 1.0)
      }
      // Re-whitening filter for changed LPC coefficients.
      let mut j = -sf_pitchlag[i] - silk_ltp_order / 2
      while j < out_end {
        let mut sum = frame.output[out_base + j]
        for k in 0..<order.val {
          sum -= lpc_coeff[k] * frame.output[out_base + j - k - 1]
        }
        residual[res_base + j] = silk_clipf(sum, -1.0, 1.0) * scale / sf_gain[i]
        j += 1
      }
      if out_end != 0 {
        let rescale = sf_gain[i - 1] / sf_gain[i]
        for j in out_end..<0 {
          residual[res_base + j] *= rescale
        }
      }
      // LTP synthesis.
      for j in 0..<self.sflength {
        let mut sum = residual[res_base + j]
        for k in 0..<silk_ltp_order {
          sum += sf_ltptaps[i][k] * residual[res_base + j - sf_pitchlag[i] + silk_ltp_order / 2 - k]
        }
        residual[res_base + j] = sum
      }
    }
    // LPC synthesis.
    for j in 0..<self.sflength {
      let mut sum = residual[res_base + j] * sf_gain[i]
      for k in 1..<=order.val {
        sum += lpc_coeff[k - 1] * frame.lpc_history[lpc_base + j - k]
      }
      frame.lpc_history[lpc_base + j] = sum
      frame.output[out_base + j] = silk_clipf(sum, -1.0, 1.0)
    }
  }
  frame.prev_voiced = voiced != 0
  for i in 0..<silk_history {
    frame.lpc_history[i] = frame.lpc_history[i + self.flength]
    frame.output[i] = frame.output[i + self.flength]
  }
  frame.coded = true
  Ok(())
}

///|
/// Stereo unmixing (`silk_unmix_ms`) with weight interpolation over the
/// bandwidth-dependent ramp length.
fn OpusSilkDecoder::unmix_ms(
  self : OpusSilkDecoder,
  l : Array[Float],
  l_offset : Int,
  r : Array[Float],
  r_offset : Int,
) -> Result[Unit, String] {
  let mid = self.frames[0]
  let side = self.frames[1]
  let mid_base = silk_history - self.flength
  let side_base = silk_history - self.flength
  guard l.length() >= l_offset + self.flength && r.length() >= r_offset + self.flength
    else { return Err("opus: stereo unmix buffer too small") }
  let w0_prev = self.prev_stereo_weights[0]
  let w1_prev = self.prev_stereo_weights[1]
  let w0 = self.stereo_weights[0]
  let w1 = self.stereo_weights[1]
  let n1 = silk_stereo_interp_len[self.bandwidth]
  let n1f = Float::from_int(n1)
  let f2 : Float = 2.0
  let f1 : Float = 1.0
  let quarter : Float = 0.25
  let mut i = 0
  while i < n1 {
    let interp0 = w0_prev + Float::from_int(i) * (w0 - w0_prev) / n1f
    let interp1 = w1_prev + Float::from_int(i) * (w1 - w1_prev) / n1f
    let p0 = quarter * (mid.output[mid_base + i - 2] + f2 * mid.output[mid_base + i - 1] +
      mid.output[mid_base + i])
    l[l_offset + i] = silk_clipf((f1 + interp1) * mid.output[mid_base + i - 1] +
      side.output[side_base + i - 1] + interp0 * p0, -1.0, 1.0)
    r[r_offset + i] = silk_clipf((f1 - interp1) * mid.output[mid_base + i - 1] -
      side.output[side_base + i - 1] - interp0 * p0, -1.0, 1.0)
    i += 1
  }
  while i < self.flength {
    let p0 = quarter * (mid.output[mid_base + i - 2] + f2 * mid.output[mid_base + i - 1] +
      mid.output[mid_base + i])
    l[l_offset + i] = silk_clipf((f1 + w1) * mid.output[mid_base + i - 1] +
      side.output[side_base + i - 1] + w0 * p0, -1.0, 1.0)
    r[r_offset + i] = silk_clipf((f1 - w1) * mid.output[mid_base + i - 1] -
      side.output[side_base + i - 1] - w0 * p0, -1.0, 1.0)
    i += 1
  }
  self.prev_stereo_weights[0] = self.stereo_weights[0]
  self.prev_stereo_weights[1] = self.stereo_weights[1]
  Ok(())
}

///|
/// Decode the LP layer of one Opus frame, which may contain several SILK
/// frames (`ff_silk_decode_superframe`). `output` receives channel-major
/// float PCM; returns the number of samples per channel.
pub fn OpusSilkDecoder::decode_superframe(
  self : OpusSilkDecoder,
  rc : OpusRangeDecoder,
  output : Array[Array[Float]],
  bandwidth : Int,
  coded_channels : Int,
  duration_ms : Int,
) -> Result[Int, String] {
  if bandwidth > 2 || coded_channels > 2 || duration_ms > 60 {
    return Err("opus: invalid parameters passed to the SILK decoder")
  }
  let nb_frames = 1 + (if duration_ms > 20 { 1 } else { 0 }) + (if duration_ms > 40 { 1 } else { 0 })
  self.subframes = duration_ms / nb_frames / 5
  self.sflength = 20 * (bandwidth + 2)
  self.flength = self.sflength * self.subframes
  self.bandwidth = bandwidth
  self.wb = bandwidth == 2
  if coded_channels > self.prev_coded_channels {
    silk_flush_frame(self.frames[1])
  }
  self.prev_coded_channels = coded_channels
  // Read the LP-layer header bits.
  let active : Array[FixedArray[Int]] = [FixedArray::make(6, 0), FixedArray::make(6, 0)]
  let redundancy : FixedArray[Int] = FixedArray::make(2, 0)
  for i in 0..<coded_channels {
    for j in 0..<nb_frames {
      match rc.decode_log(1) {
        Ok(bit) => active[i][j] = bit
        Err(error) => return Err(error)
      }
    }
    match rc.decode_log(1) {
      Ok(bit) => redundancy[i] = bit
      Err(error) => return Err(error)
    }
  }
  // Read the per-frame LBRR flags.
  for i in 0..<coded_channels {
    if redundancy[i] != 0 && duration_ms > 20 {
      let model = if duration_ms == 40 { silk_model_lbrr_flags_40[:] } else { silk_model_lbrr_flags_60[:] }
      match rc.decode_cdf(model) {
        Ok(value) => redundancy[i] = value
        Err(error) => return Err(error)
      }
    }
  }
  // Decode the LBRR frames.
  for i in 0..<nb_frames {
    for j in 0..<coded_channels {
      if (redundancy[j] & (1 << i)) != 0 {
        let active1 = if j == 0 && (redundancy[1] & (1 << i)) == 0 { 0 } else { 1 }
        match self.decode_frame(rc, i, j, coded_channels, 1, active1, true) {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
      }
    }
    self.midonly = 0
  }
  for i in 0..<nb_frames {
    let mut j = 0
    while j < coded_channels && self.midonly == 0 {
      let active1 = if coded_channels > 1 { active[1][i] } else { 0 }
      match self.decode_frame(rc, i, j, coded_channels, active[j][i], active1, false) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      j += 1
    }
    if self.midonly != 0 && self.frames[1].coded {
      silk_flush_frame(self.frames[1])
    }
    if coded_channels == 1 || self.output_channels == 1 {
      for j in 0..<self.output_channels {
        let base = silk_history - self.flength - 2
        for k in 0..<self.flength {
          output[j][i * self.flength + k] = self.frames[0].output[base + k]
        }
      }
    } else {
      match self.unmix_ms(output[0], i * self.flength, output[1], i * self.flength) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    self.midonly = 0
  }
  Ok(nb_frames * self.flength)
}
