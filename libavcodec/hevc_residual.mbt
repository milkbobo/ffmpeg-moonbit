///|
/// HEVC residual coding and inverse transform, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/cabac.c` (`ff_hevc_hls_residual_coding`) for 8/10/12-bit
/// 4:2:0/4:2:2/4:4:4 streams. Transform skip is supported (including the
/// transform-skip significance contexts and rotation swap), as are scaling
/// lists (SPS/PPS matrices and DC scales); RDPCM and cross-component
/// prediction are not.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub let hevc_scan_diag : Int32 = 0

///|
pub let hevc_scan_horiz : Int32 = 1

///|
pub let hevc_scan_vert : Int32 = 2

///|
let hevc_level_scale : FixedArray[Int32] = [40, 45, 51, 57, 64, 72]

///|
let hevc_qp_c : FixedArray[Int32] = [
  29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37,
]

///|
let hevc_sig_ctx_idx_map : Array[Int32] = [
  0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8, 1, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0,
  0, 0, 0, 0, 0, 2, 2, 2, 2, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 0, 0, 2, 1,
  0, 0, 2, 1, 0, 0, 2, 1, 0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
]

///|
/// `qp_c` mapping for 4:2:0 chroma; other formats clip to 51
/// (`sps.qp_bd_offset` included). */
fn hevc_chroma_qp(
  qp_y : Int32,
  offset : Int32,
  qp_bd_offset : Int32,
  chroma_format_idc : Int32,
) -> Int32 {
  let qp_i = if qp_y + offset < -qp_bd_offset {
    -qp_bd_offset
  } else if qp_y + offset > 57 {
    57
  } else {
    qp_y + offset
  }
  let qp = if chroma_format_idc != 1 {
    if qp_i > 51 {
      51
    } else {
      qp_i
    }
  } else if qp_i < 30 {
    qp_i
  } else if qp_i > 43 {
    qp_i - 6
  } else {
    hevc_qp_c[qp_i - 30]
  }
  qp + qp_bd_offset
}

///|
/// Add an `size`x`size` residual block at `(x, y)` of a picture plane. */
fn hevc_add_residual_at(
  pic : HevcPicture,
  c_idx : Int32,
  x : Int32,
  y : Int32,
  res : Array[Int32],
  size : Int32,
  bd : Int32,
) -> Unit {
  let plane = pic.plane(c_idx)
  let stride = pic.plane_stride(c_idx)
  let max = (1 << bd) - 1
  for row in 0..<size {
    for col in 0..<size {
      let v = plane[(y + row) * stride + x + col] + res[row * size + col]
      plane[(y + row) * stride + x + col] = if v < 0 {
        0
      } else if v > max {
        max
      } else {
        v
      }
    }
  }
}

