///|
/// G.722 ADPCM decoder, ported from FFmpeg 9.0.2 `libavcodec/g722dec.c`,
/// `g722.c` and `g722dsp.c` (ITU-T G.722, 64 kbit/s two-bit high band).
///
/// `G722Decoder` keeps the sub-band predictor state and the QMF history
/// across packets. Each input byte yields two 16 kHz output samples.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `inv_log2_table`.
let g722_inv_log2_table : FixedArray[Int32] = [
  2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383, 2435, 2489, 2543, 2599, 2656, 2714,
  2774, 2834, 2896, 2960, 3025, 3091, 3158, 3228, 3298, 3371, 3444, 3520, 3597, 3676,
  3756, 3838, 3922, 4008,
]

///|
/// `high_log_factor_step`.
let g722_high_log_factor_step : FixedArray[Int32] = [798, -214]

///|
/// `ff_g722_high_inv_quant`.
let g722_high_inv_quant : FixedArray[Int32] = [-926, -202, 926, 202]

///|
/// `ff_g722_low_inv_quant4`, used by the low-band predictor update.
let g722_low_inv_quant4 : FixedArray[Int32] = [
  0, -2557, -1612, -1121, -786, -530, -323, -150, 2557, 1612, 1121, 786, 530, 323,
  150, 0,
]

///|
/// `low_log_factor_step`.
let g722_low_log_factor_step : FixedArray[Int32] = [
  -60, 3042, 1198, 538, 334, 172, 58, -30, 3042, 1198, 538, 334, 172, 58, -30, -60,
]

///|
/// `ff_g722_low_inv_quant6` (the default 8-bit codeword table).
let g722_low_inv_quant6 : FixedArray[Int32] = [
  -17, -17, -17, -17, -3101, -2738, -2376, -2088, -1873, -1689, -1535, -1399, -1279,
  -1170, -1072, -982, -899, -822, -750, -682, -618, -558, -501, -447, -396, -347,
  -300, -254, -211, -170, -130, -91, 3101, 2738, 2376, 2088, 1873, 1689, 1535, 1399,
  1279, 1170, 1072, 982, 899, 822, 750, 682, 618, 558, 501, 447, 396, 347, 300, 254,
  211, 170, 130, 91, 54, 17, -54, -17,
]

///|
/// QMF coefficients (ITU-T G.722 Table 11), alternating xout[1]/xout[0].
let g722_qmf_coeffs : FixedArray[Int32] = [
  3, -11, -11, 53, 12, -156, 32, 362, -210, -805, 951, 3876, 3876, 951, -805, -210,
  362, 32, -156, 12, 53, -11, -11, 3,
]

///|
fn g722_clip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn g722_clip_int16(v : Int32) -> Int32 {
  g722_clip(v, -32768, 32767)
}

///|
/// `av_clip_intp2`: the valid range is `[-2^p, 2^p - 1]`.
fn g722_clip_intp2(v : Int32, bits : Int32) -> Int32 {
  let limit = 1 << bits
  g722_clip(v, -limit, limit - 1)
}

///|
/// Per-sub-band adaptive predictor state (`G722Band`).
pub struct G722Band {
  mut s_predictor : Int32
  mut s_zero : Int32
  part_reconst_mem : FixedArray[Int32]
  mut prev_qtzd_reconst : Int32
  pole_mem : FixedArray[Int32]
  diff_mem : FixedArray[Int32]
  zero_mem : FixedArray[Int32]
  mut log_factor : Int32
  mut scale_factor : Int32
}

///|
fn g722_band_new() -> G722Band {
  {
    s_predictor: 0,
    s_zero: 0,
    part_reconst_mem: FixedArray::make(2, 0),
    prev_qtzd_reconst: 0,
    pole_mem: FixedArray::make(2, 0),
    diff_mem: FixedArray::make(6, 0),
    zero_mem: FixedArray::make(6, 0),
    log_factor: 0,
    scale_factor: 0,
  }
}

///|
fn g722_sign16(v : Int32) -> Int32 {
  if v >= 0x8000 {
    v - 0x10000
  } else if v < -0x8000 {
    v + 0x10000
  } else {
    v
  }
}

///|
/// `s_zero`.
fn g722_s_zero(band : G722Band, cur_diff : Int32) -> Unit {
  let mut acc = 0
  let start = if cur_diff != 0 { 0 } else { 0 }
  let _ = start
  // ACCUM(k, x, d) for k = 5..0 with the matching diff_mem history.
  let xs : FixedArray[Int32] = [
    band.diff_mem[4],
    band.diff_mem[3],
    band.diff_mem[2],
    band.diff_mem[1],
    band.diff_mem[0],
    cur_diff * 2,
  ]
  for idx = 0; idx < 6; idx = idx + 1 {
    let k = 5 - idx
    let tmp = xs[idx]
    let d = if cur_diff != 0 { 1 } else { 0 }
    let upd = ((band.zero_mem[k] * 255) >> 8) +
      d * (if (band.diff_mem[k] ^ cur_diff) < 0 { -128 } else { 128 })
    band.zero_mem[k] = g722_sign16(upd)
    band.diff_mem[k] = tmp
    acc = acc + ((tmp * band.zero_mem[k]) >> 15)
  }
  band.s_zero = acc
}

