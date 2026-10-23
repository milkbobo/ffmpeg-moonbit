///|
/// MoonBit port of the VP9 inter-frame reconstruction from FFmpeg 9.0.2
/// `libavcodec/vp9dsp_template.c` (the 8-bit MC kernels),
/// `libavcodec/vp9recon.c` (`mc_luma_unscaled`, `mc_chroma_unscaled`,
/// `inter_recon`) and `libavcodec/vp9_mc_template.c` (`inter_pred`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Scope: 8-bit, unscaled references (equal frame dimensions); subsampling
/// follows the current frame (`ss_h`/`ss_v`), with the C's sub-8x8 chroma
/// granularity and its `webm/issues/993` quirks preserved.  The C dispatches
/// through `dsp->mc[bwl][filter][comp][mx][my]`; the equivalent here is
/// `mc_kernel` selected by (phase-x, phase-y) directly.  Edge emulation
/// mirrors `videodsp.emulated_edge_mc` into a scratch buffer like
/// `td->edge_emu_buffer`.  Scaled-reference MC (`mc_*_scaled`) is a later
/// slice.

///|
/// `ROUNDED_DIV(a, 2)`: away-from-zero rounding on halves.
fn vp9_rounded_div2(a : Int32) -> Int32 {
  if a > 0 {
    (a + 1) / 2
  } else {
    (a - 1) / 2
  }
}

///|
/// `ROUNDED_DIV(a, 4)`.
fn vp9_rounded_div4(a : Int32) -> Int32 {
  if a > 0 {
    (a + 2) / 4
  } else {
    (a - 2) / 4
  }
}


///|
/// `emulated_edge_mc` (videodsp semantics, 8-bit): copy a `bw x bh` block
/// whose top-left corner sits at frame coordinates (`x`, `y`) — possibly
/// outside the `w x h` frame — into `buf` at `buf_off`, replicating frame
/// edges.  `src_off` addresses the block's top-left pixel (which may lie
/// before the plane start when `x`/`y` are negative).
fn vp9_emulated_edge(
  buf : FixedArray[Int32],
  buf_off : Int32,
  buf_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  bw : Int32,
  bh : Int32,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
) -> Unit {
  // src_off == frame_origin + y * src_stride + x; address frame pixel
  // (sx, sy) as src_off + (sy - y) * stride + (sx - x)
  for j in 0..<bh {
    let fy = y + j
    let sy = if fy < 0 {
      0
    } else if fy >= h {
      h - 1
    } else {
      fy
    }
    let row = src_off + (sy - y) * src_stride
    let orow = buf_off + j * buf_stride
    if x >= 0 && x + bw <= w {
      for i in 0..<bw {
        buf[orow + i] = src[row + i]
      }
    } else {
      for i in 0..<bw {
        let fx = x + i
        let sx = if fx < 0 {
          0
        } else if fx >= w {
          w - 1
        } else {
          fx
        }
        buf[orow + i] = src[row + (sx - x)]
      }
    }
  }
}

