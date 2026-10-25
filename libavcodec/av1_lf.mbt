///|
/// AV1 in-loop deblocking filter for intra frames.
///
/// Port of dav1d 1.5.1 `src/lf_mask.c` (intra mask builder), `src/lf_mask.c`
/// `dav1d_calc_eih`/`dav1d_calc_lf_values`, `src/loopfilter_tmpl.c` (C
/// reference kernels) and the intra-relevant parts of `src/lf_apply_tmpl.c`.
/// dav1d is BSD-2-Clause (Copyright © 2018, VideoLAN and dav1d authors;
/// Copyright © 2018, Two Orioles, LLC); this port keeps the same algorithm
/// with LGPL-2.1-or-later packaging consistent with the rest of the module.
///
/// Filtering runs once per superblock row after the whole frame is decoded.
/// That is equivalent to dav1d's per-row filtering for intra frames: all
/// prediction has already consumed the unfiltered reconstruction, and each
/// row only reads the (already filtered) row above.

///|
/// Per 128x128 area filter masks. Each bit is one 4x4 column/row edge.
priv struct Av1Filter {
  /// `[dir][col4][level][sidx]`, dir 0 = vertical (column) edges.
  fy : FixedArray[UInt]
  /// `[dir][col4][level][sidx]` for chroma (levels 0/1 are block edges).
  fuv : FixedArray[UInt]
  /// CDEF index per 64x64 sub-block inside the 128x128 area (-1 = unset).
  cdef_idx : FixedArray[Int32]
  /// `noskip_mask[16][2]` flattened: 8x8 blocks, stored on a 4x8 basis.
  noskip : FixedArray[UInt]
  /// Loop-restoration units: `[plane * 4 + unit_idx]`.
  lr : FixedArray[Av1RestorationUnit]
}

///|
fn av1_filter_new() -> Av1Filter {
  {
    fy: FixedArray::make(2 * 32 * 3 * 2, (0 : UInt)),
    fuv: FixedArray::make(2 * 32 * 2 * 2, (0 : UInt)),
    cdef_idx: FixedArray::make(4, -1),
    noskip: FixedArray::make(32, (0 : UInt)),
    lr: {
      let l = FixedArray::make(12, av1_restoration_unit_new())
      for i in 0..<12 {
        l[i] = av1_restoration_unit_new()
      }
      l
    },
  }
}

///|
fn av1_fy_i(dir : Int32, col : Int32, lvl : Int32, sidx : Int32) -> Int32 {
  ((dir * 32 + col) * 3 + lvl) * 2 + sidx
}

///|
fn av1_fuv_i(dir : Int32, col : Int32, lvl : Int32, sidx : Int32) -> Int32 {
  ((dir * 32 + col) * 2 + lvl) * 2 + sidx
}

///|
/// `Av1FilterLUT` (only the E/I tables are consumed by the C filters).
priv struct Av1FilterLut {
  e : FixedArray[Int32]
  i : FixedArray[Int32]
}

///|
fn av1_filter_lut_new() -> Av1FilterLut {
  { e: FixedArray::make(64, 0), i: FixedArray::make(64, 0) }
}

///|
/// `dav1d_calc_eih`.
fn av1_calc_eih(lut : Av1FilterLut, sharpness : Int32) -> Unit {
  for level in 0..<64 {
    let mut limit = level
    if sharpness > 0 {
      limit = limit >> ((sharpness + 3) >> 2)
      limit = av1_imin(limit, 9 - sharpness)
    }
    limit = av1_imax(limit, 1)
    lut.i[level] = limit
    lut.e[level] = 2 * (level + 2) + limit
  }
}

///|
/// `calc_lf_value` (8 refs x 2 modes per direction/segment).
fn av1_calc_lf_value(
  values : FixedArray[Int32],
  off : Int32,
  base_lvl : Int32,
  lf_delta : Int32,
  seg_delta : Int32,
  mr : Bool,
  ref_deltas : Array[Int32],
  mode_deltas : Array[Int32],
) -> Unit {
  let base = av1_iclip(av1_iclip(base_lvl + lf_delta, 0, 63) + seg_delta, 0, 63)
  if !mr {
    for i in 0..<16 {
      values[off + i] = base
    }
  } else {
    let sh = if base >= 32 { 1 } else { 0 }
    let v00 = av1_iclip(base + (ref_deltas[0] << sh), 0, 63)
    values[off + 0] = v00
    values[off + 1] = v00
    for r in 1..<8 {
      for m in 0..<2 {
        let delta = mode_deltas[m] + ref_deltas[r]
        values[off + r * 2 + m] = av1_iclip(base + (delta << sh), 0, 63)
      }
    }
  }
}

