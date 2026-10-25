///|
/// AV1 constrained directional enhancement filter (CDEF).
///
/// Port of dav1d 1.5.1 `src/cdef_tmpl.c` (direction search + constrained
/// filter) and the single-threaded core of `src/cdef_apply_tmpl.c`
/// (`dav1d_cdef_brow`). dav1d is BSD-2-Clause (Copyright © 2018, VideoLAN
/// and dav1d authors; Copyright © 2018, Two Orioles, LLC); this port keeps
/// the same algorithm with LGPL-2.1-or-later packaging.
///
/// Instead of dav1d's rolling 2-line backups the whole loop-filtered frame
/// is snapshotted first: CDEF filters every 8x8 block from the pre-CDEF
/// pixels, so a frame-sized copy is equivalent and much simpler.

///|
/// `dav1d_cdef_directions[12][2]` flattened (offsets with luma row stride 12).
let av1_cdef_directions : FixedArray[Int] = [
  1 * 12 + 0, 2 * 12 + 0, // 6
  1 * 12 + 0, 2 * 12 - 1, // 7
  -1 * 12 + 1, -2 * 12 + 2, // 0
  0 * 12 + 1, -1 * 12 + 2, // 1
  0 * 12 + 1, 0 * 12 + 2, // 2
  0 * 12 + 1, 1 * 12 + 2, // 3
  1 * 12 + 1, 2 * 12 + 2, // 4
  1 * 12 + 0, 2 * 12 + 1, // 5
  1 * 12 + 0, 2 * 12 + 0, // 6
  1 * 12 + 0, 2 * 12 - 1, // 7
  -1 * 12 + 1, -2 * 12 + 2, // 0
  0 * 12 + 1, -1 * 12 + 2, // 1
]

///|
fn av1_cdef_constrain(diff : Int32, threshold : Int32, shift : Int32) -> Int32 {
  let adiff = av1_abs(diff)
  let v = av1_imin(adiff, av1_imax(0, threshold - (adiff >> shift)))
  if diff < 0 {
    -v
  } else {
    v
  }
}

