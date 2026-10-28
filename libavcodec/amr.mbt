///|
/// AMR-NB decoder, ported from FFmpeg 9.0.2 `libavcodec/amrnbdec.c` plus the
/// ACELP/CELP/LSP helpers it calls (`acelp_filters.c`, `acelp_vectors.c`,
/// `acelp_pitch_delay.c`, `celp_filters.c`, `lsp.c`).
///
/// Scope: the eight speech modes (4.75-12.2 kbit/s), 8 kHz mono, the float
/// decoder path (FFmpeg itself notes it is not bit-exact against the 3GPP
/// reference).  DTX frames and no-data frames are rejected.  The port uses
/// doubles throughout; the 3GPP "homing frame" detection is not implemented,
/// matching the C.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// constants
// ---------------------------------------------------------------------------

///|
let amr_lp_order : Int32 = 10

///|
let amr_subframe_size : Int32 = 40

///|
let amr_block_size : Int32 = 160

///|
let amr_pitch_delay_max : Int32 = 143

///|
let amr_pitch_delay_min : Int32 = 20

///|
let amr_sample_bound : Double = 32768.0

///|
let amr_sample_scale : Double = 2.0 / 32768.0

///|
let amr_pred_fac_mode_12k2 : Double = 0.65

///|
let amr_lsf_r_fac : Double = 8000.0 / 32768.0

///|
let amr_min_lsf_spacing : Double = 50.0488 / 8000.0

///|
let amr_pitch_lag_min_mode_12k2 : Int32 = 18

///|
let amr_min_energy : Double = -14.0

///|
let amr_sharp_max : Double = 0.79449462890625

///|
let amr_tilt_response : Int32 = 22

///|
let amr_tilt_gamma_t : Double = 0.8

///|
let amr_agc_alpha : Double = 0.9

///|
let amr_mode_12k2 : Int32 = 7

///|
let amr_mode_10k2 : Int32 = 6

///|
let amr_mode_7k95 : Int32 = 5

///|
let amr_mode_7k4 : Int32 = 4

///|
let amr_mode_6k7 : Int32 = 3

///|
let amr_mode_5k9 : Int32 = 2

///|
let amr_mode_5k15 : Int32 = 1

///|
let amr_mode_4k75 : Int32 = 0

///|
let amr_n_modes : Int32 = 9

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

