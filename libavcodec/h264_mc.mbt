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
/// One 6-tap half-pel filter application; `p0..p5` are the six input samples
/// `src[-2..3]`. Both the horizontal and the vertical stage clip to uint8,
/// matching `ff_put_h264_qpel16_h_lowpass`.
fn h264_mc_hpel6(
  p0 : Int32,
  p1 : Int32,
  p2 : Int32,
  p3 : Int32,
  p4 : Int32,
  p5 : Int32,
) -> Int32 {
  clip_uint8((p0 - 5 * p1 + 20 * p2 + 20 * p3 - 5 * p4 + p5 + 16) >> 5)
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
  // `hpel_h(x, y)` is the half-pel sample at (x + 0.5, y): filter over
  // x - 2 .. x + 3, matching `src[y][x - 2 .. x + 3]` in the C.
  fn hpel_h(x : Int32, y : Int32) -> Int32 {
    h264_mc_hpel6(
      px(x - 2, y),
      px(x - 1, y),
      px(x, y),
      px(x + 1, y),
      px(x + 2, y),
      px(x + 3, y),
    )
  }
  // `hpel_v(g, x, y)` is the sample at (x?, y + 0.5) for the x-generator
  // `g` (identity or `hpel_h`): filter over rows y - 2 .. y + 3.
  fn hpel_v(g : (Int32, Int32) -> Int32, x : Int32, y : Int32) -> Int32 {
    h264_mc_hpel6(
      g(x, y - 2),
      g(x, y - 1),
      g(x, y),
      g(x, y + 1),
      g(x, y + 2),
      g(x, y + 3),
    )
  }
  // Vertically processed value at (x, y) for sub-pel `sy` (0, 1, 2, 3):
  // sy==2 filters, odd sy averages the full and the filtered row.
  fn vert(
    g : (Int32, Int32) -> Int32,
    x : Int32,
    y : Int32,
    sy : Int32,
  ) -> Int32 {
    if sy == 0 {
      g(x, y)
    } else if sy == 2 {
      hpel_v(g, x, y)
    } else {
      (g(x, y) + hpel_v(g, x, y) + 1) >> 1
    }
  }
  for row = 0; row < h; row = row + 1 {
    let y = src_y + row
    for col = 0; col < w; col = col + 1 {
      let x = src_x + col
      let v = if subx == 0 {
        vert(px, x, y, suby)
      } else if subx == 2 {
        vert(hpel_h, x, y, suby)
      } else {
        (vert(px, x, y, suby) + vert(hpel_h, x, y, suby) + 1) >> 1
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
