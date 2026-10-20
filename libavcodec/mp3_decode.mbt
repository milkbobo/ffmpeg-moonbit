///|
/// MPEG Audio decoder: Layer III lives here, Layer I/II in `mpa_layer12.mbt`.
/// Built on the tables in `mp3_tables.mbt`/`mpa_layer12_tables.mbt` and the DSP
/// in `mp3_dsp.mbt`, following FFmpeg 9.0.2 `mpegaudiodec_template.c` along the
/// fixed-point path (`USE_FLOATS=0`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: MPEG-1/2/2.5 Layers I, II and III; mono/stereo; joint stereo
/// (MS/intensity for Layer III, the shared-region `bound` for Layers I/II);
/// short blocks and the bit reservoir for Layer III; output S16 interleaved.
/// `decode_frame` dispatches on the header's `layer` field, and the synthesis
/// filter (`mpa_synthesize`) is shared by all three layers.
///
/// Implementation deviation: the C bit-reservoir state machine copies a
/// rolling 1048-byte `last_buf` and switches between `gb` and `in_gb`. This
/// port keeps the concatenation of each frame's main-data region and starts
/// the Huffman reader `8*main_data_begin` bits before the current frame's
/// main-data start. That is the same byte stream the C reconstructs; it avoids
/// the buffer-switch code while remaining bit-exact for well-formed streams.
/// The reservoir is trimmed to its last 4 KiB when it grows beyond 8 KiB.

// ---------------------------------------------------------------------------
// Huffman tables (canonical trees built from mpa_huff_lens/symbols)
// ---------------------------------------------------------------------------

///| A canonical Huffman decode tree for one layer-3 table. */
priv struct Mp3HuffTree {
  sym : Array[Int]
  c0 : Array[Int]
  c1 : Array[Int]
}

///| Transform a raw C symbol exactly as `mpegaudiodec_common.c` does. */
fn transform_huff_symbol(s : Int) -> Int {
  let high = s & 0xF0
  let low = s & 0x0F
  (high << 1) | (if high != 0 && low != 0 { 0x10 } else { 0 }) | low
}

///| Build one VLC tree exactly like `ff_vlc_init_from_lengths`: codes are
/// accumulated in the array order of `lens`, top-aligned in 32 bits. MP3's
/// length tables are not sorted, so sorting by length would change the code
/// assignment.
fn make_huff_tree(lens : Array[Int], raw_syms : Array[Int]) -> Mp3HuffTree {
  let tree : Mp3HuffTree = { sym: [-1], c0: [-1], c1: [-1] }
  let mut code = 0UL
  for i = 0; i < lens.length(); i = i + 1 {
    let len = lens[i]
    if len <= 0 {
      continue
    }
    let symbol = transform_huff_symbol(raw_syms[i])
    let mut node = 0
    for b = 0; b < len; b = b + 1 {
      let bit = ((code >> (31 - b)) & 1UL).to_int()
      if bit == 0 {
        if tree.c0[node] < 0 {
          tree.c0[node] = tree.sym.length()
          tree.sym.push(-1)
          tree.c0.push(-1)
          tree.c1.push(-1)
        }
        node = tree.c0[node]
      } else {
        if tree.c1[node] < 0 {
          tree.c1[node] = tree.sym.length()
          tree.sym.push(-1)
          tree.c0.push(-1)
          tree.c1.push(-1)
        }
        node = tree.c1[node]
      }
    }
    tree.sym[node] = symbol
    code = code + (1UL << (32 - len))
  }
  tree
}

///| Tables 1..15; entry 0 is unused (`huff_data[l] == 0` means zero table). */
let mp3_huff_trees : Array[Mp3HuffTree] = make_mp3_huff_trees()

///| Build the 16-entry tree array once. */
fn make_mp3_huff_trees() -> Array[Mp3HuffTree] {
  let trees : Array[Mp3HuffTree] = [{ sym: [], c0: [], c1: [] }]
  for i = 0; i < 15; i = i + 1 {
    trees.push(make_huff_tree(mpa_huff_lens[i], mpa_huff_symbols[i]))
  }
  trees
}

///| Decode one symbol from a layer-3 Huffman tree. */
fn huff_decode(gb : BitReader, tree : Mp3HuffTree) -> Int {
  let mut node = 0
  while tree.sym[node] < 0 {
    let bit = gb.read1().reinterpret_as_int()
    let next = if bit == 0 { tree.c0[node] } else { tree.c1[node] }
    if next < 0 {
      return -1
    }
    node = next
  }
  tree.sym[node]
}

///| Decode a count1 quadruple using `mpa_quad_codes/bits`. */
fn quad_decode(gb : BitReader, sel : Int) -> Int {
  let codes = if sel == 0 {
    [1, 5, 4, 5, 6, 5, 4, 4, 7, 3, 6, 0, 7, 2, 3, 1]
  } else {
    [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0]
  }
  let bits = if sel == 0 {
    [1, 4, 4, 5, 4, 6, 5, 6, 4, 5, 5, 6, 5, 6, 6, 6]
  } else {
    [4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4]
  }
  let mut code = 0
  for depth = 1; depth <= 6; depth = depth + 1 {
    code = (code << 1) | gb.read1().reinterpret_as_int()
    for i = 0; i < 16; i = i + 1 {
      if bits[i] == depth && codes[i] == code {
        return i
      }
    }
  }
  0
}

// ---------------------------------------------------------------------------
// Granule and decoder state
// ---------------------------------------------------------------------------