///|
fn amr_clip_int(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn amr_clipf(v : Double, lo : Double, hi : Double) -> Double {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// `ff_scalarproduct_float_c` / `dot_productf` (a and b may alias).
fn amr_dot(
  a : Array[Double],
  a_off : Int32,
  b : Array[Double],
  b_off : Int32,
  len : Int32,
) -> Double {
  let mut sum = 0.0
  for i = 0; i < len; i = i + 1 {
    sum = sum + a[a_off + i] * b[b_off + i]
  }
  sum
}

///|
/// `ff_set_min_dist_lsf`.
fn amr_set_min_dist_lsf(lsf : Array[Double], min_spacing : Double) -> Unit {
  let mut prev = 0.0
  for i = 0; i < amr_lp_order; i = i + 1 {
    if lsf[i] < prev + min_spacing {
      lsf[i] = prev + min_spacing
    }
    prev = lsf[i]
  }
}

///|
/// `ff_acelp_lsf2lspd`: LSF to LSP (cosine domain).
fn amr_lsf2lspd(lsp : Array[Double], lsf : Array[Double]) -> Unit {
  for i = 0; i < amr_lp_order; i = i + 1 {
    lsp[i] = @math.cos(2.0 * 3.14159265358979323846 * lsf[i])
  }
}

///|
/// `lsp2polyf` (TIA/EIA/IS-733): `off` selects the even or odd LSP phase.
fn amr_lsp2polyf(
  lsp : Array[Double],
  off : Int32,
  f : Array[Double],
  lp_half_order : Int32,
) -> Unit {
  f[0] = 1.0
  f[1] = -2.0 * lsp[off]
  for i = 2; i <= lp_half_order; i = i + 1 {
    let val = -2.0 * lsp[off + 2 * i - 2]
    f[i] = val * f[i - 1] + 2.0 * f[i - 2]
    let mut j = i - 1
    while j > 1 {
      f[j] = f[j] + f[j - 1] * val + f[j - 2]
      j = j - 1
    }
    f[1] = f[1] + val
  }
}

///|
/// `ff_acelp_lspd2lpc`: LSP (cosine) to LP coefficients, order 10.
fn amr_lspd2lpc(lsp : Array[Double], lpc : Array[Double]) -> Unit {
  let half = amr_lp_order / 2
  let pa : Array[Double] = Array::make(half + 1, 0.0)
  let qa : Array[Double] = Array::make(half + 1, 0.0)
  amr_lsp2polyf(lsp, 0, pa, half)
  amr_lsp2polyf(lsp, 1, qa, half)
  let mut ih = half - 1
  while ih >= 0 {
    let paf = pa[ih + 1] + pa[ih]
    let qaf = qa[ih + 1] - qa[ih]
    lpc[ih] = 0.5 * (paf + qaf)
    lpc[amr_lp_order - 1 - ih] = 0.5 * (paf - qaf)
    ih = ih - 1
  }
}

///|
/// `ff_weighted_vector_sumf`.
fn amr_weighted_vector_sum(
  out : Array[Double],
  out_off : Int32,
  a : Array[Double],
  a_off : Int32,
  b : Array[Double],
  b_off : Int32,
  wa : Double,
  wb : Double,
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    out[out_off + i] = wa * a[a_off + i] + wb * b[b_off + i]
  }
}

///|
/// `ff_acelp_interpolatef` with explicit offsets: `src(k) = buf[src_off + k]`.
fn amr_acelp_interpolatef(
  out : Array[Double],
  out_off : Int32,
  buf : Array[Double],
  src_off : Int32,
  coeffs : FixedArray[Double],
  precision : Int32,
  frac_pos : Int32,
  filter_length : Int32,
  length : Int32,
) -> Unit {
  for n = 0; n < length; n = n + 1 {
    let mut idx = 0
    let mut v = 0.0
    let mut i = 0
    while i < filter_length {
      v = v + buf[src_off + n + i] * coeffs[idx + frac_pos]
      idx = idx + precision
      i = i + 1
      v = v + buf[src_off + n - i] * coeffs[idx - frac_pos]
    }
    out[out_off + n] = v
  }
}

///|
/// `ff_celp_circ_addf`.
fn amr_celp_circ_addf(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  lagged : Array[Double],
  lagged_off : Int32,
  lag : Int32,
  fac : Double,
  n : Int32,
) -> Unit {
  let mut k = 0
  while k < lag {
    out[out_off + k] = src[src_off + k] + fac * lagged[lagged_off + n + k - lag]
    k = k + 1
  }
  while k < n {
    out[out_off + k] = src[src_off + k] + fac * lagged[lagged_off + k - lag]
    k = k + 1
  }
}

///|
/// `ff_celp_lp_synthesis_filterf`: all-pole synthesis.  `out` may alias `buf`
/// at the same offset (tilt factor impulse response); history lives before
/// `out_off` src `buf`.
fn amr_celp_lp_synthesis_filterf(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  coeffs : Array[Double],
  buffer_length : Int32,
  filter_length : Int32,
) -> Unit {
  for n = 0; n < buffer_length; n = n + 1 {
    let mut v = src[src_off + n]
    for i = 1; i <= filter_length; i = i + 1 {
      v = v - coeffs[i - 1] * out[out_off + n - i]
    }
    out[out_off + n] = v
  }
}

///|
/// `ff_celp_lp_zero_synthesis_filterf`: all-zero synthesis.
fn amr_celp_lp_zero_synthesis_filterf(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  coeffs : Array[Double],
  buffer_length : Int32,
  filter_length : Int32,
) -> Unit {
  for n = 0; n < buffer_length; n = n + 1 {
    let mut v = src[src_off + n]
    for i = 1; i <= filter_length; i = i + 1 {
      v = v + coeffs[i - 1] * src[src_off + n - i]
    }
    out[out_off + n] = v
  }
}

///|
/// `ff_scale_vector_to_given_sum_of_squares`.
fn amr_scale_to_sum_of_squares(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  sum_of_squares : Double,
  n : Int32,
) -> Unit {
  let sp = amr_dot(src, src_off, src, src_off, n)
  let scale = if sp != 0.0 { (sum_of_squares / sp).sqrt() } else { 0.0 }
  for i = 0; i < n; i = i + 1 {
    out[out_off + i] = src[src_off + i] * scale
  }
}

///|
/// `ff_adaptive_gain_control`.
fn amr_adaptive_gain_control(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  speech_energy : Double,
  size : Int32,
  alpha : Double,
  gain_mem : Ref[Double],
) -> Unit {
  let postfilter_energ = amr_dot(src, src_off, src, src_off, size)
  let mut gain_scale_factor = if postfilter_energ != 0.0 {
    (speech_energy / postfilter_energ).sqrt()
  } else {
    1.0
  }
  gain_scale_factor = gain_scale_factor * (1.0 - alpha)
  let mut mem = gain_mem.val
  for i = 0; i < size; i = i + 1 {
    mem = alpha * mem + gain_scale_factor
    out[out_off + i] = src[src_off + i] * mem
  }
  gain_mem.val = mem
}

///|
/// `ff_tilt_compensation`.
fn amr_tilt_compensation(
  samples : Array[Double],
  off : Int32,
  mem : Ref[Double],
  tilt : Double,
  size : Int32,
) -> Unit {
  let new_tilt_mem = samples[off + size - 1]
  let mut i = size - 1
  while i > 0 {
    samples[off + i] = samples[off + i] - tilt * samples[off + i - 1]
    i = i - 1
  }
  samples[off] = samples[off] - tilt * mem.val
  mem.val = new_tilt_mem
}

///|
/// `ff_acelp_apply_order_2_transfer_function`.
fn amr_apply_order_2(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  zeros : FixedArray[Double],
  poles : FixedArray[Double],
  gain : Double,
  mem : Array[Double],
) -> Unit {
  for i = 0; i < amr_block_size; i = i + 1 {
    let tmp = gain * src[src_off + i] - poles[0] * mem[0] - poles[1] * mem[1]
    out[out_off + i] = tmp + zeros[0] * mem[0] + zeros[1] * mem[1]
    mem[1] = mem[0]
    mem[0] = tmp
  }
}

// ---------------------------------------------------------------------------
// AMR fixed (algebraic) codebook
// ---------------------------------------------------------------------------

///|
/// `AMRFixed`: sparse pulse positions and values.
priv struct AmrFixed {
  x : FixedArray[Int32]
  y : FixedArray[Double]
  mut n : Int32
  mut pitch_lag : Int32
  mut pitch_fac : Double
  mut no_repeat_mask : Int32
}

///|
fn amr_fixed_new() -> AmrFixed {
  {
    x: FixedArray::make(10, 0),
    y: FixedArray::make(10, 0.0),
    n: 0,
    pitch_lag: 0,
    pitch_fac: 0.0,
    no_repeat_mask: 0,
  }
}

///|
/// `ff_set_fixed_vector`: `out[off..]` accumulates the pulses, repeating at
/// `pitch_lag` with pitch sharpening `pitch_fac`.
fn amr_set_fixed_vector(
  out : Array[Double],
  off : Int32,
  fixed : AmrFixed,
  scale : Double,
  size : Int32,
) -> Unit {
  for i = 0; i < fixed.n; i = i + 1 {
    let mut x = fixed.x[i]
    let repeats = ((fixed.no_repeat_mask >> i) & 1) == 0
    let mut y = fixed.y[i] * scale
    if fixed.pitch_lag > 0 {
      let mut first = true
      while x < size && (first || repeats) {
        out[off + x] = out[off + x] + y
        y = y * fixed.pitch_fac
        x = x + fixed.pitch_lag
        first = false
      }
    }
  }
}

///|
/// `ff_clear_fixed_vector`.
fn amr_clear_fixed_vector(
  out : Array[Double],
  off : Int32,
  fixed : AmrFixed,
  size : Int32,
) -> Unit {
  for i = 0; i < fixed.n; i = i + 1 {
    let mut x = fixed.x[i]
    let repeats = ((fixed.no_repeat_mask >> i) & 1) == 0
    if fixed.pitch_lag > 0 {
      let mut first = true
      while x < size && (first || repeats) {
        out[off + x] = 0.0
        x = x + fixed.pitch_lag
        first = false
      }
    }
  }
}

// ---------------------------------------------------------------------------
// decoder state
// ---------------------------------------------------------------------------

///|
/// Persistent AMR-NB decoder state (one 8 kHz mono channel).
pub struct AmrNbDecoder {
  mut bad_frame : Bool
  mut mode : Int32
  prev_lsf_r : FixedArray[Int32]
  lsp : Array[Array[Double]]
  prev_lsp_sub4 : Array[Double]
  lsf_q : Array[Array[Double]]
  lsf_avg : Array[Double]
  lpc : Array[Array[Double]]
  mut pitch_lag_int : Int32
  excitation_buf : Array[Double]
  pitch_vector : Array[Double]
  fixed_vector : Array[Double]
  prediction_error : Array[Double]
  pitch_gain : Array[Double]
  fixed_gain : Array[Double]
  mut beta : Double
  mut diff_count : Int32
  mut hang_count : Int32
  mut prev_sparse_fixed_gain : Double
  mut prev_ir_filter_nr : Int32
  mut ir_filter_onset : Int32
  postfilter_mem : Array[Double]
  mut tilt_mem : Double
  mut postfilter_agc : Double
  high_pass_mem : Array[Double]
  samples_in : Array[Double]
}

///|
let amr_excitation_off : Int32 = amr_pitch_delay_max + amr_lp_order + 1

///|
pub fn amrnb_decoder_new() -> AmrNbDecoder {
  let lsp : Array[Array[Double]] = []
  let lsf_q : Array[Array[Double]] = []
  let lpc : Array[Array[Double]] = []
  for _k = 0; _k < 4; _k = _k + 1 {
    lsp.push(Array::make(amr_lp_order, 0.0))
    lsf_q.push(Array::make(amr_lp_order, 0.0))
    lpc.push(Array::make(amr_lp_order, 0.0))
  }
  let prev_lsp_sub4 : Array[Double] = Array::make(amr_lp_order, 0.0)
  let lsf_avg : Array[Double] = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    prev_lsp_sub4[i] = amr_lsp_sub4_init[i].to_double() * 1000.0 / 32768.0
    lsf_avg[i] = amr_lsp_avg_init[i].to_double() / 32768.0
    lsf_q[3][i] = lsf_avg[i]
  }
  let prediction_error : Array[Double] = Array::make(4, amr_min_energy)
  {
    bad_frame: false,
    mode: 15,
    prev_lsf_r: FixedArray::make(amr_lp_order, 0),
    lsp,
    prev_lsp_sub4,
    lsf_q,
    lsf_avg,
    lpc,
    pitch_lag_int: 0,
    excitation_buf: Array::make(
      amr_pitch_delay_max + amr_lp_order + 1 + amr_subframe_size,
      0.0,
    ),
    pitch_vector: Array::make(amr_subframe_size, 0.0),
    fixed_vector: Array::make(amr_subframe_size, 0.0),
    prediction_error,
    pitch_gain: Array::make(5, 0.0),
    fixed_gain: Array::make(5, 0.0),
    beta: 0.0,
    diff_count: 0,
    hang_count: 0,
    prev_sparse_fixed_gain: 0.0,
    prev_ir_filter_nr: 0,
    ir_filter_onset: 0,
    postfilter_mem: Array::make(amr_lp_order, 0.0),
    tilt_mem: 0.0,
    postfilter_agc: 0.0,
    high_pass_mem: Array::make(2, 0.0),
    samples_in: Array::make(amr_lp_order + amr_subframe_size, 0.0),
  }
}