///|
/// `dav1d_calc_lf_values` into `[seg][dir][ref][mode]`. `lf_delta[4]` is the
/// per-superblock delta-lf offset (all zeros for the frame-wide table);
/// without `delta_lf_multi` every direction uses `lf_delta[0]`.
fn av1_calc_lf_values(
  values : FixedArray[Int32],
  hdr : Av1FrameHeader,
  lf_delta : FixedArray[Int32],
) -> Unit {
  let n_seg = if hdr.segmentation_enabled { 8 } else { 1 }
  if hdr.loop_filter_level.length() < 2 ||
    (hdr.loop_filter_level[0] == 0 && hdr.loop_filter_level[1] == 0) {
    for i in 0..<(n_seg * 64) {
      values[i] = 0
    }
    return
  }
  let mr = hdr.loop_filter_delta_enabled
  let multi = hdr.delta_lf_multi
  let dy_v = lf_delta[0]
  let dy_h = lf_delta[if multi { 1 } else { 0 }]
  let du = lf_delta[if multi { 2 } else { 0 }]
  let dv = lf_delta[if multi { 3 } else { 0 }]
  for s in 0..<n_seg {
    let y_v = hdr.loop_filter_level[0]
    let y_h = hdr.loop_filter_level[1]
    let u = if hdr.loop_filter_level.length() > 2 {
      hdr.loop_filter_level[2]
    } else {
      0
    }
    let v = if hdr.loop_filter_level.length() > 3 {
      hdr.loop_filter_level[3]
    } else {
      0
    }
    let base = s * 64
    av1_calc_lf_value(
      values, base + 0 * 16, y_v, dy_v, hdr.seg_delta_lf[s * 4], mr, hdr.loop_filter_ref_deltas,
      hdr.loop_filter_mode_deltas,
    )
    av1_calc_lf_value(
      values, base + 1 * 16, y_h, dy_h, hdr.seg_delta_lf[s * 4 + 1], mr, hdr.loop_filter_ref_deltas,
      hdr.loop_filter_mode_deltas,
    )
    if u == 0 {
      for i in 0..<16 {
        values[base + 2 * 16 + i] = 0
      }
    } else {
      av1_calc_lf_value(
        values, base + 2 * 16, u, du, hdr.seg_delta_lf[s * 4 + 2], mr, hdr.loop_filter_ref_deltas,
        hdr.loop_filter_mode_deltas,
      )
    }
    if v == 0 {
      for i in 0..<16 {
        values[base + 3 * 16 + i] = 0
      }
    } else {
      av1_calc_lf_value(
        values, base + 3 * 16, v, dv, hdr.seg_delta_lf[s * 4 + 3], mr, hdr.loop_filter_ref_deltas,
        hdr.loop_filter_mode_deltas,
      )
    }
  }
}

///|
/// `inner = ((1 << start) << n) - (1 << start)` truncated to 32 bits, built
/// bitwise so a start+n >= 32 range does not depend on shift masking.
fn av1_inner_mask(start : Int32, n : Int32) -> UInt {
  let mut m : UInt = 0
  for k in 0..<n {
    let bit = start + k
    if bit < 32 {
      m = m | ((1 : UInt) << bit)
    }
  }
  m
}

///|
/// `mask_edges_intra`.
fn av1_mask_edges_intra(
  fy : FixedArray[UInt],
  by4 : Int32,
  bx4 : Int32,
  w4 : Int32,
  h4 : Int32,
  tx : Int32,
  a : FixedArray[Int32],
  a_off : Int32,
  l : FixedArray[Int32],
  l_off : Int32,
) -> Unit {
  let twl4 = av1_txfm_lw(tx)
  let thl4 = av1_txfm_lh(tx)
  let twl4c = av1_imin(2, twl4)
  let thl4c = av1_imin(2, thl4)
  // left block edge
  let mut mask : UInt = (1 : UInt) << by4
  for y in 0..<h4 {
    let sidx : Int32 = if mask >= 0x10000U { 1 } else { 0 }
    let smask = if sidx != 0 { mask >> 16 } else { mask }
    let i = av1_fy_i(0, bx4, av1_imin(twl4c, l[l_off + y]), sidx)
    fy[i] = fy[i] | smask
    mask = mask << 1
  }
  // top block edge
  let mut mask2 : UInt = (1 : UInt) << bx4
  for x in 0..<w4 {
    let sidx : Int32 = if mask2 >= 0x10000U { 1 } else { 0 }
    let smask = if sidx != 0 { mask2 >> 16 } else { mask2 }
    let i = av1_fy_i(1, by4, av1_imin(thl4c, a[a_off + x]), sidx)
    fy[i] = fy[i] | smask
    mask2 = mask2 << 1
  }
  // inner (tx) left|right edges
  let hstep = 1 << twl4
  let inner = av1_inner_mask(by4, h4)
  let inner1 = inner & 0xFFFFU
  let inner2 = inner >> 16
  let mut x = hstep
  while x < w4 {
    if inner1 != 0 {
      let i = av1_fy_i(0, bx4 + x, twl4c, 0)
      fy[i] = fy[i] | inner1
    }
    if inner2 != 0 {
      let i = av1_fy_i(0, bx4 + x, twl4c, 1)
      fy[i] = fy[i] | inner2
    }
    x = x + hstep
  }
  // inner (tx) top|bottom edges
  let vstep = 1 << thl4
  let inner_v = av1_inner_mask(bx4, w4)
  let inner_v1 = inner_v & 0xFFFFU
  let inner_v2 = inner_v >> 16
  let mut y = vstep
  while y < h4 {
    if inner_v1 != 0 {
      let i = av1_fy_i(1, by4 + y, thl4c, 0)
      fy[i] = fy[i] | inner_v1
    }
    if inner_v2 != 0 {
      let i = av1_fy_i(1, by4 + y, thl4c, 1)
      fy[i] = fy[i] | inner_v2
    }
    y = y + vstep
  }
  for i in 0..<w4 {
    a[a_off + i] = thl4c
  }
  for i in 0..<h4 {
    l[l_off + i] = twl4c
  }
}