///|
/// One MC pass: the C `dsp->mc[..][..][put/avg][mx][my]` family.  `fx`/`fy`
/// are the sub-pel phases (0..15, 0 = integer).  `filter` is the FilterMode
/// (0 regular, 1 smooth, 2 sharp, 3 bilinear); `avg` selects the
/// compound-average variant that blends into the existing destination.
fn Vp9Decoder::mc_kernel(
  self : Vp9Decoder,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  fx : Int32,
  fy : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  if fx == 0 && fy == 0 {
    // whole-pixel copy/avg
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      if avg {
        for x in 0..<w {
          dst[do_ + x] = (dst[do_ + x] + src[so + x] + 1) / 2
        }
      } else {
        for x in 0..<w {
          dst[do_ + x] = src[so + x]
        }
      }
      so += src_stride
      do_ += dst_stride
    }
    return
  }
  if filter == 3 {
    // FILTER_BILINEAR; C's `(m * d + 8) >> 4` floors negative sums
    if fy == 0 {
      let mut so = src_off
      let mut do_ = dst_off
      for _ in 0..<h {
        for x in 0..<w {
          let v = vp9_clip_pixel(
            src[so + x] + ((fx * (src[so + x + 1] - src[so + x]) + 8) >> 4),
          self.pixel_max)
          dst[do_ + x] = if avg {
            (dst[do_ + x] + v + 1) / 2
          } else {
            v
          }
        }
        so += src_stride
        do_ += dst_stride
      }
    } else if fx == 0 {
      let mut so = src_off
      let mut do_ = dst_off
      for _ in 0..<h {
        for x in 0..<w {
          let v = vp9_clip_pixel(
            src[so + x] + ((fy * (src[so + x + src_stride] - src[so + x]) + 8) >> 4),
          self.pixel_max)
          dst[do_ + x] = if avg {
            (dst[do_ + x] + v + 1) / 2
          } else {
            v
          }
        }
        so += src_stride
        do_ += dst_stride
      }
    } else {
      // 2d bilinear via temp (h + 1 rows)
      let tmp = self.mc_tmp
      let mut so = src_off
      let mut to = 0
      for _ in 0..<(h + 1) {
        for x in 0..<w {
          tmp[to + x] = vp9_clip_pixel(
            src[so + x] + ((fx * (src[so + x + 1] - src[so + x]) + 8) >> 4),
          self.pixel_max)
        }
        to += 64
        so += src_stride
      }
      let mut do_ = dst_off
      to = 0
      for _ in 0..<h {
        for x in 0..<w {
          let v = vp9_clip_pixel(tmp[to + x] + ((fy * (tmp[to + x + 64] - tmp[to + x]) + 8) >> 4), self.pixel_max)
          dst[do_ + x] = if avg {
            (dst[do_ + x] + v + 1) / 2
          } else {
            v
          }
        }
        to += 64
        do_ += dst_stride
      }
    }
    return
  }
  // 8-tap filters; C's `(Σ F*src + 64) >> 7` floors negative sums
  let ftab = vp9_filter_to_table(filter)
  let filters = vp9_subpel_filters
  if fy == 0 {
    let fb = ftab * 128 + fx * 8
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      for x in 0..<w {
        let v = vp9_clip_pixel(
          (filters[fb] * src[so + x - 3] +
          filters[fb + 1] * src[so + x - 2] +
          filters[fb + 2] * src[so + x - 1] +
          filters[fb + 3] * src[so + x] +
          filters[fb + 4] * src[so + x + 1] +
          filters[fb + 5] * src[so + x + 2] +
          filters[fb + 6] * src[so + x + 3] +
          filters[fb + 7] * src[so + x + 4] +
          64) >>
          7,
        self.pixel_max)
        dst[do_ + x] = if avg {
          (dst[do_ + x] + v + 1) / 2
        } else {
          v
        }
      }
      so += src_stride
      do_ += dst_stride
    }
  } else if fx == 0 {
    let fb = ftab * 128 + fy * 8
    let mut so = src_off
    let mut do_ = dst_off
    for _ in 0..<h {
      for x in 0..<w {
        let v = vp9_clip_pixel(
          (filters[fb] * src[so + x - 3 * src_stride] +
          filters[fb + 1] * src[so + x - 2 * src_stride] +
          filters[fb + 2] * src[so + x - src_stride] +
          filters[fb + 3] * src[so + x] +
          filters[fb + 4] * src[so + x + src_stride] +
          filters[fb + 5] * src[so + x + 2 * src_stride] +
          filters[fb + 6] * src[so + x + 3 * src_stride] +
          filters[fb + 7] * src[so + x + 4 * src_stride] +
          64) >>
          7,
        self.pixel_max)
        dst[do_ + x] = if avg {
          (dst[do_ + x] + v + 1) / 2
        } else {
          v
        }
      }
      so += src_stride
      do_ += dst_stride
    }
  } else {
    // 2d via temp: h + 7 rows, horizontal pass from src - 3 rows
    let tmp = self.mc_tmp
    let fb = ftab * 128 + fx * 8
    let mut so = src_off - 3 * src_stride
    let mut to = 0
    for _ in 0..<(h + 7) {
      for x in 0..<w {
        tmp[to + x] = vp9_clip_pixel(
          (filters[fb] * src[so + x - 3] +
          filters[fb + 1] * src[so + x - 2] +
          filters[fb + 2] * src[so + x - 1] +
          filters[fb + 3] * src[so + x] +
          filters[fb + 4] * src[so + x + 1] +
          filters[fb + 5] * src[so + x + 2] +
          filters[fb + 6] * src[so + x + 3] +
          filters[fb + 7] * src[so + x + 4] +
          64) >>
          7,
        self.pixel_max)
      }
      to += 64
      so += src_stride
    }
    let fb2 = ftab * 128 + fy * 8
    let mut do_ = dst_off
    to = 3 * 64
    for _ in 0..<h {
      for x in 0..<w {
        let v = vp9_clip_pixel(
          (filters[fb2] * tmp[to + x - 3 * 64] +
          filters[fb2 + 1] * tmp[to + x - 2 * 64] +
          filters[fb2 + 2] * tmp[to + x - 64] +
          filters[fb2 + 3] * tmp[to + x] +
          filters[fb2 + 4] * tmp[to + x + 64] +
          filters[fb2 + 5] * tmp[to + x + 2 * 64] +
          filters[fb2 + 6] * tmp[to + x + 3 * 64] +
          filters[fb2 + 7] * tmp[to + x + 4 * 64] +
          64) >>
          7,
        self.pixel_max)
        dst[do_ + x] = if avg {
          (dst[do_ + x] + v + 1) / 2
        } else {
          v
        }
      }
      to += 64
      do_ += dst_stride
    }
  }
}