///|
/// `do_adaptive_prediction`.
fn g722_do_adaptive_prediction(band : G722Band, cur_diff : Int32) -> Unit {
  let cur_part_reconst = if band.s_zero + cur_diff < 0 { 1 } else { 0 }
  let sg0 = if cur_part_reconst != band.part_reconst_mem[0] { 1 } else { -1 }
  let sg1 = if cur_part_reconst == band.part_reconst_mem[1] { 1 } else { -1 }
  band.part_reconst_mem[1] = band.part_reconst_mem[0]
  band.part_reconst_mem[0] = cur_part_reconst
  band.pole_mem[1] = g722_clip(
    ((sg0 * g722_clip(band.pole_mem[0], -8191, 8191)) >> 5) +
    sg1 * 128 +
    ((band.pole_mem[1] * 127) >> 7),
    -12288,
    12288,
  )
  let limit = 15360 - band.pole_mem[1]
  band.pole_mem[0] = g722_clip(
    -192 * sg0 + ((band.pole_mem[0] * 255) >> 8),
    -limit,
    limit,
  )
  g722_s_zero(band, cur_diff)
  let cur_qtzd_reconst = g722_clip_int16((band.s_predictor + cur_diff) * 2)
  band.s_predictor = g722_clip_int16(
    band.s_zero +
    ((band.pole_mem[0] * cur_qtzd_reconst) >> 15) +
    ((band.pole_mem[1] * band.prev_qtzd_reconst) >> 15),
  )
  band.prev_qtzd_reconst = cur_qtzd_reconst
}

///|
/// `linear_scale_factor`.
fn g722_linear_scale_factor(log_factor : Int32) -> Int32 {
  let wd1 = g722_inv_log2_table[(log_factor >> 6) & 31]
  let shift = log_factor >> 11
  if shift < 0 {
    wd1 >> -shift
  } else {
    wd1 << shift
  }
}

///|
/// `ff_g722_update_low_predictor`.
fn g722_update_low_predictor(band : G722Band, ilow : Int32) -> Unit {
  g722_do_adaptive_prediction(
    band,
    (band.scale_factor * g722_low_inv_quant4[ilow]) >> 10,
  )
  band.log_factor = g722_clip(
    ((band.log_factor * 127) >> 7) + g722_low_log_factor_step[ilow],
    0,
    18432,
  )
  band.scale_factor = g722_linear_scale_factor(band.log_factor - (8 << 11))
}

///|
/// `ff_g722_update_high_predictor`.
fn g722_update_high_predictor(
  band : G722Band,
  dhigh : Int32,
  ihigh : Int32,
) -> Unit {
  g722_do_adaptive_prediction(band, dhigh)
  band.log_factor = g722_clip(
    ((band.log_factor * 127) >> 7) + g722_high_log_factor_step[ihigh & 1],
    0,
    22528,
  )
  band.scale_factor = g722_linear_scale_factor(band.log_factor - (10 << 11))
}

///|
/// G.722 decoder with persistent sub-band and QMF state.
pub struct G722Decoder {
  band0 : G722Band
  band1 : G722Band
  prev : FixedArray[Int32]
  mut prev_pos : Int32
}

///|
pub fn g722_decoder_new() -> G722Decoder {
  let band0 = g722_band_new()
  let band1 = g722_band_new()
  band0.scale_factor = 8
  band1.scale_factor = 2
  { band0, band1, prev: FixedArray::make(1024, 0), prev_pos: 22, }
}

///|
/// `g722_apply_qmf`: `(xout[0], xout[1])`.
fn g722_apply_qmf(prev : FixedArray[Int32], start : Int32) -> (Int32, Int32) {
  let mut x0 = 0
  let mut x1 = 0
  for i = 0; i < 12; i = i + 1 {
    x1 = x1 + prev[start + 2 * i] * g722_qmf_coeffs[2 * i]
    x0 = x0 + prev[start + 2 * i + 1] * g722_qmf_coeffs[2 * i + 1]
  }
  (x0, x1)
}

///|
/// Decode a packet of G.722 codewords (8 bits per codeword) into 16-bit PCM.
pub fn G722Decoder::decode(self : G722Decoder, data : Bytes) -> Array[Int32] {
  let out : Array[Int32] = []
  for byte in data {
    let v = byte.to_int()
    let ihigh = (v >> 6) & 0x03
    let ilow = v & 0x3F
    let rlow = g722_clip_intp2(
      ((self.band0.scale_factor * g722_low_inv_quant6[ilow]) >> 10) +
      self.band0.s_predictor,
      14,
    )
    g722_update_low_predictor(self.band0, ilow >> 2)
    let dhigh = (self.band1.scale_factor * g722_high_inv_quant[ihigh]) >> 10
    let rhigh = g722_clip_intp2(dhigh + self.band1.s_predictor, 14)
    g722_update_high_predictor(self.band1, dhigh, ihigh)
    self.prev[self.prev_pos] = rlow + rhigh
    self.prev_pos = self.prev_pos + 1
    self.prev[self.prev_pos] = rlow - rhigh
    self.prev_pos = self.prev_pos + 1
    let (x0, x1) = g722_apply_qmf(self.prev, self.prev_pos - 24)
    out.push(g722_clip_int16(x0 >> 11))
    out.push(g722_clip_int16(x1 >> 11))
    if self.prev_pos >= 1024 {
      for i = 0; i < 22; i = i + 1 {
        self.prev[i] = self.prev[self.prev_pos - 22 + i]
      }
      self.prev_pos = 22
    }
  }
  out
}
