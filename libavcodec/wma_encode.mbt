///|
/// WMA v1/v2 encoder — MoonBit port of FFmpeg 9.0.2 `libavcodec/wmaenc.c`
/// (the `ff_wmav1_encoder` / `ff_wmav2_encoder` pure-algorithm core).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Deviations from the C:
///   * The shared `ff_wma_init` parameter derivation (frame length, band
///     tables, coefficient VLC choice) is reused verbatim from the decoder
///     port by embedding a `WmaDecoder` built with the encoder's flag set
///     (`flags2 = 1`: exp-VLC exponents, no bit reservoir, fixed block
///     length) — exactly the constants the C encoder pins in `encode_init`.
///   * The MDCT is a direct f64 evaluation of `ff_tx_mdct_naive_fwd`
///     (`X[i] = sum_j x[j]*cos(pi/(4N)*(2j+1+N)*(2i+1))`, scale 1) with a
///     rotation recurrence; the stock build runs the av_tx f32 split-radix
///     codelet, so quantizer boundary flips are possible in principle but
///     the ~1e-13 relative drift stays far below the lrint rounding grid.
///     Verified by cross-decoding (this stream decodes in FFmpeg, FFmpeg's
///     stream decodes here) and round-trip SNR.
///   * `lrint` is spelled out as round-half-to-even (the C default
///     rounding mode).
///   * Packet assembly reproduces the C byte-for-byte protocol: binary
///     search over `total_gain`, the final `encode_frame` output plus
///     `'N'` padding up to `block_align`.

///|
/// `BLOCK_MAX_SIZE`.
let wma_enc_block_max_size = 2048

///|
/// `MAX_CODED_SUPERFRAME_SIZE`.
let wma_enc_max_coded_superframe_size = 16384

///| `M_LOG2_10` — unused here, `exp10` goes through `pow(10, x)` like the
/// decoder's verified `wma_exp10_20`.

///|
/// `ff_exp10(x)` in the decoder-verified form: `pow(10, x)`.
fn wma_enc_exp10(x : Double) -> Double {
  @math.pow(10.0, x)
}

///|
/// f32 rounding (C `float` truncation on assignment).
fn wma_enc_f32(x : Double) -> Double {
  Float::from_double(x).to_double()
}

///|
/// `lrint` with the C default rounding mode (round half to even).
fn wma_enc_lrint(x : Double) -> Int32 {
  let r = @math.floor(x)
  let diff = x - r
  if diff > 0.5 {
    (r + 1.0).to_int()
  } else if diff < 0.5 {
    r.to_int()
  } else {
    // tie: floor must round to even
    let odd = r.mod(2.0) != 0.0
    if odd {
      (r + 1.0).to_int()
    } else {
      r.to_int()
    }
  }
}

///|
/// `ff_tx_mdct_naive_fwd` (scale 1): `X[i] = sum_{j<2N} x[j] *
/// cos(pi/(4N)*(2j+1+N)*(2i+1))`, evaluated with a per-output rotation
/// recurrence (`step` is exact arithmetic; the drift stays ~1e-13 relative
/// over 2N steps).
fn wma_enc_mdct_fwd(x : Array[Double], len : Int32) -> Array[Double] {
  let out : Array[Double] = Array::make(len, 0.0)
  let phase = 3.14159265358979323846 / (4.0 * len.to_double())
  for i = 0; i < len; i = i + 1 {
    let m = (2 * i + 1).to_double()
    let step = 2.0 * m * phase
    let cs = @math.cos(step)
    let sn = @math.sin(step)
    let mut c = @math.cos((1.0 + len.to_double()) * m * phase)
    let mut s = @math.sin((1.0 + len.to_double()) * m * phase)
    let mut sum = 0.0
    for j = 0; j < 2 * len; j = j + 1 {
      sum = sum + x[j] * c
      let nc = c * cs - s * sn
      s = s * cs + c * sn
      c = nc
    }
    out[i] = sum
  }
  out
}

///|
/// Encoder-side coefficient VLC table: the raw code/bit tables plus the
/// `int_table` (first code index per absolute level) derived exactly like
/// C `init_coef_vlc`.
struct WmaCoefEnc {
  codes : FixedArray[UInt32]
  bits : FixedArray[Int32]
  levels : FixedArray[Int32]
  int_table : Array[Int32]
}

