///|
/// MoonBit port of the CAVLC residual decoder from FFmpeg 9.0.2
/// `libavcodec/h264_cavlc.c` (`decode_residual`) together with the
/// PPS-derived dequantisation tables (`ff_h264_dequant4_coeff_init`,
/// `ff_h264_chroma_qp`) consumed by it.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C VLC subsystem is replaced by explicit binary tries built from the
/// same `(length, bits)` tables; decoding is bit-exact but not table-driven.
/// `decode_residual` covers 16-entry luma blocks, 15-entry luma AC blocks,
/// the 4-entry (4:2:0) and 8-entry (4:2:2) chroma DC blocks and 15-entry
/// chroma AC blocks.
///
/// Coefficient blocks use FFmpeg's transposed layout: the scan tables and the
/// `qmul` arrays are both transposed by `(x >> 2) | ((x << 2) & 0xF)`, so the
/// stored position can be fed to `h264_idct_add` unchanged.

///|
/// One node of a binary VLC trie (`c0`/`c1` are child indices, `-1` = none). */
priv struct H264VlcNode {
  c0 : Int32
  c1 : Int32
  sym : Int32
}

///|
/// A binary VLC trie indexed by consecutive bits starting at the MSB. */
priv struct H264Vlc {
  nodes : Array[H264VlcNode]
}

///|
/// Build a decode trie from explicit `(length, code)` VLC tables. */
fn h264_vlc_build(lens : Array[Int32], bits : Array[Int32]) -> H264Vlc {
  let nodes : Array[H264VlcNode] = [{ c0: -1, c1: -1, sym: -1, }]
  for sym = 0; sym < lens.length(); sym = sym + 1 {
    let len = lens[sym]
    if len > 0 {
      let mut node = 0
      for k = len - 1; k >= 0; k = k - 1 {
        let cur = nodes[node]
        let bit = (bits[sym] >> k) & 1
        let next = if bit == 0 { cur.c0 } else { cur.c1 }
        if next < 0 {
          nodes.push({ c0: -1, c1: -1, sym: -1, })
          let idx = nodes.length() - 1
          if bit == 0 {
            nodes[node] = { c0: idx, c1: cur.c1, sym: cur.sym, }
          } else {
            nodes[node] = { c0: cur.c0, c1: idx, sym: cur.sym, }
          }
          node = idx
        } else {
          node = next
        }
      }
      nodes[node] = { c0: nodes[node].c0, c1: nodes[node].c1, sym, }
    }
  }
  { nodes, }
}

///|
/// Decode one symbol; returns -1 on an invalid or truncated code. */
fn H264Vlc::decode(self : H264Vlc, gb : BitReader) -> Int32 {
  let mut node = 0
  while self.nodes[node].sym < 0 {
    let bit = gb.read1().reinterpret_as_int()
    node = if bit == 0 { self.nodes[node].c0 } else { self.nodes[node].c1 }
    if node < 0 || gb.bits_left() < 0 {
      return -1
    }
  }
  self.nodes[node].sym
}

///|
/// `coeff_token_vlc[0..3]`: one table per nC class. */
let h264_coeff_token_vlcs : Array[H264Vlc] = [
  h264_vlc_build(h264_coeff_token_len[0], h264_coeff_token_bits[0]),
  h264_vlc_build(h264_coeff_token_len[1], h264_coeff_token_bits[1]),
  h264_vlc_build(h264_coeff_token_len[2], h264_coeff_token_bits[2]),
  h264_vlc_build(h264_coeff_token_len[3], h264_coeff_token_bits[3]),
]

///|
/// `chroma_dc_coeff_token_vlc_table`. */
let h264_chroma_dc_coeff_token_vlc : H264Vlc = h264_vlc_build(
  h264_chroma_dc_coeff_token_len, h264_chroma_dc_coeff_token_bits,
)