// ---------------------------------------------------------------------------
// bitstream unpacking
// ---------------------------------------------------------------------------

///|
/// One order table lookup src `ff_amr_bit_reorder` format.
fn amr_unpack_words(
  table : FixedArray[Int32],
  data : Bytes,
) -> FixedArray[Int32] {
  let words = FixedArray::make(57, 0)
  let mut t = 0
  while table[t] != 0 {
    let field_size = table[t]
    let field_offset = table[t + 1]
    t = t + 2
    let mut field = 0
    for _b = 0; _b < field_size; _b = _b + 1 {
      let bit = table[t]
      t = t + 1
      field = field << 1
      field = field | ((data[bit >> 3].to_int() >> (bit & 7)) & 1)
    }
    words[field_offset >> 1] = field
  }
  words
}

///|
fn amr_order_table(mode : Int32) -> FixedArray[Int32] {
  match mode {
    0 => amr_order_mode_4k75
    1 => amr_order_mode_5k15
    2 => amr_order_mode_5k9
    3 => amr_order_mode_6k7
    4 => amr_order_mode_7k4
    5 => amr_order_mode_7k95
    6 => amr_order_mode_10k2
    _ => amr_order_mode_12k2
  }
}

///|
fn amr_word(words : FixedArray[Int32], idx : Int32) -> Int32 {
  words[idx]
}

// ---------------------------------------------------------------------------
// LSF / LSP decoding
// ---------------------------------------------------------------------------

///|
/// `interpolate_lsf`: the old subframe-4 LSFs are read while rows are
/// overwritten, so snapshot them first.
fn AmrNbDecoder::interpolate_lsf(
  self : AmrNbDecoder,
  lsf_new : Array[Double],
) -> Unit {
  let old = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    old[i] = self.lsf_q[3][i]
  }
  for i = 0; i < 4; i = i + 1 {
    amr_weighted_vector_sum(
      self.lsf_q[i],
      0,
      old,
      0,
      lsf_new,
      0,
      0.25 * (3 - i).to_double(),
      0.25 * (i + 1).to_double(),
      amr_lp_order,
    )
  }
}

///|
/// `lsf2lsp_for_mode12k2`.
fn AmrNbDecoder::lsf2lsp_for_mode12k2(
  self : AmrNbDecoder,
  lsp : Array[Double],
  lsf_no_r : Array[Double],
  quant_rows : Array[Array[Int32]],
  quantizer_offset : Int32,
  sign : Int32,
  update : Bool,
) -> Unit {
  let lsf_r : Array[Int32] = Array::make(amr_lp_order, 0)
  for i = 0; i < amr_lp_order / 2; i = i + 1 {
    lsf_r[2 * i] = quant_rows[i][quantizer_offset]
    lsf_r[2 * i + 1] = quant_rows[i][quantizer_offset + 1]
  }
  if sign != 0 {
    lsf_r[4] = -lsf_r[4]
    lsf_r[5] = -lsf_r[5]
  }
  if update {
    for i = 0; i < amr_lp_order; i = i + 1 {
      self.prev_lsf_r[i] = lsf_r[i]
    }
  }
  let lsf_q : Array[Double] = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    lsf_q[i] = lsf_r[i].to_double() * (amr_lsf_r_fac / 8000.0) +
      lsf_no_r[i] * (1.0 / 8000.0)
  }
  amr_set_min_dist_lsf(lsf_q, amr_min_lsf_spacing)
  if update {
    self.interpolate_lsf(lsf_q)
  }
  amr_lsf2lspd(lsp, lsf_q)
}

///|
fn amr_row3(table : FixedArray[Int32], idx : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for i = 0; i < 3; i = i + 1 {
    out.push(table[idx * 3 + i])
  }
  out
}

///|
fn amr_row4(table : FixedArray[Int32], idx : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  for i = 0; i < 4; i = i + 1 {
    out.push(table[idx * 4 + i])
  }
  out
}

