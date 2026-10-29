///|
/// Minimal ALAC encoder: SCE/CPE elements with adaptive FIR prediction
/// (`alacenc.c`'s `alac_linear_predictor`), Rice entropy coding, the four
/// stereo decorrelation modes and the 36-byte ALACSpecificConfig cookie.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AlacEncoded {
  /// 36-byte magic cookie (ALACSpecificConfig with the size/tag header).
  cookie : Bytes
  frames : Array[Bytes]
  sample_rate : Int32
  channels : Int32
  bits : Int32
  total_samples : Int64
  /// Maximum samples per frame stored in the cookie.
  frame_size : Int32
}

///|
fn alac_enc_be32(out : Array[Byte], v : UInt32) -> Unit {
  out.push(((v >> 24) & 0xFFU).to_byte())
  out.push(((v >> 16) & 0xFFU).to_byte())
  out.push(((v >> 8) & 0xFFU).to_byte())
  out.push((v & 0xFFU).to_byte())
}

///|
fn alac_enc_cookie(
  frame_size : Int32,
  bits : Int32,
  channels : Int32,
  sample_rate : Int32,
) -> Bytes {
  let out : Array[Byte] = []
  alac_enc_be32(out, 36U)
  for b in b"alac" {
    out.push(b)
  }
  alac_enc_be32(out, 0U) // version/flags
  alac_enc_be32(out, frame_size.reinterpret_as_uint())
  out.push(b'\x00') // compatible version
  out.push(bits.to_byte())
  out.push(b'\x28') // history_mult = 40
  out.push(b'\x0a') // initial_history = 10
  out.push(b'\x0e') // k_modifier = 14
  out.push(channels.to_byte())
  out.push(b'\x00')
  out.push(b'\x00')
  // Maximum encoded frame size (verbatim estimate from alacenc.c).
  let header_bits = 23 + (if frame_size < 4096 { 32 } else { 0 })
  let max_frame = (header_bits + bits * channels * frame_size + 3 + 7) / 8
  alac_enc_be32(out, max_frame.reinterpret_as_uint())
  alac_enc_be32(out, (sample_rate * channels * bits).reinterpret_as_uint())
  alac_enc_be32(out, sample_rate.reinterpret_as_uint())
  Bytes::from_array(out)
}