///|
/// Build `WmaCoefEnc` for one of the six tables.
fn wma_coef_enc_table(idx : Int32) -> WmaCoefEnc {
  let codes : FixedArray[UInt32] = match idx {
    0 => wma_coef0_codes
    1 => wma_coef1_codes
    2 => wma_coef2_codes
    3 => wma_coef3_codes
    4 => wma_coef4_codes
    _ => wma_coef5_codes
  }
  let bits : FixedArray[Int32] = match idx {
    0 => wma_coef0_bits
    1 => wma_coef1_bits
    2 => wma_coef2_bits
    3 => wma_coef3_bits
    4 => wma_coef4_bits
    _ => wma_coef5_bits
  }
  let levels : FixedArray[Int32] = match idx {
    0 => wma_coef0_levels
    1 => wma_coef1_levels
    2 => wma_coef2_levels
    3 => wma_coef3_levels
    4 => wma_coef4_levels
    _ => wma_coef5_levels
  }
  // init_coef_vlc: i starts at 2; each level block of `levels[k]` codes
  // records int_table[k] = i.
  let n = codes.length()
  let int_table : Array[Int32] = []
  let mut i = 2
  let mut k = 0
  while i < n && k < levels.length() {
    int_table.push(i)
    let l = levels[k]
    i = i + l
    k = k + 1
  }
  { codes, bits, levels, int_table, }
}

///|
/// `WMACodecContext` encoder side.  Shared `ff_wma_init` parameters live in
/// the embedded decoder state.
pub struct WmaEncoder {
  d : WmaDecoder
  ms_stereo : Bool
  coef_enc : Array[WmaCoefEnc]
  coefs : Array[Array[Double]]
  coefs1 : Array[Array[Int32]]
  exponents : Array[Array[Double]]
  max_exponent : FixedArray[Double]
  channel_coded : FixedArray[Bool]
  output : Array[Double]
  frame_out : Array[Array[Double]]
  frame_len : Int32
  frame_len_bits : Int32
  block_align : Int32
  version : Int32
  extradata : Bytes
}

