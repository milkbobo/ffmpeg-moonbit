/// DCA (DTS Coherent Acoustics) fixed-point DSP layer: the `dcamath.h`
/// primitives, the canonical VLC tables built from `ff_dca_vlc_src_tables`,
/// the fixed-point half IMDCT (`dcadct.c`), the 32-band synthesis filter
/// (`synth_filter.c`), the fixed-point `dcadsp.c` kernels and
/// `ff_dca_core_dequantize`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2016 foo86
/// (and 2008 Michael Niedermayer for the synth filter). This port keeps the
/// same license. Everything here is exact integer arithmetic, so the fixed
/// point decode path is bit-exact with FFmpeg's `-bitexact` output.

///|
/// `norm__`: round-shift right by `bits` (no shift when `bits <= 0`). */
fn dca_norm(a : Int64, bits : Int32) -> Int32 {
  if bits > 0 {
    ((a + (1 << (bits - 1)).to_int64()) >> bits).to_int()
  } else {
    a.to_int()
  }
}

///|
/// `mul__`: multiply and round-shift. */
fn dca_mul(a : Int32, b : Int32, bits : Int32) -> Int32 {
  dca_norm(a.to_int64() * b.to_int64(), bits)
}

///|
/// `clip23` / `av_clip_intp2(a, 23)`. */
fn dca_clip23(a : Int32) -> Int32 {
  if a < -8388608 {
    -8388608
  } else if a > 8388607 {
    8388607
  } else {
    a
  }
}

///|
fn dca_norm13(a : Int64) -> Int32 {
  dca_norm(a, 13)
}

///|
fn dca_norm21(a : Int64) -> Int32 {
  dca_norm(a, 21)
}

///|
fn dca_norm23(a : Int64) -> Int32 {
  dca_norm(a, 23)
}

///|
fn dca_mul17(a : Int32, b : Int32) -> Int32 {
  dca_mul(a, b, 17)
}

///|
fn dca_mul23(a : Int32, b : Int32) -> Int32 {
  dca_mul(a, b, 23)
}

///|
/// One Huffman book (`ff_vlc_init_from_lengths` semantics): codes are
/// assigned in source order, `acc += 1 << (32 - len)`, and `acc` is the
/// entry's left-aligned 32-bit code. The source order interleaves code
/// lengths, so the book is an explicit bit tree rather than the
/// length-sorted canonical form. Slot value: -1 empty, <= -2 leaf with
/// symbol index -2 - v, >= 0 internal node (in pairs). */
priv struct DcaVlcBook {
  nodes : FixedArray[Int32]
  syms : FixedArray[Int32]
}

///|
/// Build one book from a slice of `dca_vlc_src_tables` pairs. */
fn dca_vlc_build(
  src : FixedArray[Int32],
  off : Int32,
  n : Int32,
  offset : Int32,
) -> DcaVlcBook {
  let children : Array[Int32] = [-1, -1]
  let syms : Array[Int32] = []
  let mut acc = 0
  for i = 0; i < n; i = i + 1 {
    let len = src[(off + i) * 2 + 1]
    let mut node = 0
    let last = 32 - len
    let mut sh = 31
    while sh > last {
      let slot = node + node + ((acc >> sh) & 1)
      if children[slot] == -1 {
        children[slot] = children.length() / 2
        children.push(-1)
        children.push(-1)
      }
      node = children[slot]
      sh = sh - 1
    }
    let slot = node + node + ((acc >> sh) & 1)
    children[slot] = -2 - syms.length()
    syms.push(src[(off + i) * 2] + offset)
    acc = acc + (1 << (32 - len))
  }
  { nodes: FixedArray::from_array(children), syms: FixedArray::from_array(syms) }
}

///|
/// `get_vlc2` on one book: walk the bit tree until a leaf resolves.
/// Returns the entry value (already offset). */
fn DcaVlcBook::decode(self : DcaVlcBook, gb : BitReader) -> Int32 {
  let nodes = self.nodes
  let mut node = 0
  let mut res = 0
  while true {
    let v = nodes[node + node + gb.read1().reinterpret_as_int()]
    if v <= -2 {
      res = self.syms[-2 - v]
      break
    }
    node = v
  }
  res
}