///|
/// `chroma422_dc_coeff_token_len[4*9]` (`h264_cavlc.c`). */
let h264_chroma422_dc_coeff_token_len : Array[Int32] = [
  1, 0, 0, 0, 7, 2, 0, 0, 7, 7, 3, 0, 9, 7, 7, 5, 9, 9, 7, 6, 10, 10, 9, 7, 11,
  11, 10, 7, 12, 12, 11, 10, 13, 12, 12, 11,
]

///|
/// `chroma422_dc_coeff_token_bits[4*9]`. */
let h264_chroma422_dc_coeff_token_bits : Array[Int32] = [
  1, 0, 0, 0, 15, 1, 0, 0, 14, 13, 1, 0, 7, 12, 11, 1, 6, 5, 10, 1, 7, 6, 4, 9, 7,
  6, 5, 8, 7, 6, 5, 4, 7, 5, 4, 4,
]

///|
/// `chroma422_dc_coeff_token_vlc_table`. */
let h264_chroma422_dc_coeff_token_vlc : H264Vlc = h264_vlc_build(
  h264_chroma422_dc_coeff_token_len, h264_chroma422_dc_coeff_token_bits,
)

///|
/// `chroma422_dc_total_zeros_len[7][8]`. */
let h264_chroma422_dc_total_zeros_len : Array[Array[Int32]] = [
  [1, 3, 3, 4, 4, 4, 5, 5],
  [3, 2, 3, 3, 3, 3, 3],
  [3, 3, 2, 2, 3, 3],
  [3, 2, 2, 2, 3],
  [2, 2, 2, 2],
  [2, 2, 1],
  [1, 1],
]

///|
/// `chroma422_dc_total_zeros_bits[7][8]`. */
let h264_chroma422_dc_total_zeros_bits : Array[Array[Int32]] = [
  [1, 2, 3, 2, 3, 1, 1, 0],
  [0, 1, 1, 4, 5, 6, 7],
  [0, 1, 1, 2, 6, 7],
  [6, 0, 1, 2, 7],
  [0, 1, 2, 3],
  [0, 1, 1],
  [0, 1],
]

///|
/// `chroma422_dc_total_zeros_vlc[1..7]`. */
let h264_chroma422_dc_total_zeros_vlcs : Array[H264Vlc] = {
  let v : Array[H264Vlc] = []
  for i = 0; i < 7; i = i + 1 {
    v.push(
      h264_vlc_build(
        h264_chroma422_dc_total_zeros_len[i],
        h264_chroma422_dc_total_zeros_bits[i],
      ),
    )
  }
  v
}

///|
/// `ff_h264_chroma422_dc_scan[8]`: coefficient i lands at block offset
/// `(x + 2 * y) * 16` of the macroblock coefficient buffer. */
let h264_chroma422_dc_scan : Array[Int32] = [0, 32, 16, 64, 96, 48, 80, 112]

///|
/// `golomb_to_inter_cbp_gray[16]` (`h264_cavlc.c`): 4:4:4 codes no chroma CBP. */
let h264_golomb_to_inter_cbp_gray : Array[Int32] = [
  0, 1, 2, 4, 8, 3, 5, 10, 12, 15, 7, 11, 13, 14, 6, 9,
]

///|
/// `golomb_to_intra4x4_cbp_gray[16]`. */
let h264_golomb_to_intra4x4_cbp_gray : Array[Int32] = [
  15, 0, 7, 11, 13, 14, 3, 5, 10, 12, 1, 2, 4, 8, 6, 9,
]

///|
/// `total_zeros_vlc[1..15]` (row i is total_coeff = i + 1). */
let h264_total_zeros_vlcs : Array[H264Vlc] = {
  let v : Array[H264Vlc] = []
  for i = 0; i < 15; i = i + 1 {
    v.push(h264_vlc_build(h264_total_zeros_len[i], h264_total_zeros_bits[i]))
  }
  v
}

///|
/// `chroma_dc_total_zeros_vlc[1..3]`. */
let h264_chroma_dc_total_zeros_vlcs : Array[H264Vlc] = {
  let v : Array[H264Vlc] = []
  for i = 0; i < 3; i = i + 1 {
    v.push(
      h264_vlc_build(
        h264_chroma_dc_total_zeros_len[i],
        h264_chroma_dc_total_zeros_bits[i],
      ),
    )
  }
  v
}