///| `GranuleDef`. */
struct Mp3Granule {
  mut scfsi : Int
  mut part2_3_length : Int
  mut big_values : Int
  mut global_gain : Int
  mut scalefac_compress : Int
  mut block_type : Int
  mut switch_point : Int
  table_select : Array[Int]
  subblock_gain : Array[Int]
  mut scalefac_scale : Int
  mut count1table_select : Int
  region_size : Array[Int]
  mut preflag : Int
  mut short_start : Int
  mut long_end : Int
  scale_factors : Array[Int]
  sb_hybrid : Array[Int]
}

///| Fresh granule. */
fn new_mp3_granule() -> Mp3Granule {
  {
    scfsi: 0,
    part2_3_length: 0,
    big_values: 0,
    global_gain: 0,
    scalefac_compress: 0,
    block_type: 0,
    switch_point: 0,
    table_select: Array::make(3, 0),
    subblock_gain: Array::make(3, 0),
    scalefac_scale: 0,
    count1table_select: 0,
    region_size: Array::make(3, 0),
    preflag: 0,
    short_start: 0,
    long_end: 0,
    scale_factors: Array::make(40, 0),
    sb_hybrid: Array::make(576, 0),
  }
}

///| One decoded MPEG-audio frame, interleaved signed 16-bit PCM. */
pub struct Mp3Pcm {
  sample_rate : Int
  channels : Int
  samples : Array[Int]
}

///|
/// Persistent MPEG-audio decoder state: synthesis windows, Layer III MDCT
/// overlap and the bit-reservoir main-data stream. Layer I/II only use the
/// synthesis half plus `sb_samples`.
pub struct Mp3Decoder {
  mut sample_rate : Int
  mut sample_rate_index : Int
  mut lsf : Int
  mut error_protection : Int
  mut nb_channels : Int
  mut mode : Int
  mut mode_ext : Int
  mut bit_rate : Int
  mut frame_size : Int
  synth_buf : Array[Array[Int]]
  synth_offset : Array[Int]
  sb_samples : Array[Array[Int]]
  mdct_buf : Array[Array[Int]]
  granules : Array[Array[Mp3Granule]]
  mut dither_state : Int
  mut reservoir : Array[Byte]
  mut reservoir_base_bit : Int
}

///| Create a decoder with zeroed synthesis/overlap state and a 1 KiB zero
/// prefix in the reservoir (so early `main_data_begin` references read zero). */
pub fn new_mp3_decoder() -> Mp3Decoder {
  let synth : Array[Array[Int]] = [
    Array::make(1024, 0),
    Array::make(1024, 0),
  ]
  let sb : Array[Array[Int]] = [
    Array::make(36 * 32, 0),
    Array::make(36 * 32, 0),
  ]
  let mdct : Array[Array[Int]] = [
    Array::make(576, 0),
    Array::make(576, 0),
  ]
  let gr : Array[Array[Mp3Granule]] = [
    [new_mp3_granule(), new_mp3_granule()],
    [new_mp3_granule(), new_mp3_granule()],
  ]
  let reservoir = Array::make(1024, b'\x00')
  {
    sample_rate: 0,
    sample_rate_index: 0,
    lsf: 0,
    error_protection: 0,
    nb_channels: 0,
    mode: 0,
    mode_ext: 0,
    bit_rate: 0,
    frame_size: 0,
    synth_buf: synth,
    synth_offset: [0, 0],
    sb_samples: sb,
    mdct_buf: mdct,
    granules: gr,
    dither_state: 0,
    reservoir,
    reservoir_base_bit: 0,
  }
}

///| Clear overlap/synthesis/reservoir state (the C `flush`). */
pub fn Mp3Decoder::flush(self : Mp3Decoder) -> Unit {
  for ch = 0; ch < 2; ch = ch + 1 {
    for i = 0; i < 1024; i = i + 1 {
      self.synth_buf[ch][i] = 0
    }
    self.synth_offset[ch] = 0
    for i = 0; i < 576; i = i + 1 {
      self.mdct_buf[ch][i] = 0
    }
  }
  self.dither_state = 0
  self.reservoir = Array::make(1024, b'\x00')
  self.reservoir_base_bit = 0
}

// ---------------------------------------------------------------------------
// Side info / scale factors / exponents
// ---------------------------------------------------------------------------

///| `region_offset2size`. */
fn region_offset2size(g : Mp3Granule) -> Unit {
  g.region_size[2] = 576 / 2
  let mut j = 0
  for i = 0; i < 3; i = i + 1 {
    let k = if g.region_size[i] < g.big_values {
      g.region_size[i]
    } else {
      g.big_values
    }
    g.region_size[i] = k - j
    j = k
  }
}

///| `init_short_region`. */
fn init_short_region(sr_index : Int, g : Mp3Granule) -> Unit {
  if g.block_type == 2 {
    g.region_size[0] = if sr_index != 8 { 36 / 2 } else { 72 / 2 }
  } else if sr_index <= 2 {
    g.region_size[0] = 36 / 2
  } else if sr_index != 8 {
    g.region_size[0] = 54 / 2
  } else {
    g.region_size[0] = 108 / 2
  }
  g.region_size[1] = 576 / 2
}

///| `band_index_long[9][23]`, built from `band_size_long`. */
let band_index_long : Array[Int] = make_band_index_long()