///|
/// The 48 quantization-index books `[codebook][variant]` (flattened), then
/// the 5 bit-allocation, 5 scale-factor and 4 transition-mode books. */
let dca_vlc_quant_index : FixedArray[DcaVlcBook] = {
  let group_size = dca_quant_index_group_size
  let sizes = dca_bitalloc_sizes
  let offsets = dca_bitalloc_offsets
  let books : FixedArray[DcaVlcBook] = FixedArray::make(48, dca_vlc_book_empty())
  let mut src_off = 0
  let mut book = 0
  for i = 0; i < 10; i = i + 1 {
    for j = 0; j < group_size[i]; j = j + 1 {
      books[book] = dca_vlc_build(
        dca_vlc_src_tables,
        src_off,
        sizes[i],
        offsets[i],
      )
      book += 1
      src_off += sizes[i]
    }
  }
  books
}

///|
let dca_vlc_bit_allocation : FixedArray[DcaVlcBook] = {
  let books : FixedArray[DcaVlcBook] = FixedArray::make(5, dca_vlc_book_empty())
  let base = dca_vlc_segment_offset(48)
  for k = 0; k < 5; k = k + 1 {
    books[k] = dca_vlc_build(dca_vlc_src_tables, base + k * 12, 12, 1)
  }
  books
}

///|
let dca_vlc_scale_factor : FixedArray[DcaVlcBook] = {
  let books : FixedArray[DcaVlcBook] = FixedArray::make(5, dca_vlc_book_empty())
  let base = dca_vlc_segment_offset(53)
  for k = 0; k < 5; k = k + 1 {
    books[k] = dca_vlc_build(dca_vlc_src_tables, base + k * 129, 129, -64)
  }
  books
}

///|
let dca_vlc_transition_mode : FixedArray[DcaVlcBook] = {
  let books : FixedArray[DcaVlcBook] = FixedArray::make(4, dca_vlc_book_empty())
  let base = dca_vlc_segment_offset(58)
  for k = 0; k < 4; k = k + 1 {
    books[k] = dca_vlc_build(dca_vlc_src_tables, base + k * 4, 4, 0)
  }
  books
}

///|
/// Pair offset of VLC segment `seg` within `dca_vlc_src_tables` (the first
/// 48 segments are the quantization books, 48..52 bit allocation, 53..57
/// scale factor, 58..61 transition mode). */
fn dca_vlc_segment_offset(seg : Int32) -> Int32 {
  let mut off = 0
  for i = 0; i < seg; i = i + 1 {
    off += dca_vlc_segment_sizes[i]
  }
  off
}

///|
fn dca_vlc_book_empty() -> DcaVlcBook {
  { nodes: FixedArray::make(2, -1), syms: FixedArray::make(1, 0) }
}

///|
/// Quantization-index book selection: `ff_dca_vlc_quant_index[abits-1][sel]`
/// flattened at `(abits-1) variants start + sel`. */
fn dca_quant_vlc(abits : Int32, sel : Int32) -> DcaVlcBook {
  dca_vlc_quant_index[dca_quant_vlc_base[abits - 1] + sel]
}

///|
/// Flattened start index of each codebook's variants in
/// . */
let dca_quant_vlc_base : FixedArray[Int32] = {
  let bases : FixedArray[Int32] = FixedArray::make(10, 0)
  let group_size = dca_quant_index_group_size
  let mut b = 0
  for i = 0; i < 10; i = i + 1 {
    bases[i] = b
    b += group_size[i]
  }
  bases
}

///|
/// `ff_dca_core_dequantize`: scale subband samples by step size and factor,
/// optionally accumulating residuals. */
fn dca_core_dequantize(
  output : FixedArray[Int32],
  out_off : Int32,
  input : FixedArray[Int32],
  step_size : Int32,
  scale : Int32,
  residual : Bool,
  len : Int32,
) -> Unit {
  let mut step_scale : Int64 = step_size.to_int64() * scale.to_int64()
  let mut shift = 0
  if step_scale > (1 << 23) {
    shift = dca_log2((step_scale >> 23).to_int()) + 1
    step_scale = step_scale >> shift
  }
  if residual {
    for n = 0; n < len; n = n + 1 {
      output[out_off + n] = dca_clip23(
        output[out_off + n] + dca_norm(
          input[n].to_int64() * step_scale,
          22 - shift,
        ),
      )
    }
  } else {
    for n = 0; n < len; n = n + 1 {
      output[out_off + n] = dca_clip23(
        dca_norm(input[n].to_int64() * step_scale, 22 - shift),
      )
    }
  }
}

///|
/// `av_log2` for non-negative values. */
fn dca_log2(v : Int32) -> Int32 {
  let mut n = -1
  let mut x = v
  while x > 0 {
    x = x >> 1
    n += 1
  }
  n
}