///|
/// `run_vlc[1..6]` then `run7_vlc_table` at index 6. */
let h264_run_vlcs : Array[H264Vlc] = {
  let v : Array[H264Vlc] = []
  for i = 0; i < 7; i = i + 1 {
    v.push(h264_vlc_build(h264_run_len[i], h264_run_bits[i]))
  }
  v
}

///|
/// `suffix_limit[7]` from `decode_residual`. */
let h264_suffix_limit : Array[Int32] = [0, 3, 6, 12, 24, 48, 2147483647]

///|
/// `coeff_token_table_index[nC]`: nC 0..1, 2..3, 4..7 and 8..16 share tables.
fn h264_coeff_token_table_for_nc(nc : Int32) -> Int32 {
  if nc <= 1 {
    0
  } else if nc <= 3 {
    1
  } else if nc <= 7 {
    2
  } else {
    3
  }
}

///|
/// `pred_non_zero_count`: average of the left/top non-zero counts, where 64
/// marks an unavailable neighbour (the C cache convention).
fn h264_pred_non_zero_count(left : Int32, top : Int32) -> Int32 {
  let sum = left + top
  if sum < 64 {
    (sum + 1) >> 1
  } else {
    sum & 31
  }
}

///|
/// `get_level_prefix`: number of leading zero bits (consuming the terminating
/// one). The C's 32-bit cache gives 31 for an all-zero window.
fn h264_get_level_prefix(gb : BitReader) -> Int32 {
  let mut n = 0
  while n < 32 {
    if gb.read1() != 0U {
      return n
    }
    n = n + 1
  }
  31
}

///|
/// `((int)(level * qmul + 32)) >> 6`, with the C's 32-bit unsigned product. */
fn h264_dequant_level(level : Int32, qmul : Int32,
  bit_depth? : Int32 = 8,
) -> Int32 {
  let prod = level.reinterpret_as_uint() * qmul.reinterpret_as_uint() + 32U
  h264_store_coef(prod.reinterpret_as_int() >> 6, bit_depth=bit_depth)
}

