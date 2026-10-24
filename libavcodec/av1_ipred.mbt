///|
/// MoonBit port of dav1d 1.5.1 `src/ipred_tmpl.c` and
/// `src/ipred_prepare_tmpl.c` (8-bit): intra prediction modes, edge
/// preparation (including Z1/Z2/Z3 angle handling, edge filter and
/// upsample), CFL AC/prediction and palette prediction.
///
/// Pixel planes are `FixedArray[Byte]` accessed through (array, offset,
/// stride) so callers keep dav1d's pointer arithmetic shape.

///|
/// IntraPredMode constants (dav1d levels.h order).
let av1_dc_pred : Int32 = 0

///|
let av1_vert_pred : Int32 = 1

///|
let av1_hor_pred : Int32 = 2

///|
let av1_diag_down_left_pred : Int32 = 3

///|
let av1_diag_down_right_pred : Int32 = 4

///|
let av1_vert_right_pred : Int32 = 5

///|
let av1_hor_down_pred : Int32 = 6

///|
let av1_hor_up_pred : Int32 = 7

///|
let av1_vert_left_pred : Int32 = 8

///|
let av1_smooth_pred : Int32 = 9

///|
let av1_smooth_v_pred : Int32 = 10

///|
let av1_smooth_h_pred : Int32 = 11

///|
let av1_paeth_pred : Int32 = 12

///|
let av1_n_intra_pred_modes : Int32 = 13

///|
let av1_cfl_pred : Int32 = 13

///|
let av1_n_uv_intra_pred_modes : Int32 = 14

///|
let av1_left_dc_pred : Int32 = 3

///|
let av1_top_dc_pred : Int32 = 4

///|
let av1_dc_128_pred : Int32 = 5

///|
let av1_z1_pred : Int32 = 6

///|
let av1_z2_pred : Int32 = 7

///|
let av1_z3_pred : Int32 = 8

///|
let av1_filter_pred : Int32 = 13

///|
let av1_angle_smooth_edge_flag : Int32 = 512

///|
let av1_angle_use_edge_filter_flag : Int32 = 1024

///|
/// Edge flag bits (dav1d intra_edge.h EdgeFlags).
let av1_edge_i444_top_has_right : Int32 = 1

///|
let av1_edge_i422_top_has_right : Int32 = 2

///|
let av1_edge_i420_top_has_right : Int32 = 4

///|
let av1_edge_i444_left_has_bottom : Int32 = 8

///|
let av1_edge_i422_left_has_bottom : Int32 = 16

///|
let av1_edge_i420_left_has_bottom : Int32 = 32

///|
let av1_edge_all_top_has_right : Int32 = 7

///|
let av1_edge_all_left_has_bottom : Int32 = 56

///|
let av1_edge_all_tr_and_bl : Int32 = 63

