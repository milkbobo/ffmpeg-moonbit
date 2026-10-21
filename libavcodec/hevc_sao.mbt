///|
/// HEVC sample adaptive offset (SAO) parsing and filtering, ported from
/// FFmpeg 9.0.2 `libavcodec/hevc/hevcdec.c` (`hls_sao_param`) and
/// `libavcodec/h26x/h2656_sao_template.c`.
///
/// Filtering reads neighbouring samples from a pre-SAO copy of the deblocked
/// picture, which is equivalent to FFmpeg's CTB edge buffers for a single
/// slice without tiles.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub let hevc_sao_band : Int32 = 1

///|
pub let hevc_sao_edge : Int32 = 2

///|
pub struct HevcSaoParams {
  type_idx : Array[Int32]
  offset_val : Array[Int32]
  band_position : Array[Int32]
  eo_class : Array[Int32]
  ctb_width : Int32
}

///|
pub fn hevc_sao_params_new(
  ctb_count : Int32,
  ctb_width : Int32,
) -> HevcSaoParams {
  {
    type_idx: Array::make(ctb_count * 3, 0),
    offset_val: Array::make(ctb_count * 15, 0),
    band_position: Array::make(ctb_count * 3, 0),
    eo_class: Array::make(ctb_count * 3, 0),
    ctb_width,
  }
}

///|
fn HevcSaoParams::copy_ctb(
  self : HevcSaoParams,
  dst_rs : Int32,
  src_rs : Int32,
) -> Unit {
  for c in 0..<3 {
    self.type_idx[dst_rs * 3 + c] = self.type_idx[src_rs * 3 + c]
    self.band_position[dst_rs * 3 + c] = self.band_position[src_rs * 3 + c]
    self.eo_class[dst_rs * 3 + c] = self.eo_class[src_rs * 3 + c]
    for k in 0..<5 {
      self.offset_val[dst_rs * 15 + c * 5 + k] = self.offset_val[src_rs * 15 +
        c * 5 +
        k]
    }
  }
}

///|
/// `hls_sao_param`: parse one CTB's SAO parameters (or merge them). */
pub fn hevc_sao_parse(
  cabac : HevcCabac,
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  sao : HevcSaoParams,
  ctb_rs : Int32,
  x_ctb : Int32,
  y_ctb : Int32,
) -> Unit {
  let mut merge_left = false
  let mut merge_up = false
  if sh.slice_sao_luma_flag || sh.slice_sao_chroma_flag {
    if x_ctb > 0 {
      merge_left = cabac.sao_merge_flag()
    }
    if y_ctb > 0 && !merge_left {
      merge_up = cabac.sao_merge_flag()
    }
  }
  if merge_left {
    sao.copy_ctb(ctb_rs, ctb_rs - 1)
    return
  }
  if merge_up {
    sao.copy_ctb(ctb_rs, ctb_rs - sao.ctb_width)
    return
  }
  for c_idx in 0..<3 {
    let active = if c_idx == 0 {
      sh.slice_sao_luma_flag
    } else {
      sh.slice_sao_chroma_flag
    }
    if !active {
      sao.type_idx[ctb_rs * 3 + c_idx] = 0
      continue
    }
    let sao_type = if c_idx == 2 {
      sao.type_idx[ctb_rs * 3 + 1]
    } else {
      cabac.sao_type_idx()
    }
    sao.type_idx[ctb_rs * 3 + c_idx] = sao_type
    if c_idx == 2 {
      sao.eo_class[ctb_rs * 3 + 2] = sao.eo_class[ctb_rs * 3 + 1]
    }
    if sao_type == 0 {
      continue
    }
    let offset_abs : Array[Int32] = Array::make(4, 0)
    for i in 0..<4 {
      offset_abs[i] = cabac.sao_offset_abs(sps.bit_depth)
    }
    let offset_sign : Array[Int32] = Array::make(4, 0)
    if sao_type == hevc_sao_band {
      for i in 0..<4 {
        if offset_abs[i] != 0 {
          offset_sign[i] = cabac.sao_offset_sign()
        }
      }
      sao.band_position[ctb_rs * 3 + c_idx] = cabac.sao_band_position()
    } else if c_idx != 2 {
      sao.eo_class[ctb_rs * 3 + c_idx] = cabac.sao_eo_class()
    }
    let scale = if c_idx == 0 {
      pps.log2_sao_offset_scale_luma
    } else {
      pps.log2_sao_offset_scale_chroma
    }
    for i in 0..<5 {
      sao.offset_val[ctb_rs * 15 + c_idx * 5 + i] = 0
    }
    for i in 0..<4 {
      let mut v = offset_abs[i]
      if sao_type == hevc_sao_edge {
        if i > 1 {
          v = -v
        }
      } else if offset_sign[i] != 0 {
        v = -v
      }
      sao.offset_val[ctb_rs * 15 + c_idx * 5 + i + 1] = v << scale
    }
  }
}

///|
fn hevc_sao_cmp(a : Int32, b : Int32) -> Int32 {
  if a > b {
    1
  } else if a < b {
    -1
  } else {
    0
  }
}

///|
fn hevc_sao_copy_plane(src : Array[Int32]) -> Array[Int32] {
  let out : Array[Int32] = Array::make(src.length(), 0)
  for i in 0..<src.length() {
    out[i] = src[i]
  }
  out
}