///|
/// `decode_residual` for 8-bit 4:2:0 CAVLC.
///
/// `block`/`base` address the 16-coefficient destination block; `scan` is the
/// (already transposed) scan table and `scan_start` is 0 for blocks that
/// include the DC coefficient or 1 for AC-only blocks. `qmul` is the
/// dequantisation table for AC blocks and `None` for the DC blocks. `nc` is
/// the predicted non-zero count for blocks with `max_coeff > 8`.
///
/// Returns the decoded `total_coeff` (the C's non-zero count).
fn h264_decode_residual(
  gb : BitReader,
  block : Array[Int32],
  base : Int32,
  scan : Array[Int32],
  scan_start : Int32,
  qmul : Array[Int32]?,
  max_coeff : Int32,
  nc : Int32,

  bit_depth? : Int32 = 8,
) -> Result[Int32, String] {
  let coeff_token = if max_coeff == 8 {
    h264_chroma422_dc_coeff_token_vlc.decode(gb)
  } else if max_coeff == 4 {
    h264_chroma_dc_coeff_token_vlc.decode(gb)
  } else {
    h264_coeff_token_vlcs[h264_coeff_token_table_for_nc(nc & 31)].decode(gb)
  }
  if coeff_token < 0 {
    return Err("invalid coeff_token")
  }
  let total_coeff = coeff_token >> 2
  if total_coeff == 0 {
    return Ok(0)
  }
  if total_coeff > max_coeff {
    return Err("total_coeff exceeds block size")
  }
  let trailing_ones = coeff_token & 3
  let level : Array[Int32] = Array::make(16, 0)
  let bits3 = gb.show(3).reinterpret_as_int()
  gb.skip(trailing_ones)
  level[0] = 1 - ((bits3 & 4) >> 1)
  level[1] = 1 - (bits3 & 2)
  level[2] = 1 - ((bits3 & 1) << 1)
  if trailing_ones < total_coeff {
    let mut suffix_length = if total_coeff > 10 && trailing_ones < 3 {
      1
    } else {
      0
    }
    let prefix = h264_get_level_prefix(gb)
    let mut code = 0
    if prefix < 14 {
      code = if suffix_length != 0 {
        (prefix << 1) + gb.read1().reinterpret_as_int()
      } else {
        prefix
      }
    } else if prefix == 14 {
      code = if suffix_length != 0 {
        (prefix << 1) + gb.read1().reinterpret_as_int()
      } else {
        prefix + gb.read(4).reinterpret_as_int()
      }
    } else {
      if prefix > 28 {
        return Err("invalid level prefix")
      }
      code = 30
      if prefix >= 16 {
        code = code + (1 << (prefix - 3)) - 4096
      }
      code = code + gb.read(prefix - 3).reinterpret_as_int()
    }
    if trailing_ones < 3 {
      code = code + 2
    }
    let mask = -(code & 1)
    let signed = (((2 + code) >> 1) ^ mask) - mask
    level[trailing_ones] = signed
    // `init_cavlc_level_tab` (LEVEL_TAB_BITS == 8): prefixes within the
    // 8-bit window use the folded table value and the small-level suffix
    // rule; longer ones take the escape path with suffix_length 2.
    suffix_length = if prefix + 1 + suffix_length <= 8 {
      1 + (if (if signed < 0 { -signed } else { signed }) > 3 { 1 } else { 0 })
    } else {
      2
    }
    for k = trailing_ones + 1; k < total_coeff; k = k + 1 {
      let p = h264_get_level_prefix(gb)
      let mut c = 0
      if p < 15 {
        c = (p << suffix_length) + gb.read(suffix_length).reinterpret_as_int()
      } else {
        c = 15 << suffix_length
        if p >= 16 {
          if p > 28 {
            return Err("invalid level prefix")
          }
          c = c + (1 << (p - 3)) - 4096
        }
        c = c + gb.read(p - 3).reinterpret_as_int()
      }
      let m = -(c & 1)
      let v = (((2 + c) >> 1) ^ m) - m
      level[k] = v
      let limit = h264_suffix_limit[suffix_length]
      if (if v < 0 { -v } else { v }) > limit {
        suffix_length = suffix_length + 1
      }
    }
  }
  let zeros_left = if total_coeff == max_coeff {
    0
  } else if max_coeff == 8 {
    let z = h264_chroma422_dc_total_zeros_vlcs[total_coeff - 1].decode(gb)
    if z < 0 {
      return Err("invalid chroma422_dc_total_zeros")
    }
    z
  } else if max_coeff == 4 {
    let z = h264_chroma_dc_total_zeros_vlcs[total_coeff - 1].decode(gb)
    if z < 0 {
      return Err("invalid chroma_dc_total_zeros")
    }
    z
  } else {
    let z = h264_total_zeros_vlcs[total_coeff - 1].decode(gb)
    if z < 0 {
      return Err("invalid total_zeros")
    }
    z
  }
  let mut si = scan_start + zeros_left + total_coeff - 1
  let mut i = 0
  let mut zl = zeros_left
  while i < total_coeff {
    if i > 0 && zl > 0 {
      let run = if zl < 7 {
        h264_run_vlcs[zl - 1].decode(gb)
      } else {
        h264_run_vlcs[6].decode(gb)
      }
      if run < 0 {
        return Err("invalid run_before")
      }
      zl = zl - run
      si = si - 1 - run
    } else if i > 0 {
      si = si - 1
    }
    if si < 0 || si >= scan.length() {
      return Err("residual scan out of range")
    }
    let pos = scan[si]
    block[base + pos] = match qmul {
      Some(q) => h264_dequant_level(level[i], q[pos], bit_depth=bit_depth)
      None => h264_store_coef(level[i], bit_depth=bit_depth)
    }
    i = i + 1
  }
  if zl < 0 {
    return Err("negative zero run")
  }
  Ok(total_coeff)
}

