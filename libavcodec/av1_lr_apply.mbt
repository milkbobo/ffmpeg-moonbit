///|
/// AV1 loop-restoration application: port of dav1d 1.5.1
/// `src/lr_apply_tmpl.c` plus the `lr_lpf_line` backup from
/// `src/lf_apply_tmpl.c` (`backup_lpf`), single-threaded, no superres.
///
/// Our decoder runs the whole-frame deblocking filter first and CDEF second,
/// so the "loop filtered, pre-CDEF" picture needed by the restoration stripe
/// boundaries is passed in as a snapshot (`pre`). Restoration output is
/// written in place into the current (CDEF'd) planes, exactly like dav1d
/// writes into `sr_cur`.

///|
/// `backup4xU`: copy four columns of `u` rows into a `[rows][4]` border buffer.
fn av1_lr_backup4x_u(
  dst : FixedArray[Int32],
  dst_row : Int,
  src : FixedArray[Int32],
  src_off : Int,
  src_stride : Int,
  u : Int,
) -> Unit {
  for r in 0..<u {
    for i in 0..<4 {
      dst[(dst_row + r) * 4 + i] = src[src_off + r * src_stride + i]
    }
  }
}

///|
/// `backup_lpf` for the LR backup buffer (single thread, no resize).
/// `dst` is a 12-row buffer with row stride `dst_stride`; `src` is the
/// post-deblock, pre-CDEF plane.
fn av1_lr_backup_lpf(
  dst : FixedArray[Int32],
  dst_stride : Int,
  src : FixedArray[Int32],
  src_off : Int,
  src_stride : Int,
  ss_ver : Int,
  sb128 : Int,
  row : Int,
  row_h : Int,
  src_w : Int,
  h : Int,
) -> Unit {
  let mut stripe_h = (64 - 8 * (if row == 0 { 1 } else { 0 })) >> ss_ver
  let mut s_off = src_off + (stripe_h - 2) * src_stride
  if row != 0 {
    let top = 4 << sb128
    for k in 0..<4 {
      for i in 0..<src_w {
        dst[k * dst_stride + i] = dst[(top + k) * dst_stride + i]
      }
    }
  }
  let mut dst_row = 4
  let mut r = row
  while r + stripe_h <= row_h {
    let n_lines = 4 - (if r + stripe_h + 1 == h { 1 } else { 0 })
    for i in 0..<4 {
      if i == n_lines {
        for xx in 0..<src_w {
          dst[dst_row * dst_stride + xx] = dst[(dst_row - 1) * dst_stride + xx]
        }
      } else {
        for xx in 0..<src_w {
          dst[dst_row * dst_stride + xx] = src[s_off + xx]
        }
      }
      dst_row = dst_row + 1
      s_off = s_off + src_stride
    }
    r = r + stripe_h
    stripe_h = 64 >> ss_ver
    s_off = s_off + (stripe_h - 4) * src_stride
  }
}

