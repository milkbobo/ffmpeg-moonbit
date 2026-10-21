///|
/// MoonBit port of the H.264 motion compensation half of FFmpeg 9.0.2:
/// the quarter-pel luma interpolation (the 6-tap filter behind
/// `put_h264_qpel*` in `libavcodec/h264_mc_template.h` plus the border
/// replication of `ff_emulated_edge_mc`) and the 1/8-pel chroma filter
/// (`put_h264_chroma_mc8` semantics, `h264_mb.c: mc_dir_part`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C runs fixed block sizes over a pre-clipped `edge_emu_buffer`; this
/// port keeps the same arithmetic (clip after the horizontal 6-tap, clip
/// after the vertical 6-tap, `(a + b + 1) >> 1` for quarter positions) but
/// fetches pixels through a clamped accessor, which reproduces the border
/// replication for exactly the samples the filters touch.

///|
/// Clamp a sample fetch coordinate into `[0, limit)` (border replication of
/// `ff_emulated_edge_mc`). */
fn h264_mc_clamp(v : Int32, limit : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= limit {
    limit - 1
  } else {
    v
  }
}

///|
/// Put a luma block of `w` x `h` from `src` at full-pel offset
/// (`src_x`, `src_y`) relative to the plane origin, with quarter-pel
/// remainders `subx`/`suby` (0..3). `pic_w`/`pic_h` delimit the reference
/// plane; out-of-plane samples are border replicated. `dstoff` is the
/// destination plane offset, `dstride`/`sstride` the strides.
///
/// This is `mc_dir_part`'s luma half: full-pel positions copy, half-pel
/// positions 6-tap filter (horizontally, vertically, or both), and quarter
/// positions average the two neighbouring half-pel/full-pel results with
/// `(a + b + 1) >> 1`.
fn h264_mc_luma(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  src_x : Int32,
  src_y : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  subx : Int32,
  suby : Int32,
  pic_w : Int32,
  pic_h : Int32,
) -> Unit {
  fn px(x : Int32, y : Int32) -> Int32 {
    src[h264_mc_clamp(y, pic_h) * sstride + h264_mc_clamp(x, pic_w)]
  }
  // Unclipped horizontal 6-tap at (x, y). `put_h264_qpelN_hv_lowpass` keeps
  // these sums unshifted and unclipped until the final `(v + 512) >> 10`.
  fn hsum(x : Int32, y : Int32) -> Int32 {
    px(x - 2, y) - 5 * px(x - 1, y) + 20 * px(x, y) + 20 * px(x + 1, y) -
    5 * px(x + 2, y) + px(x + 3, y)
  }
  fn vsum(g : (Int32, Int32) -> Int32, x : Int32, y : Int32) -> Int32 {
    g(x, y - 2) - 5 * g(x, y - 1) + 20 * g(x, y) + 20 * g(x, y + 1) -
    5 * g(x, y + 2) + g(x, y + 3)
  }
  fn half_h(x : Int32, y : Int32) -> Int32 {
    clip_uint8((hsum(x, y) + 16) >> 5)
  }
  fn half_v(x : Int32, y : Int32) -> Int32 {
    clip_uint8((vsum(px, x, y) + 16) >> 5)
  }
  fn half_hv(x : Int32, y : Int32) -> Int32 {
    clip_uint8((vsum(hsum, x, y) + 512) >> 10)
  }
  for row = 0; row < h; row = row + 1 {
    let y = src_y + row
    for col = 0; col < w; col = col + 1 {
      let x = src_x + col
      // `ff_h264_qpel_pixels_tab[...][subx + 4 * suby]`, i.e. the mcXY
      // functions of h264qpel_template.c.
      let v = if subx == 0 {
        if suby == 0 {
          px(x, y)
        } else if suby == 2 {
          half_v(x, y)
        } else if suby == 1 {
          (px(x, y) + half_v(x, y) + 1) >> 1
        } else {
          (half_v(x, y) + px(x, y + 1) + 1) >> 1
        }
      } else if subx == 2 {
        if suby == 0 {
          half_h(x, y)
        } else if suby == 2 {
          half_hv(x, y)
        } else if suby == 1 {
          (half_h(x, y) + half_hv(x, y) + 1) >> 1
        } else {
          (half_h(x, y + 1) + half_hv(x, y) + 1) >> 1
        }
      } else if subx == 1 {
        if suby == 0 {
          (px(x, y) + half_h(x, y) + 1) >> 1
        } else if suby == 2 {
          (half_v(x, y) + half_hv(x, y) + 1) >> 1
        } else if suby == 1 {
          (half_h(x, y) + half_v(x, y) + 1) >> 1
        } else {
          (half_h(x, y + 1) + half_v(x, y) + 1) >> 1
        }
      } else {
        if suby == 0 {
          (half_h(x, y) + px(x + 1, y) + 1) >> 1
        } else if suby == 2 {
          (half_v(x + 1, y) + half_hv(x, y) + 1) >> 1
        } else if suby == 1 {
          (half_h(x, y) + half_v(x + 1, y) + 1) >> 1
        } else {
          (half_h(x, y + 1) + half_v(x + 1, y) + 1) >> 1
        }
      }
      dst[dstoff + row * dstride + col] = v
    }
  }
}

