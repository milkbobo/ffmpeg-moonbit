///|
/// MoonBit port of the VP9 loop filter driver from FFmpeg 9.0.2
/// `libavcodec/vp9block.c` (`mask_edges`) and `libavcodec/vp9lpf.c`
/// (`filter_plane_cols`/`filter_plane_rows`/`ff_vp9_loopfilter_sb`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.

///|
/// `mask_edges` for one block.  `uv` selects the plane mask bank
/// (`mask[uv][dir][y][slot]`); `dir` is unused here because the C writes
/// both directions from one call — this port writes into the decoder's flat
/// `lf_mask` at `(lflvl_idx * 128) + (uv * 64) + (dir * 32) + (y * 4) + slot`. */
fn Vp9Decoder::mask_edges(
  self : Vp9Decoder,
  lflvl_idx : Int32,
  uv : Int32,
  ss_h : Int32,
  ss_v : Int32,
  row_and_7 : Int32,
  col_and_7 : Int32,
  w : Int32,
  h : Int32,
  col_end : Int32,
  row_end : Int32,
  tx : Int32,
  skip_inter : Int32,
) -> Unit {
  let mask = self.lf_mask
  let base = lflvl_idx * 128 + uv * 64
  let set = (dir : Int32, y : Int32, slot : Int32, v : Int32) => {
    let idx = base + dir * 32 + y * 4 + slot
    mask[idx] = mask[idx] | v
  }
  let wide_filter_col_mask : Array[Int32] = [0x11, 0x01]
  let wide_filter_row_mask : Array[Int32] = [0x03, 0x07]
  let mut w = w
  let mut h = h
  // for UV, we work on two subsampled blocks at a time; for any block size
  // smaller than 16x16, ignore the odd portion of the block
  if tx == 0 && (ss_v | ss_h) != 0 {
    if h == ss_v {
      if (row_and_7 & 1) != 0 {
        return
      }
      if row_end == 0 {
        h += 1
      }
    }
    if w == ss_h {
      if (col_and_7 & 1) != 0 {
        return
      }
      if col_end == 0 {
        w += 1
      }
    }
  }
  if tx == 0 && skip_inter == 0 {
    let t = 1 << col_and_7
    let m_col = (t << w) - t
    // on 32-px edges, use the 8-px wide loopfilter; else, use 4-px wide
    let m_row_8 = m_col & wide_filter_col_mask[ss_h]
    let m_row_4 = m_col - m_row_8
    let mut y = row_and_7
    while y < h + row_and_7 {
      let col_mask_id = 2 -
        (if (y & wide_filter_row_mask[ss_v]) != 0 { 0 } else { 1 })
      set(0, y, 1, m_row_8)
      set(0, y, 2, m_row_4)
      // if a/c are even row/col and b/d are odd, and d is skipped, skip b
      if (ss_h & ss_v) != 0 && (col_end & 1) != 0 && (y & 1) != 0 {
        set(1, y, col_mask_id, (t << (w - 1)) - t)
      } else {
        set(1, y, col_mask_id, m_col)
      }
      if ss_h == 0 {
        set(0, y, 3, m_col)
      }
      if ss_v == 0 {
        if ss_h != 0 && (col_end & 1) != 0 {
          set(1, y, 3, (t << (w - 1)) - t)
        } else {
          set(1, y, 3, m_col)
        }
      }
      y += 1
    }
  } else {
    let t = 1 << col_and_7
    let m_col = (t << w) - t
    if skip_inter == 0 {
      let mask_id = if tx == 1 { 1 } else { 0 }
      let masks : Array[Int32] = [0xff, 0x55, 0x11, 0x01]
      let mut l2 = tx + ss_h - 1
      let m_row = m_col & masks[l2]
      // at odd UV col/row edges tx16/tx32 loopfilter edges, force 8wd
      // loopfilter to prevent going off the visible edge
      if ss_h != 0 && tx > 1 && (w ^ (w - 1)) == 1 {
        let m_row_16 = ((t << (w - 1)) - t) & masks[l2]
        let m_row_8 = m_row - m_row_16
        let mut y = row_and_7
        while y < h + row_and_7 {
          set(0, y, 0, m_row_16)
          set(0, y, 1, m_row_8)
          y += 1
        }
      } else {
        let mut y = row_and_7
        while y < h + row_and_7 {
          set(0, y, mask_id, m_row)
          y += 1
        }
      }
      l2 = tx + ss_v - 1
      let step1d = 1 << l2
      if ss_v != 0 && tx > 1 && (h ^ (h - 1)) == 1 {
        let mut y = row_and_7
        while y < h + row_and_7 - 1 {
          set(1, y, 0, m_col)
          y += step1d
        }
        if y - row_and_7 == h - 1 {
          set(1, y, 1, m_col)
        }
      } else {
        let mut y = row_and_7
        while y < h + row_and_7 {
          set(1, y, mask_id, m_col)
          y += step1d
        }
      }
    } else if tx != 0 {
      let mask_id = if tx == 1 || h == ss_v { 1 } else { 0 }
      set(1, row_and_7, mask_id, m_col)
      let mask_id2 = if tx == 1 || w == ss_h { 1 } else { 0 }
      let mut y = row_and_7
      while y < h + row_and_7 {
        set(0, y, mask_id2, t)
        y += 1
      }
    } else {
      let t8 = t & wide_filter_col_mask[ss_h]
      let t4 = t - t8
      let mut y = row_and_7
      while y < h + row_and_7 {
        set(0, y, 2, t4)
        set(0, y, 1, t8)
        y += 1
      }
      set(
        1,
        row_and_7,
        2 - (if (row_and_7 & wide_filter_row_mask[ss_v]) != 0 { 0 } else { 1 }),
        m_col,
      )
    }
  }
}