///|
/// `lsf2lsp_5` (12.2 kbit/s).
fn AmrNbDecoder::lsf2lsp_5(
  self : AmrNbDecoder,
  words : FixedArray[Int32],
) -> Unit {
  let lsf_param = [
    amr_word(words, 0),
    amr_word(words, 1),
    amr_word(words, 2),
    amr_word(words, 3),
    amr_word(words, 4),
  ]
  let lsf_no_r : Array[Double] = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    lsf_no_r[i] = self.prev_lsf_r[i].to_double() *
      amr_lsf_r_fac *
      amr_pred_fac_mode_12k2 +
      amr_lsf_5_mean[i]
  }
  let rows : Array[Array[Int32]] = [
    amr_row4(amr_lsf_5_1, lsf_param[0]),
    amr_row4(amr_lsf_5_2, lsf_param[1]),
    amr_row4(amr_lsf_5_3, lsf_param[2] / 2),
    amr_row4(amr_lsf_5_4, lsf_param[3]),
    amr_row4(amr_lsf_5_5, lsf_param[4]),
  ]
  let sign = lsf_param[2] & 1
  self.lsf2lsp_for_mode12k2(self.lsp[1], lsf_no_r, rows, 0, sign, false)
  self.lsf2lsp_for_mode12k2(self.lsp[3], lsf_no_r, rows, 2, sign, true)
  amr_weighted_vector_sum(
    self.lsp[0],
    0,
    self.prev_lsp_sub4,
    0,
    self.lsp[1],
    0,
    0.5,
    0.5,
    amr_lp_order,
  )
  amr_weighted_vector_sum(
    self.lsp[2],
    0,
    self.lsp[1],
    0,
    self.lsp[3],
    0,
    0.5,
    0.5,
    amr_lp_order,
  )
}

///|
/// `lsf2lsp_3` (all modes below 12.2 kbit/s).
fn AmrNbDecoder::lsf2lsp_3(
  self : AmrNbDecoder,
  words : FixedArray[Int32],
) -> Unit {
  let lsf_param = [amr_word(words, 0), amr_word(words, 1), amr_word(words, 2)]
  let lsf_r : Array[Int32] = Array::make(amr_lp_order, 0)
  let table1 = if self.mode == amr_mode_7k95 {
    amr_lsf_3_1_MODE_7k95
  } else {
    amr_lsf_3_1
  }
  let row1 = amr_row3(table1, lsf_param[0])
  for i = 0; i < 3; i = i + 1 {
    lsf_r[i] = row1[i]
  }
  let idx2 = lsf_param[1] << (if self.mode <= amr_mode_5k15 { 1 } else { 0 })
  let row2 = amr_row3(amr_lsf_3_2, idx2)
  for i = 0; i < 3; i = i + 1 {
    lsf_r[3 + i] = row2[i]
  }
  let table3 = if self.mode <= amr_mode_5k15 {
    amr_lsf_3_3_MODE_5k15
  } else {
    amr_lsf_3_3
  }
  let row3 = amr_row4(table3, lsf_param[2])
  for i = 0; i < 4; i = i + 1 {
    lsf_r[6 + i] = row3[i]
  }
  let lsf_q : Array[Double] = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    lsf_q[i] = (
        lsf_r[i].to_double() + self.prev_lsf_r[i].to_double() * amr_pred_fac[i]
      ) *
      (amr_lsf_r_fac / 8000.0) +
      amr_lsf_3_mean[i] * (1.0 / 8000.0)
  }
  amr_set_min_dist_lsf(lsf_q, amr_min_lsf_spacing)
  self.interpolate_lsf(lsf_q)
  for i = 0; i < amr_lp_order; i = i + 1 {
    self.prev_lsf_r[i] = lsf_r[i]
  }
  amr_lsf2lspd(self.lsp[3], lsf_q)
  for i = 1; i <= 3; i = i + 1 {
    for j = 0; j < amr_lp_order; j = j + 1 {
      self.lsp[i - 1][j] = self.prev_lsp_sub4[j] +
        (self.lsp[3][j] - self.prev_lsp_sub4[j]) * 0.25 * i.to_double()
    }
  }
}

// ---------------------------------------------------------------------------
// pitch
// ---------------------------------------------------------------------------

///|
/// `decode_pitch_lag_1_6`: 12.2 kbit/s 1/6 resolution.
fn amr_decode_pitch_lag_1_6(
  lag_int : Ref[Int32],
  lag_frac : Ref[Int32],
  pitch_index : Int32,
  prev_lag_int : Int32,
  subframe : Int32,
) -> Unit {
  if subframe == 0 || subframe == 2 {
    if pitch_index < 463 {
      lag_int.val = ((pitch_index + 107) * 10923) >> 16
      lag_frac.val = pitch_index - lag_int.val * 6 + 105
    } else {
      lag_int.val = pitch_index - 368
      lag_frac.val = 0
    }
  } else {
    lag_int.val = (((pitch_index + 5) * 10923) >> 16) - 1
    lag_frac.val = pitch_index - lag_int.val * 6 - 3
    lag_int.val = lag_int.val +
      amr_clip_int(
        prev_lag_int - 5,
        amr_pitch_lag_min_mode_12k2,
        amr_pitch_delay_max - 9,
      )
  }
}

///|
/// `ff_decode_pitch_lag` (3GPP 1/3 resolution, possibly integer-only for the
/// 4-bit modes).
fn amr_decode_pitch_lag(
  lag_int : Ref[Int32],
  lag_frac : Ref[Int32],
  pitch_index_in : Int32,
  prev_lag_int : Int32,
  subframe : Int32,
  third_as_first : Bool,
  resolution : Int32,
) -> Unit {
  let mut pitch_index = pitch_index_in
  if subframe == 0 || (subframe == 2 && third_as_first) {
    if pitch_index < 197 {
      pitch_index = pitch_index + 59
    } else {
      pitch_index = 3 * pitch_index - 335
    }
  } else if resolution == 4 {
    let search_range_min = amr_clip_int(
      prev_lag_int - 5,
      amr_pitch_delay_min,
      amr_pitch_delay_max - 9,
    )
    if pitch_index < 4 {
      pitch_index = 3 * (pitch_index + search_range_min) + 1
    } else if pitch_index < 12 {
      pitch_index = pitch_index + 3 * search_range_min + 7
    } else {
      pitch_index = 3 * (pitch_index + search_range_min - 6) + 1
    }
  } else {
    pitch_index = pitch_index - 1
    if resolution == 5 {
      pitch_index = pitch_index +
        3 *
        amr_clip_int(
          prev_lag_int - 10,
          amr_pitch_delay_min,
          amr_pitch_delay_max - 19,
        )
    } else {
      pitch_index = pitch_index +
        3 *
        amr_clip_int(
          prev_lag_int - 5,
          amr_pitch_delay_min,
          amr_pitch_delay_max - 9,
        )
    }
  }
  lag_int.val = (pitch_index * 10923) >> 15
  lag_frac.val = pitch_index - 3 * lag_int.val - 1
}