///|
fn av1_imin(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn av1_imax(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn av1_iclip(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  av1_imin(av1_imax(v, lo), hi)
}

///|
/// `av1_mode_conv` + `av1_mode_to_angle_map` + edge-requirement table.
let av1_mode_conv : FixedArray[Byte] = [
  // DC_PRED
  av1_dc_128_pred.to_byte(),
  av1_top_dc_pred.to_byte(),
  av1_left_dc_pred.to_byte(),
  av1_dc_pred.to_byte(),
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  // PAETH_PRED
  av1_dc_128_pred.to_byte(),
  av1_vert_pred.to_byte(),
  av1_hor_pred.to_byte(),
  av1_paeth_pred.to_byte(),
]

///|
let av1_mode_to_angle_map : FixedArray[Byte] = [
  90, 180, 45, 135, 113, 157, 203, 67,
]

///|
/// `dav1d_prepare_intra_edges`. `topleft` is an index into `edge_buf`
/// (dav1d's `topleft_out`). Returns the effective prediction mode.
fn av1_prepare_intra_edges(
  x : Int32,
  have_left_in : Bool,
  y : Int32,
  have_top_in : Bool,
  w : Int32,
  h : Int32,
  edge_flags : Int32,
  plane : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  top_sb_edge : FixedArray[Byte]?,
  top_sb_edge_off : Int32,
  mode_in : Int32,
  angle_io : Ref[Int32],
  tw : Int32,
  th : Int32,
  filter_edge : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
) -> Int32 {
  let have_left = have_left_in
  let have_top = have_top_in
  let mut mode = mode_in
  if mode >= av1_vert_pred && mode <= av1_vert_left_pred {
    angle_io.val = av1_mode_to_angle_map[mode - av1_vert_pred].to_int() +
      3 * angle_io.val
    let angle = angle_io.val
    if angle <= 90 {
      mode = if angle < 90 && have_top { av1_z1_pred } else { av1_vert_pred }
    } else if angle < 180 {
      mode = av1_z2_pred
    } else {
      mode = if angle > 180 && have_left { av1_z3_pred } else { av1_hor_pred }
    }
  } else if mode == av1_dc_pred || mode == av1_paeth_pred {
    let idx = (mode - av1_dc_pred) * 4 +
      (if have_left { 2 } else { 0 }) +
      (if have_top { 1 } else { 0 })
    mode = av1_mode_conv[idx].to_int()
  }
  // Needs table indexed by the impl-mode value; map enum → needs bits.
  let needs = av1_mode_needs(mode)
  if (needs & 1) != 0 {
    // left edge, written top→bottom into edge_buf[topleft-1 .. toplevel-sz]
    let sz = th << 2
    let left_base = topleft - sz
    if have_left {
      let px_have = av1_imin(sz, (h - y) << 2)
      for i in 0..<px_have {
        edge_buf[left_base + sz - 1 - i] = plane[dst_off + stride * i - 1]
      }
      if px_have < sz {
        let v = edge_buf[left_base + sz - px_have]
        for i in 0..<(sz - px_have) {
          edge_buf[left_base + i] = v
        }
      }
    } else {
      let v : Byte = if have_top {
        match top_sb_edge {
          Some(sb) => sb[top_sb_edge_off + x * 4]
          None => plane[dst_off - stride]
        }
      } else {
        129 // ((1 << 8) >> 1) + 1
      }
      for i in 0..<sz {
        edge_buf[left_base + i] = v
      }
    }
    if (needs & 32) != 0 {
      let have_bottomleft = if !have_left || y + th >= h {
        false
      } else {
        (edge_flags & av1_edge_i444_left_has_bottom) != 0
      }
      if have_bottomleft {
        let px_have = av1_imin(sz, (h - y - th) << 2)
        for i in 0..<px_have {
          edge_buf[topleft - sz - (i + 1)] = plane[dst_off +
            (sz + i) * stride -
            1]
        }
        if px_have < sz {
          let v = edge_buf[topleft - sz - px_have]
          for i in 0..<(sz - px_have) {
            edge_buf[topleft - 2 * sz + i] = v
          }
        }
      } else {
        let v = edge_buf[topleft - sz]
        for i in 0..<sz {
          edge_buf[topleft - 2 * sz + i] = v
        }
      }
    }
  }
  if (needs & 2) != 0 {
    let sz = tw << 2
    let top_base = topleft + 1
    if have_top {
      let px_have = av1_imin(sz, (w - x) << 2)
      for i in 0..<px_have {
        edge_buf[top_base + i] = match top_sb_edge {
          Some(sb) => sb[top_sb_edge_off + x * 4 + i]
          None => plane[dst_off - stride + i]
        }
      }
      if px_have < sz {
        let v = edge_buf[top_base + px_have - 1]
        for i in 0..<(sz - px_have) {
          edge_buf[top_base + px_have + i] = v
        }
      }
    } else {
      let v : Byte = if have_left {
        plane[dst_off - 1]
      } else {
        127 // ((1 << 8) >> 1) - 1
      }
      for i in 0..<sz {
        edge_buf[top_base + i] = v
      }
    }
    if (needs & 16) != 0 {
      let have_topright = if !have_top || x + tw >= w {
        false
      } else {
        (edge_flags & av1_edge_i444_top_has_right) != 0
      }
      if have_topright {
        let px_have = av1_imin(sz, (w - x - tw) << 2)
        for i in 0..<px_have {
          edge_buf[top_base + sz + i] = match top_sb_edge {
            Some(sb) => sb[top_sb_edge_off + x * 4 + sz + i]
            None => plane[dst_off - stride + sz + i]
          }
        }
        if px_have < sz {
          let v = edge_buf[top_base + sz + px_have - 1]
          for i in 0..<(sz - px_have) {
            edge_buf[top_base + sz + px_have + i] = v
          }
        }
      } else {
        let v = edge_buf[top_base + sz - 1]
        for i in 0..<sz {
          edge_buf[top_base + sz + i] = v
        }
      }
    }
  }
  if (needs & 8) != 0 {
    edge_buf[topleft] = if have_left {
      if have_top {
        match top_sb_edge {
          Some(sb) => sb[top_sb_edge_off + x * 4 - 1]
          None => plane[dst_off - stride - 1]
        }
      } else {
        plane[dst_off - 1]
      }
    } else if have_top {
      match top_sb_edge {
        Some(sb) => sb[top_sb_edge_off + x * 4]
        None => plane[dst_off - stride]
      }
    } else {
      128
    }
    if mode == av1_z2_pred && tw + th >= 6 && filter_edge != 0 {
      edge_buf[topleft] = ((
        (edge_buf[topleft - 1].to_int() + edge_buf[topleft + 1].to_int()) * 5 +
        edge_buf[topleft].to_int() * 6 +
        8
      ) >>
      4).to_byte()
    }
  }
  mode
}

///|
/// Edge requirement bits per implemented prediction mode (dav1d
/// `av1_intra_prediction_edges` indexed by the effective mode value).
fn av1_dir_mode_ok() -> Bool {
  av1_diag_down_left_pred < av1_diag_down_right_pred &&
  av1_diag_down_right_pred < av1_vert_right_pred &&
  av1_vert_right_pred < av1_hor_down_pred &&
  av1_hor_down_pred < av1_hor_up_pred &&
  av1_hor_up_pred < av1_vert_left_pred &&
  av1_edge_i422_top_has_right == 2 &&
  av1_angle_use_edge_filter_flag == 1024
}

///|
fn av1_mode_needs(mode : Int32) -> Int32 {
  ignore(av1_dir_mode_ok())
  match mode {
    0 => 1 | 2 // DC
    1 => 2 // VERT
    2 => 1 // HOR
    3 => 1 // LEFT_DC
    4 => 2 // TOP_DC
    5 => 0 // DC_128
    6 => 2 | 8 | 16 // Z1
    7 => 1 | 2 | 8 // Z2
    8 => 1 | 8 | 32 // Z3
    9 => 1 | 2 // SMOOTH
    10 => 1 | 2 // SMOOTH_V
    11 => 1 | 2 // SMOOTH_H
    12 => 1 | 2 | 8 // PAETH
    _ => 1 | 2 | 8 // FILTER (13)
  }
}

///|
/// `splat_dc`.
fn av1_ipred_splat_dc(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  width : Int32,
  height : Int32,
  dc : Int32,
) -> Unit {
  for y in 0..<height {
    for x in 0..<width {
      dst[dst_off + y * stride + x] = dc.to_byte()
    }
  }
}

///|
fn av1_dc_gen_top(
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
) -> Int32 {
  let mut dc = width >> 1
  for i in 0..<width {
    dc = dc + edge_buf[topleft + 1 + i].to_int()
  }
  dc >> av1_ctz(width)
}

///|
fn av1_ctz(v : Int32) -> Int32 {
  let mut n = 0
  while ((v >> n) & 1) == 0 {
    n = n + 1
  }
  n
}

///|
fn av1_dc_gen_left(
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  height : Int32,
) -> Int32 {
  let mut dc = height >> 1
  for i in 0..<height {
    dc = dc + edge_buf[topleft - (1 + i)].to_int()
  }
  dc >> av1_ctz(height)
}

///|
fn av1_dc_gen(
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Int32 {
  let mut dc = (width + height) >> 1
  for i in 0..<width {
    dc = dc + edge_buf[topleft + i + 1].to_int()
  }
  for i in 0..<height {
    dc = dc + edge_buf[topleft - (i + 1)].to_int()
  }
  dc = dc >> av1_ctz(width + height)
  if width != height {
    let m = if width > height * 2 || height > width * 2 {
      0x3334
    } else {
      0x5556
    }
    dc = (dc * m) >> 16
  }
  dc
}

///|
/// `ipred_v_c`.
fn av1_ipred_v(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  for y in 0..<height {
    for x in 0..<width {
      dst[dst_off + y * stride + x] = edge_buf[topleft + 1 + x]
    }
  }
}

///|
/// `ipred_h_c`.
fn av1_ipred_h(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  for y in 0..<height {
    let v = edge_buf[topleft - (1 + y)]
    for x in 0..<width {
      dst[dst_off + y * stride + x] = v
    }
  }
}

///|
/// `ipred_paeth_c`.
fn av1_ipred_paeth(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  let tl = edge_buf[topleft].to_int()
  for y in 0..<height {
    let left = edge_buf[topleft - (y + 1)].to_int()
    for x in 0..<width {
      let top = edge_buf[topleft + 1 + x].to_int()
      let base = left + top - tl
      let ldiff = if left - base < 0 { base - left } else { left - base }
      let tdiff = if top - base < 0 { base - top } else { top - base }
      let tldiff = if tl - base < 0 { base - tl } else { tl - base }
      dst[dst_off + y * stride + x] = if ldiff <= tdiff && ldiff <= tldiff {
        left.to_byte()
      } else if tdiff <= tldiff {
        top.to_byte()
      } else {
        tl.to_byte()
      }
    }
  }
}

///|
/// `ipred_smooth_c`.
fn av1_ipred_smooth(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  let right = edge_buf[topleft + width].to_int()
  let bottom = edge_buf[topleft - height].to_int()
  for y in 0..<height {
    let wv = av1_sm_weights[height + y].to_int()
    for x in 0..<width {
      let wh = av1_sm_weights[width + x].to_int()
      let pred = wv * edge_buf[topleft + 1 + x].to_int() +
        (256 - wv) * bottom +
        wh * edge_buf[topleft - (1 + y)].to_int() +
        (256 - wh) * right
      dst[dst_off + y * stride + x] = ((pred + 256) >> 9).to_byte()
    }
  }
}

///|
/// `ipred_smooth_v_c`.
fn av1_ipred_smooth_v(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  let bottom = edge_buf[topleft - height].to_int()
  for y in 0..<height {
    let wv = av1_sm_weights[height + y].to_int()
    for x in 0..<width {
      let pred = wv * edge_buf[topleft + 1 + x].to_int() + (256 - wv) * bottom
      dst[dst_off + y * stride + x] = ((pred + 128) >> 8).to_byte()
    }
  }
}

///|
/// `ipred_smooth_h_c`.
fn av1_ipred_smooth_h(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Unit {
  let right = edge_buf[topleft + width].to_int()
  for y in 0..<height {
    for x in 0..<width {
      let wh = av1_sm_weights[width + x].to_int()
      let pred = wh * edge_buf[topleft - (y + 1)].to_int() + (256 - wh) * right
      dst[dst_off + y * stride + x] = ((pred + 128) >> 8).to_byte()
    }
  }
}

///|
/// `get_filter_strength` from ipred_tmpl.c.
fn av1_get_filter_strength(wh : Int32, angle : Int32, is_sm : Bool) -> Int32 {
  if is_sm {
    if wh <= 8 {
      if angle >= 64 {
        return 2
      }
      if angle >= 40 {
        return 1
      }
    } else if wh <= 16 {
      if angle >= 48 {
        return 2
      }
      if angle >= 20 {
        return 1
      }
    } else if wh <= 24 {
      if angle >= 4 {
        return 3
      }
    } else {
      return 3
    }
  } else if wh <= 8 {
    if angle >= 56 {
      return 1
    }
  } else if wh <= 16 {
    if angle >= 40 {
      return 1
    }
  } else if wh <= 24 {
    if angle >= 32 {
      return 3
    }
    if angle >= 16 {
      return 2
    }
    if angle >= 8 {
      return 1
    }
  } else if wh <= 32 {
    if angle >= 32 {
      return 3
    }
    if angle >= 4 {
      return 2
    }
    return 1
  } else {
    return 3
  }
  0
}

///|
/// `filter_edge`. `inp`/`outp` are offsets into `buf`; `from`/`to` are the
/// valid index window of `inp` (clipped indexing).
fn av1_filter_edge(
  out_buf : FixedArray[Byte],
  outp : Int32,
  sz : Int32,
  lim_from : Int32,
  lim_to : Int32,
  in_buf : FixedArray[Byte],
  inp : Int32,
  from : Int32,
  to : Int32,
  strength : Int32,
) -> Unit {
  let kernel : FixedArray[FixedArray[Byte]] = [
    [0, 4, 8, 4, 0],
    [0, 5, 6, 5, 0],
    [2, 4, 4, 4, 2],
  ]
  let mut i = 0
  while i < av1_imin(sz, lim_from) {
    out_buf[outp + i] = in_buf[inp + av1_iclip(i, from, to - 1)]
    i = i + 1
  }
  while i < av1_imin(lim_to, sz) {
    let mut acc = 0
    let k = kernel[strength - 1]
    for j2 in 0..<5 {
      acc = acc +
        in_buf[inp + av1_iclip(i - 2 + j2, from, to - 1)].to_int() *
        k[j2].to_int()
    }
    out_buf[outp + i] = ((acc + 8) >> 4).to_byte()
    i = i + 1
  }
  while i < sz {
    out_buf[outp + i] = in_buf[inp + av1_iclip(i, from, to - 1)]
    i = i + 1
  }
}

///|
fn av1_get_upsample(wh : Int32, angle : Int32, is_sm : Bool) -> Bool {
  angle < 40 && wh <= 16 >> (if is_sm { 1 } else { 0 })
}

///|
/// `upsample_edge`.
fn av1_upsample_edge(
  out_buf : FixedArray[Byte],
  outp : Int32,
  hsz : Int32,
  in_buf : FixedArray[Byte],
  inp : Int32,
  from : Int32,
  to : Int32,
) -> Unit {
  let kernel : FixedArray[Int32] = [-1, 9, 9, -1]
  let mut i = 0
  while i < hsz - 1 {
    out_buf[outp + i * 2] = in_buf[inp + av1_iclip(i, from, to - 1)]
    let mut s = 0
    for j in 0..<4 {
      s = s +
        in_buf[inp + av1_iclip(i + j - 1, from, to - 1)].to_int() * kernel[j]
    }
    out_buf[outp + i * 2 + 1] = av1_clip_pixel((s + 8) >> 4)
    i = i + 1
  }
  out_buf[outp + i * 2] = in_buf[inp + av1_iclip(i, from, to - 1)]
}

///|
fn av1_clip_pixel(v : Int32) -> Byte {
  av1_iclip(v, 0, 255).to_byte()
}

///|
/// `ipred_z1_c`. `angle` carries the sm/filter flag bits like dav1d.
fn av1_ipred_z1(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
  angle_in : Int32,
) -> Unit {
  let is_sm = ((angle_in >> 9) & 0x1) != 0
  let enable_filter = angle_in >> 10
  let angle = angle_in & 511
  let mut dx = av1_dr_intra_derivative[angle >> 1].to_int()
  let top = FixedArray::make(128, b'\x00')
  let upsample_above = enable_filter != 0 &&
    av1_get_upsample(width + height, 90 - angle, is_sm)
  let max_base_x = if upsample_above {
    av1_upsample_edge(
      top,
      0,
      width + height,
      edge_buf,
      topleft + 1,
      -1,
      width + av1_imin(width, height),
    )
    dx = dx << 1
    2 * (width + height) - 2
  } else {
    let filter_strength = if enable_filter != 0 {
      av1_get_filter_strength(width + height, 90 - angle, is_sm)
    } else {
      0
    }
    if filter_strength != 0 {
      av1_filter_edge(
        top,
        0,
        width + height,
        0,
        width + height,
        edge_buf,
        topleft + 1,
        -1,
        width + av1_imin(width, height),
        filter_strength,
      )
      width + height - 1
    } else {
      for i in 0..<(width + av1_imin(width, height)) {
        top[i] = edge_buf[topleft + 1 + i]
      }
      width + av1_imin(width, height) - 1
    }
  }
  let base_inc = 1 + (if upsample_above { 1 } else { 0 })
  let mut ypos = dx
  for y in 0..<height {
    let frac = ypos & 0x3E
    let mut base = ypos >> 6
    let mut x = 0
    while x < width {
      if base < max_base_x {
        let v = top[base].to_int() * (64 - frac) + top[base + 1].to_int() * frac
        dst[dst_off + y * stride + x] = ((v + 32) >> 6).to_byte()
        x = x + 1
        base = base + base_inc
      } else {
        let v = top[max_base_x]
        while x < width {
          dst[dst_off + y * stride + x] = v
          x = x + 1
        }
        break
      }
    }
    ypos = ypos + dx
  }
}

///|
/// `ipred_z2_c`.
fn av1_ipred_z2(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft_in : Int32,
  width : Int32,
  height : Int32,
  angle_in : Int32,
  max_width : Int32,
  max_height : Int32,
) -> Unit {
  let is_sm = ((angle_in >> 9) & 0x1) != 0
  let enable_filter = angle_in >> 10
  let angle = angle_in & 511
  let mut dy = av1_dr_intra_derivative[(angle - 90) >> 1].to_int()
  let mut dx = av1_dr_intra_derivative[(180 - angle) >> 1].to_int()
  let upsample_left = enable_filter != 0 &&
    av1_get_upsample(width + height, 180 - angle, is_sm)
  let upsample_above = enable_filter != 0 &&
    av1_get_upsample(width + height, angle - 90, is_sm)
  // edge[64] is the topleft anchor inside our local buffer.
  let buf = FixedArray::make(129, b'\x00')
  let topleft = 64
  if upsample_above {
    av1_upsample_edge(
      buf,
      topleft,
      width + 1,
      edge_buf,
      topleft_in,
      0,
      width + 1,
    )
    dx = dx << 1
  } else {
    let filter_strength = if enable_filter != 0 {
      av1_get_filter_strength(width + height, angle - 90, is_sm)
    } else {
      0
    }
    if filter_strength != 0 {
      av1_filter_edge(
        buf,
        topleft + 1,
        width,
        0,
        max_width,
        edge_buf,
        topleft_in + 1,
        -1,
        width,
        filter_strength,
      )
    } else {
      for i in 0..<width {
        buf[topleft + 1 + i] = edge_buf[topleft_in + 1 + i]
      }
    }
  }
  if upsample_left {
    av1_upsample_edge(
      buf,
      topleft - height * 2,
      height + 1,
      edge_buf,
      topleft_in - height,
      0,
      height + 1,
    )
    dy = dy << 1
  } else {
    let filter_strength = if enable_filter != 0 {
      av1_get_filter_strength(width + height, 180 - angle, is_sm)
    } else {
      0
    }
    if filter_strength != 0 {
      av1_filter_edge(
        buf,
        topleft - height,
        height,
        height - max_height,
        height,
        edge_buf,
        topleft_in - height,
        0,
        height + 1,
        filter_strength,
      )
    } else {
      for i in 0..<height {
        buf[topleft - height + i] = edge_buf[topleft_in - height + i]
      }
    }
  }
  buf[topleft] = edge_buf[topleft_in]
  let base_inc_x = 1 + (if upsample_above { 1 } else { 0 })
  let left_base = topleft - (1 + (if upsample_left { 1 } else { 0 }))
  let mut xpos = ((1 + (if upsample_above { 1 } else { 0 })) << 6) - dx
  for y in 0..<height {
    let mut base_x = xpos >> 6
    let frac_x = xpos & 0x3E
    let mut ypos = (y << (6 + (if upsample_left { 1 } else { 0 }))) - dy
    for x in 0..<width {
      let v = if base_x >= 0 {
        buf[topleft + base_x].to_int() * (64 - frac_x) +
        buf[topleft + base_x + 1].to_int() * frac_x
      } else {
        let base_y = ypos >> 6
        let frac_y = ypos & 0x3E
        buf[left_base - base_y].to_int() * (64 - frac_y) +
        buf[left_base - (base_y + 1)].to_int() * frac_y
      }
      dst[dst_off + y * stride + x] = ((v + 32) >> 6).to_byte()
      base_x = base_x + base_inc_x
      ypos = ypos - dy
    }
    xpos = xpos - dx
  }
}

///|
/// `ipred_z3_c`.
fn av1_ipred_z3(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
  angle_in : Int32,
) -> Unit {
  let is_sm = ((angle_in >> 9) & 0x1) != 0
  let enable_filter = angle_in >> 10
  let angle = angle_in & 511
  let mut dy = av1_dr_intra_derivative[(270 - angle) >> 1].to_int()
  let left = FixedArray::make(128, b'\x00')
  let mut z3_filtered = false
  let upsample_left = enable_filter != 0 &&
    av1_get_upsample(width + height, angle - 180, is_sm)
  let max_base_y = if upsample_left {
    av1_upsample_edge(
      left,
      0,
      width + height,
      edge_buf,
      topleft - (width + height),
      av1_imax(width - height, 0),
      width + height + 1,
    )
    dy = dy << 1
    2 * (width + height) - 2
  } else {
    let filter_strength = if enable_filter != 0 {
      av1_get_filter_strength(width + height, angle - 180, is_sm)
    } else {
      0
    }
    if filter_strength != 0 {
      av1_filter_edge(
        left,
        0,
        width + height,
        0,
        width + height,
        edge_buf,
        topleft - (width + height),
        av1_imax(width - height, 0),
        width + height + 1,
        filter_strength,
      )
      z3_filtered = true
      width + height - 1
    } else {
      for i in 0..<(height + av1_imin(width, height)) {
        left[i] = edge_buf[topleft - 1 - i]
      }
      height + av1_imin(width, height) - 1
    }
  }
  let base_inc = 1 + (if upsample_left { 1 } else { 0 })
  let mut ypos = dy
  for x in 0..<width {
    let frac = ypos & 0x3E
    let mut base = ypos >> 6
    let mut y = 0
    while y < height {
      if base < max_base_y {
        let vv = av1_z3_left(
            left, width, height, upsample_left, z3_filtered, base,
          ) *
          (64 - frac) +
          av1_z3_left(left, width, height, upsample_left, z3_filtered, base + 1) *
          frac
        dst[dst_off + y * stride + x] = ((vv + 32) >> 6).to_byte()
        y = y + 1
        base = base + base_inc
      } else {
        let v = av1_z3_left(
          left, width, height, upsample_left, z3_filtered, max_base_y,
        )
        while y < height {
          dst[dst_off + y * stride + x] = v.to_byte()
          y = y + 1
        }
        break
      }
    }
    ypos = ypos + dy
  }
}

///|
/// dav1d's z3 `left` pointer sits at the last entry; `left[-base]` maps to
/// `left_out[k - base]` with k depending on the edge preparation path.
fn av1_z3_left(
  left : FixedArray[Byte],
  width : Int32,
  height : Int32,
  upsample : Bool,
  filtered : Bool,
  base : Int32,
) -> Int32 {
  if upsample {
    left[2 * (width + height) - 2 - base].to_int()
  } else if filtered {
    left[width + height - 1 - base].to_int()
  } else {
    left[base].to_int()
  }
}

///|
/// `ipred_filter_c` (up to 32x32).
fn av1_ipred_filter(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft_in : Int32,
  width : Int32,
  height : Int32,
  filt_idx_in : Int32,
) -> Unit {
  let filt_idx = filt_idx_in & 511
  // dav1d_filter_intra_taps is [5][64] int8; flt_ptr walks 8 taps per
  // output pixel in row-major 2x4 blocks.
  let mut y = 0
  let mut dst_y = dst_off
  while y < height {
    let mut x = 0
    while x < width {
      let p0 = if x == 0 {
        edge_buf[topleft_in - y].to_int()
      } else if y == 0 {
        edge_buf[topleft_in + x].to_int()
      } else {
        dst[dst_y - stride + x - 1].to_int()
      }
      let top_at = (i : Int32) => {
        if y == 0 {
          edge_buf[topleft_in + 1 + x + i].to_int()
        } else {
          dst[dst_y - stride + x + i].to_int()
        }
      }
      let p1 = top_at(0)
      let p2 = top_at(1)
      let p3 = top_at(2)
      let p4 = top_at(3)
      let p5 = if x == 0 {
        edge_buf[topleft_in - y - 1].to_int()
      } else {
        dst[dst_y + x - 1].to_int()
      }
      let p6 = if x == 0 {
        edge_buf[topleft_in - y - 2].to_int()
      } else {
        dst[dst_y + stride + x - 1].to_int()
      }
      let fbase = filt_idx * 64
      for yy in 0..<2 {
        for xx in 0..<4 {
          let fp = fbase + yy * 4 + xx
          let acc = av1_tap(fp) * p0 +
            av1_tap(fp + 8) * p1 +
            av1_tap(fp + 16) * p2 +
            av1_tap(fp + 24) * p3 +
            av1_tap(fp + 32) * p4 +
            av1_tap(fp + 40) * p5 +
            av1_tap(fp + 48) * p6
          dst[dst_y + yy * stride + x + xx] = av1_clip_pixel((acc + 8) >> 4)
        }
      }
      x = x + 4
    }
    dst_y = dst_y + stride * 2
    y = y + 2
  }
}

///|
/// `cfl_ac_c` (4:2:0 path used by keyframes here; layout param exposed).
fn av1_cfl_ac(
  ac : FixedArray[Int32],
  ypx : FixedArray[Byte],
  y_off : Int32,
  stride : Int32,
  w_pad : Int32,
  h_pad : Int32,
  width : Int32,
  height : Int32,
  ss_hor : Int32,
  ss_ver : Int32,
) -> Unit {
  let mut ac_row = 0
  let mut y_row = y_off
  let mut y = 0
  while y < height - 4 * h_pad {
    let mut x = 0
    while x < width - 4 * w_pad {
      let mut ac_sum = ypx[y_row + (x << ss_hor)].to_int()
      if ss_hor != 0 {
        ac_sum = ac_sum + ypx[y_row + x * 2 + 1].to_int()
      }
      if ss_ver != 0 {
        ac_sum = ac_sum + ypx[y_row + (x << ss_hor) + stride].to_int()
        if ss_hor != 0 {
          ac_sum = ac_sum + ypx[y_row + x * 2 + 1 + stride].to_int()
        }
      }
      ac[ac_row + x] = ac_sum << (1 + (1 - ss_ver) + (1 - ss_hor))
      x = x + 1
    }
    while x < width {
      ac[ac_row + x] = ac[ac_row + x - 1]
      x = x + 1
    }
    ac_row = ac_row + width
    y_row = y_row + (stride << ss_ver)
    y = y + 1
  }
  while y < height {
    for x in 0..<width {
      ac[ac_row + x] = ac[ac_row - width + x]
    }
    ac_row = ac_row + width
    y = y + 1
  }
  let log2sz = av1_ctz(width) + av1_ctz(height)
  let sum_ref = Ref(1 << log2sz >> 1)
  for yy in 0..<height {
    for xx in 0..<width {
      sum_ref.val = sum_ref.val + ac[yy * width + xx]
    }
  }
  let sum = sum_ref.val >> log2sz
  for yy in 0..<height {
    for xx in 0..<width {
      ac[yy * width + xx] = ac[yy * width + xx] - sum
    }
  }
}

///|
/// `cfl_pred`.
fn av1_cfl_predict(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  width : Int32,
  height : Int32,
  dc : Int32,
  ac : FixedArray[Int32],
  alpha : Int32,
) -> Unit {
  for y in 0..<height {
    for x in 0..<width {
      let diff = alpha * ac[y * width + x]
      let mag = if diff < 0 { -diff } else { diff }
      let adj = (mag + 32) >> 6
      let signed = if diff < 0 { -adj } else { adj }
      dst[dst_off + y * stride + x] = av1_clip_pixel(dc + signed)
    }
  }
}

///|
/// `pal_pred_c`: idx holds two 4-bit palette indices per byte.
fn av1_pal_pred(
  dst : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  pal : FixedArray[Byte],
  pal_off : Int32,
  idx : FixedArray[Byte],
  idx_off : Int32,
  w : Int32,
  h : Int32,
) -> Unit {
  for y in 0..<h {
    let mut ii = idx_off + y * ((w + 1) >> 1)
    let mut x = 0
    while x < w {
      let i = idx[ii].to_int()
      ii = ii + 1
      dst[dst_off + y * stride + x] = pal[pal_off + (i & 7)]
      if x + 1 < w {
        dst[dst_off + y * stride + x + 1] = pal[pal_off + (i >> 4)]
      }
      x = x + 2
    }
  }
}

///|
/// Signed access to `av1_filter_intra_taps` (dumped as unsigned bytes).
fn av1_tap(i : Int32) -> Int32 {
  let v = av1_filter_intra_taps[i].to_int()
  if v > 127 {
    v - 256
  } else {
    v
  }
}

///|
/// `intra_pred[m]` dispatch from dav1d_intra_pred_dsp_init. `angle_flags`
/// carries the angle (or filter index for FILTER_PRED) plus the sm/filter
/// flag bits.
fn av1_ipred_predict(
  m : Int32,
  plane : FixedArray[Byte],
  dst_off : Int32,
  stride : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
  angle_flags : Int32,
  max_width : Int32,
  max_height : Int32,
) -> Unit {
  match m {
    0 => {
      let dc = av1_dc_gen(edge_buf, topleft, width, height)
      av1_ipred_splat_dc(plane, dst_off, stride, width, height, dc)
    }
    5 => av1_ipred_splat_dc(plane, dst_off, stride, width, height, 128)
    4 => {
      let dc = av1_dc_gen_top(edge_buf, topleft, width)
      av1_ipred_splat_dc(plane, dst_off, stride, width, height, dc)
    }
    3 => {
      let dc = av1_dc_gen_left(edge_buf, topleft, height)
      av1_ipred_splat_dc(plane, dst_off, stride, width, height, dc)
    }
    2 => av1_ipred_h(plane, dst_off, stride, edge_buf, topleft, width, height)
    1 => av1_ipred_v(plane, dst_off, stride, edge_buf, topleft, width, height)
    12 =>
      av1_ipred_paeth(plane, dst_off, stride, edge_buf, topleft, width, height)
    9 =>
      av1_ipred_smooth(plane, dst_off, stride, edge_buf, topleft, width, height)
    10 =>
      av1_ipred_smooth_v(
        plane, dst_off, stride, edge_buf, topleft, width, height,
      )
    11 =>
      av1_ipred_smooth_h(
        plane, dst_off, stride, edge_buf, topleft, width, height,
      )
    6 =>
      av1_ipred_z1(
        plane, dst_off, stride, edge_buf, topleft, width, height, angle_flags,
      )
    7 =>
      av1_ipred_z2(
        plane, dst_off, stride, edge_buf, topleft, width, height, angle_flags, max_width,
        max_height,
      )
    8 =>
      av1_ipred_z3(
        plane, dst_off, stride, edge_buf, topleft, width, height, angle_flags,
      )
    _ =>
      // FILTER_PRED: angle_flags low bits hold the filter index.
      av1_ipred_filter(
        plane, dst_off, stride, edge_buf, topleft, width, height, angle_flags,
      )
  }
}

///|
/// cfl DC value for the prepared mode m (DC family only).
fn av1_cfl_dc(
  m : Int32,
  edge_buf : FixedArray[Byte],
  topleft : Int32,
  width : Int32,
  height : Int32,
) -> Int32 {
  match m {
    5 => 128 // DC_128
    4 => av1_dc_gen_top(edge_buf, topleft, width)
    3 => av1_dc_gen_left(edge_buf, topleft, height)
    _ => av1_dc_gen(edge_buf, topleft, width, height)
  }
}
