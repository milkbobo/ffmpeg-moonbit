///|
/// HEVC intra reference-sample preparation, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/pred_template.c` (`intra_pred`, `ref_filter_3tap`,
/// `ref_filter_strong`) for 8/10/12-bit 4:2:0 pictures without constrained
/// intra prediction.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct HevcNeighbourAvail {
  mut cand_up : Bool
  mut cand_left : Bool
  mut cand_up_left : Bool
  mut cand_up_right : Bool
  /// `cand_up_right_sap` in the C: without the end-of-tile clamp.
  mut cand_up_right_sap : Bool
  mut cand_bottom_left : Bool
}

///|
pub fn hevc_neighbour_avail() -> HevcNeighbourAvail {
  {
    cand_up: false,
    cand_left: false,
    cand_up_left: false,
    cand_up_right: false,
    cand_up_right_sap: false,
    cand_bottom_left: false,
  }
}

///|
fn hevc_extend(
  arr : Array[Int32],
  start : Int32,
  len : Int32,
  value : Int32,
) -> Unit {
  for i in 0..<len {
    arr[start + i] = value
  }
}

///|
/// Z-scan address of a minimum transform block inside one CTB
/// (`MIN_TB_ADDR_ZS`, using the slice's tile-scan CTB map). Out-of-range
/// coordinates return -1 like the C's padding entries. */
fn hevc_min_tb_addr_zs(
  sps : HevcSps,
  pps : HevcPps,
  x_tb : Int32,
  y_tb : Int32,
) -> Int32 {
  if x_tb < 0 || y_tb < 0 || x_tb > sps.tb_mask || y_tb > sps.tb_mask {
    return -1
  }
  let log2_diff = sps.log2_ctb_size - sps.log2_min_tb_size
  let tb_x = x_tb >> log2_diff
  let tb_y = y_tb >> log2_diff
  let rs = sps.ctb_width * tb_y + tb_x
  let mut val = pps.ctb_addr_rs_to_ts[rs] << (log2_diff * 2)
  for i in 0..<log2_diff {
    let m = 1 << i
    if (m & x_tb) != 0 {
      val = val + m * m
    }
    if (m & y_tb) != 0 {
      val = val + 2 * m * m
    }
  }
  val
}

///|
/// `ref_filter_3tap` on corner-at-0 reference arrays. */
fn hevc_ref_filter_3tap(
  left : Array[Int32],
  top : Array[Int32],
  size : Int32,
) -> (Array[Int32], Array[Int32]) {
  let n = 2 * size
  let fl : Array[Int32] = Array::make(n + 1, 0)
  let ft : Array[Int32] = Array::make(n + 1, 0)
  fl[n] = left[n]
  let mut i = n - 2
  while i >= 0 {
    fl[i + 1] = (left[i + 2] + 2 * left[i + 1] + left[i] + 2) >> 2
    i = i - 1
  }
  fl[0] = (left[1] + 2 * left[0] + top[1] + 2) >> 2
  ft[0] = fl[0]
  i = n - 2
  while i >= 0 {
    ft[i + 1] = (top[i + 2] + 2 * top[i + 1] + top[i] + 2) >> 2
    i = i - 1
  }
  ft[n] = top[n]
  (fl, ft)
}

///|
/// `ref_filter_strong` on corner-at-0 reference arrays; returns the filtered
/// top and the filtered left. */
fn hevc_ref_filter_strong(
  left : Array[Int32],
  top : Array[Int32],
  size : Int32,
) -> (Array[Int32], Array[Int32]) {
  let n = 2 * size
  let fl : Array[Int32] = Array::make(n + 1, 0)
  let ft : Array[Int32] = Array::make(n + 1, 0)
  ft[0] = top[0]
  ft[n] = top[n]
  for i in 0..<n {
    ft[i + 1] = ((64 - (i + 1)) * top[0] + (i + 1) * top[n] + 32) >> 6
    fl[i + 1] = ((64 - (i + 1)) * left[0] + (i + 1) * left[n] + 32) >> 6
  }
  fl[0] = left[0]
  (fl, ft)
}