///|
/// `av_clip_pixel`: clip to the coded bit depth (255 for 8-bit). */
fn hevc_sao_clip(v : Int32, bd : Int32) -> Int32 {
  let max = (1 << bd) - 1
  if v < 0 {
    0
  } else if v > max {
    max
  } else {
    v
  }
}

///|
/// Apply SAO to the deblocked picture. */
pub fn hevc_sao_apply(
  pic : HevcPicture,
  sps : HevcSps,
  _pps : HevcPps,
  sao : HevcSaoParams,
) -> Unit {
  if sps.sao_enabled == 0 {
    return
  }
  let bd = sps.bit_depth
  let mut any = false
  for t in sao.type_idx {
    if t != 0 {
      any = true
    }
  }
  if !any {
    return
  }
  let py = hevc_sao_copy_plane(pic.y)
  let pcb = hevc_sao_copy_plane(pic.cb)
  let pcr = hevc_sao_copy_plane(pic.cr)
  let y_stride = pic.width
  let c_stride = pic.plane_stride(1)
  let c_width = (pic.width + 1) >> 1
  let c_height = (pic.height + 1) >> 1
  let ctb_size = 1 << sps.log2_ctb_size
  let ctb_size_c = ctb_size >> 1
  let edge_idx : FixedArray[Int32] = [1, 2, 0, 3, 4]
  let pos : FixedArray[Int32] = [
    -1, 0, 1, 0, 0, -1, 0, 1, -1, -1, 1, 1, 1, -1, -1, 1,
  ]
  for ctb in 0..<sps.ctb_size {
    let x_ctb = ctb % sao.ctb_width
    let y_ctb = ctb / sao.ctb_width
    for c_idx in 0..<3 {
      let sao_type = sao.type_idx[ctb * 3 + c_idx]
      if sao_type == 0 {
        continue
      }
      let src : Array[Int32] = if c_idx == 0 {
        py
      } else if c_idx == 1 {
        pcb
      } else {
        pcr
      }
      let dst : Array[Int32] = if c_idx == 0 {
        pic.y
      } else if c_idx == 1 {
        pic.cb
      } else {
        pic.cr
      }
      let stride = if c_idx == 0 { y_stride } else { c_stride }
      let pw = if c_idx == 0 { pic.width } else { c_width }
      let ph = if c_idx == 0 { pic.height } else { c_height }
      let cs = if c_idx == 0 { ctb_size } else { ctb_size_c }
      let x0 = x_ctb * cs
      let y0 = y_ctb * cs
      let mut width = cs
      let mut height = cs
      if x0 + width > pw {
        width = pw - x0
      }
      if y0 + height > ph {
        height = ph - y0
      }
      if sao_type == hevc_sao_band {
        let band = sao.band_position[ctb * 3 + c_idx]
        let table : Array[Int32] = Array::make(32, 0)
        for k in 0..<4 {
          table[(k + band) & 31] = sao.offset_val[ctb * 15 + c_idx * 5 + k + 1]
        }
        // C: shift = BIT_DEPTH - 5 (3 for 8-bit)
        let band_shift = bd - 5
        for y in 0..<height {
          for x in 0..<width {
            let idx = (y0 + y) * stride + x0 + x
            let v = src[idx]
            dst[idx] = hevc_sao_clip(v + table[(v >> band_shift) & 31], bd)
          }
        }
      } else if sao_type == hevc_sao_edge {
        let eo = sao.eo_class[ctb * 3 + c_idx]
        let o0 = eo * 4
        let dx0 = pos[o0]
        let dy0 = pos[o0 + 1]
        let dx1 = pos[o0 + 2]
        let dy1 = pos[o0 + 3]
        let off = c_idx * 5
        for y in 0..<height {
          for x in 0..<width {
            let px = x0 + x
            let pyi = y0 + y
            let idx = pyi * stride + px
            let v = src[idx]
            let nx0 = px + dx0
            let ny0 = pyi + dy0
            let n0 = if nx0 < 0 || nx0 >= pw || ny0 < 0 || ny0 >= ph {
              v
            } else {
              src[ny0 * stride + nx0]
            }
            let nx1 = px + dx1
            let ny1 = pyi + dy1
            let n1 = if nx1 < 0 || nx1 >= pw || ny1 < 0 || ny1 >= ph {
              v
            } else {
              src[ny1 * stride + nx1]
            }
            let d0 = hevc_sao_cmp(v, n0)
            let d1 = hevc_sao_cmp(v, n1)
            let oi = edge_idx[2 + d0 + d1]
            dst[idx] = hevc_sao_clip(v + sao.offset_val[ctb * 15 + off + oi], bd)
          }
        }
        if eo != 1 {
          if x0 == 0 {
            for y in 0..<height {
              let idx = (y0 + y) * stride
              dst[idx] = src[idx]
            }
          }
          if x0 + width == pw {
            for y in 0..<height {
              let idx = (y0 + y) * stride + pw - 1
              dst[idx] = src[idx]
            }
          }
        }
        if eo != 0 {
          if y0 == 0 {
            for x in 0..<width {
              dst[x0 + x] = src[x0 + x]
            }
          }
          if y0 + height == ph {
            let base = (ph - 1) * stride + x0
            for x in 0..<width {
              dst[base + x] = src[base + x]
            }
          }
        }
      }
    }
  }
}