///|
fn alac_enc_log2(v : UInt32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x > 1U {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
/// `encode_scalar`: unary quotient + k low bits, or a raw escape. */
fn alac_encode_scalar(
  w : FlacBits,
  x : Int32,
  k_in : Int32,
  write_sample_size : Int32,
) -> Unit {
  let k = if k_in > 14 { 14 } else if k_in < 1 { 1 } else { k_in }
  let divisor = (1 << k) - 1
  let q = x / divisor
  let r = x % divisor
  if q > 8 {
    w.write(0x1FFU, 9)
    w.write(x.reinterpret_as_uint(), write_sample_size)
  } else {
    if q > 0 {
      w.write((1U << q) - 1U, q)
    }
    w.write(0U, 1)
    if k != 1 {
      if r > 0 {
        w.write((r + 1).reinterpret_as_uint(), k)
      } else {
        w.write(0U, k - 1)
      }
    }
  }
}

///|
/// `alac_entropy_coder` for one channel. `samples` are the 16-bit (or
/// extra-bit-reduced 24-bit) values, `bps` is the per-element sample size.
fn alac_entropy_encode(
  w : FlacBits,
  samples : Array[Int32],
  bps : Int32,
) -> Unit {
  let mut history = 10U
  let mut sign_modifier = 0
  let history_mult = 40U
  let n = samples.length()
  let mut i = 0
  while i < n {
    let mut k = alac_enc_log2((history >> 9) + 3U)
    let s = samples[i]
    let mut x = -2 * s - 1
    x = x ^ (x >> 31)
    i = i + 1
    alac_encode_scalar(w, x - sign_modifier, k, bps)
    history = history +
      x.reinterpret_as_uint() * history_mult -
      ((history * history_mult) >> 9)
    sign_modifier = 0
    if x > 0xFFFF {
      history = 0xFFFFU
    }
    if history < 128U && i < n {
      k = 7 -
        alac_enc_log2(history) +
        ((history + 16U) >> 6).reinterpret_as_int()
      let mut block_size = 0
      while i < n && samples[i] == 0 {
        i = i + 1
        block_size = block_size + 1
      }
      alac_encode_scalar(w, block_size, k, 16)
      sign_modifier = if block_size <= 0xFFFF { 1 } else { 0 }
      history = 0U
    }
  }
}

///|
/// `estimate_stereo_mode`: the `ALAC_CHMODE_*` with the smallest summed
/// |second-order residual| over the four candidate channel pairs.
fn alac_enc_stereo_mode(
  left : Array[Int32],
  right : Array[Int32],
  n : Int32,
) -> Int32 {
  let mut sum_l = 0L
  let mut sum_r = 0L
  let mut sum_mid = 0L
  let mut sum_side = 0L
  for i = 2; i < n; i = i + 1 {
    let lt = left[i] - 2 * left[i - 1] + left[i - 2]
    let rt = right[i] - 2 * right[i - 1] + right[i - 2]
    sum_mid = sum_mid + alac_enc_abs64((lt + rt) >> 1)
    sum_side = sum_side + alac_enc_abs64(lt - rt)
    sum_l = sum_l + alac_enc_abs64(lt)
    sum_r = sum_r + alac_enc_abs64(rt)
  }
  let scores : Array[Int64] = [
    sum_l + sum_r,
    sum_l + sum_side,
    sum_r + sum_side,
    sum_mid + sum_side,
  ]
  let mut best = 0
  for i = 1; i < 4; i = i + 1 {
    if scores[i] < scores[best] {
      best = i
    }
  }
  best
}

///|
fn alac_enc_abs64(v : Int32) -> Int64 {
  if v < 0 {
    -v.to_int64()
  } else {
    v.to_int64()
  }
}

///|
/// `alac_stereo_decorrelation`: rewrites the two channel buffers in place and
/// returns `(interlacing_shift, interlacing_leftweight)`.
fn alac_enc_decorrelate(
  left : Array[Int32],
  right : Array[Int32],
  n : Int32,
) -> (Int32, Int32) {
  match alac_enc_stereo_mode(left, right, n) {
    1 => {
      // left + side
      for i = 0; i < n; i = i + 1 {
        right[i] = left[i] - right[i]
      }
      (0, 1)
    }
    2 => {
      // side + right
      for i = 0; i < n; i = i + 1 {
        let tmp = right[i]
        right[i] = left[i] - right[i]
        left[i] = tmp + (right[i] >> 31)
      }
      (31, 1)
    }
    3 => {
      // mid + side
      for i = 0; i < n; i = i + 1 {
        let tmp = left[i]
        left[i] = (tmp + right[i]) >> 1
        right[i] = tmp - right[i]
      }
      (1, 1)
    }
    _ => (0, 0)
  }
}

///|
/// `calc_predictor_params` (Levinson, `ORDER_METHOD_EST`, 9-bit coefficients,
/// shift 0..9). Returns `(order, quant, coefficients)`.
fn alac_enc_lpc_params(
  samples : Array[Int32],
  n : Int32,
) -> (Int32, Int32, Array[Int32]) {
  let min_order = 4
  let max_order = 6
  if n < 32 {
    return (0, 1, [])
  }
  let max_o = if n - 1 < max_order { n - 1 } else { max_order }
  let autoc = flac_lpc_autocorr(samples, n, max_o)
  let lpc = flac_lpc_levinson(autoc, max_o)
  let mut est = min_order
  let mut i = max_o - 1
  while i >= min_order - 1 {
    let k = lpc[i][i]
    let ak = if k < 0.0 { -k } else { k }
    if ak > 0.10 {
      est = i + 1
      break
    }
    i = i - 1
  }
  if est > max_o {
    est = max_o
  }
  let (coefs, shift) = flac_quantize_lpc(lpc[est - 1], est, 9, 9)
  if shift == 0 {
    // The decoder rejects `lpc_quant == 0`; fall back to no prediction.
    return (0, 1, [])
  }
  (est, shift, coefs)
}

///|
/// `alac_linear_predictor`: adaptive FIR residuals. `coeffs` is adapted in
/// place exactly like the decoder's `lpc_prediction`.
fn alac_enc_linear_predictor(
  samples : Array[Int32],
  n : Int32,
  order : Int32,
  quant : Int32,
  coeffs : Array[Int32],
  bps : Int32,
) -> Array[Int32] {
  let residual : Array[Int32] = Array::make(n, 0)
  residual[0] = samples[0]
  if order == 0 {
    for i = 1; i < n; i = i + 1 {
      residual[i] = samples[i]
    }
    return residual
  }
  let mut i = 1
  while i <= order && i < n {
    residual[i] = alac_sign_extend(samples[i] - samples[i - 1], bps)
    i = i + 1
  }
  while i < n {
    let d = samples[i - 1 - order]
    let mut sum = 1 << (quant - 1)
    for j = 0; j < order; j = j + 1 {
      sum = sum + (samples[i - 1 - j] - d) * coeffs[j]
    }
    sum = sum >> quant
    residual[i] = alac_sign_extend(samples[i] - (sum + d), bps)
    if residual[i] != 0 {
      let neg = residual[i] < 0
      let mut res_val = residual[i]
      let mut index = order - 1
      while index >= 0 && (if neg { res_val < 0 } else { res_val > 0 }) {
        let val = d - samples[i - 1 - index]
        let mut sign = alac_sign_only(val)
        if neg {
          sign = -sign
        }
        coeffs[index] = alac_sign_extend(coeffs[index] - sign, 16)
        let v = val * sign
        res_val = res_val - (v >> quant) * (order - index)
        index = index - 1
      }
    }
    i = i + 1
  }
  residual
}

///|
/// Encode interleaved PCM into ALAC frames.  Supports mono (SCE) and stereo
/// (CPE with the four decorrelation modes), 16- and 24-bit samples.
pub fn alac_encode(
  samples : Array[Int32],
  channels : Int32,
  sample_rate : Int32,
  bits : Int32,
  frame_size~ : Int32 = 4096,
) -> Result[AlacEncoded, String] {
  if channels != 1 && channels != 2 {
    return Err("EINVAL: ALAC encoder supports mono or stereo")
  }
  if bits != 16 && bits != 24 {
    return Err("EINVAL: ALAC encoder supports 16/24-bit samples")
  }
  if sample_rate <= 0 {
    return Err("EINVAL: invalid ALAC sample rate")
  }
  if frame_size < 16 || frame_size > 4096 {
    return Err("EINVAL: invalid ALAC frame size")
  }
  if samples.length() % channels != 0 {
    return Err("EINVAL: ALAC samples are not interleaved")
  }
  let total = samples.length() / channels
  let extra_bits = bits - 16
  let bps = bits - extra_bits + channels - 1
  let cookie = alac_enc_cookie(frame_size, bits, channels, sample_rate)
  let frames : Array[Bytes] = []
  let mask = if extra_bits > 0 { (1 << extra_bits) - 1 } else { 0 }
  let mut pos = 0
  while pos < total {
    let n = if total - pos < frame_size { total - pos } else { frame_size }
    let encode_fs = n < frame_size
    let l : Array[Int32] = Array::make(n, 0)
    let r : Array[Int32] = Array::make(n, 0)
    for i in 0..<n {
      l[i] = samples[(pos + i) * channels]
      if channels == 2 {
        r[i] = samples[(pos + i) * channels + 1]
      }
    }
    // The low bits are sent after the predictor headers and are appended back
    // after stereo decorrelation, so stash them before the channels change.
    let extra_l : Array[Int32] = Array::make(n, 0)
    let extra_r : Array[Int32] = Array::make(n, 0)
    if extra_bits > 0 {
      for i = 0; i < n; i = i + 1 {
        extra_l[i] = l[i] & mask
        l[i] = l[i] >> extra_bits
        if channels == 2 {
          extra_r[i] = r[i] & mask
          r[i] = r[i] >> extra_bits
        }
      }
    }
    let (decorr_shift, decorr_weight) = if channels == 2 {
      alac_enc_decorrelate(l, r, n)
    } else {
      (0, 0)
    }
    let (order0, quant0, coefs0) = alac_enc_lpc_params(l, n)
    let (order1, quant1, coefs1) = if channels == 2 {
      alac_enc_lpc_params(r, n)
    } else {
      (0, 1, [])
    }
    let w = flac_bits_new()
    w.write(if channels == 1 { 0U } else { 1U }, 3) // SCE / CPE
    w.write(0U, 4) // instance tag
    w.write(0U, 12) // unused header bits
    w.write(if encode_fs { 1U } else { 0U }, 1)
    w.write((extra_bits >> 3).reinterpret_as_uint(), 2)
    w.write(0U, 1) // compressed (not verbatim)
    if encode_fs {
      w.write(n.reinterpret_as_uint(), 32)
    }
    w.write(decorr_shift.reinterpret_as_uint(), 8)
    w.write(decorr_weight.reinterpret_as_uint(), 8)
    // per-channel predictor parameters (prediction type 0, adaptive FIR)
    w.write(0U, 4)
    w.write(quant0.reinterpret_as_uint(), 4)
    w.write(4U, 3) // rice modifier
    w.write(order0.reinterpret_as_uint(), 5)
    for j = 0; j < order0; j = j + 1 {
      w.write_signed(coefs0[j], 16)
    }
    if channels == 2 {
      w.write(0U, 4)
      w.write(quant1.reinterpret_as_uint(), 4)
      w.write(4U, 3)
      w.write(order1.reinterpret_as_uint(), 5)
      for j = 0; j < order1; j = j + 1 {
        w.write_signed(coefs1[j], 16)
      }
    }
    if extra_bits > 0 {
      for i = 0; i < n; i = i + 1 {
        w.write(extra_l[i].reinterpret_as_uint(), extra_bits)
        if channels == 2 {
          w.write(extra_r[i].reinterpret_as_uint(), extra_bits)
        }
      }
    }
    let res_l = alac_enc_linear_predictor(l, n, order0, quant0, coefs0, bps)
    alac_entropy_encode(w, res_l, bps)
    if channels == 2 {
      let res_r = alac_enc_linear_predictor(r, n, order1, quant1, coefs1, bps)
      alac_entropy_encode(w, res_r, bps)
    }
    w.write(7U, 3) // TYPE_END
    frames.push(Bytes::from_array(w.bytes()))
    pos = pos + n
  }
  Ok({
    cookie,
    frames,
    sample_rate,
    channels,
    bits,
    total_samples: total.to_int64(),
    frame_size,
  })
}