///|
/// `cdef_find_dir_c`: returns (direction, variance).
fn av1_cdef_find_dir(
  img : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  bpc : Int32,
) -> (Int32, UInt) {
  let bd8 = bpc - 8
  let psum_hv = FixedArray::make(16, 0) // [2][8]
  let psum_diag = FixedArray::make(30, 0) // [2][15]
  let psum_alt = FixedArray::make(44, 0) // [4][11]
  for y in 0..<8 {
    for x in 0..<8 {
      let px = (img[off + y * stride + x] >> bd8) - 128
      psum_diag[0 * 15 + y + x] = psum_diag[0 * 15 + y + x] + px
      psum_alt[0 * 11 + y + (x >> 1)] = psum_alt[0 * 11 + y + (x >> 1)] + px
      psum_hv[0 * 8 + y] = psum_hv[0 * 8 + y] + px
      psum_alt[1 * 11 + 3 + y - (x >> 1)] = psum_alt[1 * 11 + 3 + y - (x >> 1)] +
        px
      psum_diag[1 * 15 + 7 + y - x] = psum_diag[1 * 15 + 7 + y - x] + px
      psum_alt[2 * 11 + 3 - (y >> 1) + x] = psum_alt[2 * 11 + 3 - (y >> 1) + x] +
        px
      psum_hv[1 * 8 + x] = psum_hv[1 * 8 + x] + px
      psum_alt[3 * 11 + (y >> 1) + x] = psum_alt[3 * 11 + (y >> 1) + x] + px
    }
  }
  let cost = FixedArray::make(8, (0 : UInt))
  for n in 0..<8 {
    cost[2] = cost[2] +
      (psum_hv[0 * 8 + n] * psum_hv[0 * 8 + n]).reinterpret_as_uint()
    cost[6] = cost[6] +
      (psum_hv[1 * 8 + n] * psum_hv[1 * 8 + n]).reinterpret_as_uint()
  }
  cost[2] = cost[2] * 105U
  cost[6] = cost[6] * 105U
  let div_table : FixedArray[Int32] = [840, 420, 280, 210, 168, 140, 120]
  for n in 0..<7 {
    let d = div_table[n]
    let a0 = psum_diag[0 * 15 + n]
    let b0 = psum_diag[0 * 15 + 14 - n]
    cost[0] = cost[0] + ((a0 * a0 + b0 * b0) * d).reinterpret_as_uint()
    let a1 = psum_diag[1 * 15 + n]
    let b1 = psum_diag[1 * 15 + 14 - n]
    cost[4] = cost[4] + ((a1 * a1 + b1 * b1) * d).reinterpret_as_uint()
  }
  cost[0] = cost[0] +
    (psum_diag[0 * 15 + 7] * psum_diag[0 * 15 + 7] * 105).reinterpret_as_uint()
  cost[4] = cost[4] +
    (psum_diag[1 * 15 + 7] * psum_diag[1 * 15 + 7] * 105).reinterpret_as_uint()
  for n in 0..<4 {
    let ci = n * 2 + 1
    let mut c : UInt = 0
    for m in 0..<5 {
      let v = psum_alt[n * 11 + 3 + m]
      c = c + (v * v).reinterpret_as_uint()
    }
    c = c * 105U
    for m in 0..<3 {
      let d = div_table[2 * m + 1]
      let a = psum_alt[n * 11 + m]
      let b = psum_alt[n * 11 + 10 - m]
      c = c + ((a * a + b * b) * d).reinterpret_as_uint()
    }
    cost[ci] = cost[ci] + c
  }
  let mut best_dir : Int32 = 0
  let mut best_cost = cost[0]
  for n in 1..<8 {
    if cost[n] > best_cost {
      best_cost = cost[n]
      best_dir = n
    }
  }
  let variance = (best_cost - cost[(best_dir ^ 4)]) >> 10
  (best_dir, variance)
}

///|
fn av1_cdef_adjust_strength(strength : Int32, variance : UInt) -> Int32 {
  if variance == 0 {
    return 0
  }
  let v = variance.reinterpret_as_int()
  let i = if (v >> 6) != 0 { av1_imin(av1_ulog2((v >> 6).reinterpret_as_uint()), 12) } else { 0 }
  (strength * (4 + i) + 8) >> 4
}