///|
/// Reconstruct one intra prediction block. `na` must have been computed by
/// `hevc_set_neighbour_available` for this block; z-scan ordering is applied
/// here as in the C.
pub fn hevc_intra_predict(
  pic : HevcPicture,
  sps : HevcSps,
  pps : HevcPps,
  na : HevcNeighbourAvail,
  x0 : Int32,
  y0 : Int32,
  log2_size : Int32,
  c_idx : Int32,
  mode : Int32,
) -> Unit {
  let size = 1 << log2_size
  let bd = sps.bit_depth
  let hshift = sps.hshift[c_idx]
  let vshift = sps.vshift[c_idx]
  let size_in_luma_h = size << hshift
  let size_in_luma_v = size << vshift
  let size_in_tbs_h = size_in_luma_h >> sps.log2_min_tb_size
  let size_in_tbs_v = size_in_luma_v >> sps.log2_min_tb_size
  let x = x0 >> hshift
  let y = y0 >> vshift
  let x_tb = (x0 >> sps.log2_min_tb_size) & sps.tb_mask
  let y_tb = (y0 >> sps.log2_min_tb_size) & sps.tb_mask
  let spin = c_idx != 0 &&
    size_in_tbs_v == 0 &&
    ((2 * y0) & (1 << sps.log2_min_tb_size)) != 0
  let cur_tb_addr = hevc_min_tb_addr_zs(sps, pps, x_tb, y_tb)
  let cand_bottom_left = na.cand_bottom_left &&
    cur_tb_addr >
    hevc_min_tb_addr_zs(
      sps,
      pps,
      x_tb - 1,
      (y_tb + size_in_tbs_v + (if spin { 1 } else { 0 })) & sps.tb_mask,
    )
  let mut cand_left = na.cand_left
  let mut cand_up_left = na.cand_up_left
  let mut cand_up = na.cand_up
  let cand_up_right = na.cand_up_right &&
    !spin &&
    cur_tb_addr >
    hevc_min_tb_addr_zs(sps, pps, (x_tb + size_in_tbs_h) & sps.tb_mask, y_tb - 1)
  let bottom_left_size = (
      (if y0 + 2 * size_in_luma_v < sps.height {
        y0 + 2 * size_in_luma_v
      } else {
        sps.height
      }) -
      (y0 + size_in_luma_v)
    ) >>
    vshift
  let top_right_size = (
      (if x0 + 2 * size_in_luma_h < sps.width {
        x0 + 2 * size_in_luma_h
      } else {
        sps.width
      }) -
      (x0 + size_in_luma_h)
    ) >>
    hshift

  let top : Array[Int32] = Array::make(2 * size + 1, 0)
  let left : Array[Int32] = Array::make(2 * size + 1, 0)

  if cand_up_left {
    let v = pic.sample(c_idx, x - 1, y - 1)
    left[0] = v
    top[0] = v
  }
  if cand_up {
    for i in 0..<size {
      top[i + 1] = pic.sample(c_idx, x + i, y - 1)
    }
    if cand_up_right {
      for i in 0..<size {
        top[size + 1 + i] = pic.sample(c_idx, x + size + i, y - 1)
      }
      hevc_extend(
        top,
        size + top_right_size + 1,
        size - top_right_size,
        top[size + top_right_size],
      )
    }
  }
  if cand_left {
    for i in 0..<size {
      left[i + 1] = pic.sample(c_idx, x - 1, y + i)
    }
  }
  if cand_bottom_left {
    let mut i = size
    while i < size + bottom_left_size {
      left[i + 1] = pic.sample(c_idx, x - 1, y + i)
      i = i + 1
    }
    hevc_extend(
      left,
      size + bottom_left_size + 1,
      size - bottom_left_size,
      left[size + bottom_left_size],
    )
  }

  if !cand_bottom_left {
    if cand_left {
      hevc_extend(left, size + 1, size, left[size])
    } else if cand_up_left {
      hevc_extend(left, 1, 2 * size, left[0])
      cand_left = true
    } else if cand_up {
      left[0] = top[1]
      hevc_extend(left, 1, 2 * size, left[0])
      cand_up_left = true
      cand_left = true
    } else if cand_up_right {
      hevc_extend(top, 1, size, top[size + 1])
      left[0] = top[size + 1]
      hevc_extend(left, 1, 2 * size, left[0])
      cand_up = true
      cand_up_left = true
      cand_left = true
    } else {
      left[0] = 1 << (bd - 1)
      hevc_extend(top, 1, 2 * size, left[0])
      hevc_extend(left, 1, 2 * size, left[0])
    }
  }
  if !cand_left {
    hevc_extend(left, 1, size, left[size + 1])
  }
  if !cand_up_left {
    left[0] = left[1]
  }
  if !cand_up {
    hevc_extend(top, 1, size, left[0])
  }
  if !cand_up_right {
    hevc_extend(top, size + 1, size, top[size])
  }
  top[0] = left[0]

  let mut use_left = left
  let mut use_top = top
  if sps.intra_smoothing_disabled == 0 &&
    (c_idx == 0 || sps.chroma_format_idc == 3) &&
    mode != 1 &&
    size != 4 {
    let threshold = if log2_size == 3 {
      7
    } else if log2_size == 4 {
      1
    } else {
      0
    }
    let dist26 = if mode > 26 { mode - 26 } else { 26 - mode }
    let dist10 = if mode > 10 { mode - 10 } else { 10 - mode }
    let min_dist = if dist26 < dist10 { dist26 } else { dist10 }
    if min_dist > threshold {
      if sps.strong_intra_smoothing_enabled != 0 && c_idx == 0 && log2_size == 5 {
        let threshold2 = 1 << (bd - 5)
        let d1 = top[0] + top[2 * size] - 2 * top[size]
        let d2 = left[0] + left[2 * size] - 2 * left[size]
        let ad1 = if d1 < 0 { -d1 } else { d1 }
        let ad2 = if d2 < 0 { -d2 } else { d2 }
        if ad1 < threshold2 && ad2 < threshold2 {
          let (fl, ft) = hevc_ref_filter_strong(left, top, size)
          use_left = fl
          use_top = ft
        } else {
          let (fl, ft) = hevc_ref_filter_3tap(left, top, size)
          use_left = fl
          use_top = ft
        }
      } else {
        let (fl, ft) = hevc_ref_filter_3tap(left, top, size)
        use_left = fl
        use_top = ft
      }
    }
  }

  let dst : Array[Int32] = Array::make(size * size, 0)
  if mode == 0 {
    hevc_pred_planar(dst, size, size, use_top, use_left)
  } else if mode == 1 {
    hevc_pred_dc(dst, size, size, use_top, use_left, c_idx)
  } else {
    hevc_pred_angular(dst, size, size, use_top, use_left, c_idx, mode, bd)
  }
  let plane = pic.plane(c_idx)
  let stride = pic.plane_stride(c_idx)
  for row in 0..<size {
    for col in 0..<size {
      plane[(y + row) * stride + x + col] = dst[row * size + col]
    }
  }
}