///| Build the 9×23 band index table. */
fn make_band_index_long() -> Array[Int] {
  let out = Array::make(9 * 23, 0)
  for i = 0; i < 9; i = i + 1 {
    let mut k = 0
    for j = 0; j < 22; j = j + 1 {
      out[i * 23 + j] = k
      k = k + (band_size_long[i * 22 + j] >> 1)
    }
    out[i * 23 + 22] = k
  }
  out
}

///| `init_long_region`. */
fn init_long_region(sr_index : Int, g : Mp3Granule, ra1 : Int, ra2 : Int) -> Unit {
  g.region_size[0] = band_index_long[sr_index * 23 + ra1 + 1]
  let l = if ra1 + ra2 + 2 < 22 { ra1 + ra2 + 2 } else { 22 }
  g.region_size[1] = band_index_long[sr_index * 23 + l]
}

///| `compute_band_indexes`. */
fn compute_band_indexes(sr_index : Int, g : Mp3Granule) -> Unit {
  if g.block_type == 2 {
    if g.switch_point != 0 {
      g.long_end = if sr_index <= 2 { 8 } else { 6 }
      g.short_start = 3
    } else {
      g.long_end = 0
      g.short_start = 0
    }
  } else {
    g.short_start = 13
    g.long_end = 22
  }
}

///| `SPLIT` from mpegaudiodec_template.c. */
fn split_sf(sf : Int, n : Int) -> (Int, Int) {
  if n == 3 {
    let m = (sf * 171) >> 9
    (sf - 3 * m, m)
  } else if n == 4 {
    (sf & 3, sf >> 2)
  } else if n == 5 {
    let m = (sf * 205) >> 10
    (sf - 5 * m, m)
  } else if n == 6 {
    let m = (sf * 171) >> 10
    (sf - 6 * m, m)
  } else {
    (0, sf)
  }
}

///| `lsf_sf_expand`: fill `slen[0..4]` from the four-way split. */
fn lsf_sf_expand(sf : Int, n1 : Int, n2 : Int, n3 : Int) -> Array[Int] {
  let mut v = sf
  let (s3, v3) = split_sf(v, n3)
  v = v3
  let (s2, v2) = split_sf(v, n2)
  v = v2
  let (s1, v1) = split_sf(v, n1)
  v = v1
  [v, s1, s2, s3]
}