///|
/// `mc_luma_unscaled`: one luma prediction pass from `ref` at the luma pixel
/// position (px_x, px_y) with MV components in 1/8 pel.
fn Vp9Decoder::mc_luma(
  self : Vp9Decoder,
  ref_frame : Vp9RefFrame,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  px_x : Int32,
  px_y : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  let x = px_x + (mvx >> 3)
  let y = px_y + (mvy >> 3)
  let mut src = ref_frame.y
  let mut soff = ref_frame.ybase + y * ref_frame.ystride + x
  let mut sstride = ref_frame.ystride
  let mx = mvx & 7
  let my = mvy & 7
  let emx = if mx != 0 { 1 } else { 0 }
  let emy = if my != 0 { 1 } else { 0 }
  if x < emx * 3 ||
    y < emy * 3 ||
    x + emx * 4 > ref_frame.width - bw ||
    y + emy * 5 > ref_frame.height - bh {
    vp9_emulated_edge(
      self.mc_tmp,
      0,
      160,
      src,
      soff - emy * 3 * sstride - emx * 3,
      sstride,
      bw + emx * 7,
      bh + emy * 7,
      x - emx * 3,
      y - emy * 3,
      ref_frame.width,
      ref_frame.height,
    )
    src = self.mc_tmp
    soff = emy * 3 * 160 + emx * 3
    sstride = 160
  }
  self.mc_kernel(
    dst,
    dst_off,
    dst_stride,
    src,
    soff,
    sstride,
    bw,
    bh,
    mx << 1,
    my << 1,
    filter,
    avg,
  )
}