///|
/// `mask_edges_chroma`.
fn av1_mask_edges_chroma(
  fuv : FixedArray[UInt],
  cby4 : Int32,
  cbx4 : Int32,
  cw4 : Int32,
  ch4 : Int32,
  tx : Int32,
  a : FixedArray[Int32],
  a_off : Int32,
  l : FixedArray[Int32],
  l_off : Int32,
  ss_hor : Int32,
  ss_ver : Int32,
) -> Unit {
  let twl4 = av1_txfm_lw(tx)
  let thl4 = av1_txfm_lh(tx)
  let twl4c = if twl4 != 0 { 1 } else { 0 }
  let thl4c = if thl4 != 0 { 1 } else { 0 }
  let vbits = 4 - ss_ver
  let hbits = 4 - ss_hor
  let vmask = 16 >> ss_ver
  let hmask = 16 >> ss_hor
  let vmax : UInt = (1 : UInt) << vmask
  let hmax : UInt = (1 : UInt) << hmask
  // left block edge
  let mut mask : UInt = (1 : UInt) << cby4
  for y in 0..<ch4 {
    let sidx : Int32 = if mask >= vmax { 1 } else { 0 }
    let smask = if sidx != 0 { mask >> (sidx << vbits) } else { mask }
    let i = av1_fuv_i(0, cbx4, av1_imin(twl4c, l[l_off + y]), sidx)
    fuv[i] = fuv[i] | smask
    mask = mask << 1
  }
  // top block edge
  let mut mask2 : UInt = (1 : UInt) << cbx4
  for x in 0..<cw4 {
    let sidx : Int32 = if mask2 >= hmax { 1 } else { 0 }
    let smask = if sidx != 0 { mask2 >> (sidx << hbits) } else { mask2 }
    let i = av1_fuv_i(1, cby4, av1_imin(thl4c, a[a_off + x]), sidx)
    fuv[i] = fuv[i] | smask
    mask2 = mask2 << 1
  }
  // inner (tx) left|right edges
  let hstep = 1 << twl4
  let inner = av1_inner_mask(cby4, ch4)
  let inner1 = inner & (((1 : UInt) << vmask) - 1)
  let inner2 = inner >> vmask
  let mut x = hstep
  while x < cw4 {
    if inner1 != 0 {
      let i = av1_fuv_i(0, cbx4 + x, twl4c, 0)
      fuv[i] = fuv[i] | inner1
    }
    if inner2 != 0 {
      let i = av1_fuv_i(0, cbx4 + x, twl4c, 1)
      fuv[i] = fuv[i] | inner2
    }
    x = x + hstep
  }
  // inner (tx) top|bottom edges
  let vstep = 1 << thl4
  let inner_v = av1_inner_mask(cbx4, cw4)
  let inner_v1 = inner_v & (((1 : UInt) << hmask) - 1)
  let inner_v2 = inner_v >> hmask
  let mut y = vstep
  while y < ch4 {
    if inner_v1 != 0 {
      let i = av1_fuv_i(1, cby4 + y, thl4c, 0)
      fuv[i] = fuv[i] | inner_v1
    }
    if inner_v2 != 0 {
      let i = av1_fuv_i(1, cby4 + y, thl4c, 1)
      fuv[i] = fuv[i] | inner_v2
    }
    y = y + vstep
  }
  for i in 0..<cw4 {
    a[a_off + i] = thl4c
  }
  for i in 0..<ch4 {
    l[l_off + i] = twl4c
  }
}

///|
/// `dav1d_create_lf_mask_intra` (level cache + per-128-area masks).
fn Av1FrameCtx::create_lf_mask_intra(
  self : Av1FrameCtx,
  mask : Av1Filter,
  bx : Int32,
  by : Int32,
  bs : Int32,
  ytx : Int32,
  uvtx : Int32,
  ay : FixedArray[Int32],
  ay_off : Int32,
  ly : FixedArray[Int32],
  ly_off : Int32,
  auv : FixedArray[Int32],
  auv_off : Int32,
  luv : FixedArray[Int32],
  luv_off : Int32,
  has_chroma : Bool,
  lvl : FixedArray[Int32],
  seg : Int32,
) -> Unit {
  let bw4 = av1_imin(self.bw - bx, av1_bdim(bs, 0))
  let bh4 = av1_imin(self.bh - by, av1_bdim(bs, 1))
  let bx4 = bx & 31
  let by4 = by & 31
  if bw4 > 0 && bh4 > 0 {
    let v_level = lvl[seg * 64 + 0 * 16]
    let h_level = lvl[seg * 64 + 1 * 16]
    for y in 0..<bh4 {
      for x in 0..<bw4 {
        let o = ((by + y) * self.b4_stride + (bx + x)) * 4
        self.lf_level[o + 0] = v_level
        self.lf_level[o + 1] = h_level
      }
    }
    av1_mask_edges_intra(
      mask.fy, by4, bx4, bw4, bh4, ytx, ay, ay_off, ly, ly_off,
    )
  }
  if !has_chroma {
    return
  }
  let ss_v = self.ss_v
  let ss_h = self.ss_h
  let cbw4 = av1_imin(
    ((self.bw + ss_h) >> ss_h) - (bx >> ss_h),
    (av1_bdim(bs, 0) + ss_h) >> ss_h,
  )
  let cbh4 = av1_imin(
    ((self.bh + ss_v) >> ss_v) - (by >> ss_v),
    (av1_bdim(bs, 1) + ss_v) >> ss_v,
  )
  if cbw4 <= 0 || cbh4 <= 0 {
    return
  }
  let cbx4 = bx4 >> ss_h
  let cby4 = by4 >> ss_v
  let u_level = lvl[seg * 64 + 2 * 16]
  let v_level = lvl[seg * 64 + 3 * 16]
  for y in 0..<cbh4 {
    for x in 0..<cbw4 {
      let o = (((by >> ss_v) + y) * self.b4_stride + ((bx >> ss_h) + x)) * 4
      self.lf_level[o + 2] = u_level
      self.lf_level[o + 3] = v_level
    }
  }
  av1_mask_edges_chroma(
    mask.fuv, cby4, cbx4, cbw4, cbh4, uvtx, auv, auv_off, luv, luv_off, ss_h,
    ss_v,
  )
}

///|
fn av1_abs(v : Int32) -> Int32 {
  if v < 0 { -v } else { v }
}

///|
fn av1_lf_clip_pixel(v : Int32, bpc : Int32) -> Int32 {
  av1_imin(av1_imax(v, 0), (1 << bpc) - 1)
}

