///|
/// Minimal FLAC encoder: constant/verbatim/fixed/LPC subframes, Rice-coded
/// residuals with partition order 0, optional Rice2 for >16-bit samples,
/// stereo decorrelation, and a complete `fLaC` stream (STREAMINFO + frames +
/// MD5).
///
/// The layout follows FFmpeg 9.0.2 `flacenc.c` (frame header, subframe types,
/// `set_sr_golomb_flac`, CRC-8/CRC-16 and STREAMINFO) and `lpc.c` (Welch
/// window, Levinson-Durbin recursion, 15-bit error-feedback coefficient
/// quantization), but the predictor choice uses a single Rice partition.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// MSB-first bit writer used by the FLAC frame/subframe encoders.
pub struct FlacBits {
  out : Array[Byte]
  mut acc : UInt32
  mut nbits : Int32
}

///|
fn flac_bits_new() -> FlacBits {
  { out: [], acc: 0U, nbits: 0, }
}

///|
fn FlacBits::write(self : FlacBits, v : UInt32, bits : Int32) -> Unit {
  let mut left = bits
  while left > 0 {
    let take = if left > 24 { 24 } else { left }
    left = left - take
    let chunk = (v >> left) & ((1U << take) - 1U)
    self.acc = (self.acc << take) | chunk
    self.nbits = self.nbits + take
    while self.nbits >= 8 {
      self.nbits = self.nbits - 8
      self.out.push(((self.acc >> self.nbits) & 0xFFU).to_byte())
    }
    self.acc = self.acc & ((1U << self.nbits) - 1U)
  }
}

///|
fn FlacBits::write_signed(self : FlacBits, v : Int32, bits : Int32) -> Unit {
  self.write(v.reinterpret_as_uint() & ((1U << bits) - 1U), bits)
}

///|
fn FlacBits::align(self : FlacBits) -> Unit {
  if self.nbits != 0 {
    let pad = 8 - self.nbits
    self.write(0U, pad)
  }
}

///|
fn FlacBits::bytes(self : FlacBits) -> Array[Byte] {
  self.align()
  self.out.copy()
}