///|
/// `cdef_filter_block_c` for 8/10/12-bit planes. Reads the padded 12x12
/// neighborhood from the pre-CDEF snapshot and writes the filtered 8x8/4x8/4x4
/// block into `dst`.
fn av1_cdef_filter_block(
  snap : FixedArray[Int32],
  dst : FixedArray[Int32],
  x0 : Int32,
  y0 : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
  have_top : Bool,
  have_bottom : Bool,
  have_left : Bool,
  have_right : Bool,
  pri_strength : Int32,
  sec_strength : Int32,
  dir : Int32,
  damping : Int32,
  bpc : Int32,
) -> Unit {
  let tmp = FixedArray::make(144, 0)
  let ts = 12
  let mut x_start = -2
  let mut x_end = w + 2
  let mut y_start = -2
  let mut y_end = h + 2
  if !have_top {
    for y in -2..<0 {
      for x in 0..<ts {
        tmp[(y + 2) * ts + x] = -32768
      }
    }
    y_start = 0
  }
  if !have_bottom {
    for y in h..<(h + 2) {
      for x in 0..<ts {
        tmp[(y + 2) * ts + x] = -32768
      }
    }
    y_end = h
  }
  if !have_left {
    for y in y_start..<y_end {
      tmp[(y + 2) * ts + 0] = -32768
      tmp[(y + 2) * ts + 1] = -32768
    }
    x_start = 0
  }
  if !have_right {
    for y in y_start..<y_end {
      tmp[(y + 2) * ts + (w + 2)] = -32768
      tmp[(y + 2) * ts + (w + 3)] = -32768
    }
    x_end = w
  }
  for y in y_start..<0 {
    for x in x_start..<x_end {
      tmp[(y + 2) * ts + (x + 2)] = snap[(y0 + y) * stride + x0 + x]
    }
  }
  for y in 0..<h {
    for x in x_start..<0 {
      tmp[(y + 2) * ts + (x + 2)] = snap[(y0 + y) * stride + x0 + x]
    }
    for x in 0..<x_end {
      tmp[(y + 2) * ts + (x + 2)] = snap[(y0 + y) * stride + x0 + x]
    }
  }
  for y in h..<y_end {
    for x in x_start..<x_end {
      tmp[(y + 2) * ts + (x + 2)] = snap[(y0 + y) * stride + x0 + x]
    }
  }
  let bd8 = bpc - 8
  let pri_tap = 4 - ((pri_strength >> bd8) & 1)
  let pri_shift = if pri_strength != 0 {
    av1_imax(0, damping - av1_ulog2(pri_strength.reinterpret_as_uint()))
  } else {
    0
  }
  let sec_shift = if sec_strength != 0 {
    damping - av1_ulog2(sec_strength.reinterpret_as_uint())
  } else {
    0
  }
  let pixel_max = (1 << bpc) - 1
  let round = (sum : Int32) => (sum - (if sum < 0 { 1 } else { 0 }) + 8) >> 4
  for y in 0..<h {
    for x in 0..<w {
      let px = snap[(y0 + y) * stride + x0 + x]
      let tb = (y + 2) * ts + (x + 2)
      let mut sum = 0
      let mut vmin = px
      let mut vmax = px
      if pri_strength != 0 && sec_strength != 0 {
        let mut pri_tap_k = pri_tap
        for k in 0..<2 {
          let off1 = av1_cdef_directions[(dir + 2) * 2 + k]
          let off2 = av1_cdef_directions[(dir + 4) * 2 + k]
          let off3 = av1_cdef_directions[dir * 2 + k]
          let p0 = tmp[tb + off1]
          let p1 = tmp[tb - off1]
          sum = sum +
            pri_tap_k * av1_cdef_constrain(p0 - px, pri_strength, pri_shift)
          sum = sum +
            pri_tap_k * av1_cdef_constrain(p1 - px, pri_strength, pri_shift)
          pri_tap_k = (pri_tap_k & 3) | 2
          vmin = av1_umin_int(vmin, p0)
          vmax = av1_imax(vmax, p0)
          vmin = av1_umin_int(vmin, p1)
          vmax = av1_imax(vmax, p1)
          let s0 = tmp[tb + off2]
          let s1 = tmp[tb - off2]
          let s2 = tmp[tb + off3]
          let s3 = tmp[tb - off3]
          let sec_tap = 2 - k
          sum = sum +
            sec_tap * av1_cdef_constrain(s0 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s1 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s2 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s3 - px, sec_strength, sec_shift)
          vmin = av1_umin_int(vmin, s0)
          vmax = av1_imax(vmax, s0)
          vmin = av1_umin_int(vmin, s1)
          vmax = av1_imax(vmax, s1)
          vmin = av1_umin_int(vmin, s2)
          vmax = av1_imax(vmax, s2)
          vmin = av1_umin_int(vmin, s3)
          vmax = av1_imax(vmax, s3)
        }
        let v = av1_imin(av1_imax(px + round(sum), vmin), vmax)
        dst[(y0 + y) * stride + x0 + x] = v
      } else if pri_strength != 0 {
        let mut pri_tap_k = pri_tap
        for k in 0..<2 {
          let off = av1_cdef_directions[(dir + 2) * 2 + k]
          let p0 = tmp[tb + off]
          let p1 = tmp[tb - off]
          sum = sum +
            pri_tap_k * av1_cdef_constrain(p0 - px, pri_strength, pri_shift)
          sum = sum +
            pri_tap_k * av1_cdef_constrain(p1 - px, pri_strength, pri_shift)
          pri_tap_k = (pri_tap_k & 3) | 2
        }
        let v = av1_imin(av1_imax(px + round(sum), 0), pixel_max)
        dst[(y0 + y) * stride + x0 + x] = v
      } else {
        for k in 0..<2 {
          let off1 = av1_cdef_directions[(dir + 4) * 2 + k]
          let off2 = av1_cdef_directions[dir * 2 + k]
          let s0 = tmp[tb + off1]
          let s1 = tmp[tb - off1]
          let s2 = tmp[tb + off2]
          let s3 = tmp[tb - off2]
          let sec_tap = 2 - k
          sum = sum +
            sec_tap * av1_cdef_constrain(s0 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s1 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s2 - px, sec_strength, sec_shift)
          sum = sum +
            sec_tap * av1_cdef_constrain(s3 - px, sec_strength, sec_shift)
        }
        let v = av1_imin(av1_imax(px + round(sum), 0), pixel_max)
        dst[(y0 + y) * stride + x0 + x] = v
      }
    }
  }
}