///|
/// `decode_pitch_vector`: interpolate the past excitation at the pitch lag.
fn AmrNbDecoder::decode_pitch_vector(
  self : AmrNbDecoder,
  words : FixedArray[Int32],
  subframe : Int32,
) -> Unit {
  let sub = 5 + 13 * subframe
  let p_lag = amr_word(words, sub)
  let lag_int : Ref[Int32] = { val: 0, }
  let lag_frac : Ref[Int32] = { val: 0, }
  if self.mode == amr_mode_12k2 {
    amr_decode_pitch_lag_1_6(
      lag_int,
      lag_frac,
      p_lag,
      self.pitch_lag_int,
      subframe,
    )
  } else {
    let third_as_first = self.mode != amr_mode_4k75 &&
      self.mode != amr_mode_5k15
    let resolution = if self.mode <= amr_mode_6k7 {
      4
    } else if self.mode == amr_mode_7k95 {
      5
    } else {
      6
    }
    amr_decode_pitch_lag(
      lag_int,
      lag_frac,
      p_lag,
      self.pitch_lag_int,
      subframe,
      third_as_first,
      resolution,
    )
    lag_frac.val = lag_frac.val * 2
  }
  self.pitch_lag_int = lag_int.val
  if lag_frac.val > 0 {
    lag_int.val = lag_int.val + 1
  }
  let frac_pos = lag_frac.val + 6 - 6 * (if lag_frac.val > 0 { 1 } else { 0 })
  amr_acelp_interpolatef(
    self.excitation_buf,
    amr_excitation_off,
    self.excitation_buf,
    amr_excitation_off + 1 - lag_int.val,
    amr_b60_sinc,
    6,
    frac_pos,
    10,
    amr_subframe_size,
  )
  for i = 0; i < amr_subframe_size; i = i + 1 {
    self.pitch_vector[i] = self.excitation_buf[amr_excitation_off + i]
  }
}

// ---------------------------------------------------------------------------
// algebraic codebook
// ---------------------------------------------------------------------------

///|
fn amr_decode_10bit_pulse(
  code : Int32,
  positions : FixedArray[Int32],
  i1 : Int32,
  i2 : Int32,
  i3 : Int32,
) -> Unit {
  let p = (code >> 3) * 3
  positions[i1] = (amr_base_five_table[p + 2] << 1) + (code & 1)
  positions[i2] = (amr_base_five_table[p + 1] << 1) + ((code >> 1) & 1)
  positions[i3] = (amr_base_five_table[p] << 1) + ((code >> 2) & 1)
}

///|
fn amr_decode_8_pulses_31bits(
  words : FixedArray[Int32],
  sub : Int32,
  fixed : AmrFixed,
) -> Unit {
  let fixed_index : Array[Int32] = []
  for i = 0; i < 7; i = i + 1 {
    fixed_index.push(amr_word(words, sub + 3 + i))
  }
  let pulse_position = FixedArray::make(8, 0)
  amr_decode_10bit_pulse(fixed_index[4], pulse_position, 0, 4, 1)
  amr_decode_10bit_pulse(fixed_index[5], pulse_position, 2, 6, 5)
  let temp = ((fixed_index[6] >> 2) * 25 + 12) >> 5
  pulse_position[3] = temp % 5
  pulse_position[7] = temp / 5
  if (pulse_position[7] & 1) != 0 {
    pulse_position[3] = 4 - pulse_position[3]
  }
  pulse_position[3] = (pulse_position[3] << 1) + (fixed_index[6] & 1)
  pulse_position[7] = (pulse_position[7] << 1) + ((fixed_index[6] >> 1) & 1)
  fixed.n = 8
  for i = 0; i < 4; i = i + 1 {
    let pos1 = (pulse_position[i] << 2) + i
    let pos2 = (pulse_position[i + 4] << 2) + i
    let sign = if fixed_index[i] != 0 { -1.0 } else { 1.0 }
    fixed.x[i] = pos1
    fixed.x[i + 4] = pos2
    fixed.y[i] = sign
    fixed.y[i + 4] = if pos2 < pos1 { -sign } else { sign }
  }
}

///|
/// `ff_decode_10_pulses_35bits` (12.2 kbit/s).
fn amr_decode_10_pulses_35bits(
  words : FixedArray[Int32],
  sub : Int32,
  fixed : AmrFixed,
) -> Unit {
  let bits = 3
  let half_pulse_count = 5
  let mask = (1 << bits) - 1
  fixed.no_repeat_mask = 0
  fixed.n = 2 * half_pulse_count
  for i = 0; i < half_pulse_count; i = i + 1 {
    let f1 = amr_word(words, sub + 3 + 2 * i + 1)
    let f0 = amr_word(words, sub + 3 + 2 * i)
    let pos1 = amr_gray_decode[f1 & mask] + i
    let pos2 = amr_gray_decode[f0 & mask] + i
    let sign = if (f1 & (1 << bits)) != 0 { -1.0 } else { 1.0 }
    fixed.x[2 * i + 1] = pos1
    fixed.x[2 * i] = pos2
    fixed.y[2 * i + 1] = sign
    fixed.y[2 * i] = if pos2 < pos1 { -sign } else { sign }
  }
}

///|
/// `decode_fixed_sparse`.
fn amr_decode_fixed_sparse(
  words : FixedArray[Int32],
  mode : Int32,
  subframe : Int32,
  fixed : AmrFixed,
) -> Unit {
  let sub = 5 + 13 * subframe
  if mode == amr_mode_12k2 {
    amr_decode_10_pulses_35bits(words, sub, fixed)
  } else if mode == amr_mode_10k2 {
    amr_decode_8_pulses_31bits(words, sub, fixed)
  } else {
    let fixed_index = amr_word(words, sub + 3)
    let position = fixed.x
    if mode <= amr_mode_5k15 {
      let pulse_subset = ((fixed_index >> 3) & 8) + (subframe << 1)
      position[0] = (fixed_index & 7) * 5 + amr_track_position[pulse_subset]
      position[1] = ((fixed_index >> 3) & 7) * 5 +
        amr_track_position[pulse_subset + 1]
      fixed.n = 2
    } else if mode == amr_mode_5k9 {
      let mut pulse_subset = ((fixed_index & 1) << 1) + 1
      position[0] = ((fixed_index >> 1) & 7) * 5 + pulse_subset
      pulse_subset = (fixed_index >> 4) & 3
      position[1] = ((fixed_index >> 6) & 7) * 5 +
        pulse_subset +
        (if pulse_subset == 3 { 1 } else { 0 })
      fixed.n = if position[0] == position[1] { 1 } else { 2 }
    } else if mode == amr_mode_6k7 {
      position[0] = (fixed_index & 7) * 5
      let mut pulse_subset = (fixed_index >> 2) & 2
      position[1] = ((fixed_index >> 4) & 7) * 5 + pulse_subset + 1
      pulse_subset = (fixed_index >> 6) & 2
      position[2] = ((fixed_index >> 8) & 7) * 5 + pulse_subset + 2
      fixed.n = 3
    } else {
      position[0] = amr_gray_decode[fixed_index & 7]
      position[1] = amr_gray_decode[(fixed_index >> 3) & 7] + 1
      position[2] = amr_gray_decode[(fixed_index >> 6) & 7] + 2
      let pulse_subset = (fixed_index >> 9) & 1
      position[3] = amr_gray_decode[(fixed_index >> 10) & 7] + pulse_subset + 3
      fixed.n = 4
    }
    let signs = amr_word(words, sub + 4)
    for i = 0; i < fixed.n; i = i + 1 {
      fixed.y[i] = if ((signs >> i) & 1) != 0 { 1.0 } else { -1.0 }
    }
  }
}