///|
/// `filter_plane_cols`: vertical edges between columns.  `maskbase` points at
/// `mask[dir=cols]` of this superblock; `lvlbase` at `level`. */
fn Vp9Decoder::filter_plane_cols(
  self : Vp9Decoder,
  col : Int32,
  ss_h : Int32,
  ss_v : Int32,
  lvlbase : Int32,
  maskbase : Int32,
  dst : FixedArray[Int32],
  doff : Int32,
  ls : Int32,
) -> Unit {
  let mask = self.lf_mask
  let ystep = 2 << ss_v
  let mut y = 0
  while y < 8 {
    let ptr = doff + y / ystep * 16 * ls
    let l0 = lvlbase + y / ystep * (16 << ss_v)
    let hm1row = maskbase + y * 4
    let hm2row = maskbase + (y + 1 + ss_v) * 4
    let hm1 = mask[hm1row] | mask[hm1row + 1] | mask[hm1row + 2]
    let hm13 = mask[hm1row + 3]
    let hm2 = mask[hm2row + 1] | mask[hm2row + 2]
    let hm23 = mask[hm2row + 3]
    let hm = hm1 | hm2 | hm13 | hm23
    let mut x = 1
    let mut l = l0
    let mut p = ptr
    while (hm & (x - 1).lnot()) != 0 {
      if col != 0 || x > 1 {
        if (hm1 & x) != 0 {
          let mut lq = self.lf_level[l + 0]
          let mut hh = lq >> 4
          let mut e = self.mblim_lut[lq]
          let mut i = self.lim_lut[lq]
          if (mask[hm1row] & x) != 0 {
            if (mask[hm2row] & x) != 0 {
              vp9_loop_filter_16(
                0,
                dst,
                p,
                ls,
                e,
                i,
                hh,
                self.bpp,
                self.pixel_max,
              )
            } else {
              vp9_lf8(2, 0, dst, p, ls, e, i, hh, self.bpp, self.pixel_max)
            }
          } else if (hm2 & x) != 0 {
            lq = self.lf_level[l + (8 << ss_v)]
            hh = hh | (lq >> 4 << 8)
            e = e | (self.mblim_lut[lq] << 8)
            i = i | (self.lim_lut[lq] << 8)
            vp9_loop_filter_mix2(
              0,
              if (mask[hm1row + 1] & x) != 0 {
                1
              } else {
                0
              },
              if (mask[hm2row + 1] & x) != 0 {
                1
              } else {
                0
              },
              dst,
              p,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          } else {
            vp9_lf8(
              if (mask[hm1row + 1] & x) != 0 {
                1
              } else {
                0
              },
              0,
              dst,
              p,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          }
        } else if (hm2 & x) != 0 {
          let lq = self.lf_level[l + (8 << ss_v)]
          let hh = lq >> 4
          let e = self.mblim_lut[lq]
          let i = self.lim_lut[lq]
          vp9_lf8(
            if (mask[hm2row + 1] & x) != 0 {
              1
            } else {
              0
            },
            0,
            dst,
            p + 8 * ls,
            ls,
            e,
            i,
            hh,
            self.bpp,
            self.pixel_max,
          )
        }
      }
      if ss_h != 0 {
        if (x & 0xAA) != 0 {
          l += 2
        }
      } else {
        if (hm13 & x) != 0 {
          let mut lq = self.lf_level[l + 0]
          let mut hh = lq >> 4
          let mut e = self.mblim_lut[lq]
          let mut i = self.lim_lut[lq]
          if (hm23 & x) != 0 {
            lq = self.lf_level[l + (8 << ss_v)]
            hh = hh | (lq >> 4 << 8)
            e = e | (self.mblim_lut[lq] << 8)
            i = i | (self.lim_lut[lq] << 8)
            vp9_loop_filter_mix2(
              0,
              0,
              0,
              dst,
              p + 4,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          } else {
            vp9_lf8(0, 0, dst, p + 4, ls, e, i, hh, self.bpp, self.pixel_max)
          }
        } else if (hm23 & x) != 0 {
          let lq = self.lf_level[l + (8 << ss_v)]
          let hh = lq >> 4
          let e = self.mblim_lut[lq]
          let i = self.lim_lut[lq]
          vp9_lf8(
            0,
            0,
            dst,
            p + 8 * ls + 4,
            ls,
            e,
            i,
            hh,
            self.bpp,
            self.pixel_max,
          )
        }
        l += 1
      }
      x = x << 1
      p += 8 >> ss_h
    }
    y += ystep
  }
}

///|
/// `filter_plane_rows`: horizontal edges between rows. */
fn Vp9Decoder::filter_plane_rows(
  self : Vp9Decoder,
  row : Int32,
  ss_h : Int32,
  ss_v : Int32,
  lvlbase : Int32,
  maskbase : Int32,
  dst : FixedArray[Int32],
  doff : Int32,
  ls : Int32,
) -> Unit {
  let mask = self.lf_mask
  let xstep = 2 << ss_h
  let mut y = 0
  while y < 8 {
    let ptr = doff + y * ((8 * ls) >> ss_v)
    let l0 = lvlbase + (if ss_v != 0 { (y >> 1) * 16 } else { y * 8 })
    let vmask = maskbase + y * 4
    let vm = mask[vmask] | mask[vmask + 1] | mask[vmask + 2]
    let vm3 = mask[vmask + 3]
    let mut x = 1
    let mut l = l0
    let mut p = ptr
    while (vm & (x - 1).lnot()) != 0 {
      if row != 0 || y != 0 {
        if (vm & x) != 0 {
          let mut lq = self.lf_level[l + 0]
          let mut hh = lq >> 4
          let mut e = self.mblim_lut[lq]
          let mut i = self.lim_lut[lq]
          if (mask[vmask] & x) != 0 {
            if (mask[vmask] & (x << (1 + ss_h))) != 0 {
              vp9_loop_filter_16(
                1,
                dst,
                p,
                ls,
                e,
                i,
                hh,
                self.bpp,
                self.pixel_max,
              )
            } else {
              vp9_lf8(2, 1, dst, p, ls, e, i, hh, self.bpp, self.pixel_max)
            }
          } else if (vm & (x << (1 + ss_h))) != 0 {
            lq = self.lf_level[l + 1 + ss_h]
            hh = hh | (lq >> 4 << 8)
            e = e | (self.mblim_lut[lq] << 8)
            i = i | (self.lim_lut[lq] << 8)
            vp9_loop_filter_mix2(
              1,
              if (mask[vmask + 1] & x) != 0 {
                1
              } else {
                0
              },
              if (mask[vmask + 1] & (x << (1 + ss_h))) != 0 {
                1
              } else {
                0
              },
              dst,
              p,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          } else {
            vp9_lf8(
              if (mask[vmask + 1] & x) != 0 {
                1
              } else {
                0
              },
              1,
              dst,
              p,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          }
        } else if (vm & (x << (1 + ss_h))) != 0 {
          let lq = self.lf_level[l + 1 + ss_h]
          let hh = lq >> 4
          let e = self.mblim_lut[lq]
          let i = self.lim_lut[lq]
          vp9_lf8(
            if (mask[vmask + 1] & (x << (1 + ss_h))) != 0 {
              1
            } else {
              0
            },
            1,
            dst,
            p + 8,
            ls,
            e,
            i,
            hh,
            self.bpp,
            self.pixel_max,
          )
        }
      }
      if ss_v == 0 {
        if (vm3 & x) != 0 {
          let mut lq = self.lf_level[l + 0]
          let mut hh = lq >> 4
          let mut e = self.mblim_lut[lq]
          let mut i = self.lim_lut[lq]
          if (vm3 & (x << (1 + ss_h))) != 0 {
            lq = self.lf_level[l + 1 + ss_h]
            hh = hh | (lq >> 4 << 8)
            e = e | (self.mblim_lut[lq] << 8)
            i = i | (self.lim_lut[lq] << 8)
            vp9_loop_filter_mix2(
              1,
              0,
              0,
              dst,
              p + ls * 4,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          } else {
            vp9_lf8(
              0,
              1,
              dst,
              p + ls * 4,
              ls,
              e,
              i,
              hh,
              self.bpp,
              self.pixel_max,
            )
          }
        } else if (vm3 & (x << (1 + ss_h))) != 0 {
          let lq = self.lf_level[l + 1 + ss_h]
          let hh = lq >> 4
          let e = self.mblim_lut[lq]
          let i = self.lim_lut[lq]
          vp9_lf8(
            0,
            1,
            dst,
            p + ls * 4 + 8,
            ls,
            e,
            i,
            hh,
            self.bpp,
            self.pixel_max,
          )
        }
      }
      x = x << xstep
      p += 16
      l += 2 << ss_h
    }
    y += 1
  }
}

///|
/// `ff_vp9_loopfilter_sb` for one superblock. */
fn Vp9Decoder::loopfilter_sb(
  self : Vp9Decoder,
  lflvl_idx : Int32,
  yoff : Int32,
  uvoff : Int32,
) -> Unit {
  let lvlbase = lflvl_idx * 64
  self.filter_plane_cols(
    self.sb_col_of(lflvl_idx),
    0,
    0,
    lvlbase,
    lflvl_idx * 128,
    self.y,
    yoff,
    self.ystride,
  )
  self.filter_plane_rows(
    self.sb_row_of(lflvl_idx),
    0,
    0,
    lvlbase,
    lflvl_idx * 128 + 32,
    self.y,
    yoff,
    self.ystride,
  )
  let uvbank = if (self.ss_h | self.ss_v) != 0 { 64 } else { 0 }
  for p in 0..<2 {
    let dst = if p == 0 { self.cb } else { self.cr }
    self.filter_plane_cols(
      self.sb_col_of(lflvl_idx),
      self.ss_h,
      self.ss_v,
      lvlbase,
      lflvl_idx * 128 + uvbank,
      dst,
      uvoff,
      self.uvstride,
    )
    self.filter_plane_rows(
      self.sb_row_of(lflvl_idx),
      self.ss_h,
      self.ss_v,
      lvlbase,
      lflvl_idx * 128 + uvbank + 32,
      dst,
      uvoff,
      self.uvstride,
    )
  }
}

///|
fn Vp9Decoder::sb_col_of(self : Vp9Decoder, lflvl_idx : Int32) -> Int32 {
  lflvl_idx % self.sb_cols
}

///|
fn Vp9Decoder::sb_row_of(self : Vp9Decoder, lflvl_idx : Int32) -> Int32 {
  lflvl_idx / self.sb_cols
}

///|
/// `dsp->loop_filter_8[sel][dir]`: wd = 4 << sel. */
fn vp9_lf8(
  sel : Int32,
  dir : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i : Int32,
  h : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  let wd = 4 << sel
  if dir == 0 {
    vp9_loop_filter_h(p, off, stride, e, i, h, wd, bpp, pixel_max)
  } else {
    vp9_loop_filter_v(p, off, stride, e, i, h, wd, bpp, pixel_max)
  }
}