///|
/// `ff_hevc_hls_residual_coding`: decode, dequantize, inverse transform and add
/// one transform block. `qp_y` is the luma QP of the current CU.
pub fn hevc_hls_residual_coding(
  cabac : HevcCabac,
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  pic : HevcPicture,
  x0 : Int32,
  y0 : Int32,
  log2_trafo_size : Int32,
  scan_idx : Int32,
  c_idx : Int32,
  qp_y : Int32,
  is_intra : Bool,
) -> Result[Unit, String] {
  let trafo_size = 1 << log2_trafo_size
  let coeffs : Array[Int32] = Array::make(trafo_size * trafo_size, 0)
  let mut last_x = 0
  let mut last_y = 0

  let qp = if c_idx == 0 {
    qp_y + sps.qp_bd_offset
  } else {
    let offset = if c_idx == 1 {
      pps.cb_qp_offset + sh.slice_cb_qp_offset
    } else {
      pps.cr_qp_offset + sh.slice_cr_qp_offset
    }
    hevc_chroma_qp(qp_y, offset, sps.qp_bd_offset, sps.chroma_format_idc)
  }
  // C: shift = sps->bit_depth + log2_trafo_size - 5 (8 for 8-bit)
  let shift = sps.bit_depth + log2_trafo_size - 5
  let add = 1 << (shift - 1)
  let scale = hevc_level_scale[qp % 6] << (qp / 6)
  let transform_skip = if pps.transform_skip_enabled_flag != 0 &&
    log2_trafo_size <= pps.log2_max_transform_skip_block_size {
    cabac.transform_skip_flag(c_idx)
  } else {
    false
  }
  let ts_ctx = sps.transform_skip_context_enabled != 0 && transform_skip

  let use_scaling = sps.scaling_list_enabled != 0 &&
    !(transform_skip && log2_trafo_size > 2)
  let scaling = if pps.scaling_list_data_present_flag != 0 {
    pps.scaling_list
  } else {
    sps.scaling_list
  }
  let matrix_id = (if is_intra { 0 } else { 3 }) + c_idx
  let scale_matrix = scaling.sl[log2_trafo_size - 2][matrix_id]
  let dc_scale = if log2_trafo_size >= 4 {
    scaling.sl_dc[log2_trafo_size - 4][matrix_id]
  } else {
    16
  }

  let (lx_prefix, ly_prefix) = cabac.last_sig_xy_prefix(c_idx, log2_trafo_size)
  last_x = lx_prefix
  last_y = ly_prefix
  if last_x > 3 {
    last_x = (1 << ((last_x >> 1) - 1)) * (2 + (last_x & 1)) +
      cabac.last_sig_suffix(last_x)
  }
  if last_y > 3 {
    last_y = (1 << ((last_y >> 1) - 1)) * (2 + (last_y & 1)) +
      cabac.last_sig_suffix(last_y)
  }
  if scan_idx == hevc_scan_vert {
    let tmp = last_x
    last_x = last_y
    last_y = tmp
  }

  let x_cg_last = last_x >> 2
  let y_cg_last = last_y >> 2
  let mut scan_x_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_y_cg : Array[Int32] = hevc_scan_1x1
  let mut scan_x_off : Array[Int32] = hevc_diag_scan4x4_x
  let mut scan_y_off : Array[Int32] = hevc_diag_scan4x4_y
  let mut num_coeff = 0
  if scan_idx == hevc_scan_diag {
    let last_x_c = last_x & 3
    let last_y_c = last_y & 3
    num_coeff = hevc_diag_scan4x4_inv[last_y_c * 4 + last_x_c]
    if trafo_size == 4 {
      scan_x_cg = hevc_scan_1x1
      scan_y_cg = hevc_scan_1x1
    } else if trafo_size == 8 {
      num_coeff = num_coeff +
        (hevc_diag_scan2x2_inv[y_cg_last * 2 + x_cg_last] << 4)
      scan_x_cg = hevc_diag_scan2x2_x
      scan_y_cg = hevc_diag_scan2x2_y
    } else if trafo_size == 16 {
      num_coeff = num_coeff +
        (hevc_diag_scan4x4_inv[y_cg_last * 4 + x_cg_last] << 4)
      scan_x_cg = hevc_diag_scan4x4_x
      scan_y_cg = hevc_diag_scan4x4_y
    } else {
      num_coeff = num_coeff +
        (hevc_diag_scan8x8_inv[y_cg_last * 8 + x_cg_last] << 4)
      scan_x_cg = hevc_diag_scan8x8_x
      scan_y_cg = hevc_diag_scan8x8_y
    }
  } else if scan_idx == hevc_scan_horiz {
    scan_x_cg = hevc_horiz_scan2x2_x
    scan_y_cg = hevc_horiz_scan2x2_y
    scan_x_off = hevc_horiz_scan4x4_x
    scan_y_off = hevc_horiz_scan4x4_y
    num_coeff = hevc_horiz_scan8x8_inv[last_y * 8 + last_x]
  } else {
    scan_x_cg = hevc_horiz_scan2x2_y
    scan_y_cg = hevc_horiz_scan2x2_x
    scan_x_off = hevc_horiz_scan4x4_y
    scan_y_off = hevc_horiz_scan4x4_x
    num_coeff = hevc_horiz_scan8x8_inv[last_x * 8 + last_y]
  }
  num_coeff = num_coeff + 1
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
      sig_cg[x_cg + y_cg * 8] = cabac.sig_coeff_group_flag(c_idx, ctx_cg)
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
      if ts_ctx {
        map_base = 4 * 16
        scf_offset = if c_idx == 0 { 40 } else { 41 }
      } else {
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
      }
      while n_end > 0 {
        let x_c = scan_x_off[n_end]
        let y_c = scan_y_off[n_end]
        if cabac.sig_coeff_flag(
            x_c, y_c, scf_offset, hevc_sig_ctx_idx_map, map_base,
          ) !=
          0 {
          sig_idx[nb_sig] = n_end
          nb_sig = nb_sig + 1
          implicit_non_zero = 0
        }
        n_end = n_end - 1
      }
      if implicit_non_zero == 0 {
        if ts_ctx {
          scf_offset = if c_idx == 0 { 42 } else { 43 }
        } else if subset == 0 {
          scf_offset = if c_idx == 0 { 0 } else { 27 }
        } else {
          scf_offset = scf_offset + 2
        }
        if cabac.sig_coeff_flag_0(scf_offset) != 0 {
          sig_idx[nb_sig] = 0
          nb_sig = nb_sig + 1
        }
      } else {
        sig_idx[nb_sig] = 0
        nb_sig = nb_sig + 1
      }
    }

    if nb_sig > 0 {
      let mut ctx_set = if subset > 0 && c_idx == 0 { 2 } else { 0 }
      if subset != num_last_subset && greater1_ctx == 0 {
        ctx_set = ctx_set + 1
      }
      greater1_ctx = 1
      let last_nz_pos = sig_idx[0]
      let first_nz_pos = sig_idx[nb_sig - 1]
      let greater1 : Array[Int32] = Array::make(8, 0)
      let mut first_greater1 = -1
      let limit = if nb_sig > 8 { 8 } else { nb_sig }
      for m in 0..<limit {
        let inc = (ctx_set << 2) + greater1_ctx
        greater1[m] = cabac.coeff_abs_greater1(c_idx, inc)
        if greater1[m] != 0 {
          greater1_ctx = 0
          if first_greater1 == -1 {
            first_greater1 = m
          }
        } else if greater1_ctx > 0 && greater1_ctx < 3 {
          greater1_ctx = greater1_ctx + 1
        }
      }
      let sign_hidden = pps.sign_data_hiding_flag != 0 &&
        last_nz_pos - first_nz_pos >= 4
      if first_greater1 != -1 {
        greater1[first_greater1] = greater1[first_greater1] +
          cabac.coeff_abs_greater2(c_idx, ctx_set)
      }
      let mut sign_flags = if sign_hidden {
        cabac.coeff_sign_flags(nb_sig - 1)
      } else {
        cabac.coeff_sign_flags(nb_sig)
      }
      if sign_hidden {
        sign_flags = sign_flags << (16 - (nb_sig - 1))
      } else {
        sign_flags = sign_flags << (16 - nb_sig)
      }
      let mut rice_param = 0
      let mut sum_abs = 0
      for m in 0..<nb_sig {
        let n = sig_idx[m]
        let x_c = (x_cg << 2) + scan_x_off[n]
        let y_c = (y_cg << 2) + scan_y_off[n]
        let mut level = 1
        if m < 8 {
          level = 1 + greater1[m]
          let threshold = if m == first_greater1 { 3 } else { 2 }
          if level == threshold {
            let remaining = match cabac.coeff_abs_remaining(rice_param) {
              Ok(v) => v
              Err(e) => return Err(e)
            }
            level = level + remaining
            if level > 3 << rice_param {
              rice_param = if rice_param < 4 { rice_param + 1 } else { 4 }
            }
          }
        } else {
          let remaining = match cabac.coeff_abs_remaining(rice_param) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          level = 1 + remaining
          if level > 3 << rice_param {
            rice_param = if rice_param < 4 { rice_param + 1 } else { 4 }
          }
        }
        if sign_hidden {
          sum_abs = sum_abs + level
          if n == first_nz_pos && (sum_abs & 1) != 0 {
            level = -level
          }
        }
        if sign_flags >> 15 != 0 {
          level = -level
        }
        sign_flags = (sign_flags << 1) & 0xFFFF
        let mut scale_m = 16
        if use_scaling {
          if y_c != 0 || x_c != 0 || log2_trafo_size < 4 {
            let pos = if log2_trafo_size == 3 {
              (y_c << 3) + x_c
            } else if log2_trafo_size == 4 {
              ((y_c >> 1) << 3) + (x_c >> 1)
            } else if log2_trafo_size == 5 {
              ((y_c >> 2) << 3) + (x_c >> 2)
            } else {
              (y_c << 2) + x_c
            }
            scale_m = scale_matrix[pos]
          } else {
            scale_m = dc_scale
          }
        }
        let mut dq = level.to_int64() *
          scale.to_int64() *
          scale_m.to_int64() +
          add.to_int64()
        dq = dq >> shift
        if dq < -32768L {
          dq = -32768L
        } else if dq > 32767L {
          dq = 32767L
        }
        coeffs[y_c * trafo_size + x_c] = dq.to_int()
      }
    }
    subset = subset - 1
  }

  let max_xy = if last_x > last_y { last_x } else { last_y }
  let bd = sps.bit_depth
  if transform_skip {
    if sps.transform_skip_rotation_enabled != 0 &&
      log2_trafo_size == 2 &&
      is_intra {
      for i in 0..<8 {
        let t = coeffs[i]
        coeffs[i] = coeffs[16 - i - 1]
        coeffs[16 - i - 1] = t
      }
    }
    match hevc_dequant(coeffs, log2_trafo_size, bd) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else if c_idx == 0 && log2_trafo_size == 2 {
    hevc_transform_4x4_luma(coeffs, bd)
  } else if max_xy == 0 {
    match hevc_idct_dc(coeffs, log2_trafo_size, bd) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    let mut col_limit = last_x + last_y + 4
    if max_xy < 4 {
      col_limit = if col_limit < 4 { col_limit } else { 4 }
    } else if max_xy < 8 {
      col_limit = if col_limit < 8 { col_limit } else { 8 }
    } else if max_xy < 12 {
      col_limit = if col_limit < 24 { col_limit } else { 24 }
    }
    match hevc_idct(coeffs, log2_trafo_size, col_limit, bd) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  let hshift = sps.hshift[c_idx]
  let vshift = sps.vshift[c_idx]
  hevc_add_residual_at(
    pic,
    c_idx,
    x0 >> hshift,
    y0 >> vshift,
    coeffs,
    trafo_size,
    bd,
  )
  Ok(())
}