///|
/// `decode_hf_c`: high-frequency VQ subbands. */
fn dca_decode_hf(
  dst : Array[FixedArray[Int32]],
  vq_index : FixedArray[Int32],
  scale_factors : FixedArray[Int32],
  sf_off : Int32, // per-band [band][0] index (band*2)
  sb_start : Int32,
  sb_end : Int32,
  ofs : Int32,
  len : Int32,
) -> Unit {
  for i = sb_start; i < sb_end; i = i + 1 {
    let vq_base = vq_index[i] * 32
    let scale = scale_factors[sf_off + i * 2]
    for j = 0; j < len; j = j + 1 {
      dst[i][dca_adpcm_coeffs + j + ofs] = dca_clip23(
        (dca_high_freq_vq[vq_base + j] * scale + (1 << 3)) >> 4,
      )
    }
  }
}

///|
/// `decode_joint_c`: joint intensity subbands. */
fn dca_decode_joint(
  dst : Array[FixedArray[Int32]],
  src : Array[FixedArray[Int32]],
  scale_factors : FixedArray[Int32],
  sf_base : Int32,
  sb_start : Int32,
  sb_end : Int32,
  ofs : Int32,
  len : Int32,
) -> Unit {
  for i = sb_start; i < sb_end; i = i + 1 {
    let scale = scale_factors[sf_base + i]
    for j = 0; j < len; j = j + 1 {
      dst[i][dca_adpcm_coeffs + j + ofs] = dca_clip23(
        dca_mul17(src[i][dca_adpcm_coeffs + j + ofs], scale),
      )
    }
  }
}

///|
/// `lfe_fir_fixed_c`: interpolate the decimated LFE channel (LFF=0). */
fn dca_lfe_fir_fixed(
  pcm : FixedArray[Int32],
  pcm_off : Int32,
  lfe_samples : FixedArray[Int32],
  lfe_off : Int32, // index of the current sample; taps read [-k]
  npcmblocks : Int32,
) -> Unit {
  let nlfesamples = npcmblocks >> 1
  let coeff = dca_lfe_fir_64_fixed
  for i = 0; i < nlfesamples; i = i + 1 {
    for j = 0; j < 32; j = j + 1 {
      let mut a : Int64 = 0
      let mut b : Int64 = 0
      for k = 0; k < 8; k = k + 1 {
        a += coeff[j * 8 + k].to_int64() * lfe_samples[lfe_off + i - k].to_int64()
        b += coeff[255 - j * 8 - k].to_int64() * lfe_samples[lfe_off + i - k].to_int64()
      }
      pcm[pcm_off + i * 64 + j] = dca_clip23(dca_norm23(a))
      pcm[pcm_off + i * 64 + 32 + j] = dca_clip23(dca_norm23(b))
    }
  }
}

///|
/// `butterflies_fixed_c`: sum/difference decoding. */
fn dca_butterflies_fixed(
  v1 : FixedArray[Int32],
  v2 : FixedArray[Int32],
  len : Int32,
) -> Unit {
  for i = 0; i < len; i = i + 1 {
    let t = v1[i] - v2[i]
    v1[i] = v1[i] + v2[i]
    v2[i] = t
  }
}

// ---------------------------------------------------------------------------
// Fixed-point half IMDCT (dcadct.c)

///|
fn dca_dct_sum_a(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32, len : Int32) -> Unit {
  for i = 0; i < len; i = i + 1 {
    output[out_off + i] = input[in_off + 2 * i] + input[in_off + 2 * i + 1]
  }
}

///|
fn dca_dct_sum_b(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32, len : Int32) -> Unit {
  output[out_off] = input[in_off]
  for i = 1; i < len; i = i + 1 {
    output[out_off + i] = input[in_off + 2 * i] + input[in_off + 2 * i - 1]
  }
}

///|
fn dca_dct_sum_c(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32, len : Int32) -> Unit {
  for i = 0; i < len; i = i + 1 {
    output[out_off + i] = input[in_off + 2 * i]
  }
}

///|
fn dca_dct_sum_d(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32, len : Int32) -> Unit {
  output[out_off] = input[in_off + 1]
  for i = 1; i < len; i = i + 1 {
    output[out_off + i] = input[in_off + 2 * i - 1] + input[in_off + 2 * i + 1]
  }
}

///|
let dca_dct_a_cos : FixedArray[Int32] = [
  8348215, 8027397, 7398092, 6484482, 5321677, 3954362, 2435084, 822227, 8027397, 5321677, 822227,
  -3954362, -7398092, -8348215, -6484482, -2435084, 7398092, 822227, -6484482, -8027397, -2435084,
  5321677, 8348215, 3954362, 6484482, -3954362, -8027397, 822227, 8348215, 2435084, -7398092,
  -5321677, 5321677, -7398092, -2435084, 8348215, -822227, -8027397, 3954362, 6484482, 3954362,
  -8348215, 5321677, 2435084, -8027397, 6484482, 822227, -7398092, 2435084, -6484482, 8348215,
  -7398092, 3954362, 822227, -5321677, 8027397, 822227, -2435084, 3954362, -5321677, 6484482,
  -7398092, 8027397, -8348215,
]

