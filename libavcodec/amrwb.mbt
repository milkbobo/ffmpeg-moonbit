///|
/// AMR-WB (Adaptive Multi-Rate WideBand) decoder, ported from FFmpeg
/// `libavcodec/amrwbdec.c` (LGPL-2.1-or-later) with the tables of
/// `amrwbdata.h` in `amrwb_tables.mbt`.
///
/// The C keeps most of its state in `float` and the ISP vectors in `double`;
/// this port evaluates the same pipeline in doubles throughout (the shared
/// ACELP helpers of `amr.mbt` do the same for AMR-NB). Against the C float
/// decoder the s16 output stays within one LSB, like AMR-NB.
///
/// Deviations from the C, all deliberate:
///
/// * One channel per decoder. The multichannel AMR files (`#!AMR_MC1.0`)
///   decode each channel with its own context in the C; the demuxer here
///   rejects them.
/// * A NO_DATA frame or a frame with the quality bit clear yields a silent
///   frame, as in the C (`av_samples_set_silence`); the C only logs it.
/// * The SID (comfort noise) mode is not implemented, as in the C
///   (`AVERROR_PATCHWELCOME`); it is an error here.

///|
/// LP_ORDER: linear predictive coding filter order.
let amrwb_lp_order : Int32 = 16

///|
/// LP_ORDER_16k: LPC filter order at 16 kHz (the high band).
let amrwb_lp_order_16k : Int32 = 20

///|
/// HB_FIR_SIZE: past samples the high-band FIR filters need.
let amrwb_hb_fir_size : Int32 = 30

///|
/// UPS_FIR_SIZE: upsampling filter size; UPS_MEM_SIZE is twice that.
let amrwb_ups_fir_size : Int32 = 12

///|
/// UPS_FIR_SIZE * 2.
let amrwb_ups_mem_size : Int32 = 24

///|
/// MIN_ISF_SPACING.
let amrwb_min_isf_spacing : Double = 128.0 / 32768.0

///|
/// PRED_FACTOR: ISF prediction factor.
let amrwb_pred_factor : Double = 1.0 / 3.0

///|
/// MIN_ENERGY: initial innovation energy (dB).
let amrwb_min_energy : Double = -14.0

///|
/// ENERGY_MEAN: mean innovation energy (dB) in all modes.
let amrwb_energy_mean : Double = 30.0

///|
/// PREEMPH_FAC.
let amrwb_preemph_fac : Double = 0.68

///|
/// AMRWB_SFR_SIZE: samples per subframe at 12.8 kHz.
let amrwb_sfr_size : Int32 = 64

///|
/// AMRWB_SFR_SIZE_16k: samples per subframe at 16 kHz.
let amrwb_sfr_size_16k : Int32 = 80

///|
/// AMRWB_P_DELAY_MAX.
let amrwb_p_delay_max : Int32 = 231

///|
/// AMRWB_P_DELAY_MIN.
let amrwb_p_delay_min : Int32 = 34

///|
/// MODE_8k85 (the first mode after MODE_6k60).
let amrwb_mode_6k60 : Int32 = 0

///|
/// MODE_8k85.
let amrwb_mode_8k85 : Int32 = 1

///|
/// MODE_SID: comfort noise frame.
let amrwb_mode_sid : Int32 = 9

///|
/// NO_DATA.
let amrwb_no_data : Int32 = 15

///|
/// Where the current excitation starts inside `excitation_buf`
/// (`AMRWB_P_DELAY_MAX + LP_ORDER + 1`).
let amrwb_excitation_off : Int32 = amrwb_p_delay_max + amrwb_lp_order + 1

///|
/// `amrwb_packed_size` of `amr_parser.c` / `amr.c`: the whole RFC 4867
/// frame (table-of-contents byte plus speech payload) per frame type.
let amrwb_packed_size : FixedArray[Int32] = [
  18, 24, 33, 37, 41, 47, 51, 59, 61, 6, 1, 1, 1, 1, 1, 1,
]

