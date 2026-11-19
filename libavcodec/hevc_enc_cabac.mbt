///|
/// HEVC CABAC encoder, slice 1 of the port: the arithmetic writer mirrors
/// the shared decoder core (`cabac.mbt`, `get_cabac`/bypass/terminate)
/// through the same verified engine shape as the H.264 CABAC encoder
/// (`h264_enc_cabac.mbt`, byte-exact against this repository's decoder),
/// every context offset reuses the decoder's `hevc_cabac_syntax.mbt`
/// constants, and the residual writer inverts `hevc_decode_residual`
/// branch by branch (scan tables, subset loop, significance contexts,
/// greater-1/2 sets, Rice adaptation). Sign data hiding is disabled (PPS
/// flag 0) so all signs are coded explicitly; Rice adaptation is the
/// non-persistent form (SPS flag 0).

///|
/// CABAC arithmetic encoder core (`put_cabac` family), identical bookkeeping
/// to the H.264 encoder's verified engine. */

///|
priv struct HevcCabacEnc {
  mut low : Int32
  mut range : Int32
  mut outstanding : Int32
  bits : Array[Int32]
}

///|
fn hevc_cabac_enc_new() -> HevcCabacEnc {
  { low: 0, range: 0x1FE, outstanding: 0, bits: [], }
}

///|
fn HevcCabacEnc::put_bit(self : HevcCabacEnc, b : Int32) -> Unit {
  self.bits.push(b)
  while self.outstanding > 0 {
    self.bits.push(1 - b)
    self.outstanding = self.outstanding - 1
  }
}

///|
fn HevcCabacEnc::renorm(self : HevcCabacEnc) -> Unit {
  while self.range < 0x100 {
    if self.low < 0x100 {
      self.put_bit(0)
    } else if self.low < 0x200 {
      self.outstanding = self.outstanding + 1
      self.low = self.low - 0x100
    } else {
      self.put_bit(1)
      self.low = self.low - 0x200
    }
    self.range = self.range + self.range
    self.low = self.low + self.low
  }
}

///|
/// One regular decision bin at context `ctx_idx` (`put_cabac`). */
fn HevcCabacEnc::decision(
  self : HevcCabacEnc,
  states : Array[Int32],
  ctx_idx : Int32,
  bit : Int32,
) -> Unit {
  let range_lps = h264_cabac_lps_range(self.range, states[ctx_idx])
  if bit == (states[ctx_idx] & 1) {
    self.range = self.range - range_lps
    states[ctx_idx] = h264_cabac_mlps_state(states[ctx_idx])
  } else {
    self.low = self.low + (self.range - range_lps)
    self.range = range_lps
    states[ctx_idx] = h264_cabac_tables[h264_cabac_mlps_state_offset +
      127 -
      states[ctx_idx]]
  }
  self.renorm()
}

///|
/// One bypass bin (`put_cabac_bypass`). */
fn HevcCabacEnc::bypass(self : HevcCabacEnc, bit : Int32) -> Unit {
  self.low = self.low + self.low
  if bit != 0 {
    self.low = self.low + self.range
  }
  if self.low < 0x200 {
    self.put_bit(0)
  } else if self.low < 0x400 {
    self.outstanding = self.outstanding + 1
    self.low = self.low - 0x200
  } else {
    self.put_bit(1)
    self.low = self.low - 0x400
  }
}

///|
/// The terminating bin (`put_cabac_terminate`); `bit` 1 also flushes. */
fn HevcCabacEnc::terminate(self : HevcCabacEnc, bit : Int32) -> Unit {
  self.range = self.range - 2
  if bit == 0 {
    self.renorm()
  } else {
    self.low = self.low + self.range
    self.range = 2
    self.renorm()
    self.put_bit(self.low >> 9)
    let v = ((self.low >> 7) & 3) | 1
    self.bits.push((v >> 1) & 1)
    self.bits.push(v & 1)
  }
}

///|
/// Pack the bit list into CABAC payload bytes (leading redundant zero of
/// `low` dropped; the decoder's initialisation supplies it). */
fn HevcCabacEnc::to_bytes(self : HevcCabacEnc) -> Array[Byte] {
  let n = (self.bits.length() - 1 + 7) / 8
  let out : Array[Byte] = Array::make(n, b'\x00')
  for i = 1; i < self.bits.length(); i = i + 1 {
    let j = i - 1
    if self.bits[i] != 0 {
      out[j / 8] = (out[j / 8].to_int() | (1 << (7 - j % 8))).to_byte()
    }
  }
  out
}