// ---------------------------------------------------------------------------
// gains
// ---------------------------------------------------------------------------

///|
fn AmrNbDecoder::decode_gains(
  self : AmrNbDecoder,
  words : FixedArray[Int32],
  subframe : Int32,
  fixed_gain_factor : Ref[Double],
) -> Unit {
  let sub = 5 + 13 * subframe
  let p_gain = amr_word(words, sub + 1)
  if self.mode == amr_mode_12k2 || self.mode == amr_mode_7k95 {
    let fixed_gain = amr_word(words, sub + 2)
    self.pitch_gain[4] = amr_qua_gain_pit[p_gain].to_double() * (1.0 / 16384.0)
    fixed_gain_factor.val = amr_qua_gain_code[fixed_gain].to_double() *
      (1.0 / 2048.0)
  } else {
    let pg = amr_word(words, 5 + 13 * (subframe & 2) + 1)
    let table = if self.mode >= amr_mode_6k7 {
      amr_gains_high
    } else if self.mode >= amr_mode_5k15 {
      amr_gains_low
    } else {
      amr_gains_mode_4k75
    }
    let base = if self.mode >= amr_mode_5k15 {
      p_gain * 2
    } else {
      ((pg << 1) + (subframe & 1)) * 2
    }
    self.pitch_gain[4] = table[base].to_double() * (1.0 / 16384.0)
    fixed_gain_factor.val = table[base + 1].to_double() * (1.0 / 4096.0)
  }
}

///|
fn AmrNbDecoder::fixed_gain_smooth(
  self : AmrNbDecoder,
  lsf : Array[Double],
) -> Double {
  let mut diff = 0.0
  for i = 0; i < amr_lp_order; i = i + 1 {
    diff = diff + (self.lsf_avg[i] - lsf[i]).abs() / self.lsf_avg[i]
  }
  self.diff_count = self.diff_count + 1
  if diff <= 0.65 {
    self.diff_count = 0
  }
  if self.diff_count > 10 {
    self.hang_count = 0
    self.diff_count = self.diff_count - 1
  }
  if self.hang_count < 40 {
    self.hang_count = self.hang_count + 1
  } else if self.mode < amr_mode_7k4 || self.mode == amr_mode_10k2 {
    let smoothing_factor = amr_clipf(4.0 * diff - 1.6, 0.0, 1.0)
    let fixed_gain_mean = (
        self.fixed_gain[0] +
        self.fixed_gain[1] +
        self.fixed_gain[2] +
        self.fixed_gain[3] +
        self.fixed_gain[4]
      ) *
      0.2
    return smoothing_factor * self.fixed_gain[4] +
      (1.0 - smoothing_factor) * fixed_gain_mean
  }
  self.fixed_gain[4]
}

///|
/// `ff_amr_set_fixed_gain`.
fn amr_set_fixed_gain(
  fixed_gain_factor : Double,
  fixed_mean_energy : Double,
  prediction_error : Array[Double],
  energy_mean : Double,
  pred_table : FixedArray[Double],
) -> Double {
  let pred = pred_table[0] * prediction_error[0] +
    pred_table[1] * prediction_error[1] +
    pred_table[2] * prediction_error[2] +
    pred_table[3] * prediction_error[3]
  let denom = if fixed_mean_energy != 0.0 { fixed_mean_energy } else { 1.0 }
  let val = fixed_gain_factor *
    @math.pow(10.0, 0.05 * (pred + energy_mean)) /
    denom.sqrt()
  prediction_error[0] = prediction_error[1]
  prediction_error[1] = prediction_error[2]
  prediction_error[2] = prediction_error[3]
  prediction_error[3] = 20.0 * @math.log10(fixed_gain_factor)
  val
}

// ---------------------------------------------------------------------------
// anti-sparseness
// ---------------------------------------------------------------------------

///|
/// `apply_ir_filter`.
fn amr_apply_ir_filter(
  out : Array[Double],
  fixed : AmrFixed,
  filter : Array[Double],
) -> Unit {
  let filter1 : Array[Double] = Array::make(amr_subframe_size, 0.0)
  let filter2 : Array[Double] = Array::make(amr_subframe_size, 0.0)
  let lag = fixed.pitch_lag
  let fac = fixed.pitch_fac
  if lag < amr_subframe_size {
    amr_celp_circ_addf(
      filter1, 0, filter, 0, filter, 0, lag, fac, amr_subframe_size,
    )
    if lag < amr_subframe_size / 2 {
      amr_celp_circ_addf(
        filter2, 0, filter, 0, filter1, 0, lag, fac, amr_subframe_size,
      )
    }
  }
  for i = 0; i < amr_subframe_size; i = i + 1 {
    out[i] = 0.0
  }
  for i = 0; i < fixed.n; i = i + 1 {
    let x = fixed.x[i]
    let y = fixed.y[i]
    let use_filter = if x >= amr_subframe_size - lag {
      0
    } else if x >= amr_subframe_size - (lag << 1) {
      1
    } else {
      2
    }
    if use_filter == 0 {
      amr_celp_circ_addf(out, 0, out, 0, filter, 0, x, y, amr_subframe_size)
    } else if use_filter == 1 {
      amr_celp_circ_addf(out, 0, out, 0, filter1, 0, x, y, amr_subframe_size)
    } else {
      amr_celp_circ_addf(out, 0, out, 0, filter2, 0, x, y, amr_subframe_size)
    }
  }
}