///|
/// Port of `AMRWBContext`: one decoder per (mono) channel.
pub struct AmrWbDecoder {
  /// Mode index of the current frame.
  mut fr_cur_mode : Int32
  /// Frame quality bit (FQI) of the current frame's header.
  mut fr_quality : Bool
  /// Working ISF vector from the current frame.
  isf_cur : Array[Double]
  /// Quantized ISF vector of the previous frame.
  isf_q_past : Array[Double]
  /// Final processed ISF vector of the previous frame.
  isf_past_final : Array[Double]
  /// ISP vectors from the current frame, one per subframe.
  isp : Array[Array[Double]]
  /// ISP vector of the 4th subframe of the previous frame.
  isp_sub4_past : Array[Double]
  /// Linear prediction coefficients per subframe.
  lp_coef : Array[Array[Double]]
  /// Integer part of the pitch lag for the next relative subframe.
  mut base_pitch_lag : Int32
  /// Integer part of the pitch lag of the previous subframe.
  mut pitch_lag_int : Int32
  /// Current excitation (at `amrwb_excitation_off`) and its history.
  excitation_buf : Array[Double]
  /// Adaptive codebook (pitch) vector of the current subframe.
  pitch_vector : Array[Double]
  /// Algebraic codebook (fixed) vector of the current subframe.
  fixed_vector : Array[Double]
  /// Quantized prediction errors {20log10(^gamma_gc)} of the last four
  /// subframes.
  prediction_error : Array[Double]
  /// Pitch gains of the current and the previous five subframes.
  pitch_gain : Array[Double]
  /// Fixed gains of the current and the previous subframe.
  fixed_gain : Array[Double]
  /// {beta_1}: voicing of the previous subframe.
  mut tilt_coef : Double
  /// Previous impulse response filter: 0 strong, 1 medium, 2 none.
  mut prev_ir_filter_nr : Int32
  /// Previous threshold gain of the noise enhancer.
  mut prev_tr_gain : Double
  /// Low-band samples and memory from synthesis at 12.8 kHz.
  samples_az : Array[Double]
  /// Low-band samples and memory processed for upsampling.
  samples_up : Array[Double]
  /// High-band samples and memory from synthesis at 16 kHz.
  samples_hb : Array[Double]
  hpf_31_mem : Array[Double]
  hpf_400_mem : Array[Double]
  demph_mem : Array[Double]
  bpf_6_7_mem : Array[Double]
  lpf_7_mem : Array[Double]
  /// `AVLFG` for the white noise excitation.
  prng : Ac3Lfg
  mut first_frame : Bool
}

///|
/// `amrwb_decode_init`.
pub fn amrwb_decoder_new() -> AmrWbDecoder {
  let isf_past_final = Array::makei(amrwb_lp_order, i => amrwb_isf_init[i].to_double() / 32768.0)
  {
    fr_cur_mode: 0,
    fr_quality: false,
    isf_cur: Array::make(amrwb_lp_order, 0.0),
    isf_q_past: Array::make(amrwb_lp_order, 0.0),
    isf_past_final,
    isp: Array::makei(4, _ => Array::make(amrwb_lp_order, 0.0)),
    isp_sub4_past: Array::make(amrwb_lp_order, 0.0),
    lp_coef: Array::makei(4, _ => Array::make(amrwb_lp_order, 0.0)),
    base_pitch_lag: 0,
    pitch_lag_int: 0,
    excitation_buf: Array::make(
      amrwb_p_delay_max + amrwb_lp_order + 2 + amrwb_sfr_size,
      0.0,
    ),
    pitch_vector: Array::make(amrwb_sfr_size, 0.0),
    fixed_vector: Array::make(amrwb_sfr_size, 0.0),
    prediction_error: Array::make(4, amrwb_min_energy),
    pitch_gain: Array::make(6, 0.0),
    fixed_gain: Array::make(2, 0.0),
    tilt_coef: 0.0,
    prev_ir_filter_nr: 0,
    prev_tr_gain: 0.0,
    samples_az: Array::make(amrwb_lp_order + amrwb_sfr_size, 0.0),
    samples_up: Array::make(amrwb_ups_mem_size + amrwb_sfr_size, 0.0),
    samples_hb: Array::make(amrwb_lp_order_16k + amrwb_sfr_size_16k, 0.0),
    hpf_31_mem: Array::make(2, 0.0),
    hpf_400_mem: Array::make(2, 0.0),
    demph_mem: Array::make(1, 0.0),
    bpf_6_7_mem: Array::make(amrwb_hb_fir_size, 0.0),
    lpf_7_mem: Array::make(amrwb_hb_fir_size, 0.0),
    prng: ac3_lfg_new(1U),
    first_frame: true,
  }
}