///|
/// `mc_chroma_unscaled`: predicts both chroma planes.  The MV maps onto
/// 1/16-pel chroma phases (for 4:2:0 the factor from the 1/8-pel luma MV is
/// exactly one).
fn Vp9Decoder::mc_chroma(
  self : Vp9Decoder,
  ref_frame : Vp9RefFrame,
  dst_cb : FixedArray[Int32],
  dst_cr : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  px_x : Int32,
  px_y : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  let mx = mvx & 15
  let my = mvy & 15
  let x = px_x + (mvx >> 4)
  let y = px_y + (mvy >> 4)
  let emx = if mx != 0 { 1 } else { 0 }
  let emy = if my != 0 { 1 } else { 0 }
  let src_cb = ref_frame.cb
  let src_cr = ref_frame.cr
  let base = ref_frame.uvbase + y * ref_frame.uvstride + x
  let sstride = ref_frame.uvstride
  let cw = (ref_frame.width + 1) >> 1
  let ch = (ref_frame.height + 1) >> 1
  if x < emx * 3 || y < emy * 3 || x + emx * 4 > cw - bw || y + emy * 5 > ch - bh {
    vp9_emulated_edge(
      self.mc_tmp,
      0,
      160,
      src_cb,
      base - emy * 3 * sstride - emx * 3,
      sstride,
      bw + emx * 7,
      bh + emy * 7,
      x - emx * 3,
      y - emy * 3,
      cw,
      ch,
    )
    self.mc_kernel(
      dst_cb,
      dst_off,
      dst_stride,
      self.mc_tmp,
      emy * 3 * 160 + emx * 3,
      160,
      bw,
      bh,
      mx,
      my,
      filter,
      avg,
    )
    vp9_emulated_edge(
      self.mc_tmp,
      0,
      160,
      src_cr,
      base - emy * 3 * sstride - emx * 3,
      sstride,
      bw + emx * 7,
      bh + emy * 7,
      x - emx * 3,
      y - emy * 3,
      cw,
      ch,
    )
    self.mc_kernel(
      dst_cr,
      dst_off,
      dst_stride,
      self.mc_tmp,
      emy * 3 * 160 + emx * 3,
      160,
      bw,
      bh,
      mx,
      my,
      filter,
      avg,
    )
    return
  }
  self.mc_kernel(
    dst_cb,
    dst_off,
    dst_stride,
    src_cb,
    base,
    sstride,
    bw,
    bh,
    mx,
    my,
    filter,
    avg,
  )
  self.mc_kernel(
    dst_cr,
    dst_off,
    dst_stride,
    src_cr,
    base,
    sstride,
    bw,
    bh,
    mx,
    my,
    filter,
    avg,
  )
}

///|
/// Chroma MV averaged over two luma sub-blocks (`ROUNDED_DIV_MVx2`).
fn vp9_uvmv2(ax : Int32, ay : Int32, bx : Int32, by : Int32) -> (Int32, Int32) {
  (vp9_rounded_div2(ax + bx), vp9_rounded_div2(ay + by))
}

