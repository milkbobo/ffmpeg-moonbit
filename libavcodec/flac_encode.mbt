///|
/// Minimal FLAC encoder: fixed predictors (orders 0..4), Rice-coded residuals
/// with partition order 0, optional Rice2 for >16-bit samples, independent
/// channels, and a complete `fLaC` stream (STREAMINFO + frames + MD5).
///
/// The layout follows FFmpeg 9.0.2 `flacenc.c` (frame header, subframe types,
/// `set_sr_golomb_flac`, CRC-8/CRC-16 and STREAMINFO), but the predictor choice
/// is limited to fixed orders and a single Rice partition.
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
fn flac_rice_bits(v : Int64, k : Int32) -> Int64 {
  (v >> k) + 1L + k.to_int64()
}

///|
fn flac_choose_rice(
  res : Array[Int32],
  from : Int32,
  max_k : Int32,
) -> (Int32, Int64) {
  let mut best_k = 0
  let mut best_bits = -1L
  for k = 0; k <= max_k; k = k + 1 {
    let mut bits = 0L
    for i in from..<res.length() {
      bits = bits + flac_rice_bits(flac_zigzag(res[i]), k)
    }
    if best_bits < 0L || bits < best_bits {
      best_bits = bits
      best_k = k
    }
  }
  (best_k, best_bits)
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
/// One encoded subframe choice.
priv struct FlacSubframePlan {
  kind : Int32 // 0 constant, 1 verbatim, 2 fixed
  order : Int32
  rice_k : Int32
  residual : Array[Int32]
  bits : Int64
}

///|
fn flac_plan_subframe(
  samples : Array[Int32],
  n : Int32,
  bits : Int32,
) -> FlacSubframePlan {
  let mut constant = true
  for i = 1; i < n; i = i + 1 {
    if samples[i] != samples[0] {
      constant = false
      break
    }
  }
  if constant {
    return {
      kind: 0,
      order: 0,
      rice_k: 0,
      residual: [],
      bits: 8L + bits.to_int64(),
    }
  }
  let verbatim_bits = 8L + (n * bits).to_int64()
  let rice2 = bits > 16
  let max_k = if rice2 { 30 } else { 14 }
  let param_bits = if rice2 { 5 } else { 4 }
  let mut best : FlacSubframePlan = {
    kind: 1,
    order: 0,
    rice_k: 0,
    residual: [],
    bits: verbatim_bits,
  }
  let max_order = if n - 1 < 4 { n - 1 } else { 4 }
  for order = 0; order <= max_order; order = order + 1 {
    let residual = flac_fixed_residual(samples, n, order)
    let (k, rice_bits) = flac_choose_rice(residual, order, max_k)
    let header = 8L +
      (order * bits).to_int64() +
      2L +
      4L +
      param_bits.to_int64()
    let total = header + rice_bits
    if total < best.bits {
      best = { kind: 2, order, rice_k: k, residual, bits: total, }
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
  // subframe header: zero bit, 6-bit type, wasted-bits flag
  if plan.kind == 0 {
    w.write(0U, 1)
    w.write(0U, 6)
    w.write(0U, 1)
    w.write_signed(samples[0], bits)
  } else if plan.kind == 1 {
    w.write(0U, 1)
    w.write(1U, 6)
    w.write(0U, 1)
    for i = 0; i < n; i = i + 1 {
      w.write_signed(samples[i], bits)
    }
  } else {
    w.write(0U, 1)
    w.write((8U | plan.order.reinterpret_as_uint()) & 0x3FU, 6)
    w.write(0U, 1)
    for i = 0; i < plan.order; i = i + 1 {
      w.write_signed(samples[i], bits)
    }
    let rice2 = bits > 16
    // 2-bit coding mode (0 = Rice, 1 = Rice2), partition order = 0
    w.write(if rice2 { 1U } else { 0U }, 2)
    w.write(0U, 4)
    w.write(plan.rice_k.reinterpret_as_uint(), if rice2 { 5 } else { 4 })
    for i = plan.order; i < n; i = i + 1 {
      flac_write_rice(w, plan.residual[i], plan.rice_k)
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
    // frame header
    w.write(0xFFF8U, 16)
    let bs_extra : Array[Byte] = []
    let bs_code = flac_blocksize_code(n, is_full, bs_extra)
    w.write(bs_code.reinterpret_as_uint(), 4)
    w.write(0U, 4) // sample rate: from STREAMINFO
    w.write((channels - 1).reinterpret_as_uint(), 4)
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
    let chans : Array[Array[Int32]] = []
    for ch = 0; ch < channels; ch = ch + 1 {
      let ch_samples : Array[Int32] = Array::make(n, 0)
      for i in 0..<n {
        ch_samples[i] = samples[(pos + i) * channels + ch]
      }
      chans.push(ch_samples)
    }
    for ch = 0; ch < channels; ch = ch + 1 {
      let plan = flac_plan_subframe(chans[ch], n, bits)
      flac_write_subframe(w, chans[ch], n, bits, plan)
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
