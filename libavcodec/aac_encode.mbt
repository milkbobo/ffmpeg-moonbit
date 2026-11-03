///|
/// MoonBit port of a minimal AAC-LC encoder, shipped as ADTS frames.
///
/// Scope (stage 1): AAC-LC object type 2, one long window (ONLY_LONG) per
/// frame, sine window, no TNS / PNS / prediction / M/S, one SCE for mono or
/// one CPE with independent channels for stereo, and codebook 11 spectral
/// Huffman with magnitudes capped at 15 (no escape sequences). Per-band
/// scalefactors are chosen from the band peak (quantised magnitude <= 15) and
/// a single frame-wide offset is binary-searched so the ADTS frame fits the
/// requested average bit rate.
///
/// The quantiser/demultiplexing conventions follow FFmpeg 9.0.2
/// `libavcodec/aacenc.c` / `aacenc_quantization.h`:
///   * encoder MDCT coefficient `c` is `65536 * X` where `X` is the textbook
///     forward MDCT (the decoder's IMDCT carries `2/N` then divides by
///     65536),
///   * `q = floor((|c| * 2^(-(sf-100)/4))^(3/4) + 0.405)`,
///   * decoder dequantisation is `q^(4/3) * 2^((sf-100)/4)`.
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// Encoder configuration. Only AAC-LC (object type 2) is produced.
pub struct AacEncodeConfig {
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
}

///|
/// AAC-LC encoder state: per-channel 1024-sample overlap history, the swb band
/// plan of the configured sample rate and the precomputed MDCT kernel.
pub struct AacEncoder {
  config : AacEncodeConfig
  sampling_index : Int32
  swb_offsets : Array[Int32]
  num_swb : Int32
  history : Array[Array[Double]]
  cos_table : Array[Double]
  spectral_rev : Array[Int32]
}