///|
/// Unsigned min of a pixel sample (values are non-negative except the
/// INT16_MIN padding markers, which must lose like C's `umin`).
fn av1_umin_int(a : Int32, b : Int32) -> Int32 {
  let ua = a.reinterpret_as_uint()
  let ub = b.reinterpret_as_uint()
  if ua < ub { a } else { b }
}

///|
/// CDEF planning state derived from the frame header.
priv struct Av1CdefParams {
  y_strength : Array[Int32]
  uv_strength : Array[Int32]
  damping : Int32
}

///|
fn av1_cdef_params(hdr : Av1FrameHeader, bpc : Int32) -> Av1CdefParams {
  let y_s : Array[Int32] = []
  let uv_s : Array[Int32] = []
  for i in 0..<hdr.cdef_y_pri_strength.length() {
    y_s.push(hdr.cdef_y_pri_strength[i] * 4 + hdr.cdef_y_sec_strength[i])
    if i < hdr.cdef_uv_pri_strength.length() {
      uv_s.push(hdr.cdef_uv_pri_strength[i] * 4 + hdr.cdef_uv_sec_strength[i])
    }
  }
  {
    y_strength: y_s,
    uv_strength: uv_s,
    damping: hdr.cdef_damping_minus_3 + 3 + (bpc - 8),
  }
}

///|
fn av1_copy_plane(p : FixedArray[Int32]) -> FixedArray[Int32] {
  let out = FixedArray::make(p.length(), 0)
  for i in 0..<p.length() {
    out[i] = p[i]
  }
  out
}

///|
fn av1_cdef_active(p : Av1CdefParams) -> Bool {
  for v in p.y_strength {
    if v != 0 {
      return true
    }
  }
  for v in p.uv_strength {
    if v != 0 {
      return true
    }
  }
  false
}