///|
fn flac_put_u16(out : Array[Byte], v : Int32) -> Unit {
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn flac_put_u24(out : Array[Byte], v : Int32) -> Unit {
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn flac_write_utf8(w : FlacBits, val : UInt32) -> Unit {
  if val < 0x80U {
    w.write(val, 8)
  } else if val < 0x800U {
    w.write(0xC0U | (val >> 6), 8)
    w.write(0x80U | (val & 0x3FU), 8)
  } else if val < 0x10000U {
    w.write(0xE0U | (val >> 12), 8)
    w.write(0x80U | ((val >> 6) & 0x3FU), 8)
    w.write(0x80U | (val & 0x3FU), 8)
  } else if val < 0x200000U {
    w.write(0xF0U | (val >> 18), 8)
    w.write(0x80U | ((val >> 12) & 0x3FU), 8)
    w.write(0x80U | ((val >> 6) & 0x3FU), 8)
    w.write(0x80U | (val & 0x3FU), 8)
  } else if val < 0x4000000U {
    w.write(0xF8U | (val >> 24), 8)
    w.write(0x80U | ((val >> 18) & 0x3FU), 8)
    w.write(0x80U | ((val >> 12) & 0x3FU), 8)
    w.write(0x80U | ((val >> 6) & 0x3FU), 8)
    w.write(0x80U | (val & 0x3FU), 8)
  } else {
    w.write(0xFCU | (val >> 30), 8)
    w.write(0x80U | ((val >> 24) & 0x3FU), 8)
    w.write(0x80U | ((val >> 18) & 0x3FU), 8)
    w.write(0x80U | ((val >> 12) & 0x3FU), 8)
    w.write(0x80U | ((val >> 6) & 0x3FU), 8)
    w.write(0x80U | (val & 0x3FU), 8)
  }
}

///|
/// Fold a signed residual to Rice's unsigned form: `(v << 1) ^ (v >> 31)`. */
fn flac_zigzag(v : Int32) -> Int64 {
  if v >= 0 {
    v.to_int64() * 2L
  } else {
    -v.to_int64() * 2L - 1L
  }
}

///|
/// Best Rice parameter for `res[from..<to]` and its total bit cost.
fn flac_choose_rice(
  res : Array[Int32],
  from : Int32,
  to : Int32,
  max_k : Int32,
) -> (Int32, Int64) {
  let count = to - from
  if count <= 0 {
    return (0, 0L)
  }
  let folded : Array[Int64] = Array::make(count, 0L)
  for i = 0; i < count; i = i + 1 {
    folded[i] = flac_zigzag(res[from + i])
  }
  let mut best_k = 0
  let mut best_bits = -1L
  for k = 0; k <= max_k; k = k + 1 {
    let mut sum = 0L
    for i = 0; i < count; i = i + 1 {
      sum = sum + (folded[i] >> k)
    }
    let bits = sum + count.to_int64() * (1 + k).to_int64()
    if best_bits < 0L || bits < best_bits {
      best_bits = bits
      best_k = k
    }
  }
  (best_k, best_bits)
}

///|
/// `get_max_p_order`: a partition order needs `blocksize % 2^p == 0` (the
/// trailing-zero count, `av_log2(n ^ (n-1))`) and, for a predictor, enough
/// samples per partition (`av_log2(blocksize / pred_order)`); capped at the
/// eight partitions `MAX_PARTITION_ORDER` allows.
fn flac_max_partition_order(n : Int32, pred_order : Int32) -> Int32 {
  let mut p = 0
  let mut m = n
  while p < 8 && (m & 1) == 0 {
    m = m >> 1
    p = p + 1
  }
  if pred_order > 0 {
    let mut q = 0
    let mut d = n / pred_order
    while d > 1 {
      d = d >> 1
      q = q + 1
    }
    if q < p {
      p = q
    }
  }
  p
}

///|
/// `calc_rice_params`: try every partition order and keep the cheapest total,
/// counting the 4-bit partition order plus one parameter per partition.
fn flac_choose_partitioned_rice(
  res : Array[Int32],
  n : Int32,
  pred_order : Int32,
  max_k : Int32,
  param_bits : Int32,
) -> (Int32, Array[Int32], Int64) {
  let max_p = flac_max_partition_order(n, pred_order)
  let mut best_p = 0
  let mut best_ks : Array[Int32] = []
  let mut best_bits = -1L
  for porder = 0; porder <= max_p; porder = porder + 1 {
    let psize = n >> porder
    let parts = 1 << porder
    let ks : Array[Int32] = Array::make(parts, 0)
    let mut bits = 4L + (parts * param_bits).to_int64()
    let mut ok = true
    for part = 0; part < parts; part = part + 1 {
      // The first partition also carries the warmed-up samples' slot.
      let from = if part == 0 { pred_order } else { part * psize }
      let to = (part + 1) * psize
      if from > to {
        ok = false
        break
      }
      let (k, kb) = flac_choose_rice(res, from, to, max_k)
      ks[part] = k
      bits = bits + kb
    }
    if ok && (best_bits < 0L || bits < best_bits) {
      best_bits = bits
      best_p = porder
      best_ks = ks
    }
  }
  (best_p, best_ks, if best_bits < 0L { 0L } else { best_bits })
}

///|
/// `set_sr_golomb_flac`: unary quotient (escaping in 31-bit chunks) + k bits. */
fn flac_write_rice(w : FlacBits, v : Int32, k : Int32) -> Unit {
  let folded = flac_zigzag(v)
  let mut e = (folded >> k) + 1L
  while e > 31L {
    w.write(0U, 31)
    e = e - 31L
  }
  if e > 0L {
    // e-1 zero bits followed by a one (C: put_bits(pb, e, 1))
    w.write(1U, e.to_int())
  }
  if k > 0 {
    w.write((folded & ((1L << k) - 1L)).to_int().reinterpret_as_uint(), k)
  }
}

///|
/// Fixed-predictor residual of `samples[0..n]` for `order` in 0..4. */
fn flac_fixed_residual(
  samples : Array[Int32],
  n : Int32,
  order : Int32,
) -> Array[Int32] {
  let res : Array[Int32] = Array::make(n, 0)
  for i = 0; i < order; i = i + 1 {
    res[i] = samples[i]
  }
  match order {
    0 =>
      for i = 0; i < n; i = i + 1 {
        res[i] = samples[i]
      }
    1 =>
      for i = 1; i < n; i = i + 1 {
        res[i] = samples[i] - samples[i - 1]
      }
    2 =>
      for i = 2; i < n; i = i + 1 {
        res[i] = samples[i] - 2 * samples[i - 1] + samples[i - 2]
      }
    3 =>
      for i = 3; i < n; i = i + 1 {
        res[i] = samples[i] -
          3 * samples[i - 1] +
          3 * samples[i - 2] -
          samples[i - 3]
      }
    _ =>
      for i = 4; i < n; i = i + 1 {
        res[i] = samples[i] -
          4 * samples[i - 1] +
          6 * samples[i - 2] -
          4 * samples[i - 3] +
          samples[i - 4]
      }
  }
  res
}

///|
/// Welch-windowed autocorrelation of `samples[0..n]`
/// (`lpc_apply_welch_window_c` + `lpc_compute_autocorr_c`). The `+1.0` seeds
/// match the C so that a silent block still yields a solvable system.
fn flac_lpc_autocorr(
  samples : Array[Int32],
  n : Int32,
  lag : Int32,
) -> Array[Double] {
  let windowed : Array[Double] = Array::make(n, 0.0)
  let c = 2.0 / (n - 1).to_double()
  for i = 0; i < n; i = i + 1 {
    let t = c * i.to_double() - 1.0
    windowed[i] = samples[i].to_double() * (1.0 - t * t)
  }
  let autoc : Array[Double] = Array::make(lag + 1, 1.0)
  for j = 0; j <= lag; j = j + 1 {
    let mut sum = 1.0
    for i = j; i < n; i = i + 1 {
      sum = sum + windowed[i] * windowed[i - j]
    }
    autoc[j] = sum
  }
  autoc
}

///|
/// Levinson-Durbin recursion (`compute_lpc_coefs` with `LPC_TYPE` = double).
/// Returns the predictor coefficients of orders 1..max_order in the decoder's
/// `sum_j coef[j] * x[i-1-j]` order.
fn flac_lpc_levinson(
  autoc : Array[Double],
  max_order : Int32,
) -> Array[Array[Double]] {
  let orders : Array[Array[Double]] = []
  let mut err = autoc[0]
  let mut last : Array[Double] = []
  for i = 0; i < max_order; i = i + 1 {
    let mut r = -autoc[i + 1]
    for j = 0; j < i; j = j + 1 {
      r = r - last[j] * autoc[i - j]
    }
    if err != 0.0 {
      r = r / err
    }
    let cur : Array[Double] = Array::make(i + 1, 0.0)
    for j = 0; j < i; j = j + 1 {
      cur[j] = last[j] + r * last[i - 1 - j]
    }
    cur[i] = r
    err = err * (1.0 - r * r)
    orders.push(cur)
    last = cur
  }
  orders
}

///|
/// `quantize_lpc_coefs`: 15-bit coefficients with an error-feedback quantizer
/// and a level shift of at most 15 bits.
fn flac_quantize_lpc(
  coefs : Array[Double],
  order : Int32,
  precision : Int32,
  max_shift : Int32,
) -> (Array[Int32], Int32) {
  let qmax = (1 << (precision - 1)) - 1
  let mut cmax = 0.0
  for i = 0; i < order; i = i + 1 {
    let a = if coefs[i] < 0.0 { -coefs[i] } else { coefs[i] }
    if a > cmax {
      cmax = a
    }
  }
  if cmax * (1 << max_shift).to_double() < 1.0 {
    return (Array::make(order, 0), 0)
  }
  let mut sh = max_shift
  while sh > 0 && cmax * (1 << sh).to_double() > qmax.to_double() {
    sh = sh - 1
  }
  // Negative shifts do not exist in the bitstream: scale the coefficients
  // down instead so `shift` stays 0.
  let scale = if sh == 0 && cmax > qmax.to_double() {
    qmax.to_double() / cmax
  } else {
    1.0
  }
  let out : Array[Int32] = Array::make(order, 0)
  let unit = (1 << sh).to_double()
  let mut error = 0.0
  for i = 0; i < order; i = i + 1 {
    error = error - coefs[i] * scale * unit
    let mut q = @math.floor(error + 0.5).to_int()
    if q > qmax {
      q = qmax
    } else if q < -qmax {
      q = -qmax
    }
    out[i] = q
    error = error - q.to_double()
  }
  (out, sh)
}

///|
/// LPC residual `x[i] - (sum_j coef[j] * x[i-1-j] >> shift)`; `None` when a
/// residual falls outside the 32-bit range the bitstream can carry.
fn flac_lpc_residual(
  samples : Array[Int32],
  n : Int32,
  order : Int32,
  coefs : Array[Int32],
  shift : Int32,
) -> Array[Int32]? {
  let res : Array[Int32] = Array::make(n, 0)
  for i = 0; i < order; i = i + 1 {
    res[i] = samples[i]
  }
  for i = order; i < n; i = i + 1 {
    let mut sum = 0L
    for j = 0; j < order; j = j + 1 {
      sum = sum + coefs[j].to_int64() * samples[i - 1 - j].to_int64()
    }
    let r = samples[i].to_int64() - (sum >> shift)
    if r < -2147483648L || r > 2147483647L {
      return None
    }
    res[i] = r.to_int()
  }
  Some(res)
}

///|
/// One encoded subframe choice.
priv struct FlacSubframePlan {
  kind : Int32 // 0 constant, 1 verbatim, 2 fixed, 3 LPC
  order : Int32
  porder : Int32
  rice_ks : Array[Int32]
  residual : Array[Int32]
  wasted : Int32
  lpc_shift : Int32
  lpc_coeffs : Array[Int32]
  bits : Int64
}

///|
/// `remove_wasted_bits`: common trailing zero bits in a subframe (0 when none). */
fn flac_wasted_bits(samples : Array[Int32], n : Int32, bits : Int32) -> Int32 {
  let mut v = 0
  for i = 0; i < n; i = i + 1 {
    v = v | samples[i]
    if (v & 1) != 0 {
      return 0
    }
  }
  if v == 0 {
    return 0
  }
  let mut wasted = 0
  let mut x = v
  while (x & 1) == 0 {
    x = x >> 1
    wasted = wasted + 1
  }
  if wasted >= bits {
    bits - 1
  } else {
    wasted
  }
}

///|
fn flac_plan_subframe(
  samples : Array[Int32],
  n : Int32,
  bits : Int32,
) -> FlacSubframePlan {
  let wasted = flac_wasted_bits(samples, n, bits)
  let eff_bits = bits - wasted
  let work : Array[Int32] = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    work[i] = if wasted > 0 { samples[i] >> wasted } else { samples[i] }
  }
  let wasted_cost = if wasted > 0 { wasted.to_int64() } else { 0L }
  let mut constant = true
  for i = 1; i < n; i = i + 1 {
    if work[i] != work[0] {
      constant = false
      break
    }
  }
  if constant {
    return {
      kind: 0,
      order: 0,
      porder: 0,
      rice_ks: [],
      residual: [],
      wasted,
      lpc_shift: 0,
      lpc_coeffs: [],
      bits: 8L + eff_bits.to_int64() + wasted_cost,
    }
  }
  let verbatim_bits = 8L + (n * eff_bits).to_int64() + wasted_cost
  let rice2 = eff_bits > 16
  let max_k = if rice2 { 30 } else { 14 }
  let param_bits = if rice2 { 5 } else { 4 }
  let mut best : FlacSubframePlan = {
    kind: 1,
    order: 0,
    porder: 0,
    rice_ks: [],
    residual: [],
    wasted,
    lpc_shift: 0,
    lpc_coeffs: [],
    bits: verbatim_bits,
  }
  // Predictors are ranked by their single-partition cost; the cheapest one
  // then gets the full partition-order search, since running it for every
  // candidate order multiplies the Rice search by the number of orders.
  let mut pred : FlacSubframePlan? = None
  let mut pred_bits = -1L
  let header_base = 8L + 2L + wasted_cost + 4L + param_bits.to_int64()
  let max_order = if n - 1 < 4 { n - 1 } else { 4 }
  for order = 0; order <= max_order; order = order + 1 {
    let residual = flac_fixed_residual(work, n, order)
    let (k, rice_bits) = flac_choose_rice(residual, order, n, max_k)
    let total = header_base + (order * eff_bits).to_int64() + rice_bits
    if pred_bits < 0L || total < pred_bits {
      pred_bits = total
      pred = Some({
        kind: 2,
        order,
        porder: 0,
        rice_ks: [k],
        residual,
        wasted,
        lpc_shift: 0,
        lpc_coeffs: [],
        bits: total,
      })
    }
  }
  // LPC: Levinson-Durbin coefficients quantized to 15 bits. Every order is
  // costed exactly (subframe header + warm-ups + coefficients + Rice), so LPC
  // only wins when it beats the fixed predictors on the real bit count.
  if n >= 32 {
    let max_lpc = if n - 1 < 12 { n - 1 } else { 12 }
    let autoc = flac_lpc_autocorr(work, n, max_lpc)
    let orders = flac_lpc_levinson(autoc, max_lpc)
    for order = 1; order <= max_lpc; order = order + 1 {
      let (coefs, shift) = flac_quantize_lpc(orders[order - 1], order, 15, 15)
      match flac_lpc_residual(work, n, order, coefs, shift) {
        None => ()
        Some(residual) => {
          let (k, rice_bits) = flac_choose_rice(residual, order, n, max_k)
          let total = header_base +
            (order * eff_bits).to_int64() +
            9L +
            15L * order.to_int64() +
            rice_bits
          if pred_bits < 0L || total < pred_bits {
            pred_bits = total
            pred = Some({
              kind: 3,
              order,
              porder: 0,
              rice_ks: [k],
              residual,
              wasted,
              lpc_shift: shift,
              lpc_coeffs: coefs,
              bits: total,
            })
          }
        }
      }
    }
  }
  match pred {
    None => ()
    Some(p) => {
      let header = 8L +
        (p.order * eff_bits).to_int64() +
        2L +
        wasted_cost +
        (if p.kind == 3 { 9L + 15L * p.order.to_int64() } else { 0L })
      let (porder, ks, rice_total) = flac_choose_partitioned_rice(
        p.residual,
        n,
        p.order,
        max_k,
        param_bits,
      )
      let total = header + rice_total
      if total < best.bits {
        best = {
          kind: p.kind,
          order: p.order,
          porder,
          rice_ks: ks,
          residual: p.residual,
          wasted,
          lpc_shift: p.lpc_shift,
          lpc_coeffs: p.lpc_coeffs,
          bits: total,
        }
      }
    }
  }
  best
}

///|
fn flac_write_subframe(
  w : FlacBits,
  samples : Array[Int32],
  n : Int32,
  bits : Int32,
  plan : FlacSubframePlan,
) -> Unit {
  let shift = plan.wasted
  let eff_bits = bits - shift
  // subframe header: zero bit, 6-bit type, wasted-bits flag
  let type_code = if plan.kind == 0 {
    0U
  } else if plan.kind == 1 {
    1U
  } else if plan.kind == 2 {
    (8U | plan.order.reinterpret_as_uint()) & 0x3FU
  } else {
    (32U | (plan.order - 1).reinterpret_as_uint()) & 0x3FU
  }
  w.write(0U, 1)
  w.write(type_code, 6)
  w.write(if shift > 0 { 1U } else { 0U }, 1)
  if shift > 0 {
    // unary: wasted-1 zero bits followed by one
    w.write(1U, shift)
  }
  if plan.kind == 0 {
    w.write_signed(samples[0] >> shift, eff_bits)
  } else if plan.kind == 1 {
    for i = 0; i < n; i = i + 1 {
      w.write_signed(samples[i] >> shift, eff_bits)
    }
  } else {
    for i = 0; i < plan.order; i = i + 1 {
      w.write_signed(samples[i] >> shift, eff_bits)
    }
    if plan.kind == 3 {
      // coefficient precision - 1 (15 bits) and the signed quantizer shift
      w.write(14U, 4)
      w.write_signed(plan.lpc_shift, 5)
      for i = 0; i < plan.order; i = i + 1 {
        w.write_signed(plan.lpc_coeffs[i], 15)
      }
    }
    let rice2 = eff_bits > 16
    // 2-bit coding mode (0 = Rice, 1 = Rice2) and the partition order
    w.write(if rice2 { 1U } else { 0U }, 2)
    w.write(plan.porder.reinterpret_as_uint(), 4)
    let psize = n >> plan.porder
    let parts = 1 << plan.porder
    let mut wi = plan.order
    for part = 0; part < parts; part = part + 1 {
      let k = plan.rice_ks[part]
      w.write(k.reinterpret_as_uint(), if rice2 { 5 } else { 4 })
      let count = if part == 0 { psize - plan.order } else { psize }
      for c = 0; c < count; c = c + 1 {
        flac_write_rice(w, plan.residual[wi], k)
        wi = wi + 1
      }
    }
  }
}

///|
pub struct FlacEncoded {
  streaminfo : Bytes
  frames : Array[Bytes]
  sample_rate : Int32
  channels : Int32
  bits : Int32
  total_samples : Int64
  min_frame_size : Int32
  max_frame_size : Int32
  md5 : FixedArray[Byte]
}

///|
fn flac_bps_code(bits : Int32) -> Result[Int32, String] {
  match bits {
    8 => Ok(1)
    12 => Ok(2)
    16 => Ok(4)
    20 => Ok(5)
    24 => Ok(6)
    _ => Err("EINVAL: FLAC encoder supports 8/12/16/20/24-bit samples")
  }
}

///|
fn flac_blocksize_code(
  block_size : Int32,
  is_full : Bool,
  out : Array[Byte],
) -> Int32 {
  if is_full {
    match block_size {
      192 => return 1
      576 => return 2
      1152 => return 3
      2304 => return 4
      4608 => return 5
      256 => return 8
      512 => return 9
      1024 => return 10
      2048 => return 11
      4096 => return 12
      8192 => return 13
      16384 => return 14
      32768 => return 15
      _ => ()
    }
  }
  // Explicit 8-bit or 16-bit block size
  if block_size <= 256 {
    out.push((block_size - 1).to_byte())
    return 6
  }
  out.push(((block_size - 1) >> 8).to_byte())
  out.push(((block_size - 1) & 0xFF).to_byte())
  7
}

///|
/// Encode interleaved PCM into a FLAC stream.  Each call produces one complete
/// `fLaC` file (STREAMINFO + all frames); `samples` must hold
/// `channels * total_samples` values in the signed range of `bits`.
pub fn flac_encode(
  samples : Array[Int32],
  channels : Int32,
  sample_rate : Int32,
  bits : Int32,
  block_size~ : Int32 = 4096,
) -> Result[FlacEncoded, String] {
  if channels < 1 || channels > 8 {
    return Err("EINVAL: FLAC channels must be 1..8")
  }
  if sample_rate <= 0 || sample_rate > 1048575 {
    return Err("EINVAL: invalid FLAC sample rate")
  }
  if block_size < 16 || block_size > 65535 {
    return Err("EINVAL: invalid FLAC block size")
  }
  let bps_code = match flac_bps_code(bits) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if samples.length() % channels != 0 {
    return Err("EINVAL: FLAC samples are not interleaved")
  }
  let total = samples.length() / channels
  let frames : Array[Bytes] = []
  let pcm_bytes : Array[Byte] = []
  for i in 0..<total {
    for ch = 0; ch < channels; ch = ch + 1 {
      let v = samples[i * channels + ch]
      let bytes_per = bits / 8
      if bits == 12 {
        pcm_bytes.push((v & 0xFF).to_byte())
        pcm_bytes.push(((v >> 8) & 0xFF).to_byte())
      } else if bytes_per == 1 {
        pcm_bytes.push((v & 0xFF).to_byte())
      } else if bytes_per == 2 {
        pcm_bytes.push((v & 0xFF).to_byte())
        pcm_bytes.push(((v >> 8) & 0xFF).to_byte())
      } else {
        pcm_bytes.push((v & 0xFF).to_byte())
        pcm_bytes.push(((v >> 8) & 0xFF).to_byte())
        pcm_bytes.push(((v >> 16) & 0xFF).to_byte())
      }
    }
  }
  let mut pos = 0
  let mut min_frame = -1
  let mut max_frame = 0
  let mut frame_number : UInt32 = 0U
  while pos < total {
    let n = if total - pos < block_size { total - pos } else { block_size }
    let is_full = n == block_size
    let w = flac_bits_new()
    // Gather the source channels for this block.
    let chans : Array[Array[Int32]] = []
    for ch = 0; ch < channels; ch = ch + 1 {
      let ch_samples : Array[Int32] = Array::make(n, 0)
      for i in 0..<n {
        ch_samples[i] = samples[(pos + i) * channels + ch]
      }
      chans.push(ch_samples)
    }
    // Stereo decorrelation: try independent, left-side, right-side and
    // mid-side, keeping the smallest estimated subframe cost.
    let mut channel_code = channels - 1
    let mut sel0 = chans[0]
    let mut sel1 = if channels == 2 { chans[1] } else { chans[0] }
    let mut out_bits0 = bits
    let mut out_bits1 = bits
    let plan0 = flac_plan_subframe(sel0, n, out_bits0)
    let mut best_plan0 = plan0
    let mut best_plan1 = plan0
    let mut best_total = plan0.bits
    if channels == 2 {
      let side : Array[Int32] = Array::make(n, 0)
      let mid : Array[Int32] = Array::make(n, 0)
      for i in 0..<n {
        side[i] = chans[0][i] - chans[1][i]
        mid[i] = (chans[0][i] + chans[1][i]) >> 1
      }
      let plan_r = flac_plan_subframe(chans[1], n, bits)
      best_plan1 = plan_r
      best_total = best_plan0.bits + plan_r.bits
      // left-side: L + (L-R)
      let p0 = flac_plan_subframe(chans[0], n, bits)
      let p1 = flac_plan_subframe(side, n, bits + 1)
      if p0.bits + p1.bits < best_total {
        best_total = p0.bits + p1.bits
        best_plan0 = p0
        best_plan1 = p1
        sel0 = chans[0]
        sel1 = side
        out_bits0 = bits
        out_bits1 = bits + 1
        channel_code = 8
      }
      // right-side: (L-R) + R
      let p0r = flac_plan_subframe(side, n, bits + 1)
      let p1r = flac_plan_subframe(chans[1], n, bits)
      if p0r.bits + p1r.bits < best_total {
        best_total = p0r.bits + p1r.bits
        best_plan0 = p0r
        best_plan1 = p1r
        sel0 = side
        sel1 = chans[1]
        out_bits0 = bits + 1
        out_bits1 = bits
        channel_code = 9
      }
      // mid-side: (L+R)>>1 + (L-R)
      let p0m = flac_plan_subframe(mid, n, bits)
      let p1m = flac_plan_subframe(side, n, bits + 1)
      if p0m.bits + p1m.bits < best_total {
        best_total = p0m.bits + p1m.bits
        best_plan0 = p0m
        best_plan1 = p1m
        sel0 = mid
        sel1 = side
        out_bits0 = bits
        out_bits1 = bits + 1
        channel_code = 10
      }
    }
    // frame header
    w.write(0xFFF8U, 16)
    let bs_extra : Array[Byte] = []
    let bs_code = flac_blocksize_code(n, is_full, bs_extra)
    w.write(bs_code.reinterpret_as_uint(), 4)
    w.write(0U, 4) // sample rate: from STREAMINFO
    w.write(channel_code.reinterpret_as_uint(), 4)
    w.write(bps_code.reinterpret_as_uint(), 3)
    w.write(0U, 1)
    flac_write_utf8(w, frame_number)
    for b in bs_extra {
      w.write(b.to_uint(), 8)
    }
    let header_crc = {
      let table = @libavutil.av_crc_init(false, 8, 0x07U).unwrap()
      @libavutil.av_crc(table, 0U, Bytes::from_array(w.out))
    }
    w.write(header_crc & 0xFFU, 8)
    flac_write_subframe(w, sel0, n, out_bits0, best_plan0)
    if channels == 2 {
      flac_write_subframe(w, sel1, n, out_bits1, best_plan1)
    }
    w.align()
    let frame_crc = {
      let table = @libavutil.av_crc_init(false, 16, 0x8005U).unwrap()
      let crc = @libavutil.av_crc(table, 0U, Bytes::from_array(w.out))
      let swapped = ((crc & 0xFFU) << 8) | ((crc >> 8) & 0xFFU)
      swapped
    }
    w.write(frame_crc & 0xFFFFU, 16)
    let frame = Bytes::from_array(w.bytes())
    let frame_len = frame.length()
    if min_frame < 0 || frame_len < min_frame {
      min_frame = frame_len
    }
    if frame_len > max_frame {
      max_frame = frame_len
    }
    frames.push(frame)
    frame_number = frame_number + 1U
    pos = pos + n
  }
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(
    digest,
    Bytes::from_array(pcm_bytes),
    pcm_bytes.length(),
  )
  let streaminfo : Array[Byte] = []
  flac_put_u16(streaminfo, block_size)
  flac_put_u16(streaminfo, block_size)
  flac_put_u24(streaminfo, if min_frame < 0 { 0 } else { min_frame })
  flac_put_u24(streaminfo, max_frame)
  // sample rate (20) | channels-1 (3) | bits-1 (5) | total samples (36)
  let packed : UInt64 = (sample_rate.reinterpret_as_uint().to_uint64() << 44) |
    ((channels - 1).reinterpret_as_uint().to_uint64() << 41) |
    ((bits - 1).reinterpret_as_uint().to_uint64() << 36) |
    total.to_uint64()
  for i in 0..<8 {
    streaminfo.push(((packed >> (56 - 8 * i)) & 0xFFUL).to_byte())
  }
  for b in digest {
    streaminfo.push(b)
  }
  Ok({
    streaminfo: Bytes::from_array(streaminfo),
    frames,
    sample_rate,
    channels,
    bits,
    total_samples: total.to_int64(),
    min_frame_size: if min_frame < 0 {
      0
    } else {
      min_frame
    },
    max_frame_size: max_frame,
    md5: digest,
  })
}

///|
/// Complete `fLaC` file: marker, last STREAMINFO metadata block and all frames.
pub fn FlacEncoded::file(self : FlacEncoded) -> Bytes {
  let out : Array[Byte] = []
  for b in b"fLaC" {
    out.push(b)
  }
  out.push(b'\x80') // last metadata block, type 0 (STREAMINFO)
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x22') // 34 bytes
  for b in self.streaminfo {
    out.push(b)
  }
  for frame in self.frames {
    for b in frame {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}