///|
/// `encode_init`: build the encoder for wmav1 (`version = 1`) or wmav2
/// (`version = 2`).  The C pins `flags1 = 0`, `flags2 = 1`.
pub fn wma_encoder_new(
  version : Int32,
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> Result[WmaEncoder, String] {
  if channels > 2 {
    return Err("wma_enc: too many channels: got \{channels}, need 2 or fewer")
  }
  if sample_rate > 48000 {
    return Err("wma_enc: sample rate is too high: \{sample_rate} > 48kHz")
  }
  if bit_rate < 24 * 1000 {
    return Err(
      "wma_enc: bitrate too low: got \{bit_rate}, need 24000 or higher",
    )
  }
  if version != 1 && version != 2 {
    return Err("wma_enc: only WMA v1/v2 are supported")
  }
  // flags2 = 1: use_exp_vlc, no bit reservoir, fixed block length.
  // block_align=1 satisfies the decoder constructor's positivity check; the
  // C's ff_wma_init never reads block_align, and the encoder computes its
  // own below.
  let flags2 = 1
  let d = match
    wma_decoder_new(version, sample_rate, channels, bit_rate, 1, flags2) {
    Ok(d) => d
    Err(e) => return Err(e)
  }
  let frame_len = d.frame_len
  let frame_len_bits = d.frame_len_bits
  let mut block_align = (bit_rate.to_int64() *
  frame_len.to_int64() /
  (sample_rate.to_int64() * 8L)).to_int()
  if block_align > wma_enc_max_coded_superframe_size {
    block_align = wma_enc_max_coded_superframe_size
  }
  // extradata: v1 = 4 bytes (flags1 u16, flags2 u16); v2 = 10 bytes
  // (flags1 u32, flags2 u16).
  let extradata : Array[Byte] = []
  if version == 1 {
    extradata.push(0)
    extradata.push(0)
    extradata.push(1)
    extradata.push(0)
  } else {
    // AV_WL32(extradata, flags1); AV_WL16(extradata + 4, flags2) - the
    // allocation is 10 bytes (mallocz), so four zero bytes trail.
    extradata.push(0)
    extradata.push(0)
    extradata.push(0)
    extradata.push(0)
    extradata.push(1)
    extradata.push(0)
    extradata.push(0)
    extradata.push(0)
    extradata.push(0)
    extradata.push(0)
  }
  let coef_enc = [
    wma_coef_enc_table(d.coef_vlc_index * 2),
    wma_coef_enc_table(d.coef_vlc_index * 2 + 1),
  ]
  let coefs : Array[Array[Double]] = []
  let coefs1 : Array[Array[Int32]] = []
  let exponents : Array[Array[Double]] = []
  let frame_out : Array[Array[Double]] = []
  for _ch in 0..<channels {
    coefs.push(Array::make(wma_enc_block_max_size, 0.0))
    coefs1.push(Array::make(wma_enc_block_max_size, 0))
    exponents.push(Array::make(wma_enc_block_max_size, 0.0))
    frame_out.push(Array::make(wma_enc_block_max_size * 2, 0.0))
  }
  Ok({
    d,
    ms_stereo: channels == 2,
    coef_enc,
    coefs,
    coefs1,
    exponents,
    max_exponent: FixedArray::make(2, 0.0),
    channel_coded: FixedArray::make(2, false),
    output: Array::make(wma_enc_block_max_size * 2, 0.0),
    frame_out,
    frame_len,
    frame_len_bits,
    block_align,
    version,
    extradata: Bytes::from_array(extradata),
  })
}

///|
/// `apply_window_and_mdct`: overlap windowing + forward MDCT.  `audio` is
/// interleaved samples of one frame (`frame_len * channels` values, f32
/// value range).
fn WmaEncoder::apply_window_and_mdct(
  self : WmaEncoder,
  audio : Array[Double],
  len : Int32,
) -> Bool {
  let channels = self.d.channels
  let window_index = self.frame_len_bits - self.frame_len_bits
  let window_len = 1 << self.frame_len_bits
  let win = self.d.windows[window_index]
  let n = wma_enc_f32(2.0 * 32768.0 / window_len.to_double())
  for ch = 0; ch < channels; ch = ch + 1 {
    let fo = self.frame_out[ch]
    let out = self.output
    // memcpy(output, frame_out[ch], window_len)
    for i = 0; i < window_len; i = i + 1 {
      out[i] = fo[i]
    }
    // vector_fmul_scalar(frame_out[ch], audio[ch], n, len)
    for i = 0; i < len; i = i + 1 {
      fo[i] = wma_enc_f32(audio[ch + i * channels] * n)
    }
    // vector_fmul_reverse(&output[window_len], frame_out[ch], win, len)
    for i = 0; i < len; i = i + 1 {
      out[window_len + i] = wma_enc_f32(fo[len - 1 - i] * win[i])
    }
    // vector_fmul(frame_out[ch], frame_out[ch], win, len)
    for i = 0; i < len; i = i + 1 {
      fo[i] = wma_enc_f32(fo[i] * win[i])
    }
    // MDCT of 2*window_len samples -> window_len coefficients.
    let input_len = 2 * window_len
    let mdct_in : Array[Double] = Array::make(input_len, 0.0)
    for i = 0; i < input_len; i = i + 1 {
      mdct_in[i] = out[i]
    }
    let coefs = wma_enc_mdct_fwd(mdct_in, window_len)
    let dst = self.coefs[ch]
    for i = 0; i < window_len; i = i + 1 {
      dst[i] = coefs[i]
    }
    // The C rejects non-finite coefficients; plain f64 arithmetic on
    // finite input cannot produce them, so only a NaN/Inf input triggers.
    let c0 = dst[0]
    if c0 != c0 || c0 * 0.0 != 0.0 {
      return false
    }
  }
  true
}

///|
/// `init_exp`: fill the exponent array from the fixed exponent parameter
/// (always 20 in the encoder) per scale-factor band.
fn WmaEncoder::init_exp(self : WmaEncoder, ch : Int32) -> Unit {
  let bands = self.d.exponent_bands[self.frame_len_bits - self.frame_len_bits]
  let exponents = self.exponents[ch]
  let block_len = 1 << self.frame_len_bits
  // exp_param is fixed_exp[] = 20 for every band.
  let v = wma_enc_f32(wma_enc_exp10(20.0 * (1.0 / 16.0)))
  let mut max_scale = wma_enc_f32(0.0)
  if v > max_scale {
    max_scale = v
  }
  let mut q = 0
  let mut b = 0
  while q < block_len && b < bands.length() {
    let n = bands[b]
    b = b + 1
    let mut i = 0
    while i < n && q < block_len {
      exponents[q] = v
      q = q + 1
      i = i + 1
    }
  }
  self.max_exponent[ch] = max_scale
}

///|
/// `encode_exp_vlc`.
fn WmaEncoder::encode_exp_vlc(self : WmaEncoder, bw : BitWriter) -> Unit {
  let bands = self.d.exponent_bands[self.frame_len_bits - self.frame_len_bits]
  let block_len = 1 << self.frame_len_bits
  let mut q = 0
  let mut b = 0
  let mut last_exp = 0
  if self.version == 1 {
    last_exp = 20
    bw.put((last_exp - 10).reinterpret_as_uint(), 5)
    // skip band 0
    if b < bands.length() {
      q = q + bands[b]
      b = b + 1
    }
  } else {
    last_exp = 36
  }
  while q < block_len && b < bands.length() {
    let exp = 20
    let code = exp - last_exp + 60
    bw.put(aac_scalefactor_code[code], aac_scalefactor_bits[code])
    q = q + bands[b]
    b = b + 1
    last_exp = exp
  }
}

///|
/// `encode_block`: returns 0 on success, -1 on quantizer overflow.
fn WmaEncoder::encode_block(
  self : WmaEncoder,
  bw : BitWriter,
  total_gain : Int32,
) -> Int32 {
  let channels = self.d.channels
  // fixed block len
  let next_block_len_bits = self.frame_len_bits
  let prev_block_len_bits = self.frame_len_bits
  let block_len_bits = self.frame_len_bits
  let block_len = 1 << block_len_bits
  let bsize = self.frame_len_bits - block_len_bits
  let _ = next_block_len_bits
  let _ = prev_block_len_bits

  let nb_coefs0 = self.d.coefs_end[bsize] - self.d.coefs_start
  let nb_coefs : FixedArray[Int32] = FixedArray::make(2, 0)
  nb_coefs[0] = nb_coefs0
  nb_coefs[1] = nb_coefs0

  let n4 = block_len / 2
  let mut mdct_norm = wma_enc_f32(1.0 / n4.to_double())
  if self.version == 1 {
    mdct_norm = wma_enc_f32(mdct_norm * n4.to_double().sqrt())
  }

  if channels == 2 {
    bw.put_bit(if self.ms_stereo { 1 } else { 0 })
  }

  for ch = 0; ch < channels; ch = ch + 1 {
    self.channel_coded[ch] = true
    self.init_exp(ch)
  }

  for ch = 0; ch < channels; ch = ch + 1 {
    let coefs1 = self.coefs1[ch]
    let exponents = self.exponents[ch]
    let mut mult = wma_enc_f32(
      wma_enc_exp10(total_gain.to_double() * 0.05) / self.max_exponent[ch],
    )
    mult = wma_enc_f32(mult * mdct_norm)
    let src = self.coefs[ch]
    let n = nb_coefs[ch]
    for i = 0; i < n; i = i + 1 {
      // C: double t = *coefs++ / (exponents[i] * mult) where the product
      // of the two floats rounds to f32 before the double division.
      let t = src[self.d.coefs_start + i] /
        Float::from_double(exponents[i] * mult).to_double()
      if t < -32768.0 || t > 32767.0 {
        return -1
      }
      coefs1[i] = wma_enc_lrint(t)
    }
  }

  let mut v = 0
  for ch = 0; ch < channels; ch = ch + 1 {
    let a = self.channel_coded[ch]
    bw.put_bit(if a { 1 } else { 0 })
    if a {
      v = 1
    }
  }

  if v == 0 {
    return 1
  }

  let mut tv = total_gain - 1
  while tv >= 127 {
    bw.put(127, 7)
    tv = tv - 127
  }
  bw.put(tv.reinterpret_as_uint(), 7)

  let coef_nb_bits = wma_total_gain_to_bits(total_gain)

  if self.d.use_noise_coding {
    for ch = 0; ch < channels; ch = ch + 1 {
      if self.channel_coded[ch] {
        let n = self.d.exponent_high_sizes[bsize]
        for _i in 0..<n {
          bw.put_bit(0)
        }
      }
    }
  }

  let parse_exponents = true
  if block_len_bits != self.frame_len_bits {
    bw.put_bit(1)
  }

  if parse_exponents {
    for ch = 0; ch < channels; ch = ch + 1 {
      if self.channel_coded[ch] {
        self.encode_exp_vlc(bw)
      }
    }
  }

  for ch = 0; ch < channels; ch = ch + 1 {
    if self.channel_coded[ch] {
      let tindex = if ch == 1 && self.ms_stereo { 1 } else { 0 }
      let tab = self.coef_enc[tindex]
      let mut run = 0
      for i = 0; i < nb_coefs[ch]; i = i + 1 {
        let level = self.coefs1[ch][i]
        if level != 0 {
          let abs_level = if level < 0 { -level } else { level }
          let mut code = 0
          if abs_level <= tab.levels.length() {
            if run < tab.levels[abs_level - 1] {
              code = run + tab.int_table[abs_level - 1]
            }
          }
          bw.put(tab.codes[code], tab.bits[code])
          if code == 0 {
            if 1 << coef_nb_bits <= abs_level {
              return -1
            }
            bw.put(abs_level.reinterpret_as_uint(), coef_nb_bits)
            bw.put(run.reinterpret_as_uint(), self.frame_len_bits)
          }
          bw.put_bit(if level < 0 { 1 } else { 0 })
          run = 0
        } else {
          run = run + 1
        }
      }
      if run != 0 {
        bw.put(tab.codes[1], tab.bits[1])
      }
    }
    if self.version == 1 && channels >= 2 {
      bw.align()
    }
  }
  0
}

///|
/// `encode_frame`: returns the frame size error in bytes
/// (bytes - block_align), or INT_MAX on overflow, plus the aligned bytes
/// (the C leaves them in the shared packet buffer).
fn WmaEncoder::encode_frame_bits(
  self : WmaEncoder,
  total_gain : Int32,
) -> (Int32, Bytes) {
  let bw = BitWriter::new()
  let err = self.encode_block(bw, total_gain)
  if err < 0 {
    return (2147483647, b"")
  }
  bw.align()
  let bytes = bw.finish()
  (bytes.length() - self.block_align, bytes)
}

///|
/// `encode_superframe`: one frame of interleaved samples
/// (`frame_len * channels`, f32 value range) into one `block_align` packet.
pub fn WmaEncoder::encode_frame(
  self : WmaEncoder,
  samples : Array[Double],
) -> Result[Bytes, String] {
  let channels = self.d.channels
  if samples.length() != self.frame_len * channels {
    return Err(
      "wma_enc: expected \{self.frame_len * channels} samples, got \{samples.length()}",
    )
  }
  // required by non variable block len
  let block_len_bits = self.frame_len_bits
  let block_len = 1 << block_len_bits
  if !self.apply_window_and_mdct(samples, self.frame_len) {
    return Err("wma_enc: input contains NaN/+-Inf")
  }
  let _ = block_len
  if self.ms_stereo {
    for i = 0; i < block_len; i = i + 1 {
      let a = self.coefs[0][i] * 0.5
      let b = self.coefs[1][i] * 0.5
      self.coefs[0][i] = a + b
      self.coefs[1][i] = a - b
    }
  }

  // total_gain binary search, exactly like the C.
  let mut total_gain = 128
  let mut error = 0
  let mut out : Bytes = b""
  let mut i = 64
  while i != 0 {
    let (e, bytes) = self.encode_frame_bits(total_gain - i)
    error = e
    if error <= 0 {
      total_gain = total_gain - i
      out = bytes
    }
    i = i >> 1
  }
  while total_gain <= 128 && error > 0 {
    let (e, bytes) = self.encode_frame_bits(total_gain)
    error = e
    total_gain = total_gain + 1
    out = bytes
  }
  if error > 0 {
    return Err(
      "wma_enc: invalid input data or requested bitrate too low, cannot encode",
    )
  }
  // pad up to block_align with 'N'.
  let pkt : Array[Byte] = []
  for b in out {
    pkt.push(b)
  }
  while pkt.length() < self.block_align {
    pkt.push(b'N')
  }
  Ok(Bytes::from_array(pkt))
}

///|
/// The declared extradata (v1: 4 bytes, v2: 10 bytes) for container muxing.
pub fn WmaEncoder::extradata(self : WmaEncoder) -> Bytes {
  self.extradata
}

///|
/// The coded packet size (`avctx->block_align`).
pub fn WmaEncoder::block_align(self : WmaEncoder) -> Int32 {
  self.block_align
}

///|
/// The declared frame size / initial padding (`avctx->frame_size`).
pub fn WmaEncoder::frame_size(self : WmaEncoder) -> Int32 {
  self.frame_len
}