///|
/// One `lr_stripe` call: build the filter parameters from the unit and run the
/// kernel over the stripe.
fn av1_lr_stripe(
  f : Av1FrameCtx,
  plane_idx : Int,
  unit : Av1RestorationUnit,
  x : Int,
  y : Int,
  unit_w : Int,
  row_h : Int,
  sby : Int,
  sbh : Int,
  edges0 : Int,
  left : FixedArray[Int32]?,
  left_off : Int,
  lpf : FixedArray[Int32],
  lpf_width : Int,
) -> Unit {
  let chroma = plane_idx != 0
  let stride = if chroma { f.uv_stride } else { f.y_stride }
  let plane = f.planes[plane_idx]
  let ss_ver = if chroma && f.ss_v != 0 { 1 } else { 0 }
  let mut edges = edges0
  let mut yy = y
  let mut p_off = y * stride + x
  let mut lpf_row = 0
  let mut stripe_h = av1_imin(
    (64 - 8 * (if y == 0 { 1 } else { 0 })) >> ss_ver,
    row_h - y,
  )
  while yy + stripe_h <= row_h {
    let have_bottom = sby + 1 != sbh || yy + stripe_h != row_h
    edges = if have_bottom {
      edges | av1_lr_have_bottom
    } else {
      edges & (-1 - av1_lr_have_bottom)
    }
    let lp = lpf_row * lpf_width + x
    if unit.typ == 2 {
      let fh = FixedArray::make(8, 0)
      let fv = FixedArray::make(8, 0)
      fh[0] = unit.filter_h[0]
      fh[6] = unit.filter_h[0]
      fh[1] = unit.filter_h[1]
      fh[5] = unit.filter_h[1]
      fh[2] = unit.filter_h[2]
      fh[4] = unit.filter_h[2]
      fh[3] = -(unit.filter_h[0] + unit.filter_h[1] + unit.filter_h[2]) * 2 +
        (if f.bpc != 8 { 128 } else { 0 })
      fv[0] = unit.filter_v[0]
      fv[6] = unit.filter_v[0]
      fv[1] = unit.filter_v[1]
      fv[5] = unit.filter_v[1]
      fv[2] = unit.filter_v[2]
      fv[4] = unit.filter_v[2]
      fv[3] = 128 - (unit.filter_v[0] + unit.filter_v[1] + unit.filter_v[2]) * 2
      av1_lr_wiener(plane, p_off, stride, left, left_off, lpf, lp, unit_w,
        stripe_h, fh, fv, edges, f.bpc)
    } else {
      let sgr_idx = unit.typ - 3
      let s0 = av1_sgr_params[sgr_idx * 2]
      let s1 = av1_sgr_params[sgr_idx * 2 + 1]
      let w0 = unit.sgr_weights[0]
      let w1 = 128 - (unit.sgr_weights[0] + unit.sgr_weights[1])
      if s0 == 0 {
        av1_lr_sgr3(plane, p_off, stride, left, left_off, lpf, lp, unit_w,
          stripe_h, s1, w1, edges, f.bpc)
      } else if s1 == 0 {
        av1_lr_sgr5(plane, p_off, stride, left, left_off, lpf, lp, unit_w,
          stripe_h, s0, w0, edges, f.bpc)
      } else {
        av1_lr_sgr_mix(plane, p_off, stride, left, left_off, lpf, lp, unit_w,
          stripe_h, s0, s1, w0, w1, edges, f.bpc)
      }
    }
    yy = yy + stripe_h
    p_off = p_off + stripe_h * stride
    edges = edges | av1_lr_have_top
    stripe_h = av1_imin(64 >> ss_ver, row_h - yy)
    if stripe_h == 0 {
      break
    }
    lpf_row = lpf_row + 4
  }
}

///|
/// `lr_sbrow`: run one plane's restoration for superblock row `sby`.
fn av1_lr_sbrow(
  f : Av1FrameCtx,
  plane_idx : Int,
  sby : Int,
  y : Int,
  row_h : Int,
  lpf : FixedArray[Int32],
  lpf_width : Int,
) -> Unit {
  let chroma = plane_idx != 0
  let ss_ver = if chroma && f.ss_v != 0 { 1 } else { 0 }
  let ss_hor = if chroma && f.ss_h != 0 { 1 } else { 0 }
  let plane_h = if chroma { (f.hdr.height + f.ss_v) >> f.ss_v } else {
    f.hdr.height
  }
  let plane_w = if chroma { (f.hdr.width + f.ss_h) >> f.ss_h } else {
    f.hdr.width
  }
  let stride = if chroma { f.uv_stride } else { f.y_stride }
  let unit_size = 1 << f.hdr.lr_unit_size[if chroma { 1 } else { 0 }]
  let half = unit_size >> 1
  let max_unit = unit_size + half
  let row_y = y + (8 >> ss_ver) * (if y != 0 { 1 } else { 0 })
  let mut aligned = row_y & -unit_size
  if aligned != 0 && aligned + half > plane_h {
    aligned = aligned - unit_size
  }
  aligned = aligned << ss_ver
  let sb_idx = (aligned >> 7) * f.sb128w
  let unit_idx = ((aligned >> 6) & 1) << 1
  let shift_hor = 7 - ss_hor
  let sbh = (f.bh + f.sb_step - 1) / f.sb_step
  let mut edges = (if y > 0 { av1_lr_have_top } else { 0 }) |
    av1_lr_have_right
  let border_rows = row_h - y
  let border = FixedArray::make(2 * 132 * 4, 0)
  let mut cur = f.lf_mask[sb_idx].lr[plane_idx * 4 + unit_idx]
  let mut restore = cur.typ != 0
  let mut x = 0
  let mut bit = 0
  while x + max_unit <= plane_w {
    let next_x = x + unit_size
    let next_uidx = unit_idx + ((next_x >> (shift_hor - 1)) & 1)
    let next_unit = f.lf_mask[sb_idx + (next_x >> shift_hor)].lr[plane_idx *
      4 +
      next_uidx]
    let restore_next = next_unit.typ != 0
    if restore_next {
      av1_lr_backup4x_u(
        border,
        bit * 132,
        f.planes[plane_idx],
        y * stride + x + unit_size - 4,
        stride,
        border_rows,
      )
    }
    if restore {
      av1_lr_stripe(
        f,
        plane_idx,
        cur,
        x,
        y,
        unit_size,
        row_h,
        sby,
        sbh,
        edges,
        Some(border),
        (1 - bit) * 132 * 4,
        lpf,
        lpf_width,
      )
    }
    x = next_x
    cur = next_unit
    restore = restore_next
    bit = 1 - bit
    edges = edges | av1_lr_have_left
  }
  if restore {
    av1_lr_stripe(
      f,
      plane_idx,
      cur,
      x,
      y,
      plane_w - x,
      row_h,
      sby,
      sbh,
      edges & (-1 - av1_lr_have_right),
      Some(border),
      (1 - bit) * 132 * 4,
      lpf,
      lpf_width,
    )
  }
}