///|
/// `inter_pred` (`vp9_mc_template.c`, unscaled path): predict the whole
/// block for one or both references.  `yoff`/`uvoff` are the current frame
/// plane offsets of the block origin.
fn Vp9Decoder::inter_pred(self : Vp9Decoder, yoff : Int32, uvoff : Int32) -> Unit {
  let b = self.b
  let h = self.header
  let r1 : Vp9RefFrame = match self.references[h.ref_indices[b.refidx[0]]] {
    Some(r) => r
    None => return // inter_recon reports invalid scales earlier
  }
  let filter = b.filter
  let ystride = self.ystride
  let uvstride = self.uvstride
  let ss_h = self.ss_h
  let ss_v = self.ss_v
  let comp = b.comp != 0
  let r2 : Vp9RefFrame = if comp {
    match self.references[h.ref_indices[b.refidx[1]]] {
      Some(r) => r
      None => return
    }
  } else {
    r1
  }
  let row8 = self.b_row << 3
  let col8 = self.b_col << 3
  if b.bs > 9 {
    // sub-8x8: BS_8x4 = 10, BS_4x8 = 11, BS_4x4 = 12
    if b.bs == 10 {
      // 8x4
      self.mc_luma(r1, self.y, yoff, ystride, col8, row8, b.mvx[0], b.mvy[0], 8, 4, filter, false)
      self.mc_luma(
        r1,
        self.y,
        yoff + 4 * ystride,
        ystride,
        col8,
        row8 + 4,
        b.mvx[4],
        b.mvy[4],
        8,
        4,
        filter,
        false,
      )
      if ss_v != 0 {
        let (uvx, uvy) = vp9_uvmv2(b.mvx[0], b.mvy[0], b.mvx[4], b.mvy[4])
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8 >> ss_h,
          row8 >> 1,
          uvx,
          uvy,
          8 >> ss_h,
          4,
          filter,
          false,
        )
      } else {
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8 >> ss_h,
          row8,
          b.mvx[0],
          b.mvy[0],
          8 >> ss_h,
          4,
          filter,
          false,
        )
        // BUG for 4:2:2 bs=8x4, libvpx uses the wrong block index for the
        // bottom 4x4 block (webm/issues/993)
        let (uvx, uvy) = if ss_h == 0 {
          (b.mvx[4], b.mvy[4])
        } else {
          vp9_uvmv2(b.mvx[0], b.mvy[0], b.mvx[4], b.mvy[4])
        }
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4 * uvstride,
          uvstride,
          col8 >> ss_h,
          row8 + 4,
          uvx,
          uvy,
          8 >> ss_h,
          4,
          filter,
          false,
        )
      }
      if comp {
        self.mc_luma(
          r2,
          self.y,
          yoff,
          ystride,
          col8,
          row8,
          b.mvx[1],
          b.mvy[1],
          8,
          4,
          filter,
          true,
        )
        self.mc_luma(
          r2,
          self.y,
          yoff + 4 * ystride,
          ystride,
          col8,
          row8 + 4,
          b.mvx[5],
          b.mvy[5],
          8,
          4,
          filter,
          true,
        )
        if ss_v != 0 {
          let (uvx, uvy) = vp9_uvmv2(b.mvx[1], b.mvy[1], b.mvx[5], b.mvy[5])
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8 >> ss_h,
            row8 >> 1,
            uvx,
            uvy,
            8 >> ss_h,
            4,
            filter,
            true,
          )
        } else {
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8 >> ss_h,
            row8,
            b.mvx[1],
            b.mvy[1],
            8 >> ss_h,
            4,
            filter,
            true,
          )
          let (uvx, uvy) = if ss_h == 0 {
            (b.mvx[5], b.mvy[5])
          } else {
            vp9_uvmv2(b.mvx[1], b.mvy[1], b.mvx[5], b.mvy[5])
          }
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff + 4 * uvstride,
            uvstride,
            col8 >> ss_h,
            row8 + 4,
            uvx,
            uvy,
            8 >> ss_h,
            4,
            filter,
            true,
          )
        }
      }
    } else if b.bs == 11 {
      // 4x8
      self.mc_luma(r1, self.y, yoff, ystride, col8, row8, b.mvx[0], b.mvy[0], 4, 8, filter, false)
      self.mc_luma(
        r1,
        self.y,
        yoff + 4,
        ystride,
        col8 + 4,
        row8,
        b.mvx[2],
        b.mvy[2],
        4,
        8,
        filter,
        false,
      )
      if ss_h != 0 {
        let (uvx, uvy) = vp9_uvmv2(b.mvx[0], b.mvy[0], b.mvx[2], b.mvy[2])
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8 >> 1,
          row8 >> ss_v,
          uvx,
          uvy,
          4,
          8 >> ss_v,
          filter,
          false,
        )
      } else {
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8,
          row8 >> ss_v,
          b.mvx[0],
          b.mvy[0],
          4,
          8 >> ss_v,
          filter,
          false,
        )
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4,
          uvstride,
          col8 + 4,
          row8 >> ss_v,
          b.mvx[2],
          b.mvy[2],
          4,
          8 >> ss_v,
          filter,
          false,
        )
      }
      if comp {
        self.mc_luma(
          r2,
          self.y,
          yoff,
          ystride,
          col8,
          row8,
          b.mvx[1],
          b.mvy[1],
          4,
          8,
          filter,
          true,
        )
        self.mc_luma(
          r2,
          self.y,
          yoff + 4,
          ystride,
          col8 + 4,
          row8,
          b.mvx[3],
          b.mvy[3],
          4,
          8,
          filter,
          true,
        )
        if ss_h != 0 {
          let (uvx, uvy) = vp9_uvmv2(b.mvx[1], b.mvy[1], b.mvx[3], b.mvy[3])
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8 >> 1,
            row8 >> ss_v,
            uvx,
            uvy,
            4,
            8 >> ss_v,
            filter,
            true,
          )
        } else {
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8,
            row8 >> ss_v,
            b.mvx[1],
            b.mvy[1],
            4,
            8 >> ss_v,
            filter,
            true,
          )
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff + 4,
            uvstride,
            col8 + 4,
            row8 >> ss_v,
            b.mvx[3],
            b.mvy[3],
            4,
            8 >> ss_v,
            filter,
            true,
          )
        }
      }
    } else {
      // 4x4
      self.mc_luma(r1, self.y, yoff, ystride, col8, row8, b.mvx[0], b.mvy[0], 4, 4, filter, false)
      self.mc_luma(
        r1,
        self.y,
        yoff + 4,
        ystride,
        col8 + 4,
        row8,
        b.mvx[2],
        b.mvy[2],
        4,
        4,
        filter,
        false,
      )
      self.mc_luma(
        r1,
        self.y,
        yoff + 4 * ystride,
        ystride,
        col8,
        row8 + 4,
        b.mvx[4],
        b.mvy[4],
        4,
        4,
        filter,
        false,
      )
      self.mc_luma(
        r1,
        self.y,
        yoff + 4 * ystride + 4,
        ystride,
        col8 + 4,
        row8 + 4,
        b.mvx[6],
        b.mvy[6],
        4,
        4,
        filter,
        false,
      )
      if ss_v != 0 {
        if ss_h != 0 {
          let uvx = vp9_rounded_div4(b.mvx[0] + b.mvx[2] + b.mvx[4] + b.mvx[6])
          let uvy = vp9_rounded_div4(b.mvy[0] + b.mvy[2] + b.mvy[4] + b.mvy[6])
          self.mc_chroma(
            r1,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8 >> 1,
            row8 >> 1,
            uvx,
            uvy,
            4,
            4,
            filter,
            false,
          )
        } else {
          let (uvx, uvy) = vp9_uvmv2(b.mvx[0], b.mvy[0], b.mvx[4], b.mvy[4])
          self.mc_chroma(
            r1,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8,
            row8 >> 1,
            uvx,
            uvy,
            4,
            4,
            filter,
            false,
          )
        }
      } else if ss_h != 0 {
        let (uvx, uvy) = vp9_uvmv2(b.mvx[0], b.mvy[0], b.mvx[2], b.mvy[2])
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8 >> 1,
          row8,
          uvx,
          uvy,
          4,
          4,
          filter,
          false,
        )
        // BUG libvpx uses the wrong block index for 4:2:2 bs=4x4 bottom
        let (uvx2, uvy2) = vp9_uvmv2(b.mvx[2], b.mvy[2], b.mvx[4], b.mvy[4])
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4 * uvstride,
          uvstride,
          col8 >> 1,
          row8 + 4,
          uvx2,
          uvy2,
          4,
          4,
          filter,
          false,
        )
      } else {
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff,
          uvstride,
          col8,
          row8,
          b.mvx[0],
          b.mvy[0],
          4,
          4,
          filter,
          false,
        )
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4,
          uvstride,
          col8 + 4,
          row8,
          b.mvx[2],
          b.mvy[2],
          4,
          4,
          filter,
          false,
        )
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4 * uvstride,
          uvstride,
          col8,
          row8 + 4,
          b.mvx[4],
          b.mvy[4],
          4,
          4,
          filter,
          false,
        )
        self.mc_chroma(
          r1,
          self.cb,
          self.cr,
          uvoff + 4 * uvstride + 4,
          uvstride,
          col8 + 4,
          row8 + 4,
          b.mvx[6],
          b.mvy[6],
          4,
          4,
          filter,
          false,
        )
      }
      if comp {
        self.mc_luma(
          r2,
          self.y,
          yoff,
          ystride,
          col8,
          row8,
          b.mvx[1],
          b.mvy[1],
          4,
          4,
          filter,
          true,
        )
        self.mc_luma(
          r2,
          self.y,
          yoff + 4,
          ystride,
          col8 + 4,
          row8,
          b.mvx[3],
          b.mvy[3],
          4,
          4,
          filter,
          true,
        )
        self.mc_luma(
          r2,
          self.y,
          yoff + 4 * ystride,
          ystride,
          col8,
          row8 + 4,
          b.mvx[5],
          b.mvy[5],
          4,
          4,
          filter,
          true,
        )
        self.mc_luma(
          r2,
          self.y,
          yoff + 4 * ystride + 4,
          ystride,
          col8 + 4,
          row8 + 4,
          b.mvx[7],
          b.mvy[7],
          4,
          4,
          filter,
          true,
        )
        if ss_v != 0 {
          if ss_h != 0 {
            let uvx = vp9_rounded_div4(b.mvx[1] + b.mvx[3] + b.mvx[5] + b.mvx[7])
            let uvy = vp9_rounded_div4(b.mvy[1] + b.mvy[3] + b.mvy[5] + b.mvy[7])
            self.mc_chroma(
              r2,
              self.cb,
              self.cr,
              uvoff,
              uvstride,
              col8 >> 1,
              row8 >> 1,
              uvx,
              uvy,
              4,
              4,
              filter,
              true,
            )
          } else {
            let (uvx, uvy) = vp9_uvmv2(b.mvx[1], b.mvy[1], b.mvx[5], b.mvy[5])
            self.mc_chroma(
              r2,
              self.cb,
              self.cr,
              uvoff,
              uvstride,
              col8,
              row8 >> 1,
              uvx,
              uvy,
              4,
              4,
              filter,
              true,
            )
          }
        } else if ss_h != 0 {
          let (uvx, uvy) = vp9_uvmv2(b.mvx[1], b.mvy[1], b.mvx[3], b.mvy[3])
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8 >> 1,
            row8,
            uvx,
            uvy,
            4,
            4,
            filter,
            true,
          )
        } else {
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff,
            uvstride,
            col8,
            row8,
            b.mvx[1],
            b.mvy[1],
            4,
            4,
            filter,
            true,
          )
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff + 4,
            uvstride,
            col8 + 4,
            row8,
            b.mvx[3],
            b.mvy[3],
            4,
            4,
            filter,
            true,
          )
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff + 4 * uvstride,
            uvstride,
            col8,
            row8 + 4,
            b.mvx[5],
            b.mvy[5],
            4,
            4,
            filter,
            true,
          )
          self.mc_chroma(
            r2,
            self.cb,
            self.cr,
            uvoff + 4 * uvstride + 4,
            uvstride,
            col8 + 4,
            row8 + 4,
            b.mvx[7],
            b.mvy[7],
            4,
            4,
            filter,
            true,
          )
        }
      }
    }
  } else {
    // BS <= BS_8x8: one luma block + one chroma block per reference
    let bw = vp9_bwh_tab[b.bs * 2] * 4
    let bh = vp9_bwh_tab[b.bs * 2 + 1] * 4
    let uvbw = vp9_bwh_tab[ss_h * 26 + b.bs * 2] * 4
    let uvbh = vp9_bwh_tab[ss_v * 26 + b.bs * 2 + 1] * 4
    self.mc_luma(
      r1,
      self.y,
      yoff,
      ystride,
      col8,
      row8,
      b.mvx[0],
      b.mvy[0],
      bw,
      bh,
      filter,
      false,
    )
    self.mc_chroma(
      r1,
      self.cb,
      self.cr,
      uvoff,
      uvstride,
      col8 >> ss_h,
      row8 >> ss_v,
      b.mvx[0],
      b.mvy[0],
      uvbw,
      uvbh,
      filter,
      false,
    )
    if comp {
      self.mc_luma(
        r2,
        self.y,
        yoff,
        ystride,
        col8,
        row8,
        b.mvx[1],
        b.mvy[1],
        bw,
        bh,
        filter,
        true,
      )
      self.mc_chroma(
        r2,
        self.cb,
        self.cr,
        uvoff,
        uvstride,
        col8 >> ss_h,
        row8 >> ss_v,
        b.mvx[1],
        b.mvy[1],
        uvbw,
        uvbh,
        filter,
        true,
      )
    }
  }
}