///|
/// Slice-1 CABAC writer: the engine plus the per-slice context states and
/// the syntax layer. Context offsets come from `hevc_cabac_syntax.mbt`. */
priv struct HevcEncCabac {
  eng : HevcCabacEnc
  states : Array[Int32]
  /// Debug bin trace: (ctx, bit) for regular bins, (-1, bit) for bypass.
  trace : Array[(Int32, Int32)]
}

///|
fn HevcEncCabac::bin(self : HevcEncCabac, ctx : Int32, bit : Int32) -> Unit {
  self.trace.push((ctx, bit))
  self.eng.decision(self.states, ctx, bit)
}

///|
fn HevcEncCabac::bypass(self : HevcEncCabac, bit : Int32) -> Unit {
  self.trace.push((-1, bit))
  self.eng.bypass(bit)
}

///|
fn HevcEncCabac::terminate(self : HevcEncCabac, bit : Int32) -> Unit {
  self.eng.terminate(bit)
}

///|
/// `ff_hevc_split_coding_unit_flag_decode` write side. */
fn HevcEncCabac::split_coding_unit_flag(
  self : HevcEncCabac,
  depth_left : Int32,
  depth_top : Int32,
  ct_depth : Int32,
  bit : Bool,
) -> Unit {
  let inc = (if depth_left > ct_depth { 1 } else { 0 }) +
    (if depth_top > ct_depth { 1 } else { 0 })
  self.bin(hevc_cabac_split_coding_unit_flag + inc, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_part_mode_decode` write side for an intra CU: 2Nx2N is one
/// `1` bin; NxN (only at the min CB size) is `0` then (intra) done. */
fn HevcEncCabac::part_mode_intra(self : HevcEncCabac, nxn : Bool) -> Unit {
  if nxn {
    self.bin(hevc_cabac_part_mode, 0)
  } else {
    self.bin(hevc_cabac_part_mode, 1)
  }
}

///|
/// `ff_hevc_prev_intra_luma_pred_flag_decode` write side. */
fn HevcEncCabac::prev_intra_luma_pred_flag(
  self : HevcEncCabac,
  bit : Bool,
) -> Unit {
  self.bin(hevc_cabac_prev_intra_luma_pred_flag, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_mpm_idx_decode` write side: truncated unary, `i` ones then a
/// zero (two ones when i == 2). */
fn HevcEncCabac::mpm_idx(self : HevcEncCabac, i : Int32) -> Unit {
  for _ in 0..<i {
    self.bypass(1)
  }
  if i < 2 {
    self.bypass(0)
  }
}

///|
/// `ff_hevc_rem_intra_luma_pred_mode_decode` write side: five bypass bits,
/// most significant first. */
fn HevcEncCabac::rem_intra_luma_pred_mode(
  self : HevcEncCabac,
  value : Int32,
) -> Unit {
  for k = 4; k >= 0; k = k - 1 {
    self.bypass((value >> k) & 1)
  }
}

///|
/// `ff_hevc_intra_chroma_pred_mode_decode` write side: mode 4 (derived) is
/// one `0` bin; otherwise `1` then the two-bit index, MSB first. */
fn HevcEncCabac::intra_chroma_pred_mode(
  self : HevcEncCabac,
  mode : Int32,
) -> Unit {
  if mode == 4 {
    self.bin(hevc_cabac_intra_chroma_pred_mode, 0)
  } else {
    self.bin(hevc_cabac_intra_chroma_pred_mode, 1)
    self.bypass((mode >> 1) & 1)
    self.bypass(mode & 1)
  }
}

///|
/// `ff_hevc_cbf_cb_cr_decode` write side. */
fn HevcEncCabac::cbf_cb_cr(
  self : HevcEncCabac,
  trafo_depth : Int32,
  bit : Bool,
) -> Unit {
  self.bin(hevc_cabac_cbf_cb_cr + trafo_depth, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_cbf_luma_decode` write side. */
fn HevcEncCabac::cbf_luma(
  self : HevcEncCabac,
  trafo_depth : Int32,
  bit : Bool,
) -> Unit {
  self.bin(
    hevc_cabac_cbf_luma + (if trafo_depth == 0 { 1 } else { 0 }),
    if bit {
      1
    } else {
      0
    },
  )
}

///|
/// `ff_hevc_skip_flag_decode` write side (`skip_flag` context from the two
/// already-coded neighbouring minimum CBs). */
fn HevcEncCabac::skip_flag(
  self : HevcEncCabac,
  skip_tab : Array[Int32],
  x0b : Int32,
  y0b : Int32,
  x_cb : Int32,
  y_cb : Int32,
  min_cb_width : Int32,
  ctb_left : Bool,
  ctb_up : Bool,
  bit : Bool,
) -> Unit {
  let mut inc = 0
  if ctb_left || x0b != 0 {
    if skip_tab[y_cb * min_cb_width + x_cb - 1] != 0 {
      inc = inc + 1
    }
  }
  if ctb_up || y0b != 0 {
    if skip_tab[(y_cb - 1) * min_cb_width + x_cb] != 0 {
      inc = inc + 1
    }
  }
  self.bin(hevc_cabac_skip_flag + inc, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_pred_mode_decode` write side: 0 = MODE_INTER, 1 = MODE_INTRA. */
fn HevcEncCabac::pred_mode_flag(self : HevcEncCabac, intra : Bool) -> Unit {
  self.bin(hevc_cabac_pred_mode_flag, if intra { 1 } else { 0 })
}

///|
/// `ff_hevc_part_mode_decode` write side for an inter CU. PART_2Nx2N is one
/// `1` bin at every CU size; the remaining splits are only reachable through
/// the `0` branch (this slice codes 2Nx2N only). */
fn HevcEncCabac::part_mode_inter_2nx2n(self : HevcEncCabac) -> Unit {
  self.bin(hevc_cabac_part_mode, 1)
}

///|
/// `ff_hevc_merge_flag_decode` write side. */
fn HevcEncCabac::merge_flag(self : HevcEncCabac, bit : Bool) -> Unit {
  self.bin(hevc_cabac_merge_flag, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_merge_idx_decode` write side: the first bin is the regular
/// `MERGE_IDX` context, then bypass `1` bins up to `max_num_merge_cand - 1`;
/// no terminator is written when the value already reaches that cap (the
/// decoder's loop stops there without reading another bin). */
fn HevcEncCabac::merge_idx(
  self : HevcEncCabac,
  i : Int32,
  max_num_merge_cand : Int32,
) -> Unit {
  if i == 0 {
    self.bin(hevc_cabac_merge_idx, 0)
    return
  }
  self.bin(hevc_cabac_merge_idx, 1)
  let mut k = 1
  while k < i {
    self.bypass(1)
    k = k + 1
  }
  if i < max_num_merge_cand - 1 {
    self.bypass(0)
  }
}

///|
/// `ff_hevc_mvp_lx_flag_decode` write side. */
fn HevcEncCabac::mvp_lx_flag(self : HevcEncCabac, flag : Int32) -> Unit {
  self.bin(hevc_cabac_mvp_lx_flag, flag)
}

///|
/// `ff_hevc_hls_mvd_coding` write side: both greater-0 flags use the base
/// context, both greater-1 flags the `+1` context, then the two magnitudes.
/// `mvd_decode`'s bypass form is `2 + sum(2^k)` for the continuation bins
/// plus `k` data bits, then a bypass sign (1 = negative). */
fn HevcEncCabac::mvd_coding(
  self : HevcEncCabac,
  dx : Int32,
  dy : Int32,
) -> Unit {
  let ax = if dx < 0 { -dx } else { dx }
  let ay = if dy < 0 { -dy } else { dy }
  self.bin(hevc_cabac_abs_mvd_greater0_flag, if ax != 0 { 1 } else { 0 })
  self.bin(hevc_cabac_abs_mvd_greater0_flag, if ay != 0 { 1 } else { 0 })
  if ax != 0 {
    self.bin(hevc_cabac_abs_mvd_greater1_flag + 1, if ax > 1 { 1 } else { 0 })
  }
  if ay != 0 {
    self.bin(hevc_cabac_abs_mvd_greater1_flag + 1, if ay > 1 { 1 } else { 0 })
  }
  self.mvd_one(dx)
  self.mvd_one(dy)
}

///|
/// One signed `mvd` component after its two flag levels. The decoder reads
/// `mvd_sign_flag_decode` (`bypass_sign(-1)`) for |mvd| == 1 and the
/// `mvd_decode` bypass form otherwise: `ret = 2 + sum(2^k)` over the ones
/// until a zero, then `k` data bits, then `bypass_sign(-ret)`. A `1` sign
/// bin means negative. */
fn HevcEncCabac::mvd_one(self : HevcEncCabac, mvd : Int32) -> Unit {
  let mag = if mvd < 0 { -mvd } else { mvd }
  if mag == 0 {
    return
  }
  if mag > 1 {
    let mut rest = mag - 2
    let mut k = 1
    while k < hevc_cabac_max_bin && rest >= 1 << k {
      self.bypass(1)
      rest = rest - (1 << k)
      k = k + 1
    }
    if k < hevc_cabac_max_bin {
      self.bypass(0)
    }
    for b = k - 1; b >= 0; b = b - 1 {
      self.bypass((rest >> b) & 1)
    }
  }
  self.bypass(if mvd < 0 { 1 } else { 0 })
}

///|
/// `ff_hevc_no_residual_syntax_flag_decode` (`rqt_root_cbf`) write side: the
/// bin value is 1 when the CU carries residual data. */
fn HevcEncCabac::no_residual_flag(
  self : HevcEncCabac,
  has_residual : Bool,
) -> Unit {
  self.bin(hevc_cabac_no_residual_data_flag, if has_residual { 1 } else { 0 })
}

///|
/// `end_of_slice_segment_flag` / `end_of_one_tile` terminate bin. */
fn HevcEncCabac::end_of_slice(self : HevcEncCabac, last : Bool) -> Unit {
  self.terminate(if last { 1 } else { 0 })
}

///|
/// `last_significant_coeff_xy_prefix` + suffix write side. `coded_x` /
/// `coded_y` are the prefixes' absolute values BEFORE the decoder's vert
/// swap (the caller applies the swap). */
fn HevcEncCabac::last_sig_coeff_xy(
  self : HevcEncCabac,
  c_idx : Int32,
  log2_size : Int32,
  coded_x : Int32,
  coded_y : Int32,
) -> Unit {
  let max = (log2_size << 1) - 1
  let ctx_offset = if c_idx == 0 {
    3 * (log2_size - 2) + ((log2_size - 1) >> 2)
  } else {
    15
  }
  let ctx_shift = if c_idx == 0 { (log2_size + 1) >> 2 } else { log2_size - 2 }
  // The decoder reads a truncated-unary prefix (ones until a zero, capped
  // at `max` without a terminator) and reconstructs the value as
  // base(p) + suffix for p > 3 with base(p) =
  // (1 << ((p >> 1) - 1)) * (2 + (p & 1)) and suffix length (p >> 1) - 1.
  // Emit the prefix for that p - NOT the raw value.
  let px = hevc_enc_last_prefix(coded_x, max)
  let py = hevc_enc_last_prefix(coded_y, max)
  let mut i = 0
  while i < px {
    self.bin(hevc_cabac_last_sig_x_prefix + (i >> ctx_shift) + ctx_offset, 1)
    i = i + 1
  }
  if px < max {
    self.bin(hevc_cabac_last_sig_x_prefix + (i >> ctx_shift) + ctx_offset, 0)
  }
  let mut j = 0
  while j < py {
    self.bin(hevc_cabac_last_sig_y_prefix + (j >> ctx_shift) + ctx_offset, 1)
    j = j + 1
  }
  if py < max {
    self.bin(hevc_cabac_last_sig_y_prefix + (j >> ctx_shift) + ctx_offset, 0)
  }
  // Suffixes come after BOTH prefixes, MSB-first.
  if px > 3 {
    let len = (px >> 1) - 1
    let suffix = coded_x - hevc_enc_last_base(px)
    self.write_suffix(suffix, len)
  }
  if py > 3 {
    let len = (py >> 1) - 1
    let suffix = coded_y - hevc_enc_last_base(py)
    self.write_suffix(suffix, len)
  }
}

///|
/// The prefix length coding absolute value `v` (the decoder's reconstruction
/// of prefix `p` covers base(p) .. base(p) + 2^((p>>1)-1) - 1 for p > 3). */
fn hevc_enc_last_prefix(v : Int32, max : Int32) -> Int32 {
  if v <= 3 {
    return v
  }
  let mut p = 4
  while hevc_enc_last_base(p) + (1 << ((p >> 1) - 1)) <= v {
    p = p + 1
  }
  if p > max {
    p = max
  }
  p
}

///|
/// `base(p)` of the last-significant-coefficient reconstruction. */
fn hevc_enc_last_base(p : Int32) -> Int32 {
  (1 << ((p >> 1) - 1)) * (2 + (p & 1))
}

///|
/// `last_significant_coeff_suffix` / bypass-field writer: `len` bits of
/// `value`, most significant first (the decoder folds `value = (value << 1)
/// | bypass` starting from a first bypass read). */
fn HevcEncCabac::write_suffix(
  self : HevcEncCabac,
  value : Int32,
  len : Int32,
) -> Unit {
  for k = len - 1; k >= 0; k = k - 1 {
    self.bypass((value >> k) & 1)
  }
}

///|
/// Residual write side of `hevc_decode_residual` (sign data hiding off,
/// persistent Rice off, no transform skip / scaling lists / RDPCM / CCP):
/// `levels` is the row-major n x n signed quantised block, `scan_idx` one
/// of `hevc_scan_diag/horiz/vert`, `intra_mode` the TU luma mode for the
/// scan selection. Writes every bin exactly where the decoder reads one.
fn HevcEncCabac::residual(
  self : HevcEncCabac,
  levels : FixedArray[Int32],
  n : Int32,
  scan_idx : Int32,
  c_idx : Int32,
) -> Unit {
  let log2_trafo_size = match n {
    2 => 1
    4 => 2
    8 => 3
    16 => 4
    _ => 5
  }
  // Scan-order level array: position p -> (x_c, y_c).
  let mut scan_x_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_y_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_x_off : Array[Int32] = hevc_diag_scan4x4_x
  let mut scan_y_off : Array[Int32] = hevc_diag_scan4x4_y
  if scan_idx == hevc_scan_diag {
    if n == 8 {
      scan_x_cg = hevc_diag_scan2x2_x
      scan_y_cg = hevc_diag_scan2x2_y
    } else if n == 16 {
      scan_x_cg = hevc_diag_scan4x4_x
      scan_y_cg = hevc_diag_scan4x4_y
    } else if n == 32 {
      scan_x_cg = hevc_diag_scan8x8_x
      scan_y_cg = hevc_diag_scan8x8_y
    }
  } else if scan_idx == hevc_scan_horiz {
    scan_x_cg = hevc_horiz_scan2x2_x
    scan_y_cg = hevc_horiz_scan2x2_y
    scan_x_off = hevc_horiz_scan4x4_x
    scan_y_off = hevc_horiz_scan4x4_y
  } else {
    // vert: the C mirrors the horiz pair (decode swaps x/y afterwards).
    scan_x_cg = hevc_horiz_scan2x2_y
    scan_y_cg = hevc_horiz_scan2x2_x
    scan_x_off = hevc_horiz_scan4x4_y
    scan_y_off = hevc_horiz_scan4x4_x
  }
  let total = n * n
  let lv : FixedArray[Int32] = FixedArray::make(total, 0)
  let mut last_p = -1
  for p in 0..<total {
    let x_cg = scan_x_cg[p >> 4]
    let y_cg = scan_y_cg[p >> 4]
    let x_c = (x_cg << 2) + scan_x_off[p & 15]
    let y_c = (y_cg << 2) + scan_y_off[p & 15]
    let v = levels[y_c * n + x_c]
    lv[p] = v
    if v != 0 {
      last_p = p
    }
  }
  let last_x = (scan_x_cg[last_p >> 4] << 2) + scan_x_off[last_p & 15]
  let last_y = (scan_y_cg[last_p >> 4] << 2) + scan_y_off[last_p & 15]
  // The decoder reads x then y prefixes and swaps for the vert scan.
  let (coded_x, coded_y) = if scan_idx == hevc_scan_vert {
    (last_y, last_x)
  } else {
    (last_x, last_y)
  }
  self.last_sig_coeff_xy(c_idx, log2_trafo_size, coded_x, coded_y)
  // last_x/last_y are the TRUE (unswapped) coordinates of the last
  // significant coefficient - the decoder swaps its prefix-derived values
  // INTO these; the writer derived them directly from the scan, so no
  // swap here (a swap would transpose x_cg_last/y_cg_last and break the
  // last subset's implicit significant-CG test for vert/horiz scans).
  let x_cg_last = last_x >> 2
  let y_cg_last = last_y >> 2
  let num_coeff = last_p + 1
  let num_last_subset = (num_coeff - 1) >> 4
  let sig_cg : Array[Int32] = Array::make(64, 0)
  let sig_idx : Array[Int32] = Array::make(16, 0)
  let mut greater1_ctx = 1
  let mut subset = num_last_subset
  while subset >= 0 {
    let x_cg = scan_x_cg[subset]
    let y_cg = scan_y_cg[subset]
    let offset = subset << 4
    let mut implicit_non_zero = 0
    if subset < num_last_subset && subset > 0 {
      let mut ctx_cg = 0
      if x_cg < (1 << (log2_trafo_size - 2)) - 1 {
        ctx_cg = ctx_cg + sig_cg[x_cg + 1 + y_cg * 8]
      }
      if y_cg < (1 << (log2_trafo_size - 2)) - 1 {
        ctx_cg = ctx_cg + sig_cg[x_cg + (y_cg + 1) * 8]
      }
      let bit = if sig_cg_has(lv, subset) { 1 } else { 0 }
      sig_cg[x_cg + y_cg * 8] = bit
      self.sig_coeff_group_flag(c_idx, ctx_cg, bit)
      implicit_non_zero = 1
    } else if (x_cg == x_cg_last && y_cg == y_cg_last) ||
      (x_cg == 0 && y_cg == 0) {
      sig_cg[x_cg + y_cg * 8] = 1
    }
    let last_scan_pos = num_coeff - offset - 1
    let mut n_end = if subset == num_last_subset {
      last_scan_pos - 1
    } else {
      15
    }
    let mut nb_sig = 0
    if subset == num_last_subset {
      sig_idx[0] = last_scan_pos
      nb_sig = 1
    }
    let mut prev_sig = 0
    if x_cg < ((1 << log2_trafo_size) - 1) >> 2 {
      prev_sig = sig_cg[x_cg + 1 + y_cg * 8]
    }
    if y_cg < ((1 << log2_trafo_size) - 1) >> 2 {
      prev_sig = prev_sig + (sig_cg[x_cg + (y_cg + 1) * 8] << 1)
    }
    if sig_cg[x_cg + y_cg * 8] != 0 && n_end >= 0 {
      let mut scf_offset = 0
      let mut map_base = 0
      if c_idx != 0 {
        scf_offset = 27
      }
      if log2_trafo_size == 2 {
        map_base = 0
      } else {
        map_base = (prev_sig + 1) << 4
        if c_idx == 0 {
          if x_cg > 0 || y_cg > 0 {
            scf_offset = scf_offset + 3
          }
          if log2_trafo_size == 3 {
            scf_offset = scf_offset +
              (if scan_idx == hevc_scan_diag { 9 } else { 15 })
          } else {
            scf_offset = scf_offset + 21
          }
        } else if log2_trafo_size == 3 {
          scf_offset = scf_offset + 9
        } else {
          scf_offset = scf_offset + 12
        }
      }
      while n_end > 0 {
        let x_c = scan_x_off[n_end]
        let y_c = scan_y_off[n_end]
        let bit = if lv[offset + n_end] != 0 { 1 } else { 0 }
        if bit != 0 {
          sig_idx[nb_sig] = n_end
          nb_sig = nb_sig + 1
          implicit_non_zero = 0
        }
        self.sig_coeff_flag(x_c, y_c, scf_offset, map_base, bit)
        n_end = n_end - 1
      }
      if implicit_non_zero == 0 {
        if subset == 0 {
          scf_offset = if c_idx == 0 { 0 } else { 27 }
        } else {
          scf_offset = scf_offset + 2
        }
        let bit = if lv[offset] != 0 { 1 } else { 0 }
        if bit != 0 {
          sig_idx[nb_sig] = 0
          nb_sig = nb_sig + 1
        }
        self.bin(hevc_cabac_sig_coeff_flag + scf_offset, bit)
      } else {
        sig_idx[nb_sig] = 0
        nb_sig = nb_sig + 1
      }
    }
    if nb_sig > 0 {
      // The decoder's rice_param is declared per subset (reset to 0 for
      // non-persistent adaptation) - the writer must mirror that scope.
      let mut rice_param = 0
      let mut ctx_set = if subset > 0 && c_idx == 0 { 2 } else { 0 }
      if subset != num_last_subset && greater1_ctx == 0 {
        ctx_set = ctx_set + 1
      }
      greater1_ctx = 1
      let greater1 : Array[Int32] = Array::make(8, 0)
      let mut first_greater1 = -1
      let mut greater1_hits = 0
      let limit = if nb_sig > 8 { 8 } else { nb_sig }
      for m in 0..<limit {
        let lvl = lv[offset + sig_idx[m]]
        let mag = if lvl < 0 { -lvl } else { lvl }
        // The bin value is (level > 1); the first hit's magnitude above 2
        // rides the greater-2 bin.
        let g1 = if mag > 1 { 1 } else { 0 }
        let inc = (ctx_set << 2) + greater1_ctx
        greater1[m] = g1
        if g1 != 0 {
          greater1_hits = greater1_hits + 1
          greater1_ctx = 0
          if first_greater1 == -1 {
            first_greater1 = m
          }
        } else if greater1_ctx > 0 && greater1_ctx < 3 {
          greater1_ctx = greater1_ctx + 1
        }
        self.coeff_abs_greater1(c_idx, inc, g1)
      }
      if first_greater1 != -1 {
        let lvl = lv[offset + sig_idx[first_greater1]]
        let mag = if lvl < 0 { -lvl } else { lvl }
        let g2 = if mag > 2 { 1 } else { 0 }
        greater1[first_greater1] = greater1[first_greater1] + g2
        self.coeff_abs_greater2(c_idx, ctx_set, g2)
      }
      // Signs: one bypass per significant coefficient (no sign hiding).
      for m in 0..<nb_sig {
        let lvl = lv[offset + sig_idx[m]]
        self.bypass(if lvl < 0 { 1 } else { 0 })
      }
      // Remaining values in scan order with the decoder's Rice adaptation.
      for m in 0..<nb_sig {
        let lvl = lv[offset + sig_idx[m]]
        let mag = if lvl < 0 { -lvl } else { lvl }
        if m < 8 {
          let base = 1 + greater1[m]
          let threshold = if m == first_greater1 { 3 } else { 2 }
          if base == threshold {
            let remaining = mag - threshold
            self.coeff_abs_remaining(rice_param, remaining)
            let level = base + remaining
            if level > 3 << rice_param && rice_param < 4 {
              rice_param = rice_param + 1
            }
          }
        } else {
          let remaining = mag - 1
          self.coeff_abs_remaining(rice_param, remaining)
          let level = mag
          if level > 3 << rice_param && rice_param < 4 {
            rice_param = rice_param + 1
          }
        }
      }
    }
    subset = subset - 1
  }
}

///|
/// Whether any coefficient of scan subset `subset` is non-zero (the group
/// flag bin value). */
fn sig_cg_has(lv : FixedArray[Int32], subset : Int32) -> Bool {
  let base = subset << 4
  for k in 0..<16 {
    if lv[base + k] != 0 {
      return true
    }
  }
  false
}

///|
/// `significant_coeff_group_flag_decode` write side. */
fn HevcEncCabac::sig_coeff_group_flag(
  self : HevcEncCabac,
  c_idx : Int32,
  ctx_cg : Int32,
  bit : Int32,
) -> Unit {
  let inc = (if ctx_cg < 1 { ctx_cg } else { 1 }) +
    (if c_idx > 0 { 2 } else { 0 })
  self.bin(hevc_cabac_sig_coeff_group_flag + inc, bit)
}

///|
/// `significant_coeff_flag_decode` write side (context from the decoder's
/// `ctx_idx_map` with the caller's `prev_sig` neighbour derivation). */
fn HevcEncCabac::sig_coeff_flag(
  self : HevcEncCabac,
  x_c : Int32,
  y_c : Int32,
  offset : Int32,
  map_base : Int32,
  bit : Int32,
) -> Unit {
  self.bin(
    hevc_cabac_sig_coeff_flag +
    hevc_sig_ctx_idx_map[map_base + (y_c << 2) + x_c] +
    offset,
    bit,
  )
}

///|
/// `coeff_abs_level_greater1_flag_decode` write side. */
fn HevcEncCabac::coeff_abs_greater1(
  self : HevcEncCabac,
  c_idx : Int32,
  inc : Int32,
  bit : Int32,
) -> Unit {
  self.bin(
    hevc_cabac_coeff_abs_greater1 + inc + (if c_idx > 0 { 16 } else { 0 }),
    bit,
  )
}

///|
/// `coeff_abs_level_greater2_flag_decode` write side. */
fn HevcEncCabac::coeff_abs_greater2(
  self : HevcEncCabac,
  c_idx : Int32,
  ctx_set : Int32,
  bit : Int32,
) -> Unit {
  self.bin(
    hevc_cabac_coeff_abs_greater2 + ctx_set + (if c_idx > 0 { 4 } else { 0 }),
    bit,
  )
}

///|
/// `coeff_abs_level_remaining_decode` write side: unary prefix of `1` bins
/// then a `0` (up to the CABAC_MAX_BIN cap), then the Rice suffix. */
fn HevcEncCabac::coeff_abs_remaining(
  self : HevcEncCabac,
  rice_param : Int32,
  value : Int32,
) -> Unit {
  if value < 3 << rice_param {
    let prefix = value >> rice_param
    for _ in 0..<prefix {
      self.bypass(1)
    }
    self.bypass(0)
    let suffix = value - (prefix << rice_param)
    self.write_suffix(suffix, rice_param)
  } else {
    // value >= (3 << rice): prefix-3 = k with 2^k <= (value>>rice) - 2 <
    // 2^(k+1); the decoder's unary count stops at the first zero, so the
    // terminating 0 bin comes before the (k + rice)-bit suffix.
    let h = value >> rice_param
    let mut k = 0
    while 1 << (k + 1) <= h - 2 {
      k = k + 1
    }
    let prefix = 3 + k
    for _ in 0..<prefix {
      self.bypass(1)
    }
    self.bypass(0)
    let suffix = value - (((1 << k) + 2) << rice_param)
    self.write_suffix(suffix, k + rice_param)
  }
}

///|
/// `ff_hevc_sao_merge_flag_decode` write side. */
fn HevcEncCabac::sao_merge_flag(self : HevcEncCabac, bit : Bool) -> Unit {
  self.bin(hevc_cabac_sao_merge_flag, if bit { 1 } else { 0 })
}

///|
/// `ff_hevc_sao_type_idx_decode` write side: 0 = off (single context bin),
/// 1 = band and 2 = edge (context bin 1 then one bypass bin). */
fn HevcEncCabac::sao_type_idx(self : HevcEncCabac, sao_type : Int32) -> Unit {
  if sao_type == 0 {
    self.bin(hevc_cabac_sao_type_idx, 0)
  } else {
    self.bin(hevc_cabac_sao_type_idx, 1)
    self.bypass(if sao_type == hevc_sao_band { 0 } else { 1 })
  }
}

///|
/// `ff_hevc_sao_offset_abs_decode` write side: unary code capped at
/// `(1 << (min(bit_depth,10) - 5)) - 1`. */
fn HevcEncCabac::sao_offset_abs(
  self : HevcEncCabac,
  bit_depth : Int32,
  value : Int32,
) -> Unit {
  let cap = (1 << ((if bit_depth < 10 { bit_depth } else { 10 }) - 5)) - 1
  let v = if value > cap { cap } else { value }
  for _ in 0..<v {
    self.bypass(1)
  }
  if v < cap {
    self.bypass(0)
  }
}

///|
/// `ff_hevc_sao_offset_sign_decode` write side. */
fn HevcEncCabac::sao_offset_sign(self : HevcEncCabac, bit : Int32) -> Unit {
  self.bypass(bit)
}

///|
/// `ff_hevc_sao_band_position_decode` write side: 5 bypass bits, MSB first. */
fn HevcEncCabac::sao_band_position(self : HevcEncCabac, pos : Int32) -> Unit {
  for k in 0..<5 {
    self.bypass((pos >> (4 - k)) & 1)
  }
}

///|
/// `ff_hevc_sao_eo_class_decode` write side: 2 bypass bits, MSB first. */
fn HevcEncCabac::sao_eo_class(self : HevcEncCabac, eo_class : Int32) -> Unit {
  self.bypass((eo_class >> 1) & 1)
  self.bypass(eo_class & 1)
}

///|
/// `ff_hevc_inter_pred_idc_decode` write side: 0 = PRED_L0, 1 = PRED_L1,
/// 2 = PRED_BI. The 2Nx2N (non-4x4) shape uses one context bin for "is BI",
/// then one bin distinguishing L0 from L1. */
fn HevcEncCabac::inter_pred_idc(
  self : HevcEncCabac,
  ct_depth : Int32,
  n_pb_w : Int32,
  n_pb_h : Int32,
  pred_flag : Int32,
) -> Unit {
  // `pred_flag` is `hevc_pf_l0` (1) / `hevc_pf_l1` (2) / `hevc_pf_bi` (3); the
  // syntax element is PRED_L0 (0) / PRED_L1 (1) / PRED_BI (2).
  let idc = if pred_flag == hevc_pf_bi {
    2
  } else if pred_flag == hevc_pf_l1 {
    1
  } else {
    0
  }
  if n_pb_w + n_pb_h == 12 {
    self.bin(hevc_cabac_inter_pred_idc + 4, if idc == 2 { 1 } else { 0 })
    return
  }
  if idc == 2 {
    self.bin(hevc_cabac_inter_pred_idc + ct_depth, 1)
  } else {
    self.bin(hevc_cabac_inter_pred_idc + ct_depth, 0)
    self.bin(hevc_cabac_inter_pred_idc + 4, idc)
  }
}