///|
/// Run loop restoration for the whole frame, in dav1d's per-SB-row order.
/// `pre0/pre1/pre2` are the post-deblock, pre-CDEF planes.
fn Av1FrameCtx::lr_frame(
  self : Av1FrameCtx,
  pre0 : FixedArray[Int32],
  pre1 : FixedArray[Int32],
  pre2 : FixedArray[Int32],
) -> Unit {
  let sb128 = if self.sb_step == 32 { 1 } else { 0 }
  let sbh = (self.bh + self.sb_step - 1) / self.sb_step
  let snap = [pre0, pre1, pre2]
  // The 12-row backup buffer is persistent across SB rows: the top 4 rows of
  // each row are copied from the previous row's buffer (dav1d's lr_lpf_line).
  let lpfs : FixedArray[FixedArray[Int32]] = [
    FixedArray::make(12 * self.y_stride, 0),
    FixedArray::make(12 * self.uv_stride, 0),
    FixedArray::make(12 * self.uv_stride, 0),
  ]
  for sby in 0..<sbh {
    for plane_idx in 0..<3 {
      if (self.restore_planes & (1 << plane_idx)) == 0 {
        continue
      }
      let chroma = plane_idx != 0
      let ss_ver = if chroma && self.ss_v != 0 { 1 } else { 0 }
      let ss_hor = if chroma && self.ss_h != 0 { 1 } else { 0 }
      let plane_h = if chroma {
        (self.hdr.height + self.ss_v) >> self.ss_v
      } else {
        self.hdr.height
      }
      let stride = if chroma { self.uv_stride } else { self.y_stride }
      let not_last = sby + 1 < sbh
      let y = (sby << ((6 - ss_ver) + sb128)) -
        ((8 * (if sby > 0 { 1 } else { 0 })) >> ss_ver)
      let row_h = av1_imin(
        ((sby + 1) << ((6 - ss_ver) + sb128)) -
        ((8 >> ss_ver) * (if not_last { 1 } else { 0 })),
        plane_h,
      )
      let lpf_width = stride
      let lpf = lpfs[plane_idx]
      let src_w = if chroma {
        self.bw << (2 - ss_hor)
      } else {
        self.bw << 2
      }
      let bak_row_h = av1_imin(
        (sby + 1) << ((6 - ss_ver) + sb128),
        plane_h - 1,
      )
      av1_lr_backup_lpf(
        lpf,
        lpf_width,
        snap[plane_idx],
        y * stride,
        stride,
        ss_ver,
        sb128,
        y,
        bak_row_h,
        src_w,
        plane_h,
      )
      av1_lr_sbrow(self, plane_idx, sby, y, row_h, lpf, lpf_width)
    }
  }
}