///|
/// `inter_recon` (8 bpp, unscaled): predict the block and, unless skipped,
/// add the decoded residual (inter blocks always use DCT_DCT).
fn Vp9Decoder::inter_recon(self : Vp9Decoder, y_off : Int32, uv_off : Int32) -> Unit {
  let b = self.b
  let row = self.b_row
  let col = self.b_col
  self.inter_pred(y_off, uv_off)
  if b.skip != 0 {
    return
  }
  let w4 = vp9_bwh8_at(b.bs)[0] << 1
  let h4 = vp9_bwh8_at(b.bs)[1] << 1
  let end_x = vp9_min(2 * (self.cols - col), w4)
  let end_y = vp9_min(2 * (self.rows - row), h4)
  let tx_kind = 4 * self.lossless() + b.tx
  let step1d = 1 << b.tx
  let mut step = 1 << (b.tx * 2)
  let mut n = 0
  let mut y = 0
  while y < end_y {
    let mut x = 0
    while x < end_x {
      let eob = self.eob[n]
      if eob != 0 {
        vp9_itxfm_add(
          tx_kind,
          0,
          self.y,
          y_off + x * 4 + y * 4 * self.ystride,
          self.ystride,
          self.block,
          16 * n,
          eob,
          self.bpp,
          self.pixel_max,
        )
      }
      n += step
      x += step1d
    }
    y += step1d
  }
  let uend_x = end_x >> self.ss_h
  let uend_y = end_y >> self.ss_v
  let uvtx_kind = 4 * self.lossless() + b.uvtx
  let uvstep1d = 1 << b.uvtx
  step = 1 << (b.uvtx * 2)
  for pl in 0..<2 {
    let plane = if pl == 0 {
      self.cb
    } else {
      self.cr
    }
    let ublock = if pl == 0 {
      self.uvblock0
    } else {
      self.uvblock1
    }
    let ueob = if pl == 0 {
      self.uveob0
    } else {
      self.uveob1
    }
    let mut n2 = 0
    let mut y2 = 0
    while y2 < uend_y {
      let mut x2 = 0
      while x2 < uend_x {
        let eob = ueob[n2]
        if eob != 0 {
          vp9_itxfm_add(
            uvtx_kind,
            0,
            plane,
            uv_off + x2 * 4 + y2 * 4 * self.uvstride,
            self.uvstride,
            ublock,
            16 * n2,
            eob,
            self.bpp,
            self.pixel_max,
          )
        }
        n2 += step
        x2 += uvstep1d
      }
      y2 += uvstep1d
    }
  }
}