///|
/// Build an AAC-LC encoder configuration.
pub fn aac_encode_config(
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> AacEncodeConfig {
  { sample_rate, channels, bit_rate, }
}

///|
/// MPEG-4 sampling_frequency_index for a sample rate (mpeg4audio.c table).
fn aac_encode_sampling_index(rate : Int32) -> Int32 {
  for i = 0; i < mpeg4audio_sample_rates.length(); i = i + 1 {
    if mpeg4audio_sample_rates[i] == rate {
      return i
    }
  }
  -1
}

///|
/// Forward MDCT kernel table: `K[j][t] = cos(pi/1024 * (t + 512.5) * (j + 0.5))`
/// for the 1024 coefficients of a 2048-sample window (`aac_mdct_forward`'s
/// kernel, precomputed because the direct O(N^2) loop is the encoder's hot
/// path).
fn aac_encode_cos_table() -> Array[Double] {
  let out : Array[Double] = Array::make(1024 * 2048, 0.0)
  let base = 3.14159265358979323846 / 1024.0
  for j = 0; j < 1024; j = j + 1 {
    let jf = j.to_double() + 0.5
    for t = 0; t < 2048; t = t + 1 {
      out[j * 2048 + t] = @math.cos(base * (t.to_double() + 512.5) * jf)
    }
  }
  out
}

///|
/// Reverse map from the codebook 11 packed pair index to its Huffman row.
/// Only escape-free symbols (|q| <= 15) are registered; `-1` marks the rest.
fn aac_encode_spectral_reverse() -> Array[Int32] {
  let rev : Array[Int32] = Array::make(16384, -1)
  for row = 0; row < aac_idx_pairs10.length(); row = row + 1 {
    let idx = aac_idx_pairs10[row].reinterpret_as_int()
    if idx >= 0 && idx < 16384 && ((idx >> 8) & 15) == 0 {
      rev[idx] = row
    }
  }
  rev
}

///|
/// Create an AAC-LC encoder for `config`. Supports 1 or 2 channels, a standard
/// MPEG-4 sample rate and a positive target bit rate.
pub fn aac_encoder_new(config : AacEncodeConfig) -> Result[AacEncoder, String] {
  if config.channels != 1 && config.channels != 2 {
    return Err("AAC encoder supports 1 or 2 channels")
  }
  if config.bit_rate <= 0 {
    return Err("AAC encoder requires a positive bit rate")
  }
  let sampling_index = aac_encode_sampling_index(config.sample_rate)
  if sampling_index < 0 {
    return Err("unsupported AAC sample rate")
  }
  let num_swb = aac_num_swb_1024[sampling_index]
  let table = aac_swb_offset_1024[sampling_index]
  if table.length() != num_swb + 1 {
    return Err("AAC swb table length mismatch")
  }
  let swb_offsets : Array[Int32] = []
  for i = 0; i < table.length(); i = i + 1 {
    swb_offsets.push(table[i].reinterpret_as_int())
  }
  let history : Array[Array[Double]] = []
  for _ch = 0; _ch < config.channels; _ch = _ch + 1 {
    history.push(Array::make(1024, 0.0))
  }
  Ok({
    config,
    sampling_index,
    swb_offsets,
    num_swb,
    history,
    cos_table: aac_encode_cos_table(),
    spectral_rev: aac_encode_spectral_reverse(),
  })
}

///|
/// Forward MDCT of the 2048-sample windowed buffer, scaled into the encoder's
/// coefficient domain (`65536 * textbook MDCT`).
fn AacEncoder::forward_mdct(
  self : AacEncoder,
  buf : Array[Double],
) -> Array[Double] {
  let win = aac_sine_long
  let d : Array[Double] = Array::make(2048, 0.0)
  for i = 0; i < 1024; i = i + 1 {
    d[i] = buf[i] * win[i]
    d[1024 + i] = buf[1024 + i] * win[1023 - i]
  }
  let out : Array[Double] = Array::make(1024, 0.0)
  for j = 0; j < 1024; j = j + 1 {
    let row = j * 2048
    let mut acc = 0.0
    for t = 0; t < 2048; t = t + 1 {
      acc = acc + d[t] * self.cos_table[row + t]
    }
    out[j] = acc * 65536.0
  }
  out
}

///|
/// Frame-wide base scalefactor: the smallest `sf` that keeps the frame's
/// largest coefficient's quantised magnitude at or below 15 (codebook 11
/// without escape). A frame-wide scale (rather than per-band peaks) makes
/// quiet bands quantise to zero, which is what a rate-controlled encoder
/// wants: only the energetic bands cost bits. `-1` marks an all-zero frame.
fn aac_encode_base_sf(coef : Array[Double]) -> Int32 {
  let mut peak = 0.0
  for i = 0; i < coef.length(); i = i + 1 {
    let a = coef[i].abs()
    if a > peak {
      peak = a
    }
  }
  if peak <= 0.0 {
    return -1
  }
  // (peak * 2^(-(sf-100)/4))^(3/4) + 0.405 <= 15
  let target = 100.0 + 4.0 * @math.log2(peak / 35.66)
  let g = @math.ceil(target).to_int()
  if g > 255 || g < 0 {
    return -1
  }
  g
}

///|
/// Quantise the whole spectrum at one scalefactor:
/// `q = sign(c) * floor((|c| * 2^(-(s-100)/4))^(3/4) + 0.405)`, clamped to 15
/// (codebook 11 has no escape). `s < 0` zeroes the spectrum.
fn aac_encode_quantize_all(
  q : Array[Int32],
  coef : Array[Double],
  s : Int32,
) -> Unit {
  if s < 0 {
    for i = 0; i < q.length(); i = i + 1 {
      q[i] = 0
    }
    return
  }
  let step = @math.pow(2.0, -(s - 100).to_double() / 4.0)
  for i = 0; i < coef.length(); i = i + 1 {
    let a = coef[i].abs() * step
    let mut n = if a <= 0.0 { 0 } else { (@math.pow(a, 0.75) + 0.405).to_int() }
    if n > 15 {
      n = 15
    }
    q[i] = if coef[i] < 0.0 && n > 0 { -n } else { n }
  }
}

///|
/// One channel's quantised spectrum plus its per-band scalefactors.
priv struct AacEncChannel {
  sf : Array[Int32]
  q : Array[Int32]
  max_sfb : Int32
}

///|
/// Build one channel's quantised spectrum at the frame-wide scalefactor
/// `base_sf + delta`. Bands whose quantised coefficients are all zero get
/// scalefactor `-1` and are coded with codebook 0.
fn aac_encode_channel_data(
  coef : Array[Double],
  base_sf : Int32,
  offsets : Array[Int32],
  num_swb : Int32,
  delta : Int32,
) -> AacEncChannel {
  let sf : Array[Int32] = Array::make(num_swb, -1)
  let q : Array[Int32] = Array::make(1024, 0)
  let mut max_sfb = 0
  if base_sf >= 0 {
    let v = if base_sf + delta > 255 { 255 } else { base_sf + delta }
    aac_encode_quantize_all(q, coef, v)
    for b = 0; b < num_swb; b = b + 1 {
      let mut nonzero = false
      for i = offsets[b]; i < offsets[b + 1]; i = i + 1 {
        if q[i] != 0 {
          nonzero = true
          break
        }
      }
      if nonzero {
        sf[b] = v
        max_sfb = b + 1
      }
    }
  }
  { sf, q, max_sfb, }
}

///|
/// Global gain: the first coded band's scalefactor (or 100 when silent).
fn aac_encode_global_gain(ch : AacEncChannel) -> Int32 {
  for b = 0; b < ch.max_sfb; b = b + 1 {
    if ch.sf[b] >= 0 {
      return ch.sf[b]
    }
  }
  100
}

///|
/// section_data: group runs of equal band type (0 = zero, 11 = codebook 11).
fn aac_encode_write_sections(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let mut b = 0
  while b < ch.max_sfb {
    let cb = if ch.sf[b] >= 0 { 11 } else { 0 }
    let mut e = b + 1
    while e < ch.max_sfb && (if ch.sf[e] >= 0 { 11 } else { 0 }) == cb {
      e = e + 1
    }
    bw.put(cb.reinterpret_as_uint(), 4)
    let mut len = e - b
    while len >= 31 {
      bw.put(31, 5)
      len = len - 31
    }
    bw.put(len.reinterpret_as_uint(), 5)
    b = e
  }
}

///|
/// scale_factor_data: differential Huffman coding (60 = zero delta).
fn aac_encode_write_scalefactors(
  bw : BitWriter,
  ch : AacEncChannel,
  global_gain : Int32,
) -> Unit {
  let mut prev = global_gain
  for b = 0; b < ch.max_sfb; b = b + 1 {
    if ch.sf[b] >= 0 {
      let mut diff = ch.sf[b] - prev + 60
      if diff < 0 {
        diff = 0
      }
      if diff > 120 {
        diff = 120
      }
      bw.put(aac_scalefactor_code[diff], aac_scalefactor_bits[diff])
      prev = ch.sf[b]
    }
  }
}

///|
/// spectral_data: codebook 11 pairs plus one sign bit per non-zero magnitude.
fn aac_encode_write_spectral(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  rev : Array[Int32],
) -> Unit {
  for b = 0; b < ch.max_sfb; b = b + 1 {
    if ch.sf[b] < 0 {
      continue
    }
    let mut i = offsets[b]
    let end = offsets[b + 1]
    while i < end {
      let v0 = ch.q[i]
      let v1 = ch.q[i + 1]
      let a0 = if v0 < 0 { -v0 } else { v0 }
      let a1 = if v1 < 0 { -v1 } else { v1 }
      let nnz = (if a0 != 0 { 1 } else { 0 }) + (if a1 != 0 { 1 } else { 0 })
      let packed = (nnz << 12) | (a1 << 4) | a0
      let row = rev[packed]
      bw.put(aac_codes11[row], aac_bits11[row])
      if a0 != 0 {
        bw.put_bit(if v0 < 0 { 1 } else { 0 })
      }
      if a1 != 0 {
        bw.put_bit(if v1 < 0 { 1 } else { 0 })
      }
      i = i + 2
    }
  }
}

///|
/// individual_channel_stream for one channel of the raw_data_block.
fn aac_encode_write_channel(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  rev : Array[Int32],
) -> Unit {
  let global_gain = aac_encode_global_gain(ch)
  bw.put(global_gain.reinterpret_as_uint(), 8)
  // ics_info: reserved bit, ONLY_LONG, sine window, max_sfb, no prediction.
  bw.put(0, 1)
  bw.put(0, 2)
  bw.put(0, 1)
  bw.put(ch.max_sfb.reinterpret_as_uint(), 6)
  bw.put(0, 1)
  aac_encode_write_sections(bw, ch)
  aac_encode_write_scalefactors(bw, ch, global_gain)
  bw.put(0, 1) // pulse_data_present
  bw.put(0, 1) // tns_data_present
  bw.put(0, 1) // gain_control_data_present
  aac_encode_write_spectral(bw, ch, offsets, rev)
}

///|
/// Assemble one ADTS frame for the given coefficients and frame-wide
/// scalefactor offset.
fn AacEncoder::build_frame(
  self : AacEncoder,
  coefs : Array[Array[Double]],
  base_sf : Array[Int32],
  delta : Int32,
) -> Result[Bytes, String] {
  let chans : Array[AacEncChannel] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    chans.push(
      aac_encode_channel_data(
        coefs[ch],
        base_sf[ch],
        self.swb_offsets,
        self.num_swb,
        delta,
      ),
    )
  }
  let bw = BitWriter::new()
  if self.config.channels == 1 {
    bw.put(0, 3) // ID_SCE
    bw.put(0, 4) // element_instance_tag
    aac_encode_write_channel(bw, chans[0], self.swb_offsets, self.spectral_rev)
  } else {
    bw.put(1, 3) // ID_CPE
    bw.put(0, 4) // element_instance_tag
    bw.put(0, 1) // common_window = 0: independent channel streams
    aac_encode_write_channel(bw, chans[0], self.swb_offsets, self.spectral_rev)
    aac_encode_write_channel(bw, chans[1], self.swb_offsets, self.spectral_rev)
  }
  bw.put(7, 3) // ID_END
  let payload = bw.finish()
  let frame_length = av_aac_adts_header_size + payload.length()
  let header = match
    aac_adts_header_write(
      self.config.sample_rate,
      self.config.channels,
      2,
      frame_length,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let out : Array[Byte] = []
  for i = 0; i < header.length(); i = i + 1 {
    out.push(header[i])
  }
  for i = 0; i < payload.length(); i = i + 1 {
    out.push(payload[i])
  }
  Ok(Bytes::from_array(out[:]))
}

///|
/// Encode one 1024-sample frame per channel into a single ADTS frame. The
/// input is planar float PCM in `[-1, 1]`; the first frame's 1024-sample
/// history is silence, so a decoder emits one priming frame before the input
/// samples (AAC's is 1024 samples of delay).
pub fn AacEncoder::encode_frame(
  self : AacEncoder,
  pcm : Array[Array[Double]],
) -> Result[Bytes, String] {
  if pcm.length() != self.config.channels {
    return Err("AAC encoder input channel count mismatch")
  }
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    if pcm[ch].length() != 1024 {
      return Err("AAC encoder expects 1024 samples per channel")
    }
  }
  let coefs : Array[Array[Double]] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    let buf : Array[Double] = Array::make(2048, 0.0)
    let hist = self.history[ch]
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = hist[i]
      buf[1024 + i] = pcm[ch][i]
      hist[i] = pcm[ch][i]
    }
    coefs.push(self.forward_mdct(buf))
  }
  let base_sf : Array[Int32] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    base_sf.push(aac_encode_base_sf(coefs[ch]))
  }
  let mut target_bytes = self.config.bit_rate * 1024 / self.config.sample_rate
  target_bytes = target_bytes / 8
  if target_bytes < av_aac_adts_header_size + 1 {
    target_bytes = av_aac_adts_header_size + 1
  }
  let mut lo = 0
  let mut hi = 255
  let mut best : Bytes = b""
  let mut found = false
  while lo <= hi {
    let mid = (lo + hi) / 2
    let frame = match self.build_frame(coefs, base_sf, mid) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if frame.length() <= target_bytes {
      best = frame
      found = true
      hi = mid - 1
    } else {
      lo = mid + 1
    }
  }
  if !found {
    return Err("AAC frame exceeds the requested bit rate")
  }
  Ok(best)
}