///|
/// `anti_sparseness`: returns true when the filtered `out` vector is used.
fn AmrNbDecoder::anti_sparseness(
  self : AmrNbDecoder,
  fixed : AmrFixed,
  fixed_gain : Double,
  out : Array[Double],
) -> Bool {
  let mut ir_filter_nr = if self.pitch_gain[4] < 0.6 {
    0
  } else if self.pitch_gain[4] < 0.9 {
    1
  } else {
    2
  }
  if fixed_gain > 2.0 * self.prev_sparse_fixed_gain {
    self.ir_filter_onset = 2
  } else if self.ir_filter_onset > 0 {
    self.ir_filter_onset = self.ir_filter_onset - 1
  }
  if self.ir_filter_onset == 0 {
    let mut count = 0
    for i = 0; i < 5; i = i + 1 {
      if self.pitch_gain[i] < 0.6 {
        count = count + 1
      }
    }
    if count > 2 {
      ir_filter_nr = 0
    }
    if ir_filter_nr > self.prev_ir_filter_nr + 1 {
      ir_filter_nr = ir_filter_nr - 1
    }
  } else if ir_filter_nr < 2 {
    ir_filter_nr = ir_filter_nr + 1
  }
  if fixed_gain < 5.0 {
    ir_filter_nr = 2
  }
  let mut use_out = false
  if self.mode != amr_mode_7k4 && self.mode < amr_mode_10k2 && ir_filter_nr < 2 {
    let source = if self.mode == amr_mode_7k95 {
      if ir_filter_nr == 0 {
        amr_ir_filter_strong_mode_795
      } else {
        amr_ir_filter_medium
      }
    } else if ir_filter_nr == 0 {
      amr_ir_filter_strong
    } else {
      amr_ir_filter_medium
    }
    let filter : Array[Double] = Array::make(amr_subframe_size, 0.0)
    for i = 0; i < amr_subframe_size; i = i + 1 {
      filter[i] = source[i]
    }
    amr_apply_ir_filter(out, fixed, filter)
    use_out = true
  }
  self.prev_ir_filter_nr = ir_filter_nr
  self.prev_sparse_fixed_gain = fixed_gain
  use_out
}

// ---------------------------------------------------------------------------
// synthesis and postfilter
// ---------------------------------------------------------------------------

///|
/// `pitch_sharpening`.
fn AmrNbDecoder::pitch_sharpening(
  self : AmrNbDecoder,
  fixed : AmrFixed,
  subframe : Int32,
) -> Unit {
  if self.mode == amr_mode_12k2 {
    self.beta = if self.pitch_gain[4] < 1.0 { self.pitch_gain[4] } else { 1.0 }
  }
  fixed.pitch_lag = self.pitch_lag_int
  fixed.pitch_fac = self.beta
  if self.mode != amr_mode_4k75 || (subframe & 1) != 0 {
    self.beta = amr_clipf(self.pitch_gain[4], 0.0, amr_sharp_max)
  }
}

///|
/// `synthesis`: returns true on overflow.
fn AmrNbDecoder::synthesis(
  self : AmrNbDecoder,
  lpc : Array[Double],
  fixed_gain : Double,
  fixed_vector : Array[Double],
  overflow : Bool,
) -> Bool {
  let excitation : Array[Double] = Array::make(amr_subframe_size, 0.0)
  if overflow {
    for i = 0; i < amr_subframe_size; i = i + 1 {
      self.pitch_vector[i] = self.pitch_vector[i] * 0.25
    }
  }
  amr_weighted_vector_sum(
    excitation,
    0,
    self.pitch_vector,
    0,
    fixed_vector,
    0,
    self.pitch_gain[4],
    fixed_gain,
    amr_subframe_size,
  )
  if self.pitch_gain[4] > 0.5 && !overflow {
    let energy = amr_dot(excitation, 0, excitation, 0, amr_subframe_size)
    let pitch_factor = if self.mode == amr_mode_12k2 {
      self.pitch_gain[4] *
      (0.25 * (if self.pitch_gain[4] < 1.0 { self.pitch_gain[4] } else { 1.0 }))
    } else {
      self.pitch_gain[4] *
      (
        0.5 *
        (if self.pitch_gain[4] < amr_sharp_max {
          self.pitch_gain[4]
        } else {
          amr_sharp_max
        })
      )
    }
    for i = 0; i < amr_subframe_size; i = i + 1 {
      excitation[i] = excitation[i] + pitch_factor * self.pitch_vector[i]
    }
    amr_scale_to_sum_of_squares(
      excitation, 0, excitation, 0, energy, amr_subframe_size,
    )
  }
  amr_celp_lp_synthesis_filterf(
    self.samples_in,
    amr_lp_order,
    excitation,
    0,
    lpc,
    amr_subframe_size,
    amr_lp_order,
  )
  for i = 0; i < amr_subframe_size; i = i + 1 {
    if self.samples_in[amr_lp_order + i].abs() > amr_sample_bound {
      return true
    }
  }
  false
}

///|
/// `tilt_factor`.
fn amr_tilt_factor(lpc_n : Array[Double], lpc_d : Array[Double]) -> Double {
  let impulse_buffer : Array[Double] = Array::make(
    amr_lp_order + amr_tilt_response,
    0.0,
  )
  let hf = amr_lp_order
  impulse_buffer[hf] = 1.0
  for i = 0; i < amr_lp_order; i = i + 1 {
    impulse_buffer[hf + 1 + i] = lpc_n[i]
  }
  amr_celp_lp_synthesis_filterf(
    impulse_buffer, hf, impulse_buffer, hf, lpc_d, amr_tilt_response, amr_lp_order,
  )
  let rh0 = amr_dot(impulse_buffer, hf, impulse_buffer, hf, amr_tilt_response)
  let rh1 = amr_dot(
    impulse_buffer,
    hf,
    impulse_buffer,
    hf + 1,
    amr_tilt_response - 1,
  )
  if rh1 >= 0.0 {
    rh1 / rh0 * amr_tilt_gamma_t
  } else {
    0.0
  }
}

///|
/// `postfilter`.
fn AmrNbDecoder::postfilter(
  self : AmrNbDecoder,
  lpc : Array[Double],
  buf_out : Array[Double],
  out_off : Int32,
) -> Unit {
  let samples = amr_lp_order
  let speech_gain = amr_dot(
    self.samples_in,
    samples,
    self.samples_in,
    samples,
    amr_subframe_size,
  )
  let gamma_n = if self.mode == amr_mode_12k2 || self.mode == amr_mode_10k2 {
    amr_pow_0_7
  } else {
    amr_pow_0_55
  }
  let gamma_d = if self.mode == amr_mode_12k2 || self.mode == amr_mode_10k2 {
    amr_pow_0_75
  } else {
    amr_pow_0_7
  }
  let lpc_n : Array[Double] = Array::make(amr_lp_order, 0.0)
  let lpc_d : Array[Double] = Array::make(amr_lp_order, 0.0)
  for i = 0; i < amr_lp_order; i = i + 1 {
    lpc_n[i] = lpc[i] * gamma_n[i]
    lpc_d[i] = lpc[i] * gamma_d[i]
  }
  let pole_out : Array[Double] = Array::make(
    amr_subframe_size + amr_lp_order,
    0.0,
  )
  for i = 0; i < amr_lp_order; i = i + 1 {
    pole_out[i] = self.postfilter_mem[i]
  }
  amr_celp_lp_synthesis_filterf(
    pole_out,
    amr_lp_order,
    self.samples_in,
    amr_lp_order,
    lpc_d,
    amr_subframe_size,
    amr_lp_order,
  )
  for i = 0; i < amr_lp_order; i = i + 1 {
    self.postfilter_mem[i] = pole_out[amr_subframe_size + i]
  }
  amr_celp_lp_zero_synthesis_filterf(
    buf_out, out_off, pole_out, amr_lp_order, lpc_n, amr_subframe_size, amr_lp_order,
  )
  let tilt_mem : Ref[Double] = { val: self.tilt_mem, }
  amr_tilt_compensation(
    buf_out,
    out_off,
    tilt_mem,
    amr_tilt_factor(lpc_n, lpc_d),
    amr_subframe_size,
  )
  self.tilt_mem = tilt_mem.val
  let agc : Ref[Double] = { val: self.postfilter_agc, }
  amr_adaptive_gain_control(
    buf_out, out_off, buf_out, out_off, speech_gain, amr_subframe_size, amr_agc_alpha,
    agc,
  )
  self.postfilter_agc = agc.val
}

