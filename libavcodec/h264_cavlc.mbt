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
/// `decode_residual` covers the 4:2:0/8-bit paths: 16-entry luma blocks,
/// 15-entry luma AC blocks, 4-entry chroma DC and 15-entry chroma AC blocks.
/// 4:2:2 chroma DC (8-entry) is not ported.
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
fn h264_dequant_level(level : Int32, qmul : Int32) -> Int32 {
  let prod = level.reinterpret_as_uint() * qmul.reinterpret_as_uint() + 32U
  h264_i16(prod.reinterpret_as_int() >> 6)
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
) -> Result[Int32, String] {
  let coeff_token = if max_coeff <= 8 {
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
    let initial_suffix = suffix_length
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
    suffix_length = if prefix + 1 + initial_suffix <= 8 {
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
  } else if max_coeff <= 8 {
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
      Some(q) => h264_dequant_level(level[i], q[pos])
      None => h264_i16(level[i])
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
fn h264_get_chroma_qp(pps : H264Pps, t : Int32, qscale : Int32) -> Int32 {
  let offset = if t == 0 {
    pps.chroma_qp_index_offset0
  } else {
    pps.chroma_qp_index_offset1
  }
  let idx = qscale + offset
  let clipped = if idx < 0 { 0 } else if idx > 51 { 51 } else { idx }
  h264_chroma_qp_8bit[clipped]
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