///|
/// Apply CDEF over the whole frame (after the loop filter). `snap_*` are
/// pre-CDEF copies of the planes.
fn Av1FrameCtx::cdef_frame(
  self : Av1FrameCtx,
  p : Av1CdefParams,
  snap0 : FixedArray[Int32],
  snap1 : FixedArray[Int32],
  snap2 : FixedArray[Int32],
) -> Unit {
  let ss_v = self.ss_v
  let ss_h = self.ss_h
  let layout_422 = ss_h == 1 && ss_v == 0
  let uv_dirs : FixedArray[Int32] = if layout_422 {
    [7, 0, 2, 4, 5, 6, 6, 6]
  } else {
    [0, 1, 2, 3, 4, 5, 6, 7]
  }
  let bd8 = self.bpc - 8
  let mut by4 : Int32 = 0
  while by4 < self.bh {
    let by_idx = ((by4 & 30) >> 1)
    let have_top = by4 > 0
    let have_bottom = by4 + 2 < self.bh
    let mut bx4 : Int32 = 0
    while bx4 < self.bw {
      let sb128x = bx4 >> 5
      let mask = self.lf_mask[
        ((by4 >> 5) * self.sb128w + sb128x)
      ]
      let sb64_idx = (((by4 & 16) >> 3) + ((bx4 & 16) >> 4))
      let cdef_idx = mask.cdef_idx[sb64_idx]
      let y_lvl = if cdef_idx >= 0 && cdef_idx < p.y_strength.length() {
        p.y_strength[cdef_idx]
      } else {
        0
      }
      let uv_lvl = if cdef_idx >= 0 && cdef_idx < p.uv_strength.length() {
        p.uv_strength[cdef_idx]
      } else {
        0
      }
      if y_lvl == 0 && uv_lvl == 0 {
        bx4 = bx4 + 2
        continue
      }
      let noskip = (mask.noskip[by_idx * 2 + 1] << 16) | mask.noskip[by_idx * 2]
      let bx_mask : UInt = (3 : UInt) << (bx4 & 30)
      if (noskip & bx_mask) == 0 {
        bx4 = bx4 + 2
        continue
      }
      let have_left = bx4 > 0
      let have_right = bx4 + 2 < self.bw
      let y_pri_lvl = (y_lvl >> 2) << bd8
      let mut y_sec_lvl = y_lvl & 3
      if y_sec_lvl == 3 {
        y_sec_lvl = 4
      }
      y_sec_lvl = y_sec_lvl << bd8
      let uv_pri_lvl = (uv_lvl >> 2) << bd8
      let mut uv_sec_lvl = uv_lvl & 3
      if uv_sec_lvl == 3 {
        uv_sec_lvl = 4
      }
      uv_sec_lvl = uv_sec_lvl << bd8
      let mut dir : Int32 = 0
      let mut variance : UInt = 0
      if y_pri_lvl != 0 || uv_pri_lvl != 0 {
        let (d, v) = av1_cdef_find_dir(
          snap0, (by4 * 4) * self.y_stride + bx4 * 4, self.y_stride, self.bpc,
        )
        dir = d
        variance = v
      }
      if y_pri_lvl != 0 || y_sec_lvl != 0 {
        let adj = if y_pri_lvl != 0 {
          av1_cdef_adjust_strength(y_pri_lvl, variance)
        } else {
          0
        }
        if adj != 0 || y_sec_lvl != 0 {
          // dav1d passes dir=0 for the secondary-only luma case.
          let ydir = if y_pri_lvl != 0 { dir } else { 0 }
          av1_cdef_filter_block(
            snap0, self.planes[0], bx4 * 4, by4 * 4, self.y_stride, 8, 8,
            have_top, have_bottom, have_left, have_right, adj, y_sec_lvl, ydir,
            p.damping, self.bpc,
          )
        }
      }
      if uv_lvl != 0 && !self.seq.monochrome {
        let uvdir = if uv_pri_lvl != 0 { uv_dirs[dir] } else { 0 }
        let cw = 8 >> ss_h
        let ch = 8 >> ss_v
        let mut pl = 1
        while pl <= 2 {
          av1_cdef_filter_block(
            if pl == 1 { snap1 } else { snap2 }, self.planes[pl],
            (bx4 * 4) >> ss_h, (by4 * 4) >> ss_v, self.uv_stride, cw, ch,
            have_top, have_bottom, have_left, have_right, uv_pri_lvl,
            uv_sec_lvl, uvdir, p.damping - 1, self.bpc,
          )
          pl = pl + 1
        }
      }
      bx4 = bx4 + 2
    }
    by4 = by4 + 2
  }
}