///|
/// `update_state`.
fn AmrNbDecoder::update_state(self : AmrNbDecoder) -> Unit {
  for i = 0; i < amr_lp_order; i = i + 1 {
    self.prev_lsp_sub4[i] = self.lsp[3][i]
  }
  for i = 0; i < amr_pitch_delay_max + amr_lp_order + 1; i = i + 1 {
    self.excitation_buf[i] = self.excitation_buf[i + amr_subframe_size]
  }
  for i = 0; i < 4; i = i + 1 {
    self.pitch_gain[i] = self.pitch_gain[i + 1]
    self.fixed_gain[i] = self.fixed_gain[i + 1]
  }
  for i = 0; i < amr_lp_order; i = i + 1 {
    self.samples_in[i] = self.samples_in[i + amr_subframe_size]
  }
}

// ---------------------------------------------------------------------------
// frame decode
// ---------------------------------------------------------------------------

///|
/// `unpack_bitstream`: reads the RFC 4867 table of contents and reorders the
/// speech bits into 16-bit fields.
fn AmrNbDecoder::unpack_bitstream(
  self : AmrNbDecoder,
  data : Bytes,
) -> Result[Int32, String] {
  if data.length() < 1 {
    return Err("amr: empty frame")
  }
  let toc = data[0].to_int()
  let mode = (toc >> 3) & 0x0F
  self.bad_frame = (toc & 0x4) != 0x4
  if mode >= amr_n_modes || data.length() < amr_frame_sizes_nb[mode] + 1 {
    return Err("amr: corrupt bitstream")
  }
  self.mode = mode
  Ok(mode)
}

///|
/// Total byte size of one AMR-NB frame (TOC byte plus speech payload), or 0
/// when the TOC frame type is invalid.
pub fn amrnb_frame_size(frame : Bytes) -> Int32 {
  if frame.length() < 1 {
    return 0
  }
  let mode = (frame[0].to_int() >> 3) & 0x0F
  if mode >= amr_n_modes {
    return 0
  }
  1 + amr_frame_sizes_nb[mode]
}

///|
/// Decode one AMR-NB frame (TOC byte plus speech payload) to 160 samples.
pub fn AmrNbDecoder::decode_frame(
  self : AmrNbDecoder,
  data : Bytes,
) -> Result[Array[Double], String] {
  let mode = match self.unpack_bitstream(data) {
    Ok(m) => m
    Err(e) => return Err(e)
  }
  if mode == 8 {
    return Err("amr: DTX frames are not supported")
  }
  let table = amr_order_table(mode)
  let payload = data[1:].to_owned()
  let words = amr_unpack_words(table, payload)
  if mode == amr_mode_12k2 {
    self.lsf2lsp_5(words)
  } else {
    self.lsf2lsp_3(words)
  }
  for i = 0; i < 4; i = i + 1 {
    amr_lspd2lpc(self.lsp[i], self.lpc[i])
  }
  let buf_out : Array[Double] = Array::make(amr_block_size, 0.0)
  let fixed = amr_fixed_new()
  for subframe = 0; subframe < 4; subframe = subframe + 1 {
    self.decode_pitch_vector(words, subframe)
    amr_decode_fixed_sparse(words, self.mode, subframe, fixed)
    let fixed_gain_factor : Ref[Double] = { val: 0.0, }
    self.decode_gains(words, subframe, fixed_gain_factor)
    self.pitch_sharpening(fixed, subframe)
    if fixed.pitch_lag == 0 {
      return Err("amr: pitch lag 0 is not allowed")
    }
    amr_set_fixed_vector(self.fixed_vector, 0, fixed, 1.0, amr_subframe_size)
    let mean_energy = amr_dot(
        self.fixed_vector,
        0,
        self.fixed_vector,
        0,
        amr_subframe_size,
      ) /
      amr_subframe_size.to_double()
    self.fixed_gain[4] = amr_set_fixed_gain(
      fixed_gain_factor.val,
      mean_energy,
      self.prediction_error,
      amr_energy_mean[self.mode],
      amr_energy_pred_fac,
    )
    for i = 0; i < amr_subframe_size; i = i + 1 {
      self.excitation_buf[amr_excitation_off + i] = self.excitation_buf[amr_excitation_off +
        i] *
        self.pitch_gain[4]
    }
    amr_set_fixed_vector(
      self.excitation_buf,
      amr_excitation_off,
      fixed,
      self.fixed_gain[4],
      amr_subframe_size,
    )
    for i = 0; i < amr_subframe_size; i = i + 1 {
      self.excitation_buf[amr_excitation_off + i] = amr_trunc(
        self.excitation_buf[amr_excitation_off + i],
      )
    }
    let synth_fixed_gain = self.fixed_gain_smooth(self.lsf_q[subframe])
    let spare : Array[Double] = Array::make(amr_subframe_size, 0.0)
    let use_spare = self.anti_sparseness(fixed, synth_fixed_gain, spare)
    let synth_fixed_vector = if use_spare { spare } else { self.fixed_vector }
    if self.synthesis(
        self.lpc[subframe],
        synth_fixed_gain,
        synth_fixed_vector,
        false,
      ) {
      let _ = self.synthesis(
        self.lpc[subframe],
        synth_fixed_gain,
        synth_fixed_vector,
        true,
      )
    }
    self.postfilter(self.lpc[subframe], buf_out, subframe * amr_subframe_size)
    amr_clear_fixed_vector(self.fixed_vector, 0, fixed, amr_subframe_size)
    self.update_state()
  }
  let gain = amr_highpass_gain[0] * amr_sample_scale
  amr_apply_order_2(
    buf_out,
    0,
    buf_out,
    0,
    amr_highpass_zeros,
    amr_highpass_poles,
    gain,
    self.high_pass_mem,
  )
  amr_weighted_vector_sum(
    self.lsf_avg,
    0,
    self.lsf_avg,
    0,
    self.lsf_q[3],
    0,
    0.84,
    0.16,
    amr_lp_order,
  )
  Ok(buf_out)
}

///|
/// `truncf`: round toward zero.
fn amr_trunc(v : Double) -> Double {
  if v >= 0.0 {
    v.floor()
  } else {
    v.ceil()
  }
}