// ---------------------------------------------------------------------------
// generic helpers (the AMR-NB versions of amr.mbt fix the order and size)
// ---------------------------------------------------------------------------

///|
/// `lsp2polyf`: the Pa / (1 + z^-1) or Qa / (1 - z^-1) coefficients of the
/// even (`off` 0) or odd (`off` 1) LSP phase.
fn amrwb_lsp2polyf(
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
/// `ff_amrwb_lsp2lpc`: LSP (cosine domain) to LP coefficients, any even
/// order. `qa` is read one slot before `f[0]` (`qa[-1]` is 0 in the C), so
/// the buffer carries a leading zero.
fn amrwb_lsp2lpc(lsp : Array[Double], lp : Array[Double], lp_order : Int32) -> Unit {
  let half = lp_order >> 1
  let pa : Array[Double] = Array::make(half + 1, 0.0)
  let qa : Array[Double] = Array::make(half + 1, 0.0)
  amrwb_lsp2polyf(lsp, 0, pa, half)
  amrwb_lsp2polyf(lsp, 1, qa, half - 1)
  let last = lsp[lp_order - 1]
  let mut i = 1
  let mut j = lp_order - 1
  while i < half {
    // the C reads qa[-1] (a zero in front of the array) for i = 1
    let qa_im2 = if i >= 2 { qa[i - 2] } else { 0.0 }
    let paf = pa[i] * (1.0 + last)
    let qaf = (qa[i] - qa_im2) * (1.0 - last)
    lp[i - 1] = (paf + qaf) * 0.5
    lp[j - 1] = (paf - qaf) * 0.5
    i = i + 1
    j = j - 1
  }
  lp[half - 1] = (1.0 + last) * pa[half] * 0.5
  lp[lp_order - 1] = last
}

///|
/// `ff_set_min_dist_lsf` for `size` coefficients.
fn amrwb_set_min_dist_lsf(lsf : Array[Double], min_spacing : Double, size : Int32) -> Unit {
  let mut prev = 0.0
  for i = 0; i < size; i = i + 1 {
    if lsf[i] < prev + min_spacing {
      lsf[i] = prev + min_spacing
    }
    prev = lsf[i]
  }
}

///|
/// `ff_acelp_lsf2lspd` for `n` coefficients.
fn amrwb_lsf2lspd(lsp : Array[Double], lsf : Array[Double], n : Int32) -> Unit {
  for i = 0; i < n; i = i + 1 {
    lsp[i] = @math.cos(2.0 * 3.14159265358979323846 * lsf[i])
  }
}

///|
/// `ff_acelp_apply_order_2_transfer_function` over `n` samples.
fn amrwb_apply_order_2(
  out : Array[Double],
  out_off : Int32,
  src : Array[Double],
  src_off : Int32,
  zeros : FixedArray[Double],
  poles : FixedArray[Double],
  gain : Double,
  mem : Array[Double],
  n : Int32,
) -> Unit {
  for i = 0; i < n; i = i + 1 {
    let tmp = gain * src[src_off + i] - poles[0] * mem[0] - poles[1] * mem[1]
    out[out_off + i] = tmp + zeros[0] * mem[0] + zeros[1] * mem[1]
    mem[1] = mem[0]
    mem[0] = tmp
  }
}

// ---------------------------------------------------------------------------
// ISF (immittance spectral pairs) decoding
// ---------------------------------------------------------------------------

///|
/// `decode_isf_indices_36b`: quantized ISF vector from 36-bit indexes
/// (6K60 mode only). `ind` holds the five indexes.
fn amrwb_decode_isf_indices_36b(ind : FixedArray[Int32], isf_q : Array[Double]) -> Unit {
  for i = 0; i < 9; i = i + 1 {
    isf_q[i] = amrwb_dico1_isf[ind[0] * 9 + i].to_double() / 32768.0
  }
  for i = 0; i < 7; i = i + 1 {
    isf_q[i + 9] = amrwb_dico2_isf[ind[1] * 7 + i].to_double() / 32768.0
  }
  for i = 0; i < 5; i = i + 1 {
    isf_q[i] += amrwb_dico21_isf_36b[ind[2] * 5 + i].to_double() / 32768.0
  }
  for i = 0; i < 4; i = i + 1 {
    isf_q[i + 5] += amrwb_dico22_isf_36b[ind[3] * 4 + i].to_double() / 32768.0
  }
  for i = 0; i < 7; i = i + 1 {
    isf_q[i + 9] += amrwb_dico23_isf_36b[ind[4] * 7 + i].to_double() / 32768.0
  }
}

///|
/// `decode_isf_indices_46b`: quantized ISF vector from 46-bit indexes (all
/// modes but 6K60). `ind` holds the seven indexes.
fn amrwb_decode_isf_indices_46b(ind : FixedArray[Int32], isf_q : Array[Double]) -> Unit {
  for i = 0; i < 9; i = i + 1 {
    isf_q[i] = amrwb_dico1_isf[ind[0] * 9 + i].to_double() / 32768.0
  }
  for i = 0; i < 7; i = i + 1 {
    isf_q[i + 9] = amrwb_dico2_isf[ind[1] * 7 + i].to_double() / 32768.0
  }
  for i = 0; i < 3; i = i + 1 {
    isf_q[i] += amrwb_dico21_isf[ind[2] * 3 + i].to_double() / 32768.0
  }
  for i = 0; i < 3; i = i + 1 {
    isf_q[i + 3] += amrwb_dico22_isf[ind[3] * 3 + i].to_double() / 32768.0
  }
  for i = 0; i < 3; i = i + 1 {
    isf_q[i + 6] += amrwb_dico23_isf[ind[4] * 3 + i].to_double() / 32768.0
  }
  for i = 0; i < 3; i = i + 1 {
    isf_q[i + 9] += amrwb_dico24_isf[ind[5] * 3 + i].to_double() / 32768.0
  }
  for i = 0; i < 4; i = i + 1 {
    isf_q[i + 12] += amrwb_dico25_isf[ind[6] * 4 + i].to_double() / 32768.0
  }
}

///|
/// `isf_add_mean_and_past`: add the mean and the past ISF with the
/// prediction factor; updates the past ISF.
fn amrwb_isf_add_mean_and_past(isf_q : Array[Double], isf_past : Array[Double]) -> Unit {
  for i = 0; i < amrwb_lp_order; i = i + 1 {
    let tmp = isf_q[i]
    isf_q[i] += amrwb_isf_mean[i].to_double() / 32768.0
    isf_q[i] += amrwb_pred_factor * isf_past[i]
    isf_past[i] = tmp
  }
}

///|
/// `interpolate_isp`: subframes 1-3 from the past 4th subframe and the
/// current 4th.
fn amrwb_interpolate_isp(isp_q : Array[Array[Double]], isp4_past : Array[Double]) -> Unit {
  for k = 0; k < 3; k = k + 1 {
    let c = amrwb_isfp_inter[k]
    for i = 0; i < amrwb_lp_order; i = i + 1 {
      isp_q[k][i] = (1.0 - c) * isp4_past[i] + c * isp_q[3][i]
    }
  }
}

///|
/// `stability_factor`: 1.0 is maximum signal stability.
fn amrwb_stability_factor(isf : Array[Double], isf_past : Array[Double]) -> Double {
  let mut acc = 0.0
  for i = 0; i < amrwb_lp_order - 1; i = i + 1 {
    acc += (isf[i] - isf_past[i]) * (isf[i] - isf_past[i])
  }
  (1.25 - acc * 0.8 * 512.0).max(0.0)
}

// ---------------------------------------------------------------------------
// adaptive codebook (pitch)
// ---------------------------------------------------------------------------

///|
/// `decode_pitch_lag_high` (modes above 8k85): 1/4 resolution lags; the
/// 1st and 3rd subframes are absolute, the others relative to the base lag.
fn AmrWbDecoder::decode_pitch_lag_high(
  self : AmrWbDecoder,
  pitch_index : Int32,
  subframe : Int32,
) -> (Int32, Int32) {
  if subframe == 0 || subframe == 2 {
    let (lag_int, lag_frac) = if pitch_index < 376 {
      let li = (pitch_index + 137) >> 2
      (li, pitch_index - (li << 2) + 136)
    } else if pitch_index < 440 {
      let li = (pitch_index + 257 - 376) >> 1
      // the actual resolution is 1/2 but expressed as 1/4
      (li, (pitch_index - (li << 1) + 256 - 376) * 2)
    } else {
      (pitch_index - 280, 0)
    }
    // Minimum lag for the next subframe; the reference takes the floor.
    let low = if lag_frac < 0 { 1 } else { 0 }
    self.base_pitch_lag = (lag_int - 8 - low).clamp(
      min=amrwb_p_delay_min,
      max=amrwb_p_delay_max - 15,
    )
    (lag_int, lag_frac)
  } else {
    let li = (pitch_index + 1) >> 2
    let frac = pitch_index - (li << 2)
    (li + self.base_pitch_lag, frac)
  }
}

///|
/// `decode_pitch_lag_low` (6k60 and 8k85): 1/2 resolution lags; in 6k60
/// every subframe but the first is relative.
fn AmrWbDecoder::decode_pitch_lag_low(
  self : AmrWbDecoder,
  pitch_index : Int32,
  subframe : Int32,
  mode : Int32,
) -> (Int32, Int32) {
  if subframe == 0 || (subframe == 2 && mode != amrwb_mode_6k60) {
    let (lag_int, lag_frac) = if pitch_index < 116 {
      let li = (pitch_index + 69) >> 1
      (li, (pitch_index - (li << 1) + 68) * 2)
    } else {
      (pitch_index - 24, 0)
    }
    let low = if lag_frac < 0 { 1 } else { 0 }
    self.base_pitch_lag = (lag_int - 8 - low).clamp(
      min=amrwb_p_delay_min,
      max=amrwb_p_delay_max - 15,
    )
    (lag_int, lag_frac)
  } else {
    let li = (pitch_index + 1) >> 1
    let frac = (pitch_index - (li << 1)) * 2
    (li + self.base_pitch_lag, frac)
  }
}

///|
/// `decode_pitch_vector`: interpolate the past excitation at the decoded
/// pitch lag (hamming windowed sinc), with the optional LTP filtering.
fn AmrWbDecoder::decode_pitch_vector(
  self : AmrWbDecoder,
  adap : Int32,
  ltp : Int32,
  subframe : Int32,
) -> Unit {
  let (lag, lag_frac) = if self.fr_cur_mode <= amrwb_mode_8k85 {
    self.decode_pitch_lag_low(adap, subframe, self.fr_cur_mode)
  } else {
    self.decode_pitch_lag_high(adap, subframe)
  }
  self.pitch_lag_int = lag
  let pitch_lag_int = if lag_frac > 0 { lag + 1 } else { lag }
  let ex = amrwb_excitation_off
  let frac = lag_frac + (if lag_frac > 0 { 0 } else { 4 })
  amr_acelp_interpolatef(
    self.excitation_buf,
    ex,
    self.excitation_buf,
    ex + 1 - pitch_lag_int,
    amrwb_ac_inter,
    4,
    frac,
    amrwb_lp_order,
    amrwb_sfr_size + 1,
  )
  if ltp != 0 {
    for i = 0; i < amrwb_sfr_size; i = i + 1 {
      self.pitch_vector[i] = self.excitation_buf[ex + i]
    }
  } else {
    for i = 0; i < amrwb_sfr_size; i = i + 1 {
      self.pitch_vector[i] = 0.18 * self.excitation_buf[ex + i - 1] +
        0.64 * self.excitation_buf[ex + i] +
        0.18 * self.excitation_buf[ex + i + 1]
    }
    for i = 0; i < amrwb_sfr_size; i = i + 1 {
      self.excitation_buf[ex + i] = self.pitch_vector[i]
    }
  }
}
