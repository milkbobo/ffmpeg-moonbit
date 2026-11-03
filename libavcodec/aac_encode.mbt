///|
/// MoonBit port of a minimal AAC-LC encoder, shipped as ADTS frames.
///
/// Scope: AAC-LC object type 2, one long window (ONLY_LONG) per frame, sine
/// window, no TNS / PNS / prediction / M/S, one SCE for mono or one CPE with
/// independent channels for stereo, and codebook 11 spectral Huffman with
/// escape sequences (quantised magnitudes up to 8191). All coded bands of a
/// channel share one scalefactor; a frame-wide offset around a reference
/// scalefactor (the one that puts the spectral peak at a quantised magnitude
/// of about 15) is binary-searched so each ADTS frame fills the requested
/// average bit rate. This is a CBR-style rate control: when a frame has bit
/// head-room the quantiser is refined instead of the spare bits being dropped.
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
/// plan of the configured sample rate, the precomputed MDCT kernel and the
/// per-codebook Huffman tables (codes, code lengths and the reverse map from a
/// packed vector back to its symbol).
pub struct AacEncoder {
  config : AacEncodeConfig
  sampling_index : Int32
  swb_offsets : Array[Int32]
  num_swb : Int32
  history : Array[Array[Double]]
  cos_table : Array[Double]
  spectral_codes : Array[Array[UInt32]]
  spectral_bits : Array[Array[Int32]]
  spectral_rev : Array[Array[Int32]]
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
/// Huffman code / code-length tables of codebooks 1..11, indexed by
/// `codebook - 1`.
fn aac_encode_code_tables() -> (Array[Array[UInt32]], Array[Array[Int32]]) {
  let codes : Array[Array[UInt32]] = [
    aac_codes1, aac_codes2, aac_codes3, aac_codes4, aac_codes5, aac_codes6, aac_codes7,
    aac_codes8, aac_codes9, aac_codes10, aac_codes11,
  ]
  let bits : Array[Array[Int32]] = [
    aac_bits1, aac_bits2, aac_bits3, aac_bits4, aac_bits5, aac_bits6, aac_bits7,
    aac_bits8, aac_bits9, aac_bits10, aac_bits11,
  ]
  (codes, bits)
}

///|
/// Reverse map for the packed indices of a codebook whose low 8 bits hold the
/// 2-bit / 4-bit digit tuple (`codebook_vector02_idx`, `codebook_vector4_idx`):
/// the digit tuple alone identifies a row, so the redundant non-zero-count and
/// sign-mask bits above bit 8 are dropped from the key.
fn aac_encode_rev_digits(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(256, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    rev[idx_table[row].reinterpret_as_int() & 255] = row
  }
  rev
}

///|
/// Reverse map for the unsigned pair codebooks (`codebook_vector6_idx` /
/// `codebook_vector8_idx`): the low 8 bits are the two magnitudes and bits
/// 12..15 hold the one-bit sign-slot shift (set when only the first value is
/// non-zero).
fn aac_encode_rev_pairs(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(1024, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    let idx = idx_table[row].reinterpret_as_int()
    rev[(idx & 255) | (((idx >> 12) & 1) << 8)] = row
  }
  rev
}

///|
/// Reverse map for codebook 11: the low 8 bits are the two 4-bit magnitudes
/// (0 for an escaped value) and bits 8..9 the escape mask.
fn aac_encode_rev_escape(idx_table : Array[UInt32]) -> Array[Int32] {
  let rev : Array[Int32] = Array::make(1024, -1)
  for row = 0; row < idx_table.length(); row = row + 1 {
    let idx = idx_table[row].reinterpret_as_int()
    rev[(idx & 255) | (((idx >> 8) & 3) << 8)] = row
  }
  rev
}

///|
/// Per-codebook reverse maps, indexed by `codebook - 1`. Codebooks 1..4 share
/// `codebook_vector02_idx` and 5..10 come in pairs sharing one table, so only
/// five distinct maps are built.
fn aac_encode_reverse_tables() -> Array[Array[Int32]] {
  let rev02 = aac_encode_rev_digits(aac_idx_quads02)
  let rev4 = aac_encode_rev_digits(aac_idx_quads4)
  let rev6 = aac_encode_rev_pairs(aac_idx_pairs6)
  let rev8 = aac_encode_rev_pairs(aac_idx_pairs8)
  let rev11 = aac_encode_rev_escape(aac_idx_pairs10)
  [rev02, rev02, rev02, rev02, rev4, rev4, rev6, rev6, rev8, rev8, rev11]
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
  let (spectral_codes, spectral_bits) = aac_encode_code_tables()
  Ok({
    config,
    sampling_index,
    swb_offsets,
    num_swb,
    history,
    cos_table: aac_encode_cos_table(),
    spectral_codes,
    spectral_bits,
    spectral_rev: aac_encode_reverse_tables(),
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
/// Reference scalefactor of a channel: the smallest `sf` that keeps the
/// frame's largest coefficient's quantised magnitude at or below 15. The
/// escape-capable quantiser of `aac_encode_quantize_all` may go finer than
/// this, so the reference only centres the rate-control search. `-1` marks an
/// all-zero frame.
fn aac_encode_reference_sf(coef : Array[Double]) -> Int32 {
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
/// Largest quantised magnitude codebook 11 can carry: escape sequences allow
/// up to 8 leading one bits, i.e. a mantissa length of 12, i.e. 8191.
let aac_encode_max_q : Int32 = 8191

///|
/// Quantise the whole spectrum at one scalefactor:
/// `q = sign(c) * floor((|c| * 2^(-(s-100)/4))^(3/4) + 0.405)`, clamped to
/// `aac_encode_max_q` (the escape limit of codebook 11). `s < 0` zeroes the
/// spectrum.
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
    // Clamp in the real domain before converting: coarse scalefactors can push
    // `a^(3/4)` far past Int's range (the rate-control search visits them).
    let mut n = 0
    if a > 0.0 {
      let p = @math.pow(a, 0.75) + 0.405
      n = if p >= aac_encode_max_q.to_double() {
        aac_encode_max_q
      } else {
        p.to_int()
      }
    }
    q[i] = if coef[i] < 0.0 && n > 0 { -n } else { n }
  }
}

///|
/// One channel's quantised spectrum, its per-band scalefactors and the
/// codebook chosen for each band (0 for a zero band).
priv struct AacEncChannel {
  sf : Array[Int32]
  cb : Array[Int32]
  q : Array[Int32]
  max_sfb : Int32
}

///|
fn aac_encode_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// Packed vector key of the tuple starting at `i`, in the same bit layout as
/// `ff_aac_codebook_vector_idx` (see `aac_encode_reverse_tables`).
fn aac_encode_tuple_key(cb : Int32, q : Array[Int32], i : Int32) -> Int32 {
  if cb <= 4 {
    // 4-tuple, 2 bits per value: books 1/2 store the signed value as `v + 1`
    // (the sign lives inside the Huffman symbol), books 3/4 the magnitude.
    let mut key = 0
    for j = 0; j < 4; j = j + 1 {
      let v = q[i + j]
      let d = if cb <= 2 { v + 1 } else { aac_encode_abs(v) }
      key = key | ((d & 3) << (j * 2))
    }
    key
  } else if cb <= 6 {
    // Signed pair: digit = value + 4.
    (q[i] + 4) | ((q[i + 1] + 4) << 4)
  } else if cb <= 10 {
    // Unsigned pair: magnitudes plus the one-bit sign-slot shift used when
    // only the first value is non-zero.
    let a0 = aac_encode_abs(q[i])
    let a1 = aac_encode_abs(q[i + 1])
    a0 | (a1 << 4) | ((if a0 != 0 && a1 == 0 { 1 } else { 0 }) << 8)
  } else {
    // Codebook 11: escaped magnitudes are stored as 0 and marked in bits 8..9.
    let a0 = aac_encode_abs(q[i])
    let a1 = aac_encode_abs(q[i + 1])
    let nzt = (if a0 >= 16 { 1 } else { 0 }) | (if a1 >= 16 { 2 } else { 0 })
    (if a0 >= 16 { 0 } else { a0 }) |
    ((if a1 >= 16 { 0 } else { a1 }) << 4) |
    (nzt << 8)
  }
}

///|
/// Number of separate sign bits of the tuple (zero for codebooks 1/2 and 5/6,
/// which carry the sign inside the Huffman symbol).
fn aac_encode_tuple_signs(cb : Int32, q : Array[Int32], i : Int32) -> Int32 {
  if cb <= 2 || (cb >= 5 && cb <= 6) {
    0
  } else {
    let dim = if cb <= 4 { 4 } else { 2 }
    let mut n = 0
    for j = 0; j < dim; j = j + 1 {
      if q[i + j] != 0 {
        n = n + 1
      }
    }
    n
  }
}

///|
/// Bits spent by a codebook 11 escape sequence for magnitude `v >= 16`:
/// `(len - 4)` one bits, a terminating zero and `len` mantissa bits.
fn aac_encode_escape_bits(v : Int32) -> Int32 {
  let mut len = 0
  let mut t = v
  while t > 1 {
    t = t >> 1
    len = len + 1
  }
  len - 4 + 1 + len
}

///|
/// Bits needed to code `[start, end)` with codebook `cb`, or `-1` when the
/// codebook cannot represent the band (tuple size or magnitude limit).
fn aac_encode_band_cost(
  cb : Int32,
  q : Array[Int32],
  start : Int32,
  end : Int32,
  rev : Array[Int32],
  bits : Array[Int32],
) -> Int32 {
  let dim = if cb <= 4 { 4 } else { 2 }
  if (end - start) % dim != 0 {
    return -1
  }
  let mut cost = 0
  let mut i = start
  while i < end {
    let row = rev[aac_encode_tuple_key(cb, q, i)]
    if row < 0 {
      return -1
    }
    cost = cost + bits[row] + aac_encode_tuple_signs(cb, q, i)
    if cb == 11 {
      let a0 = aac_encode_abs(q[i])
      let a1 = aac_encode_abs(q[i + 1])
      if a0 >= 16 {
        cost = cost + aac_encode_escape_bits(a0)
      }
      if a1 >= 16 {
        cost = cost + aac_encode_escape_bits(a1)
      }
    }
    i = i + dim
  }
  cost
}

///|
/// Cheapest codebook able to code the band `[start, end)` whose largest
/// magnitude is `magnitude`. The magnitude limits mirror AAC's codebook
/// ranges: 1/2 -> 1, 3/4 -> 2, 5/6 -> 4, 7/8 -> 7, 9/10 -> 12, 11 -> escape.
fn AacEncoder::select_band_cb(
  self : AacEncoder,
  q : Array[Int32],
  start : Int32,
  end : Int32,
  magnitude : Int32,
) -> Int32 {
  let limits : Array[Int32] = [1, 1, 2, 2, 4, 4, 7, 7, 12, 12, aac_encode_max_q]
  let mut best = 11
  let mut best_cost = 1 << 30
  for cb = 1; cb <= 11; cb = cb + 1 {
    if magnitude <= limits[cb - 1] {
      let cost = aac_encode_band_cost(
        cb,
        q,
        start,
        end,
        self.spectral_rev[cb - 1],
        self.spectral_bits[cb - 1],
      )
      if cost >= 0 && cost < best_cost {
        best_cost = cost
        best = cb
      }
    }
  }
  best
}

///|
/// Build one channel's quantised spectrum at the frame-wide scalefactor
/// `reference_sf + delta` (clamped to the legal 0..255 range). Bands whose
/// quantised coefficients are all zero get scalefactor `-1` and codebook 0;
/// the remaining bands use the cheapest codebook that can represent them.
fn AacEncoder::channel_data(
  self : AacEncoder,
  coef : Array[Double],
  reference_sf : Int32,
  delta : Int32,
) -> AacEncChannel {
  let sf : Array[Int32] = Array::make(self.num_swb, -1)
  let cb : Array[Int32] = Array::make(self.num_swb, 0)
  let q : Array[Int32] = Array::make(1024, 0)
  let mut max_sfb = 0
  if reference_sf >= 0 {
    let mut v = reference_sf + delta
    if v < 0 {
      v = 0
    }
    if v > 255 {
      v = 255
    }
    aac_encode_quantize_all(q, coef, v)
    for b = 0; b < self.num_swb; b = b + 1 {
      let start = self.swb_offsets[b]
      let end = self.swb_offsets[b + 1]
      let mut magnitude = 0
      for i = start; i < end; i = i + 1 {
        let a = aac_encode_abs(q[i])
        if a > magnitude {
          magnitude = a
        }
      }
      if magnitude > 0 {
        sf[b] = v
        max_sfb = b + 1
        cb[b] = self.select_band_cb(q, start, end, magnitude)
      }
    }
  }
  { sf, cb, q, max_sfb, }
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
/// section_data: group runs of equal band type (0 = zero band).
fn aac_encode_write_sections(bw : BitWriter, ch : AacEncChannel) -> Unit {
  let mut b = 0
  while b < ch.max_sfb {
    let cb = ch.cb[b]
    let mut e = b + 1
    while e < ch.max_sfb && ch.cb[e] == cb {
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
/// Write one codebook 11 escape sequence for a magnitude `v >= 16`:
/// `(len - 4)` one bits, a terminating zero, then `len` bits holding
/// `v - 2^len`, where `len` is the position of `v`'s highest set bit. This is
/// the mirror of the decoder's ``n = (1 << b) + read(b)`` with
/// ``b = 4 + ones`` (spec 4.6.3.3).
fn aac_encode_write_escape(bw : BitWriter, v : Int32) -> Unit {
  let mut len = 0
  let mut t = v
  while t > 1 {
    t = t >> 1
    len = len + 1
  }
  let mut ones = len - 4
  while ones > 0 {
    bw.put_bit(1)
    ones = ones - 1
  }
  bw.put_bit(0)
  bw.put((v - (1 << len)).reinterpret_as_uint(), len)
}

///|
/// spectral_data: the per-band Huffman codebook, its sign bits and (for
/// codebook 11) the escape sequences.
fn aac_encode_write_spectral(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  codes : Array[Array[UInt32]],
  bits : Array[Array[Int32]],
  revs : Array[Array[Int32]],
) -> Unit {
  for b = 0; b < ch.max_sfb; b = b + 1 {
    let cb = ch.cb[b]
    if cb == 0 {
      continue
    }
    let dim = if cb <= 4 { 4 } else { 2 }
    let table = cb - 1
    let mut i = offsets[b]
    let end = offsets[b + 1]
    while i < end {
      let row = revs[table][aac_encode_tuple_key(cb, ch.q, i)]
      bw.put(codes[table][row], bits[table][row])
      // Codebooks 3/4 and 7..11 carry one sign bit per non-zero magnitude;
      // codebooks 1/2 and 5/6 embed the sign in the Huffman symbol.
      let mut j = 0
      while j < dim {
        let v = ch.q[i + j]
        if v != 0 && (cb == 3 || cb == 4 || cb >= 7) {
          bw.put_bit(if v < 0 { 1 } else { 0 })
        }
        j = j + 1
      }
      if cb == 11 {
        let a0 = aac_encode_abs(ch.q[i])
        let a1 = aac_encode_abs(ch.q[i + 1])
        if a0 >= 16 {
          aac_encode_write_escape(bw, a0)
        }
        if a1 >= 16 {
          aac_encode_write_escape(bw, a1)
        }
      }
      i = i + dim
    }
  }
}

///|
/// individual_channel_stream for one channel of the raw_data_block.
fn aac_encode_write_channel(
  bw : BitWriter,
  ch : AacEncChannel,
  offsets : Array[Int32],
  codes : Array[Array[UInt32]],
  bits : Array[Array[Int32]],
  revs : Array[Array[Int32]],
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
  aac_encode_write_spectral(bw, ch, offsets, codes, bits, revs)
}

///|
/// Assemble one ADTS frame for the given coefficients and frame-wide
/// scalefactor offset.
fn AacEncoder::build_frame(
  self : AacEncoder,
  coefs : Array[Array[Double]],
  reference_sf : Array[Int32],
  delta : Int32,
) -> Result[Bytes, String] {
  let chans : Array[AacEncChannel] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    chans.push(self.channel_data(coefs[ch], reference_sf[ch], delta))
  }
  let bw = BitWriter::new()
  if self.config.channels == 1 {
    bw.put(0, 3) // ID_SCE
    bw.put(0, 4) // element_instance_tag
    aac_encode_write_channel(
      bw,
      chans[0],
      self.swb_offsets,
      self.spectral_codes,
      self.spectral_bits,
      self.spectral_rev,
    )
  } else {
    bw.put(1, 3) // ID_CPE
    bw.put(0, 4) // element_instance_tag
    bw.put(0, 1) // common_window = 0: independent channel streams
    for ch = 0; ch < 2; ch = ch + 1 {
      aac_encode_write_channel(
        bw,
        chans[ch],
        self.swb_offsets,
        self.spectral_codes,
        self.spectral_bits,
        self.spectral_rev,
      )
    }
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
  let reference_sf : Array[Int32] = []
  for ch = 0; ch < self.config.channels; ch = ch + 1 {
    reference_sf.push(aac_encode_reference_sf(coefs[ch]))
  }
  // Average bits per frame from the requested bit rate, minus the ADTS header
  // (which is not part of the payload budget).
  let mut target_bytes = self.config.bit_rate * 1024 / self.config.sample_rate
  target_bytes = target_bytes / 8
  if target_bytes < av_aac_adts_header_size + 1 {
    target_bytes = av_aac_adts_header_size + 1
  }
  // Finer quantisation costs more bits, so the smallest offset whose frame
  // still fits the budget is the highest quality this frame can afford. The
  // offset may be negative: escape coding lets the scalefactor go below the
  // reference value that a 15-step codebook would require.
  let mut lo = -255
  let mut hi = 255
  let mut best : Bytes = b""
  let mut found = false
  while lo <= hi {
    let mid = (lo + hi) / 2
    let frame = match self.build_frame(coefs, reference_sf, mid) {
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