///|
fn dca_dct_a(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    let mut res : Int64 = 0
    for j = 0; j < 8; j = j + 1 {
      res += dca_dct_a_cos[i * 8 + j].to_int64() * input[in_off + j].to_int64()
    }
    output[out_off + i] = dca_norm23(res)
  }
}

///|
let dca_dct_b_cos : FixedArray[Int32] = [
  8227423, 7750063, 6974873, 5931642, 4660461, 3210181, 1636536, 6974873, 3210181, -1636536,
  -5931642, -8227423, -7750063, -4660461, 4660461, -3210181, -8227423, -5931642, 1636536, 7750063,
  6974873, 1636536, -7750063, -4660461, 5931642, 6974873, -3210181, -8227423, -1636536, -7750063,
  4660461, 5931642, -6974873, -3210181, 8227423, -4660461, -3210181, 8227423, -5931642, -1636536,
  7750063, -6974873, -6974873, 3210181, 1636536, -5931642, 8227423, -7750063, 4660461, -8227423,
  7750063, -6974873, 5931642, -4660461, 3210181, -1636536,
]

///|
fn dca_dct_b(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    let mut res : Int64 = input[in_off].to_int64() * (1 << 23)
    for j = 0; j < 7; j = j + 1 {
      res += dca_dct_b_cos[i * 7 + j].to_int64() * input[in_off + 1 + j].to_int64()
    }
    output[out_off + i] = dca_norm23(res)
  }
}

///|
let dca_mod_a_cos : FixedArray[Int32] = [
  4199362, 4240198, 4323885, 4454708, 4639772, 4890013, 5221943, 5660703, -6245623, -7040975,
  -8158494, -9809974, -12450076, -17261920, -28585092, -85479984,
]

///|
fn dca_mod_a(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    output[out_off + i] = dca_mul23(
      dca_mod_a_cos[i],
      input[in_off + i] + input[in_off + 8 + i],
    )
  }
  let mut k = 7
  for i = 8; i < 16; i = i + 1 {
    output[out_off + i] = dca_mul23(
      dca_mod_a_cos[i],
      input[in_off + k] - input[in_off + 8 + k],
    )
    k -= 1
  }
}

///|
let dca_mod_b_cos : FixedArray[Int32] = [
  4214598, 4383036, 4755871, 5425934, 6611520, 8897610, 14448934, 42791536,
]

///|
fn dca_mod_b(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    input[in_off + 8 + i] = dca_mul23(dca_mod_b_cos[i], input[in_off + 8 + i])
  }
  for i = 0; i < 8; i = i + 1 {
    output[out_off + i] = input[in_off + i] + input[in_off + 8 + i]
  }
  let mut k = 7
  for i = 8; i < 16; i = i + 1 {
    output[out_off + i] = input[in_off + k] - input[in_off + 8 + k]
    k -= 1
  }
}

///|
let dca_mod_c_cos : FixedArray[Int32] = [
  1048892, 1051425, 1056522, 1064244, 1074689, 1087987, 1104313, 1123884, 1146975, 1173922,
  1205139, 1241133, 1282529, 1330095, 1384791, 1447815, -1520688, -1605358, -1704360, -1821051,
  -1959964, -2127368, -2332183, -2587535, -2913561, -3342802, -3931480, -4785806, -6133390,
  -8566050, -14253820, -42727120,
]

///|
fn dca_mod_c(input : FixedArray[Int32], in_off : Int32, output : FixedArray[Int32], out_off : Int32) -> Unit {
  for i = 0; i < 16; i = i + 1 {
    output[out_off + i] = dca_mul23(
      dca_mod_c_cos[i],
      input[in_off + i] + input[in_off + 16 + i],
    )
  }
  let mut k = 15
  for i = 16; i < 32; i = i + 1 {
    output[out_off + i] = dca_mul23(
      dca_mod_c_cos[i],
      input[in_off + k] - input[in_off + 16 + k],
    )
    k -= 1
  }
}

///|
fn dca_clp_v(buf : FixedArray[Int32], off : Int32, len : Int32) -> Unit {
  for i = 0; i < len; i = i + 1 {
    buf[off + i] = dca_clip23(buf[off + i])
  }
}