///|
/// Put a chroma block of `w` x `h` from `src`: (`src_x`, `src_y`) is the
/// block's full-pel chroma position in the reference picture, and the luma
/// quarter-pel MV (`mx`, `my`) displaces it by `(mx >> 3)` full pels plus
/// `mx & 7` eighths (`mc_dir_part`'s chroma half).
fn h264_mc_chroma(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  src_x : Int32,
  src_y : Int32,
  mx : Int32,
  my : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  pic_w : Int32,
  pic_h : Int32,
) -> Unit {
  let fy = src_y + (my >> 3)
  let dx = mx & 7
  let dy = my & 7
  // `put_h264_chroma_mc8`: (A*(8-dx)(8-dy) + B*dx(8-dy) + C*(8-dx)dy +
  // D*dx*dy + 32) >> 6.
  let ax = 8 - dx
  let ay = 8 - dy
  for row = 0; row < h; row = row + 1 {
    let y0 = h264_mc_clamp(fy + row, pic_h)
    let y1 = h264_mc_clamp(fy + row + 1, pic_h)
    for col = 0; col < w; col = col + 1 {
      // Chroma blocks are `w` wide, so the B/C taps of the last column may
      // come from `fx + w`; the clamp reproduces edge replication.
      let fx = src_x + (mx >> 3)
      let xa = h264_mc_clamp(fx + col, pic_w)
      let xb = h264_mc_clamp(fx + col + 1, pic_w)
      let a = src[y0 * sstride + xa]
      let b = src[y0 * sstride + xb]
      let c = src[y1 * sstride + xa]
      let d = src[y1 * sstride + xb]
      dst[dstoff + row * dstride + col] = (
          a * ax * ay + b * dx * ay + c * ax * dy + d * dx * dy + 32
        ) >>
        6
    }
  }
}

///|
/// Partition geometry: 8x8 index (0..3) plus sub-partition type
/// (0: 8x8, 1: 8x4, 2: 4x8, 3: 4x4) to sub-block list of
/// (xoff, yoff, w, h) in luma pixels.
fn h264_sub_partitions(
  part : Int32,
  x8 : Int32,
  y8 : Int32,
) -> Array[(Int32, Int32, Int32, Int32)] {
  let x = x8 * 8
  let y = y8 * 8
  if part == 0 {
    [(x, y, 8, 8)]
  } else if part == 1 {
    [(x, y, 8, 4), (x, y + 4, 8, 4)]
  } else if part == 2 {
    [(x, y, 4, 8), (x + 4, y, 4, 8)]
  } else {
    [(x, y, 4, 4), (x + 4, y, 4, 4), (x, y + 4, 4, 4), (x + 4, y + 4, 4, 4)]
  }
}