///|
/// `loop_filter` from loopfilter_tmpl.c over 4 lines.
fn av1_lf_filter(
  dst : FixedArray[Int32],
  off : Int32,
  stridea : Int32,
  strideb : Int32,
  wd : Int32,
  bpc : Int32,
  e_in : Int32,
  i_in : Int32,
  h_in : Int32,
) -> Unit {
  let bd8 = bpc - 8
  let f_add = 1 << bd8
  let e = e_in << bd8
  let i = i_in << bd8
  let h = h_in << bd8
  let mut o = off
  for _ in 0..<4 {
    let p1 = dst[o - 2 * strideb]
    let p0 = dst[o - strideb]
    let q0 = dst[o]
    let q1 = dst[o + strideb]
    let mut p2 = 0
    let mut p3 = 0
    let mut q2 = 0
    let mut q3 = 0
    let mut fm = av1_abs(p1 - p0) <= i &&
      av1_abs(q1 - q0) <= i &&
      av1_abs(p0 - q0) * 2 + (av1_abs(p1 - q1) >> 1) <= e
    if wd > 4 {
      p2 = dst[o - 3 * strideb]
      q2 = dst[o + 2 * strideb]
      fm = fm && av1_abs(p2 - p1) <= i && av1_abs(q2 - q1) <= i
      if wd > 6 {
        p3 = dst[o - 4 * strideb]
        q3 = dst[o + 3 * strideb]
        fm = fm && av1_abs(p3 - p2) <= i && av1_abs(q3 - q2) <= i
      }
    }
    if !fm {
      o = o + stridea
      continue
    }
    let mut p4 = 0
    let mut p5 = 0
    let mut p6 = 0
    let mut q4 = 0
    let mut q5 = 0
    let mut q6 = 0
    let mut flat8out = false
    if wd >= 16 {
      p6 = dst[o - 7 * strideb]
      p5 = dst[o - 6 * strideb]
      p4 = dst[o - 5 * strideb]
      q4 = dst[o + 4 * strideb]
      q5 = dst[o + 5 * strideb]
      q6 = dst[o + 6 * strideb]
      flat8out = av1_abs(p6 - p0) <= f_add &&
        av1_abs(p5 - p0) <= f_add &&
        av1_abs(p4 - p0) <= f_add &&
        av1_abs(q4 - q0) <= f_add &&
        av1_abs(q5 - q0) <= f_add &&
        av1_abs(q6 - q0) <= f_add
    }
    let mut flat8in = false
    if wd >= 6 {
      flat8in = av1_abs(p2 - p0) <= f_add &&
        av1_abs(p1 - p0) <= f_add &&
        av1_abs(q1 - q0) <= f_add &&
        av1_abs(q2 - q0) <= f_add
    }
    if wd >= 8 {
      flat8in = flat8in && av1_abs(p3 - p0) <= f_add && av1_abs(q3 - q0) <= f_add
    }
    if wd >= 16 && flat8out && flat8in {
      dst[o - 6 * strideb] = (p6 + p6 + p6 + p6 + p6 + p6 * 2 + p5 * 2 +
        p4 * 2 + p3 + p2 + p1 + p0 + q0 + 8) >> 4
      dst[o - 5 * strideb] = (p6 + p6 + p6 + p6 + p6 + p5 * 2 + p4 * 2 +
        p3 * 2 + p2 + p1 + p0 + q0 + q1 + 8) >> 4
      dst[o - 4 * strideb] = (p6 + p6 + p6 + p6 + p5 + p4 * 2 + p3 * 2 +
        p2 * 2 + p1 + p0 + q0 + q1 + q2 + 8) >> 4
      dst[o - 3 * strideb] = (p6 + p6 + p6 + p5 + p4 + p3 * 2 + p2 * 2 +
        p1 * 2 + p0 + q0 + q1 + q2 + q3 + 8) >> 4
      dst[o - 2 * strideb] = (p6 + p6 + p5 + p4 + p3 + p2 * 2 + p1 * 2 +
        p0 * 2 + q0 + q1 + q2 + q3 + q4 + 8) >> 4
      dst[o - 1 * strideb] = (p6 + p5 + p4 + p3 + p2 + p1 * 2 + p0 * 2 +
        q0 * 2 + q1 + q2 + q3 + q4 + q5 + 8) >> 4
      dst[o + 0] = (p5 + p4 + p3 + p2 + p1 + p0 * 2 + q0 * 2 + q1 * 2 + q2 +
        q3 + q4 + q5 + q6 + 8) >> 4
      dst[o + 1 * strideb] = (p4 + p3 + p2 + p1 + p0 + q0 * 2 + q1 * 2 +
        q2 * 2 + q3 + q4 + q5 + q6 + q6 + 8) >> 4
      dst[o + 2 * strideb] = (p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 * 2 +
        q3 * 2 + q4 + q5 + q6 + q6 + q6 + 8) >> 4
      dst[o + 3 * strideb] = (p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 * 2 +
        q4 * 2 + q5 + q6 + q6 + q6 + q6 + 8) >> 4
      dst[o + 4 * strideb] = (p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 * 2 +
        q5 * 2 + q6 + q6 + q6 + q6 + q6 + 8) >> 4
      dst[o + 5 * strideb] = (p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 * 2 +
        q6 * 2 + q6 + q6 + q6 + q6 + q6 + 8) >> 4
    } else if wd >= 8 && flat8in {
      dst[o - 3 * strideb] = (p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0 + 4) >> 3
      dst[o - 2 * strideb] = (p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1 + 4) >> 3
      dst[o - 1 * strideb] = (p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2 + 4) >> 3
      dst[o + 0] = (p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3 + 4) >> 3
      dst[o + 1 * strideb] = (p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3 + 4) >> 3
      dst[o + 2 * strideb] = (p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3 + 4) >> 3
    } else if wd == 6 && flat8in {
      dst[o - 2 * strideb] = (p2 + 2 * p2 + 2 * p1 + 2 * p0 + q0 + 4) >> 3
      dst[o - 1 * strideb] = (p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3
      dst[o + 0] = (p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3
      dst[o + 1 * strideb] = (p0 + 2 * q0 + 2 * q1 + 2 * q2 + q2 + 4) >> 3
    } else {
      let hev = av1_abs(p1 - p0) > h || av1_abs(q1 - q0) > h
      let lim = 128 * (1 << bd8)
      let clip_diff = (v : Int32) => av1_imin(av1_imax(v, -lim), lim - 1)
      if hev {
        let mut f = clip_diff(p1 - q1)
        f = clip_diff(3 * (q0 - p0) + f)
        let f1 = av1_imin(f + 4, lim - 1) >> 3
        let f2 = av1_imin(f + 3, lim - 1) >> 3
        dst[o - 1 * strideb] = av1_lf_clip_pixel(p0 + f2, bpc)
        dst[o + 0] = av1_lf_clip_pixel(q0 - f1, bpc)
      } else {
        let f = clip_diff(3 * (q0 - p0))
        let f1 = av1_imin(f + 4, lim - 1) >> 3
        let f2 = av1_imin(f + 3, lim - 1) >> 3
        dst[o - 1 * strideb] = av1_lf_clip_pixel(p0 + f2, bpc)
        dst[o + 0] = av1_lf_clip_pixel(q0 - f1, bpc)
        let f3 = (f1 + 1) >> 1
        dst[o - 2 * strideb] = av1_lf_clip_pixel(p1 + f3, bpc)
        dst[o + 1 * strideb] = av1_lf_clip_pixel(q1 - f3, bpc)
      }
    }
    o = o + stridea
  }
}

///|
/// `loop_filter_h_sb128y_c`: filter vertical (column) edges of one luma
/// 128-wide stripe.
fn av1_lf_h_y(
  dst : FixedArray[Int32],
  dst_off : Int32,
  stride : Int32,
  vmask : FixedArray[UInt],
  lvl : FixedArray[Int32],
  lvl_off : Int32,
  b4_stride : Int32,
  lut : Av1FilterLut,
  bpc : Int32,
) -> Unit {
  let vm = vmask[0] | vmask[1] | vmask[2]
  let mut y : UInt = 1
  let mut o = dst_off
  let mut li = lvl_off
  while (vm & (y - 1).lnot()) != 0 {
    if (vm & y) != 0 {
      let l0 = lvl[li]
      let l = if l0 != 0 || li < 4 { l0 } else { lvl[li - 4] }
      if l != 0 {
        let idx = if (vmask[2] & y) != 0 {
          2
        } else if (vmask[1] & y) != 0 {
          1
        } else {
          0
        }
        av1_lf_filter(
          dst, o, stride, 1, 4 << idx, bpc, lut.e[l], lut.i[l], l >> 4,
        )
      }
    }
    y = y << 1
    o = o + 4 * stride
    li = li + b4_stride * 4
  }
}

///|
/// `loop_filter_v_sb128y_c`: filter horizontal (row) edges of one luma
/// 128-wide stripe.
fn av1_lf_v_y(
  dst : FixedArray[Int32],
  dst_off : Int32,
  stride : Int32,
  vmask : FixedArray[UInt],
  lvl : FixedArray[Int32],
  lvl_off : Int32,
  b4_stride : Int32,
  lut : Av1FilterLut,
  bpc : Int32,
) -> Unit {
  let vm = vmask[0] | vmask[1] | vmask[2]
  let mut x : UInt = 1
  let mut o = dst_off
  let mut li = lvl_off
  while (vm & (x - 1).lnot()) != 0 {
    if (vm & x) != 0 {
      let l0 = lvl[li]
      let l = if l0 != 0 || li < b4_stride * 4 { l0 } else { lvl[li - b4_stride * 4] }
      if l != 0 {
        let idx = if (vmask[2] & x) != 0 {
          2
        } else if (vmask[1] & x) != 0 {
          1
        } else {
          0
        }
        av1_lf_filter(
          dst, o, 1, stride, 4 << idx, bpc, lut.e[l], lut.i[l], l >> 4,
        )
      }
    }
    x = x << 1
    o = o + 4
    li = li + 4
  }
}

///|
/// `loop_filter_h_sb128uv_c`.
fn av1_lf_h_uv(
  dst : FixedArray[Int32],
  dst_off : Int32,
  stride : Int32,
  vmask : FixedArray[UInt],
  lvl : FixedArray[Int32],
  lvl_off : Int32,
  b4_stride : Int32,
  lut : Av1FilterLut,
  bpc : Int32,
) -> Unit {
  let vm = vmask[0] | vmask[1]
  let mut y : UInt = 1
  let mut o = dst_off
  let mut li = lvl_off
  while (vm & (y - 1).lnot()) != 0 {
    if (vm & y) != 0 {
      let l0 = lvl[li]
      let l = if l0 != 0 || li < 4 { l0 } else { lvl[li - 4] }
      if l != 0 {
        let idx = if (vmask[1] & y) != 0 { 1 } else { 0 }
        av1_lf_filter(
          dst, o, stride, 1, 4 + 2 * idx, bpc, lut.e[l], lut.i[l], l >> 4,
        )
      }
    }
    y = y << 1
    o = o + 4 * stride
    li = li + b4_stride * 4
  }
}

///|
/// `loop_filter_v_sb128uv_c`.
fn av1_lf_v_uv(
  dst : FixedArray[Int32],
  dst_off : Int32,
  stride : Int32,
  vmask : FixedArray[UInt],
  lvl : FixedArray[Int32],
  lvl_off : Int32,
  b4_stride : Int32,
  lut : Av1FilterLut,
  bpc : Int32,
) -> Unit {
  let vm = vmask[0] | vmask[1]
  let mut x : UInt = 1
  let mut o = dst_off
  let mut li = lvl_off
  while (vm & (x - 1).lnot()) != 0 {
    if (vm & x) != 0 {
      let l0 = lvl[li]
      let l = if l0 != 0 || li < b4_stride * 4 { l0 } else { lvl[li - b4_stride * 4] }
      if l != 0 {
        let idx = if (vmask[1] & x) != 0 { 1 } else { 0 }
        av1_lf_filter(
          dst, o, 1, stride, 4 + 2 * idx, bpc, lut.e[l], lut.i[l], l >> 4,
        )
      }
    }
    x = x << 1
    o = o + 4
    li = li + 4
  }
}

///|
fn av1_lf_plane_cols_y(
  f : Av1FrameCtx,
  have_left : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  dst_off : Int32,
  w : Int32,
  starty4 : Int32,
  endy4 : Int32,
) -> Unit {
  let dst = f.planes[0]
  let ls = f.y_stride
  let b4_stride = f.b4_stride
  let hm = FixedArray::make(3, (0 : UInt))
  for x in 0..<w {
    if !have_left && x == 0 {
      continue
    }
    if starty4 == 0 {
      hm[0] = mask.fy[av1_fy_i(0, x, 0, 0)]
      hm[1] = mask.fy[av1_fy_i(0, x, 1, 0)]
      hm[2] = mask.fy[av1_fy_i(0, x, 2, 0)]
      if endy4 > 16 {
        hm[0] = hm[0] | (mask.fy[av1_fy_i(0, x, 0, 1)] << 16)
        hm[1] = hm[1] | (mask.fy[av1_fy_i(0, x, 1, 1)] << 16)
        hm[2] = hm[2] | (mask.fy[av1_fy_i(0, x, 2, 1)] << 16)
      }
    } else {
      hm[0] = mask.fy[av1_fy_i(0, x, 0, 1)]
      hm[1] = mask.fy[av1_fy_i(0, x, 1, 1)]
      hm[2] = mask.fy[av1_fy_i(0, x, 2, 1)]
    }
    av1_lf_h_y(
      dst, dst_off + x * 4, ls, hm, f.lf_level, lvl_off + x * 4, b4_stride,
      f.lf_lut, f.bpc,
    )
  }
}

///|
fn av1_lf_plane_rows_y(
  f : Av1FrameCtx,
  have_top : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  dst_off : Int32,
  w : Int32,
  starty4 : Int32,
  endy4 : Int32,
) -> Unit {
  let dst = f.planes[0]
  let ls = f.y_stride
  let b4_stride = f.b4_stride
  let vm = FixedArray::make(4, (0 : UInt))
  for y in starty4..<endy4 {
    if !have_top && y == 0 {
      continue
    }
    vm[0] = mask.fy[av1_fy_i(1, y, 0, 0)] |
      (mask.fy[av1_fy_i(1, y, 0, 1)] << 16)
    vm[1] = mask.fy[av1_fy_i(1, y, 1, 0)] |
      (mask.fy[av1_fy_i(1, y, 1, 1)] << 16)
    vm[2] = mask.fy[av1_fy_i(1, y, 2, 0)] |
      (mask.fy[av1_fy_i(1, y, 2, 1)] << 16)
    av1_lf_v_y(
      dst, dst_off + (y - starty4) * 4 * ls, ls, vm, f.lf_level, lvl_off +
      (y - starty4) * b4_stride * 4 + 1, b4_stride, f.lf_lut, f.bpc,
    )
  }
  ignore(w)
}

///|
fn av1_lf_plane_cols_uv(
  f : Av1FrameCtx,
  have_left : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  u_off : Int32,
  v_off : Int32,
  w : Int32,
  starty4 : Int32,
  endy4 : Int32,
) -> Unit {
  let u = f.planes[1]
  let v = f.planes[2]
  let ls = f.uv_stride
  let b4_stride = f.b4_stride
  let ss_v = f.ss_v
  let hm = FixedArray::make(3, (0 : UInt))
  for x in 0..<w {
    if !have_left && x == 0 {
      continue
    }
    if starty4 == 0 {
      hm[0] = mask.fuv[av1_fuv_i(0, x, 0, 0)]
      hm[1] = mask.fuv[av1_fuv_i(0, x, 1, 0)]
      if endy4 > (16 >> ss_v) {
        hm[0] = hm[0] | (mask.fuv[av1_fuv_i(0, x, 0, 1)] << (16 >> ss_v))
        hm[1] = hm[1] | (mask.fuv[av1_fuv_i(0, x, 1, 1)] << (16 >> ss_v))
      }
    } else {
      hm[0] = mask.fuv[av1_fuv_i(0, x, 0, 1)]
      hm[1] = mask.fuv[av1_fuv_i(0, x, 1, 1)]
    }
    av1_lf_h_uv(
      u, u_off + x * 4, ls, hm, f.lf_level, lvl_off + x * 4 + 2, b4_stride,
      f.lf_lut, f.bpc,
    )
    av1_lf_h_uv(
      v, v_off + x * 4, ls, hm, f.lf_level, lvl_off + x * 4 + 3, b4_stride,
      f.lf_lut, f.bpc,
    )
  }
}

///|
fn av1_lf_plane_rows_uv(
  f : Av1FrameCtx,
  have_top : Bool,
  lvl_off : Int32,
  mask : Av1Filter,
  u_off : Int32,
  v_off : Int32,
  w : Int32,
  starty4 : Int32,
  endy4 : Int32,
) -> Unit {
  let u = f.planes[1]
  let v = f.planes[2]
  let ls = f.uv_stride
  let b4_stride = f.b4_stride
  let ss_h = f.ss_h
  let vm = FixedArray::make(3, (0 : UInt))
  for y in starty4..<endy4 {
    if !have_top && y == 0 {
      continue
    }
    vm[0] = mask.fuv[av1_fuv_i(1, y, 0, 0)] |
      (mask.fuv[av1_fuv_i(1, y, 0, 1)] << (16 >> ss_h))
    vm[1] = mask.fuv[av1_fuv_i(1, y, 1, 0)] |
      (mask.fuv[av1_fuv_i(1, y, 1, 1)] << (16 >> ss_h))
    av1_lf_v_uv(
      u, u_off + (y - starty4) * 4 * ls, ls, vm, f.lf_level, lvl_off +
      (y - starty4) * b4_stride * 4 + 2, b4_stride, f.lf_lut, f.bpc,
    )
    av1_lf_v_uv(
      v, v_off + (y - starty4) * 4 * ls, ls, vm, f.lf_level, lvl_off +
      (y - starty4) * b4_stride * 4 + 3, b4_stride, f.lf_lut, f.bpc,
    )
  }
  ignore(w)
}

///|
/// `dav1d_loopfilter_sbrow_cols`, including the tile-boundary strength
/// fixups: at tile column/row edges the initial (maximum) transform-size
/// level is clamped against the neighbouring tile's saved `tx_lpf` values.
fn Av1FrameCtx::lf_sbrow_cols(self : Av1FrameCtx, sby : Int32) -> Unit {
  let is_sb64 = if self.seq.use_128x128_superblock { 0 } else { 1 }
  let starty4 = (sby & is_sb64) << 4
  let sbsz = 32 >> is_sb64
  let sbl2 = 5 - is_sb64
  let endy4 = starty4 + av1_imin(self.bh - sby * sbsz, sbsz)
  let uv_endy4 = (endy4 + self.ss_v) >> self.ss_v
  let mask_row = sby >> is_sb64
  let mono = self.seq.monochrome
  // fix lpf strength at tile col boundaries
  if self.tile_cols > 1 {
    let halign = (self.bh + 31) & -32
    let uv_halign = halign >> self.ss_v
    let vshift = 4 - self.ss_v
    let vmax = 1U << (16 >> self.ss_v)
    for tc in 1..<self.tile_cols {
      let x4 = self.tile_col_start4[tc]
      if x4 >= self.bw {
        break
      }
      let bx4 = if is_sb64 != 0 && (x4 & 16) != 0 { 16 } else { 0 }
      let mask = self.lf_mask[mask_row * self.sb128w + (x4 >> 5)]
      let lpf_base = (tc - 1) * halign + (sby << sbl2)
      for y in starty4..<endy4 {
        let bit = 1U << y
        let sidx = if bit >= 0x10000U { 1 } else { 0 }
        let smask = bit >> (sidx * 16)
        let i2 = av1_fy_i(0, bx4, 2, sidx)
        let i1 = av1_fy_i(0, bx4, 1, sidx)
        let i0 = av1_fy_i(0, bx4, 0, sidx)
        let idx = 2 *
            (if (mask.fy[i2] & smask) != (0 : UInt) { 1 } else { 0 }) +
          (if (mask.fy[i1] & smask) != (0 : UInt) { 1 } else { 0 })
        mask.fy[i2] = mask.fy[i2] & smask.lnot()
        mask.fy[i1] = mask.fy[i1] & smask.lnot()
        mask.fy[i0] = mask.fy[i0] & smask.lnot()
        let inew = av1_fy_i(0, bx4, av1_imin(idx, self.tile_lpf_y[lpf_base + (y - starty4)]), sidx)
        mask.fy[inew] = mask.fy[inew] | smask
      }
      if !mono {
        let cbx4 = bx4 >> self.ss_h
        let uv_start = starty4 >> self.ss_v
        let lpf_base = (tc - 1) * uv_halign + ((sby << sbl2) >> self.ss_v)
        let mut vbit = 1U << uv_start
        for y in uv_start..<uv_endy4 {
          let sidx = if vbit >= vmax { 1 } else { 0 }
          let smask = vbit >> (sidx << vshift)
          let i1 = av1_fuv_i(0, cbx4, 1, sidx)
          let i0 = av1_fuv_i(0, cbx4, 0, sidx)
          let idx = if (mask.fuv[i1] & smask) != (0 : UInt) {
            1
          } else {
            0
          }
          mask.fuv[i1] = mask.fuv[i1] & smask.lnot()
          mask.fuv[i0] = mask.fuv[i0] & smask.lnot()
          let inew = av1_fuv_i(
            0,
            cbx4,
            av1_imin(idx, self.tile_lpf_uv[lpf_base + (y - uv_start)]),
            sidx,
          )
          mask.fuv[inew] = mask.fuv[inew] | smask
          vbit = vbit << 1
        }
      }
    }
  }
  // fix lpf strength at tile row boundaries
  let tile_row_above = self.start_of_tile_row[sby]
  if tile_row_above > 0 {
    let hshift = 4 - self.ss_h
    let hmax = 1U << (16 >> self.ss_h)
    for x in 0..<self.sb128w {
      let a = self.a[self.sb128w * (tile_row_above - 1) + x]
      let mask = self.lf_mask[mask_row * self.sb128w + x]
      let w = av1_imin(32, self.bw - x * 32)
      let mut bit = 1U
      for i in 0..<w {
        let sidx = if bit >= 0x10000U { 1 } else { 0 }
        let smask = bit >> (sidx * 16)
        let i2 = av1_fy_i(1, starty4, 2, sidx)
        let i1 = av1_fy_i(1, starty4, 1, sidx)
        let i0 = av1_fy_i(1, starty4, 0, sidx)
        let idx = 2 *
            (if (mask.fy[i2] & smask) != (0 : UInt) { 1 } else { 0 }) +
          (if (mask.fy[i1] & smask) != (0 : UInt) { 1 } else { 0 })
        mask.fy[i2] = mask.fy[i2] & smask.lnot()
        mask.fy[i1] = mask.fy[i1] & smask.lnot()
        mask.fy[i0] = mask.fy[i0] & smask.lnot()
        let inew = av1_fy_i(1, starty4, av1_imin(idx, a.tx_lpf_y[i]), sidx)
        mask.fy[inew] = mask.fy[inew] | smask
        bit = bit << 1
      }
      if !mono {
        let cw = (w + self.ss_h) >> self.ss_h
        let uv_col = starty4 >> self.ss_v
        let mut uvbit = 1U
        for i in 0..<cw {
          let sidx = if uvbit >= hmax { 1 } else { 0 }
          let smask = uvbit >> (sidx << hshift)
          let i1 = av1_fuv_i(1, uv_col, 1, sidx)
          let i0 = av1_fuv_i(1, uv_col, 0, sidx)
          let idx = if (mask.fuv[i1] & smask) != (0 : UInt) {
            1
          } else {
            0
          }
          mask.fuv[i1] = mask.fuv[i1] & smask.lnot()
          mask.fuv[i0] = mask.fuv[i0] & smask.lnot()
          let inew = av1_fuv_i(
            1,
            uv_col,
            av1_imin(idx, a.tx_lpf_uv[i]),
            sidx,
          )
          mask.fuv[inew] = mask.fuv[inew] | smask
          uvbit = uvbit << 1
        }
      }
    }
  }
  let y_off = sby * sbsz * 4 * self.y_stride
  let uv_off = ((sby * sbsz * 4) >> self.ss_v) * self.uv_stride
  let row4 = sby * sbsz
  let lvl_off = row4 * self.b4_stride * 4
  let uv_row4 = row4 >> self.ss_v
  let uv_lvl_off = uv_row4 * self.b4_stride * 4
  let chroma_lf = self.lf_u_active || self.lf_v_active
  for x in 0..<self.sb128w {
    let mask = self.lf_mask[mask_row * self.sb128w + x]
    let w = av1_imin(32, self.bw - x * 32)
    av1_lf_plane_cols_y(
      self, x > 0, lvl_off + x * 32 * 4, mask, y_off + x * 128, w, starty4,
      endy4,
    )
    if chroma_lf {
      let cw = (w + self.ss_h) >> self.ss_h
      av1_lf_plane_cols_uv(
        self, x > 0, uv_lvl_off + x * (32 >> self.ss_h) * 4, mask,
        uv_off + x * (128 >> self.ss_h), uv_off + x * (128 >> self.ss_h), cw,
        starty4 >> self.ss_v, uv_endy4,
      )
    }
  }
}

///|
/// `dav1d_loopfilter_sbrow_rows`.
fn Av1FrameCtx::lf_sbrow_rows(self : Av1FrameCtx, sby : Int32) -> Unit {
  let is_sb64 = if self.seq.use_128x128_superblock { 0 } else { 1 }
  let starty4 = (sby & is_sb64) << 4
  let sbsz = 32 >> is_sb64
  let endy4 = starty4 + av1_imin(self.bh - sby * sbsz, sbsz)
  let uv_endy4 = (endy4 + self.ss_v) >> self.ss_v
  let y_off = sby * sbsz * 4 * self.y_stride
  let uv_off = ((sby * sbsz * 4) >> self.ss_v) * self.uv_stride
  let row4 = sby * sbsz
  let lvl_off = row4 * self.b4_stride * 4
  let uv_row4 = row4 >> self.ss_v
  let uv_lvl_off = uv_row4 * self.b4_stride * 4
  let mask_row = sby >> is_sb64
  let chroma_lf = self.lf_u_active || self.lf_v_active
  for x in 0..<self.sb128w {
    let mask = self.lf_mask[mask_row * self.sb128w + x]
    let w = av1_imin(32, self.bw - x * 32)
    av1_lf_plane_rows_y(
      self, sby > 0, lvl_off + x * 32 * 4, mask, y_off + x * 128, w, starty4,
      endy4,
    )
    if chroma_lf {
      let cw = (w + self.ss_h) >> self.ss_h
      av1_lf_plane_rows_uv(
        self, sby > 0, uv_lvl_off + x * (32 >> self.ss_h) * 4, mask,
        uv_off + x * (128 >> self.ss_h), uv_off + x * (128 >> self.ss_h), cw,
        starty4 >> self.ss_v, uv_endy4,
      )
    }
  }
}

///|
/// Apply the deblocking filter to a fully decoded frame, one superblock row
/// at a time (columns then rows).
fn Av1FrameCtx::loop_filter_frame(self : Av1FrameCtx) -> Unit {
  if !self.lf_y_active {
    return
  }
  let sb_rows = (self.bh + self.sb_step - 1) / self.sb_step
  for sby in 0..<sb_rows {
    self.lf_sbrow_cols(sby)
    self.lf_sbrow_rows(sby)
  }
}

///|
/// LF kernel entry exposed for the `lf_kernel` regression package, which
/// compares it against dav1d's `loop_filter` on randomized inputs.
pub fn av1_lf_filter_kernel(
  dst : FixedArray[Int32],
  off : Int32,
  stridea : Int32,
  strideb : Int32,
  wd : Int32,
  e : Int32,
  i : Int32,
  h : Int32,
) -> Unit {
  av1_lf_filter(dst, off, stridea, strideb, wd, 8, e, i, h)
}