///|
/// `imdct_half_32`: the fixed-point 32-input half IMDCT. */
fn dca_imdct_half_32(
  output : FixedArray[Int32],
  out_off : Int32,
  input : FixedArray[Int32],
  in_off : Int32,
) -> Unit {
  let buf_a : FixedArray[Int32] = FixedArray::make(32, 0)
  let buf_b : FixedArray[Int32] = FixedArray::make(32, 0)
  let mut mag : Int64 = 0
  for i = 0; i < 32; i = i + 1 {
    mag += dca_abs32(input[in_off + i]).to_int64()
  }
  let shift : Int32 = if mag > 0x400000 { 2 } else { 0 }
  let round : Int32 = if shift > 0 { 1 << (shift - 1) } else { 0 }
  for i = 0; i < 32; i = i + 1 {
    buf_a[i] = (input[in_off + i] + round) >> shift
  }
  dca_dct_sum_a(buf_a, 0, buf_b, 0, 16)
  dca_dct_sum_b(buf_a, 0, buf_b, 16, 16)
  dca_clp_v(buf_b, 0, 32)
  dca_dct_sum_a(buf_b, 0, buf_a, 0, 8)
  dca_dct_sum_b(buf_b, 0, buf_a, 8, 8)
  dca_dct_sum_c(buf_b, 16, buf_a, 16, 8)
  dca_dct_sum_d(buf_b, 16, buf_a, 24, 8)
  dca_clp_v(buf_a, 0, 32)
  dca_dct_a(buf_a, 0, buf_b, 0)
  dca_dct_b(buf_a, 8, buf_b, 8)
  dca_dct_b(buf_a, 16, buf_b, 16)
  dca_dct_b(buf_a, 24, buf_b, 24)
  dca_clp_v(buf_b, 0, 32)
  dca_mod_a(buf_b, 0, buf_a, 0)
  dca_mod_b(buf_b, 16, buf_a, 16)
  dca_clp_v(buf_a, 0, 32)
  dca_mod_c(buf_a, 0, buf_b, 0)
  for i = 0; i < 32; i = i + 1 {
    buf_b[i] = dca_clip23(buf_b[i] * (1 << shift))
  }
  let mut k = 31
  for i = 0; i < 16; i = i + 1 {
    output[out_off + i] = dca_clip23(buf_b[i] - buf_b[k])
    output[out_off + 16 + i] = dca_clip23(buf_b[i] + buf_b[k])
    k -= 1
  }
}

///|
fn dca_abs32(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// `synth_filter_fixed` (32-band): one subband sample column in, 32 PCM
/// samples out. `hist1` is the 1024-entry per-channel FIR ring, `hist2` the
/// 32-entry accumulation history, both persisting across frames. */
fn dca_synth_filter_fixed_32(
  hist1 : FixedArray[Int32],
  offset : Int32,
  hist2 : FixedArray[Int32],
  window : FixedArray[Int32],
  out : FixedArray[Int32],
  out_off : Int32,
  input : FixedArray[Int32],
) -> Int32 {
  let synth_base = offset
  dca_imdct_half_32(hist1, synth_base, input, 0)
  for i = 0; i < 16; i = i + 1 {
    let mut a : Int64 = hist2[i].to_int64() * (1 << 21)
    let mut b : Int64 = hist2[i + 16].to_int64() * (1 << 21)
    let mut c : Int64 = 0
    let mut d : Int64 = 0
    let mut j = 0
    while j < 512 - offset {
      a += window[i + j].to_int64() * hist1[synth_base + i + j].to_int64()
      b += window[i + j + 16].to_int64() * hist1[synth_base + 15 - i + j].to_int64()
      c += window[i + j + 32].to_int64() * hist1[synth_base + 16 + i + j].to_int64()
      d += window[i + j + 48].to_int64() * hist1[synth_base + 31 - i + j].to_int64()
      j += 64
    }
    while j < 512 {
      a += window[i + j].to_int64() * hist1[synth_base + i + j - 512].to_int64()
      b += window[i + j + 16].to_int64() * hist1[synth_base + 15 - i + j - 512].to_int64()
      c += window[i + j + 32].to_int64() * hist1[synth_base + 16 + i + j - 512].to_int64()
      d += window[i + j + 48].to_int64() * hist1[synth_base + 31 - i + j - 512].to_int64()
      j += 64
    }
    out[out_off + i] = dca_clip23(dca_norm21(a))
    out[out_off + i + 16] = dca_clip23(dca_norm21(b))
    hist2[i] = dca_norm21(c)
    hist2[i + 16] = dca_norm21(d)
  }
  (offset - 32) & 511
}