///| `exponents_from_scale_factors`. */
fn exponents_from_scale_factors(
  sr_index : Int,
  g : Mp3Granule,
  exponents : Array[Int]
) -> Unit {
  let gain = g.global_gain - 210
  let shift = g.scalefac_scale + 1
  let mut pos = 0
  let pretab_base = g.preflag * 22
  for i = 0; i < g.long_end; i = i + 1 {
    let v0 = gain - ((g.scale_factors[i] + mpa_pretab[pretab_base + i]) <<
      shift) + 400
    let len = band_size_long[sr_index * 22 + i]
    for li = 0; li < len; li = li + 1 {
      if pos < 576 {
        exponents[pos] = v0
      }
      pos = pos + 1
    }
  }
  if g.short_start < 13 {
    let gains = [
      gain - (g.subblock_gain[0] << 3),
      gain - (g.subblock_gain[1] << 3),
      gain - (g.subblock_gain[2] << 3),
    ]
    let mut k = g.long_end
    for i = g.short_start; i < 13; i = i + 1 {
      let len = band_size_short[sr_index * 13 + i]
      for l = 0; l < 3; l = l + 1 {
        let v0 = gains[l] - (g.scale_factors[k] << shift) + 400
        k = k + 1
        for li = 0; li < len; li = li + 1 {
          if pos < 576 {
            exponents[pos] = v0
          }
          pos = pos + 1
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Huffman spectrum decode
// ---------------------------------------------------------------------------

///| Read `n` bits, treating n == 0 as zero (`get_bitsz`). */
fn get_bitsz(gb : BitReader, n : Int) -> Int {
  if n == 0 {
    0
  } else {
    gb.read(n).reinterpret_as_int()
  }
}

///| `READ_FLIP_SIGN`: read a sign bit and optionally negate. */
fn read_flip_sign(gb : BitReader, value : Int) -> Int {
  if gb.read1() != 0U {
    -value
  } else {
    value
  }
}

///| `huffman_decode`: decode one granule's 576 spectral values. */
fn huffman_decode(
  gb : BitReader,
  g : Mp3Granule,
  exponents : Array[Int],
  end_pos2 : Int
) -> Unit {
  let end_pos = end_pos2
  let mut s_index = 0
  for i = 0; i < 3; i = i + 1 {
    let j = g.region_size[i]
    if j == 0 {
      continue
    }
    let k = g.table_select[i]
    let l = mpa_huff_data[k * 2]
    let linbits = mpa_huff_data[k * 2 + 1]
    if l == 0 {
      for x = 0; x < 2 * j; x = x + 1 {
        g.sb_hybrid[s_index + x] = 0
      }
      s_index = s_index + 2 * j
      continue
    }
    let tree = mp3_huff_trees[l]
    let mut pairs = j
    while pairs > 0 {
      if gb.count() >= end_pos {
        break
      }
      let y = huff_decode(gb, tree)
      if y < 0 {
        // Invalid code: zero the rest of the region and stop.
        while pairs > 0 {
          g.sb_hybrid[s_index] = 0
          g.sb_hybrid[s_index + 1] = 0
          s_index = s_index + 2
          pairs = pairs - 1
        }
        break
      }
      if y != 0 {
        let exponent = exponents[s_index]
        if (y & 16) != 0 {
          let mut x = y >> 5
          let mut yy = y & 0x0F
          if x < 15 {
            g.sb_hybrid[s_index] = read_flip_sign(
              gb,
              expval_table(exponent, x),
            )
          } else {
            x = x + get_bitsz(gb, linbits)
            let v = l3_unscale(x, exponent)
            g.sb_hybrid[s_index] = read_flip_sign(gb, v)
          }
          if yy < 15 {
            g.sb_hybrid[s_index + 1] = read_flip_sign(
              gb,
              expval_table(exponent, yy),
            )
          } else {
            yy = yy + get_bitsz(gb, linbits)
            let v = l3_unscale(yy, exponent)
            g.sb_hybrid[s_index + 1] = read_flip_sign(gb, v)
          }
        } else {
          let mut x = (y >> 5) + (y & 0x0F)
          let yy = y & 0x0F
          if x < 15 {
            g.sb_hybrid[s_index + (if yy != 0 { 1 } else { 0 })] =
              read_flip_sign(gb, expval_table(exponent, x))
          } else {
            x = x + get_bitsz(gb, linbits)
            let v = l3_unscale(x, exponent)
            g.sb_hybrid[s_index + (if yy != 0 { 1 } else { 0 })] =
              read_flip_sign(gb, v)
          }
          g.sb_hybrid[s_index + (if yy != 0 { 0 } else { 1 })] = 0
        }
      } else {
        g.sb_hybrid[s_index] = 0
        g.sb_hybrid[s_index + 1] = 0
      }
      s_index = s_index + 2
      pairs = pairs - 1
    }
  }
  // count1 quadruples
  let idxtab = [3, 3, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0]
  while s_index <= 572 {
    if gb.count() >= end_pos {
      break
    }
    let mut code = quad_decode(gb, g.count1table_select)
    g.sb_hybrid[s_index] = 0
    g.sb_hybrid[s_index + 1] = 0
    g.sb_hybrid[s_index + 2] = 0
    g.sb_hybrid[s_index + 3] = 0
    while code != 0 {
      let pos = s_index + idxtab[code]
      code = code ^ (8 >> idxtab[code])
      let v = exp_table(exponents[pos])
      g.sb_hybrid[pos] = read_flip_sign(gb, v)
    }
    s_index = s_index + 4
  }
  while s_index < 576 {
    g.sb_hybrid[s_index] = 0
    s_index = s_index + 1
  }
  gb.set_pos(end_pos2)
}

// ---------------------------------------------------------------------------
// Layer III post-processing
// ---------------------------------------------------------------------------

///| `reorder_block`. */
fn reorder_block(sr_index : Int, g : Mp3Granule) -> Unit {
  if g.block_type != 2 {
    return
  }
  let mut ptr = if g.switch_point != 0 {
    if sr_index != 8 {
      36
    } else {
      72
    }
  } else {
    0
  }
  let tmp = Array::make(576, 0)
  for i = g.short_start; i < 13; i = i + 1 {
    let len = band_size_short[sr_index * 13 + i]
    let ptr1 = ptr
    for j = 0; j < len; j = j + 1 {
      tmp[3 * j] = g.sb_hybrid[ptr + j]
      tmp[3 * j + 1] = g.sb_hybrid[ptr + len + j]
      tmp[3 * j + 2] = g.sb_hybrid[ptr + 2 * len + j]
    }
    for j = 0; j < 3 * len; j = j + 1 {
      g.sb_hybrid[ptr1 + j] = tmp[j]
    }
    ptr = ptr1 + 3 * len
  }
}

///| Apply the 8 fixed antialias butterflies at one band boundary. */
fn antialias_band(g : Mp3Granule, ptr : Int) -> Unit {
  for j = 0; j < 8; j = j + 1 {
    let t0 = g.sb_hybrid[ptr - 1 - j]
    let t1 = g.sb_hybrid[ptr + j]
    let t2 = mulh(t0 + t1, csa_table[j][0])
    g.sb_hybrid[ptr - 1 - j] = 4 * (t2 - mulh(t1, csa_table[j][2]))
    g.sb_hybrid[ptr + j] = 4 * (t2 + mulh(t0, csa_table[j][3]))
  }
}

///| `compute_antialias`. */
fn compute_antialias(g : Mp3Granule) -> Unit {
  let n = if g.block_type == 2 {
    if g.switch_point == 0 {
      return
    }
    1
  } else {
    sblimit - 1
  }
  let mut ptr = 18
  for li = 0; li < n; li = li + 1 {
    antialias_band(g, ptr)
    ptr = ptr + 18
  }
}

///| `ISQRT2`. */
let isqrt2 : Int = fixr(0.70710678118654752440)

///| `compute_stereo`. */
fn compute_stereo(
  sr_index : Int,
  lsf : Int,
  mode_ext : Int,
  g0 : Mp3Granule,
  g1 : Mp3Granule
) -> Unit {
  let intensity = (mode_ext & 1) != 0
  let ms = (mode_ext & 2) != 0
  if intensity {
    let is_tab = if lsf == 0 {
      is_table
    } else {
      is_table_lsf[g1.scalefac_compress & 1]
    }
    let sf_max = if lsf == 0 { 7 } else { 16 }
    let mut pos0 = 576
    let mut pos1 = 576
    let non_zero_short = [0, 0, 0]
    let mut k = (13 - g1.short_start) * 3 + g1.long_end - 3
    for i = 12; i >= g1.short_start; i = i - 1 {
      if i != 11 {
        k = k - 3
      }
      let len = band_size_short[sr_index * 13 + i]
      for l = 2; l >= 0; l = l - 1 {
        pos0 = pos0 - len
        pos1 = pos1 - len
        if non_zero_short[l] == 0 {
          let mut sf = g1.scale_factors[k + l]
          let mut found = false
          for j = 0; j < len; j = j + 1 {
            if g1.sb_hybrid[pos1 + j] != 0 {
              found = true
              break
            }
          }
          if !found && sf < sf_max {
            let v1 = is_tab[0][sf]
            let v2 = is_tab[1][sf]
            for j = 0; j < len; j = j + 1 {
              let t = g0.sb_hybrid[pos0 + j]
              g0.sb_hybrid[pos0 + j] = mullx(t, v1, frac_bits)
              g1.sb_hybrid[pos1 + j] = mullx(t, v2, frac_bits)
            }
            sf = sf // keep the C's scale-factor lookup read
          } else {
            non_zero_short[l] = 1
            if ms {
              for j = 0; j < len; j = j + 1 {
                let a = g0.sb_hybrid[pos0 + j]
                let b = g1.sb_hybrid[pos1 + j]
                g0.sb_hybrid[pos0 + j] = mullx(a + b, isqrt2, frac_bits)
                g1.sb_hybrid[pos1 + j] = mullx(a - b, isqrt2, frac_bits)
              }
            }
          }
        } else if ms {
          for j = 0; j < len; j = j + 1 {
            let a = g0.sb_hybrid[pos0 + j]
            let b = g1.sb_hybrid[pos1 + j]
            g0.sb_hybrid[pos0 + j] = mullx(a + b, isqrt2, frac_bits)
            g1.sb_hybrid[pos1 + j] = mullx(a - b, isqrt2, frac_bits)
          }
        }
      }
    }
    let mut non_zero = non_zero_short[0] | non_zero_short[1] | non_zero_short[2]
    let mut pos0l = pos0
    let mut pos1l = pos1
    for i = g1.long_end - 1; i >= 0; i = i - 1 {
      let len = band_size_long[sr_index * 22 + i]
      pos0l = pos0l - len
      pos1l = pos1l - len
      if non_zero == 0 {
        let mut found = false
        for j = 0; j < len; j = j + 1 {
          if g1.sb_hybrid[pos1l + j] != 0 {
            found = true
            break
          }
        }
        let kk = if i == 21 { 20 } else { i }
        let sf = g1.scale_factors[kk]
        if !found && sf < sf_max {
          let v1 = is_tab[0][sf]
          let v2 = is_tab[1][sf]
          for j = 0; j < len; j = j + 1 {
            let t = g0.sb_hybrid[pos0l + j]
            g0.sb_hybrid[pos0l + j] = mullx(t, v1, frac_bits)
            g1.sb_hybrid[pos1l + j] = mullx(t, v2, frac_bits)
          }
        } else {
          non_zero = 1
          if ms {
            for j = 0; j < len; j = j + 1 {
              let a = g0.sb_hybrid[pos0l + j]
              let b = g1.sb_hybrid[pos1l + j]
              g0.sb_hybrid[pos0l + j] = mullx(a + b, isqrt2, frac_bits)
              g1.sb_hybrid[pos1l + j] = mullx(a - b, isqrt2, frac_bits)
            }
          }
        }
      } else if ms {
        for j = 0; j < len; j = j + 1 {
          let a = g0.sb_hybrid[pos0l + j]
          let b = g1.sb_hybrid[pos1l + j]
          g0.sb_hybrid[pos0l + j] = mullx(a + b, isqrt2, frac_bits)
          g1.sb_hybrid[pos1l + j] = mullx(a - b, isqrt2, frac_bits)
        }
      }
    }
  } else if ms {
    for i = 0; i < 576; i = i + 1 {
      let a = g0.sb_hybrid[i]
      let b = g1.sb_hybrid[i]
      g0.sb_hybrid[i] = a + b
      g1.sb_hybrid[i] = a - b
    }
  }
}

// ---------------------------------------------------------------------------
// IMDCT wiring
// ---------------------------------------------------------------------------

///| `compute_imdct` for one granule/channel. */
fn compute_imdct(
  g : Mp3Granule,
  out : Array[Int],
  out_base : Int,
  buf : Array[Int]
) -> Unit {
  let mut ptr = 576
  let tmp_ptr = 36
  while ptr >= tmp_ptr {
    ptr = ptr - 6
    let mut nonzero = false
    for k = 0; k < 6; k = k + 1 {
      if g.sb_hybrid[ptr + k] != 0 {
        nonzero = true
        break
      }
    }
    if nonzero {
      break
    }
  }
  let sblimit_used = (ptr / 18) + 1
  let mdct_long_end = if g.block_type == 2 {
    if g.switch_point != 0 { 2 } else { 0 }
  } else {
    sblimit_used
  }

  let mut buf_off = 0
  for j = 0; j < mdct_long_end; j = j + 1 {
    let win_idx = if g.switch_point != 0 && j < 2 { 0 } else { g.block_type }
    let win = mdct_win[win_idx + (4 & -(j & 1))]
    imdct36(out, out_base + j, buf, buf_off, g.sb_hybrid, j * 18, win)
    buf_off = buf_off + (if (j & 3) != 3 { 1 } else { 69 })
  }
  let mut bpos = 4 * 18 * (mdct_long_end >> 2) + (mdct_long_end & 3)
  let mut ptr2 = 18 * mdct_long_end
  let out2 = Array::make(12, 0)
  for j = mdct_long_end; j < sblimit_used; j = j + 1 {
    let win = mdct_win[2 + (4 & -(j & 1))]
    let out_ptr = out_base + j
    for i = 0; i < 6; i = i + 1 {
      out[out_ptr + i * sblimit] = buf[bpos + 4 * i]
    }
    imdct12(out2, g.sb_hybrid, ptr2)
    for i = 0; i < 6; i = i + 1 {
      out[out_ptr + (6 + i) * sblimit] = mulh3(out2[i], win[i], 1) +
        buf[bpos + 4 * (i + 6 * 1)]
      buf[bpos + 4 * (i + 6 * 2)] = mulh3(out2[i + 6], win[i + 6], 1)
    }
    imdct12(out2, g.sb_hybrid, ptr2 + 1)
    for i = 0; i < 6; i = i + 1 {
      out[out_ptr + (12 + i) * sblimit] = mulh3(out2[i], win[i], 1) +
        buf[bpos + 4 * (i + 6 * 2)]
      buf[bpos + 4 * (i + 6 * 0)] = mulh3(out2[i + 6], win[i + 6], 1)
    }
    imdct12(out2, g.sb_hybrid, ptr2 + 2)
    for i = 0; i < 6; i = i + 1 {
      buf[bpos + 4 * (i + 6 * 0)] = mulh3(out2[i], win[i], 1) +
        buf[bpos + 4 * (i + 6 * 0)]
      buf[bpos + 4 * (i + 6 * 1)] = mulh3(out2[i + 6], win[i + 6], 1)
      buf[bpos + 4 * (i + 6 * 2)] = 0
    }
    ptr2 = ptr2 + 18
    bpos = bpos + (if (j & 3) != 3 { 1 } else { 69 })
  }
  for j = sblimit_used; j < sblimit; j = j + 1 {
    let out_ptr = out_base + j
    for i = 0; i < 18; i = i + 1 {
      out[out_ptr + i * sblimit] = buf[bpos + 4 * i]
      buf[bpos + 4 * i] = 0
    }
    bpos = bpos + (if (j & 3) != 3 { 1 } else { 69 })
  }
}

// ---------------------------------------------------------------------------
// Frame decode
// ---------------------------------------------------------------------------

///| Decode one MP3 frame (header + payload) and return interleaved S16 PCM. */
pub fn Mp3Decoder::decode_frame(
  self : Mp3Decoder,
  frame : Bytes
) -> Result[Mp3Pcm, String] {
  let mut start = 0
  while start < frame.length() && frame[start] == b'\x00' {
    start = start + 1
  }
  if frame.length() - start < 4 {
    return Err("EINVAL")
  }
  let header = (frame[start].to_uint() << 24) |
    (frame[start + 1].to_uint() << 16) | (frame[start + 2].to_uint() << 8) |
    frame[start + 3].to_uint()
  let h = match avpriv_mpegaudio_decode_header(header) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  if h.layer != 1 && h.layer != 2 && h.layer != 3 {
    return Err("unsupported layer")
  }
  if h.free_format || h.frame_size <= 0 {
    return Err("EINVAL")
  }
  let mut size = h.frame_size
  if start + size > frame.length() {
    size = frame.length() - start
  }
  if size < 4 {
    return Err("EINVAL")
  }
  let fbytes = frame.clamped_view(start=start, end=start + size).to_owned()
  // The sample rate/channel layout is fixed for a stream.
  if self.sample_rate != 0 && self.sample_rate != h.sample_rate {
    self.flush()
  }
  self.sample_rate = h.sample_rate
  self.sample_rate_index = h.sample_rate_index
  self.lsf = h.lsf
  self.error_protection = h.error_protection
  self.nb_channels = h.nb_channels
  self.mode = h.mode
  self.mode_ext = h.mode_ext
  self.bit_rate = h.bit_rate
  self.frame_size = size

  let gb = BitReader::with_size(fbytes.clamped_view(start=4, end=size).to_owned(), (size - 4) * 8)
  let mut main_data_begin = 0
  let mut nb_granules = 0
  if h.error_protection != 0 {
    let _ = gb.read(16) // CRC
  }
  // Layer I / II: no side info, no bit reservoir, no IMDCT — the requantised
  // subband samples go straight to the shared synthesis filter.
  if h.layer != 3 {
    let nb_blocks = if h.layer == 1 {
      match mpa_decode_layer1(self, gb, h) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    } else {
      match mpa_decode_layer2(self, gb, h) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
    }
    return Ok(mpa_synthesize(self, h, nb_blocks))
  }
  if h.lsf != 0 {
    main_data_begin = gb.read(8).reinterpret_as_int()
    gb.skip(h.nb_channels)
    nb_granules = 1
  } else {
    main_data_begin = gb.read(9).reinterpret_as_int()
    gb.skip(if h.nb_channels == 2 { 3 } else { 5 })
    nb_granules = 2
    for ch = 0; ch < h.nb_channels; ch = ch + 1 {
      self.granules[ch][0].scfsi = 0
      self.granules[ch][1].scfsi = gb.read(4).reinterpret_as_int()
    }
  }

  for gr = 0; gr < nb_granules; gr = gr + 1 {
    for ch = 0; ch < h.nb_channels; ch = ch + 1 {
      let g = self.granules[ch][gr]
      g.part2_3_length = gb.read(12).reinterpret_as_int()
      g.big_values = gb.read(9).reinterpret_as_int()
      if g.big_values > 288 {
        return Err("EINVAL")
      }
      g.global_gain = gb.read(8).reinterpret_as_int()
      if (h.mode_ext & 3) == 2 {
        g.global_gain = g.global_gain - 2
      }
      g.scalefac_compress = if h.lsf != 0 {
        gb.read(9).reinterpret_as_int()
      } else {
        gb.read(4).reinterpret_as_int()
      }
      let blocksplit = gb.read1().reinterpret_as_int()
      if blocksplit != 0 {
        g.block_type = gb.read(2).reinterpret_as_int()
        if g.block_type == 0 {
          return Err("EINVAL")
        }
        g.switch_point = gb.read1().reinterpret_as_int()
        for i = 0; i < 2; i = i + 1 {
          g.table_select[i] = gb.read(5).reinterpret_as_int()
        }
        for i = 0; i < 3; i = i + 1 {
          g.subblock_gain[i] = gb.read(3).reinterpret_as_int()
        }
        init_short_region(h.sample_rate_index, g)
      } else {
        g.block_type = 0
        g.switch_point = 0
        for i = 0; i < 3; i = i + 1 {
          g.table_select[i] = gb.read(5).reinterpret_as_int()
        }
        let ra1 = gb.read(4).reinterpret_as_int()
        let ra2 = gb.read(3).reinterpret_as_int()
        init_long_region(h.sample_rate_index, g, ra1, ra2)
      }
      region_offset2size(g)
      compute_band_indexes(h.sample_rate_index, g)
      g.preflag = 0
      if h.lsf == 0 {
        g.preflag = gb.read1().reinterpret_as_int()
      }
      g.scalefac_scale = gb.read1().reinterpret_as_int()
      g.count1table_select = gb.read1().reinterpret_as_int()
    }
  }

  // Main data region starts after the side info (and optional CRC).
  let main_data_start = 4 + (gb.count() >> 3)
  if main_data_start > fbytes.length() {
    return Err("EINVAL")
  }
  let frame_start_bit = self.reservoir_base_bit + self.reservoir.length() * 8
  for i = main_data_start; i < fbytes.length(); i = i + 1 {
    self.reservoir.push(fbytes[i])
  }
  let start_bit = frame_start_bit - 8 * main_data_begin
  let mut reader_start = start_bit - self.reservoir_base_bit
  if reader_start < 0 {
    reader_start = 0
  }
  let rb = Bytes::from_array(self.reservoir[:])
  let rgb = BitReader::new(rb)
  rgb.set_pos(reader_start)

  for gr = 0; gr < nb_granules; gr = gr + 1 {
    for ch = 0; ch < h.nb_channels; ch = ch + 1 {
      let g = self.granules[ch][gr]
      let bits_pos = rgb.count()
      if h.lsf == 0 {
        let slen1 = slen_table[g.scalefac_compress]
        let slen2 = slen_table[16 + g.scalefac_compress]
        if g.block_type == 2 {
          let n = if g.switch_point != 0 { 17 } else { 18 }
          let mut j = 0
          for li = 0; li < n; li = li + 1 {
            g.scale_factors[j] = if slen1 != 0 {
              rgb.read(slen1).reinterpret_as_int()
            } else {
              0
            }
            j = j + 1
          }
          for li = 0; li < 18; li = li + 1 {
            g.scale_factors[j] = if slen2 != 0 {
              rgb.read(slen2).reinterpret_as_int()
            } else {
              0
            }
            j = j + 1
          }
          for li = 0; li < 3; li = li + 1 {
            g.scale_factors[j] = 0
            j = j + 1
          }
        } else {
          let sc = self.granules[ch][0].scale_factors
          let mut j = 0
          for k = 0; k < 4; k = k + 1 {
            let n = if k == 0 { 6 } else { 5 }
            if (g.scfsi & (0x8 >> k)) == 0 {
              let slen = if k < 2 { slen1 } else { slen2 }
              for li = 0; li < n; li = li + 1 {
                g.scale_factors[j] = if slen != 0 {
                  rgb.read(slen).reinterpret_as_int()
                } else {
                  0
                }
                j = j + 1
              }
            } else {
              for li = 0; li < n; li = li + 1 {
                g.scale_factors[j] = sc[j]
                j = j + 1
              }
            }
          }
          g.scale_factors[j] = 0
        }
      } else {
        let tindex = if g.block_type == 2 {
          if g.switch_point != 0 { 2 } else { 1 }
        } else {
          0
        }
        let mut sf = g.scalefac_compress
        let mut slen : Array[Int] = [0, 0, 0, 0]
        let mut tindex2 = 0
        if (h.mode_ext & 1) != 0 && ch == 1 {
          sf = sf >> 1
          if sf < 180 {
            slen = lsf_sf_expand(sf, 6, 6, 0)
            tindex2 = 3
          } else if sf < 244 {
            slen = lsf_sf_expand(sf - 180, 4, 4, 0)
            tindex2 = 4
          } else {
            slen = lsf_sf_expand(sf - 244, 3, 0, 0)
            tindex2 = 5
          }
        } else {
          if sf < 400 {
            slen = lsf_sf_expand(sf, 5, 4, 4)
            tindex2 = 0
          } else if sf < 500 {
            slen = lsf_sf_expand(sf - 400, 5, 4, 0)
            tindex2 = 1
          } else {
            slen = lsf_sf_expand(sf - 500, 3, 0, 0)
            tindex2 = 2
            g.preflag = 1
          }
        }
        let mut j = 0
        for k = 0; k < 4; k = k + 1 {
          let n = lsf_nsf_table[tindex2 * 12 + tindex * 4 + k]
          for li = 0; li < n; li = li + 1 {
            g.scale_factors[j] = if slen[k] != 0 {
              rgb.read(slen[k]).reinterpret_as_int()
            } else {
              0
            }
            j = j + 1
          }
        }
        while j < 40 {
          g.scale_factors[j] = 0
          j = j + 1
        }
      }
      let exponents = Array::make(576, 0)
      exponents_from_scale_factors(h.sample_rate_index, g, exponents)
      huffman_decode(rgb, g, exponents, bits_pos + g.part2_3_length)
    }
    if h.mode == 1 && h.nb_channels == 2 {
      compute_stereo(
        h.sample_rate_index, h.lsf, h.mode_ext, self.granules[0][gr],
        self.granules[1][gr],
      )
    }
    for ch = 0; ch < h.nb_channels; ch = ch + 1 {
      let g = self.granules[ch][gr]
      reorder_block(h.sample_rate_index, g)
      compute_antialias(g)
      compute_imdct(g, self.sb_samples[ch], 18 * gr * 32, self.mdct_buf[ch])
    }
  }

  // Keep the reservoir bounded. main_data_begin <= 511 for MPEG-1, so 4 KiB
  // of history is ample.
  if self.reservoir.length() > 8192 {
    let drop = self.reservoir.length() - 4096
    let nr = Array::make(4096, b'\x00')
    for i = 0; i < 4096; i = i + 1 {
      nr[i] = self.reservoir[drop + i]
    }
    self.reservoir = nr
    self.reservoir_base_bit = self.reservoir_base_bit + drop * 8
  }

  // Synthesis filter (channels are processed in order, sharing dither_state).
  Ok(mpa_synthesize(self, h, nb_granules * 18))
}

///|
/// `ff_mpa_synth_filter` applied to `nb_blocks` blocks of 32 subband samples per
/// channel, then interleaved into one `Mp3Pcm`. Shared by all three layers.
fn mpa_synthesize(
  dec : Mp3Decoder,
  h : MpaDecodeHeader,
  nb_blocks : Int
) -> Mp3Pcm {
  let planar : Array[Array[Int]] = [
    Array::make(nb_blocks * 32, 0),
    Array::make(nb_blocks * 32, 0),
  ]
  for ch = 0; ch < h.nb_channels; ch = ch + 1 {
    for i = 0; i < nb_blocks; i = i + 1 {
      dct32(dec.synth_buf[ch], dec.synth_offset[ch], dec.sb_samples[ch], i * 32)
      dec.dither_state = apply_window(
        dec.synth_buf[ch],
        dec.synth_offset[ch],
        synth_window,
        dec.dither_state,
        planar[ch],
        i * 32,
        1,
      )
      dec.synth_offset[ch] = (dec.synth_offset[ch] - 32) & 511
    }
  }
  let samples = Array::make(nb_blocks * 32 * h.nb_channels, 0)
  for i = 0; i < nb_blocks * 32; i = i + 1 {
    for ch = 0; ch < h.nb_channels; ch = ch + 1 {
      samples[i * h.nb_channels + ch] = planar[ch][i]
    }
  }
  { sample_rate: h.sample_rate, channels: h.nb_channels, samples }
}

///|
/// Decode a complete raw MPEG-audio stream (Layer I, II or III; all frames
/// concatenated, optionally with an ID3v2 tag already removed). This is a
/// convenience wrapper around `Mp3Decoder::decode_frame` for tests and CLI use;
/// it walks frames by `frame_size`, so it handles all three layers.
pub fn decode_mp3_stream(data : Bytes) -> Result[Mp3Pcm, String] {
  let mut start = 0
  if data.length() >= 10 && data[0] == b'I' && data[1] == b'D' &&
    data[2] == b'3' {
    let len = ((data[6].to_int() & 0x7F) << 21) +
      ((data[7].to_int() & 0x7F) << 14) + ((data[8].to_int() & 0x7F) << 7) +
      (data[9].to_int() & 0x7F) + 10
    start = if len < data.length() { len } else { data.length() }
  }
  let dec = new_mp3_decoder()
  let all : Array[Int] = []
  let mut pos = start
  let mut sample_rate = 0
  let mut channels = 0
  while pos + 4 <= data.length() {
    let header = (data[pos].to_uint() << 24) |
      (data[pos + 1].to_uint() << 16) | (data[pos + 2].to_uint() << 8) |
      data[pos + 3].to_uint()
    let h = match avpriv_mpegaudio_decode_header(header) {
      Err(_) => {
        pos = pos + 1
        continue
      }
      Ok(v) => v
    }
    if h.free_format || h.frame_size <= 0 || pos + h.frame_size > data.length() {
      break
    }
    let frame = data.clamped_view(start=pos, end=pos + h.frame_size).to_owned()
    let pcm = match dec.decode_frame(frame) {
      Err(_) => {
        pos = pos + h.frame_size
        continue
      }
      Ok(v) => v
    }
    sample_rate = pcm.sample_rate
    channels = pcm.channels
    for s in pcm.samples {
      all.push(s)
    }
    pos = pos + h.frame_size
  }
  if all.length() == 0 {
    return Err("EINVAL")
  }
  Ok({ sample_rate, channels, samples: all })
}