///|
/// Build the PPS `dequant4_coeff[matrix][qp]` table used by CAVLC. The
/// storage order is transposed exactly like FFmpeg's
/// `[(x >> 2) | ((x << 2) & 0xF)]`.
fn h264_build_dequant4(
  pps : H264Pps,
  matrix : Int32,
  qp : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(16, 0)
  let scaling = pps.scaling_matrix4[matrix]
  let rem = qp % 6
  let div = qp / 6
  for x = 0; x < 16; x = x + 1 {
    let idx = (x >> 2) | ((x << 2) & 0xF)
    out[idx] = (h264_dequant4_init[rem][(x & 1) + ((x >> 2) & 1)] * scaling[x]) <<
      (div + 2)
  }
  out
}

///|
/// `get_chroma_qp(pps, t, qscale)` for 8-bit streams. */
fn h264_get_chroma_qp(pps : H264Pps, t : Int32, qscale : Int32,
  bit_depth? : Int32 = 8,
) -> Int32 {
  let offset = if t == 0 {
    pps.chroma_qp_index_offset0
  } else {
    pps.chroma_qp_index_offset1
  }
  let depth_offset = 6 * (bit_depth - 8)
  let idx = (qscale + offset).max(0).min(51 + depth_offset)
  if idx < depth_offset { idx } else { h264_chroma_qp_8bit[idx - depth_offset] + depth_offset }
}

///|
/// `h->zigzag_scan8x8[i] = TRANSPOSE(ff_zigzag_direct[i])`, the 8x8 scan used
/// by 8x8DCT residual coding (the coefficient blocks are stored transposed). */
let h264_zigzag_scan8x8 : Array[Int32] = {
  let direct : Array[Int32] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40,
    48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29,
    22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47,
    55, 62, 63,
  ]
  let t : Array[Int32] = []
  for i = 0; i < 64; i = i + 1 {
    let x = direct[i]
    t.push((x >> 3) | ((x & 7) << 3))
  }
  t
}

///|
/// `ff_h264_dequant8_coeff_init_scan[16]`. */
let h264_dequant8_init_scan : FixedArray[Int32] = [
  0, 3, 4, 3, 3, 1, 5, 1, 4, 5, 2, 5, 3, 1, 5, 1,
]

///|
/// `ff_h264_dequant8_coeff_init[6][6]`. */
let h264_dequant8_init : FixedArray[FixedArray[Int32]] = [
  [20, 18, 32, 19, 25, 24],
  [22, 19, 35, 21, 28, 26],
  [26, 23, 42, 24, 33, 31],
  [28, 25, 45, 26, 35, 33],
  [32, 28, 51, 30, 40, 38],
  [36, 32, 58, 34, 46, 43],
]

///|
/// `init_dequant8_coeff_table`: 64 8x8 dequantisation factors for one matrix
/// (`matrix` = 0 intra luma, 3 inter luma).
fn h264_build_dequant8(
  pps : H264Pps,
  matrix : Int32,
  qp : Int32,
) -> Array[Int32] {
  let out : Array[Int32] = Array::make(64, 0)
  let scaling = pps.scaling_matrix8[matrix]
  let rem = qp % 6
  let div = qp / 6
  for x = 0; x < 64; x = x + 1 {
    let idx = (x >> 3) | ((x & 7) << 3)
    let init_idx = h264_dequant8_init_scan[((x >> 1) & 12) | (x & 3)]
    out[idx] = (h264_dequant8_init[rem][init_idx] * scaling[x]) << div
  }
  out
}

///|
/// `h->zigzag_scan[i] = TRANSPOSE(ff_zigzag_scan[i])`. */
let h264_zigzag_scan_t : Array[Int32] = {
  let t : Array[Int32] = []
  for i = 0; i < 16; i = i + 1 {
    let x = h264_zigzag_scan[i]
    t.push((x >> 2) | ((x << 2) & 0xF))
  }
  t
}
