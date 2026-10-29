///|
/// Minimal ALAC encoder: SCE/CPE elements with prediction type 0 (no LPC),
/// Rice entropy coding and the 36-byte ALACSpecificConfig cookie.  This follows
/// FFmpeg 9.0.2 `alacenc.c`'s compressed path with `lpc_order = 0`; stereo is
/// coded as two independent channels (interlacing weight 0).
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
/// Encode interleaved PCM into ALAC frames.  Supports mono (SCE) and stereo
/// (CPE without decorrelation), 16- and 24-bit samples.
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
    w.write(0U, 8) // interlacing shift
    w.write(0U, 8) // interlacing left weight
    for _ch = 0; _ch < channels; _ch = _ch + 1 {
      w.write(0U, 4) // prediction type 0 (no LPC)
      w.write(1U, 4) // lpc_quant must be non-zero for the decoder
      w.write(4U, 3) // rice modifier
      w.write(0U, 5) // lpc order
    }
    let mask = if extra_bits > 0 { (1 << extra_bits) - 1 } else { 0 }
    if extra_bits > 0 {
      for i in 0..<n {
        w.write((l[i] & mask).reinterpret_as_uint(), extra_bits)
        if channels == 2 {
          w.write((r[i] & mask).reinterpret_as_uint(), extra_bits)
        }
      }
      for i = 0; i < n; i = i + 1 {
        l[i] = l[i] >> extra_bits
        r[i] = r[i] >> extra_bits
      }
    }
    alac_entropy_encode(w, l, bps)
    if channels == 2 {
      alac_entropy_encode(w, r, bps)
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
