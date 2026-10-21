///|
/// HEVC motion compensation, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/dsp_template.c` (`put_hevc_qpel*`, `put_hevc_epel*`,
/// `put_hevc_pel_*`, 8-bit) and `libavcodec/h26x/h2656_inter_template.c`,
/// with the `ff_emulated_edge_mc` boundary handling from `hevcdec.c`
/// (`luma_mc_uni`/`luma_mc_bi`/`chroma_mc_uni`/`chroma_mc_bi`).
///
/// The C picks a "direct" path when the filtered block lies fully inside the
/// reference picture and an edge-emulation path otherwise; both paths produce
/// identical samples, so this port always runs the boundary-clamped copy
/// first and filters from the padded buffer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_qpel_filters : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0, 0, 0, 0, 0],
  [-1, 4, -10, 58, 17, -5, 1, 0],
  [-1, 4, -11, 40, 40, -11, 4, -1],
  [0, 1, -5, 17, 58, -10, 4, -1],
]

///|
let hevc_epel_filters : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0],
  [-2, 58, 10, -2],
  [-4, 54, 16, -2],
  [-6, 46, 28, -4],
  [-4, 36, 36, -4],
  [-4, 28, 46, -6],
  [-2, 16, 54, -4],
  [-2, 10, 58, -2],
]

///|
/// Scratch stride for edge-emulated luma windows ((64+7) x (64+7) max). */
let hevc_mc_luma_stride : Int32 = 96

///|
let hevc_mc_chroma_stride : Int32 = 80

///|
let hevc_mc_max_pb : Int32 = 64

///|
fn hevc_mc_clip_u8(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// `ff_emulated_edge_mc`: copy the window of `block_w` x `block_h` whose top
/// left sample sits at `(x, y)`, padded by `ex_l`/`ex_t` columns/rows before
/// the block, replicating out-of-bounds samples from the picture edge. */
fn hevc_fill_edge(
  buf : FixedArray[Int32],
  buf_stride : Int32,
  plane : Array[Int32],
  plane_stride : Int32,
  pw : Int32,
  ph : Int32,
  x : Int32,
  y : Int32,
  ex_l : Int32,
  ex_t : Int32,
  ex_r : Int32,
  ex_b : Int32,
  block_w : Int32,
  block_h : Int32,
) -> Unit {
  let total_w = block_w + ex_l + ex_r
  let total_h = block_h + ex_t + ex_b
  let x0 = x - ex_l
  let y0 = y - ex_t
  for j in 0..<total_h {
    let sy = y0 + j
    let sy_c = if sy < 0 {
      0
    } else if sy >= ph {
      ph - 1
    } else {
      sy
    }
    let row = sy_c * plane_stride
    let brow = j * buf_stride
    for i in 0..<total_w {
      let sx = x0 + i
      let sx_c = if sx < 0 {
        0
      } else if sx >= pw {
        pw - 1
      } else {
        sx
      }
      buf[brow + i] = plane[row + sx_c]
    }
  }
}

///|
/// Horizontal 8-tap filter of one row: `sum f[k] * row[i + k - 3]`. */
fn hevc_qpel_h(row : FixedArray[Int32], i : Int32, f : FixedArray[Int32]) -> Int32 {
  f[0] * row[i - 3] +
  f[1] * row[i - 2] +
  f[2] * row[i - 1] +
  f[3] * row[i] +
  f[4] * row[i + 1] +
  f[5] * row[i + 2] +
  f[6] * row[i + 3] +
  f[7] * row[i + 4]
}

///|
/// Vertical 8-tap filter of one column over a MAX_PB_SIZE-stride int buffer. */
fn hevc_qpel_v(buf : FixedArray[Int32], idx : Int32, f : FixedArray[Int32]) -> Int32 {
  f[0] * buf[idx - 3 * hevc_mc_max_pb] +
  f[1] * buf[idx - 2 * hevc_mc_max_pb] +
  f[2] * buf[idx - hevc_mc_max_pb] +
  f[3] * buf[idx] +
  f[4] * buf[idx + hevc_mc_max_pb] +
  f[5] * buf[idx + 2 * hevc_mc_max_pb] +
  f[6] * buf[idx + 3 * hevc_mc_max_pb] +
  f[7] * buf[idx + 4 * hevc_mc_max_pb]
}

///|
/// Horizontal 4-tap filter: `sum f[k] * row[i + k - 1]`. */
fn hevc_epel_h(row : FixedArray[Int32], i : Int32, f : FixedArray[Int32]) -> Int32 {
  f[0] * row[i - 1] + f[1] * row[i] + f[2] * row[i + 1] + f[3] * row[i + 2]
}

///|
/// Vertical 4-tap filter over a MAX_PB_SIZE-stride int buffer. */
fn hevc_epel_v(buf : FixedArray[Int32], idx : Int32, f : FixedArray[Int32]) -> Int32 {
  f[0] * buf[idx - hevc_mc_max_pb] +
  f[1] * buf[idx] +
  f[2] * buf[idx + hevc_mc_max_pb] +
  f[3] * buf[idx + 2 * hevc_mc_max_pb]
}

///|
/// `luma_mc_uni` without the weight flag. Writes `bw` x `bh` samples at
/// `(x0, y0)` of the destination plane. */
fn hevc_luma_mc_uni(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let mx = mvx & 3
  let my = mvy & 3
  let x_off = x0 + (mvx >> 2)
  let y_off = y0 + (mvy >> 2)
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_luma_stride * hevc_mc_luma_stride,
    0,
  )
  hevc_fill_edge(
    buf,
    hevc_mc_luma_stride,
    ref_plane,
    ref_stride,
    rw,
    rh,
    x_off,
    y_off,
    3,
    3,
    4,
    4,
    bw,
    bh,
  )
  let base = 3 + 3 * hevc_mc_luma_stride
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        dst[(y0 + j) * dst_stride + x0 + i] = buf[base + j * hevc_mc_luma_stride + i]
      }
    }
  } else if my == 0 {
    let f = hevc_qpel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((hevc_qpel_h(buf, row + i, f) + 32) >> 6)
      }
    }
  } else if mx == 0 {
    let f = hevc_qpel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, f)
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((v + 32) >> 6)
      }
    }
  } else {
    let fh = hevc_qpel_filters[mx]
    let fv = hevc_qpel_filters[my]
    let tmp : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 7) {
      let row = j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh)
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = hevc_qpel_v(tmp, tbase + j * hevc_mc_max_pb + i, fv) >> 6
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((v + 32) >> 6)
      }
    }
  }
}

///|
/// `luma_mc_bi`: dst = clip((interp(ref1, mv1) + interp(ref0, mv0) + 64) >> 7)
/// with the list-0 interpolation kept in an int16 scratch. */
fn hevc_luma_mc_bi(
  ref0_plane : Array[Int32],
  ref0_stride : Int32,
  ref1_plane : Array[Int32],
  ref1_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_luma_stride * hevc_mc_luma_stride,
    0,
  )
  let tmp : FixedArray[Int32] = FixedArray::make(
    hevc_mc_max_pb * (hevc_mc_max_pb + 8),
    0,
  )
  let x_off0 = x0 + (mv0x >> 2)
  let y_off0 = y0 + (mv0y >> 2)
  hevc_fill_edge(
    buf,
    hevc_mc_luma_stride,
    ref0_plane,
    ref0_stride,
    rw,
    rh,
    x_off0,
    y_off0,
    3,
    3,
    4,
    4,
    bw,
    bh,
  )
  let mx0 = mv0x & 3
  let my0 = mv0y & 3
  let base = 3 + 3 * hevc_mc_luma_stride
  if mx0 == 0 && my0 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = buf[base + j * hevc_mc_luma_stride + i] << 6
      }
    }
  } else if my0 == 0 {
    let f = hevc_qpel_filters[mx0]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, f)
      }
    }
  } else if mx0 == 0 {
    let f = hevc_qpel_filters[my0]
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, f)
      }
    }
  } else {
    let fh = hevc_qpel_filters[mx0]
    let fv = hevc_qpel_filters[my0]
    let tmp2 : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 7) {
      let row = j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh)
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_v(tmp2, tbase + j * hevc_mc_max_pb + i, fv) >> 6
      }
    }
  }
  let x_off1 = x0 + (mv1x >> 2)
  let y_off1 = y0 + (mv1y >> 2)
  hevc_fill_edge(
    buf,
    hevc_mc_luma_stride,
    ref1_plane,
    ref1_stride,
    rw,
    rh,
    x_off1,
    y_off1,
    3,
    3,
    4,
    4,
    bw,
    bh,
  )
  let mx1 = mv1x & 3
  let my1 = mv1y & 3
  if mx1 == 0 && my1 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((buf[base + j * hevc_mc_luma_stride + i] << 6) + tmp[j * hevc_mc_max_pb + i] + 64) >> 7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else if my1 == 0 {
    let f = hevc_qpel_filters[mx1]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        let v = (hevc_qpel_h(buf, row + i, f) + tmp[j * hevc_mc_max_pb + i] + 64) >> 7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else if mx1 == 0 {
    let f = hevc_qpel_filters[my1]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, f) +
        tmp[j * hevc_mc_max_pb + i] +
        64) >>
        7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else {
    let fh = hevc_qpel_filters[mx1]
    let fv = hevc_qpel_filters[my1]
    let tmp2 : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 7) {
      let row = j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh)
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_qpel_v(tmp2, tbase + j * hevc_mc_max_pb + i, fv) >> 6) +
        tmp[j * hevc_mc_max_pb + i] +
        64) >>
        7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  }
}

///|
/// Weighted uni luma: dst = clip(((F * wx + offset) >> shift) + ox), with
/// `shift = denom + 6` (8-bit). */
fn hevc_luma_mc_uni_w(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  denom : Int32,
  wx : Int32,
  ox : Int32,
) -> Unit {
  let shift = denom + 6
  let offset = 1 << (shift - 1)
  let scratch : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_luma_mc_raw(
    ref_plane,
    ref_stride,
    rw,
    rh,
    scratch,
    bw,
    x0,
    y0,
    mvx,
    mvy,
    bw,
    bh,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let f = scratch[j * bw + i]
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(((f * wx + offset) >> shift) + ox)
    }
  }
}

///|
/// Raw luma interpolation into `out` (no clip, no rounding offsets): the
/// `put_hevc_qpel`/`pel_pixels` family, used by the weighted paths. */
fn hevc_luma_mc_raw(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  out : FixedArray[Int32],
  out_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let mx = mvx & 3
  let my = mvy & 3
  let x_off = x0 + (mvx >> 2)
  let y_off = y0 + (mvy >> 2)
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_luma_stride * hevc_mc_luma_stride,
    0,
  )
  hevc_fill_edge(
    buf,
    hevc_mc_luma_stride,
    ref_plane,
    ref_stride,
    rw,
    rh,
    x_off,
    y_off,
    3,
    3,
    4,
    4,
    bw,
    bh,
  )
  let base = 3 + 3 * hevc_mc_luma_stride
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = buf[base + j * hevc_mc_luma_stride + i] << 6
      }
    }
  } else if my == 0 {
    let f = hevc_qpel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_h(buf, row + i, f)
      }
    }
  } else if mx == 0 {
    let f = hevc_qpel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, f)
      }
    }
  } else {
    let fh = hevc_qpel_filters[mx]
    let fv = hevc_qpel_filters[my]
    let tmp : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 7) {
      let row = j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh)
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_v(tmp, tbase + j * hevc_mc_max_pb + i, fv) >> 6
      }
    }
  }
}

///|
/// Weighted bi luma (`put_hevc_qpel_bi_w*`):
/// dst = clip((F1 * wx1 + tmp * wx0 + (ox0 + ox1 + 1) << log2Wd) >> (log2Wd+1)). */
fn hevc_luma_mc_bi_w(
  ref0_plane : Array[Int32],
  ref0_stride : Int32,
  ref1_plane : Array[Int32],
  ref1_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
  bw : Int32,
  bh : Int32,
  denom : Int32,
  wx0 : Int32,
  wx1 : Int32,
  ox0 : Int32,
  ox1 : Int32,
) -> Unit {
  let log2_wd = denom + 6
  let wshift = log2_wd + 1
  let scratch0 : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_luma_mc_raw(
    ref0_plane,
    ref0_stride,
    rw,
    rh,
    scratch0,
    bw,
    x0,
    y0,
    mv0x,
    mv0y,
    bw,
    bh,
  )
  let scratch1 : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_luma_mc_raw(
    ref1_plane,
    ref1_stride,
    rw,
    rh,
    scratch1,
    bw,
    x0,
    y0,
    mv1x,
    mv1y,
    bw,
    bh,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let s2 = scratch0[j * bw + i]
      let f1 = scratch1[j * bw + i]
      let v = (f1 * wx1 + s2 * wx0 + (ox0 + ox1 + 1) * (1 << log2_wd)) >> wshift
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
    }
  }
}

///|
/// `chroma_mc_uni` (4:2:0, hshift = vshift = 1). `mvx`/`mvy` are luma MVs;
/// chroma positions and fractions derive from them. */
fn hevc_chroma_mc_uni(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let mx = mvx & 7
  let my = mvy & 7
  let x_off = x0 + (mvx >> 3)
  let y_off = y0 + (mvy >> 3)
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_chroma_stride * hevc_mc_chroma_stride,
    0,
  )
  hevc_fill_edge(
    buf,
    hevc_mc_chroma_stride,
    ref_plane,
    ref_stride,
    rw,
    rh,
    x_off,
    y_off,
    1,
    1,
    2,
    2,
    bw,
    bh,
  )
  let base = 1 + 1 * hevc_mc_chroma_stride
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        dst[(y0 + j) * dst_stride + x0 + i] = buf[base + j * hevc_mc_chroma_stride + i]
      }
    }
  } else if my == 0 {
    let f = hevc_epel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((hevc_epel_h(buf, row + i, f) + 32) >> 6)
      }
    }
  } else if mx == 0 {
    let f = hevc_epel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, f)
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((v + 32) >> 6)
      }
    }
  } else {
    let fh = hevc_epel_filters[mx]
    let fv = hevc_epel_filters[my]
    let tmp : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 3) {
      let row = j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh)
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = hevc_epel_v(tmp, tbase + j * hevc_mc_max_pb + i, fv) >> 6
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8((v + 32) >> 6)
      }
    }
  }
}

///|
/// Raw chroma interpolation (no clip), for the weighted paths. */
fn hevc_chroma_mc_raw(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  out : FixedArray[Int32],
  out_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let mx = mvx & 7
  let my = mvy & 7
  let x_off = x0 + (mvx >> 3)
  let y_off = y0 + (mvy >> 3)
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_chroma_stride * hevc_mc_chroma_stride,
    0,
  )
  hevc_fill_edge(
    buf,
    hevc_mc_chroma_stride,
    ref_plane,
    ref_stride,
    rw,
    rh,
    x_off,
    y_off,
    1,
    1,
    2,
    2,
    bw,
    bh,
  )
  let base = 1 + 1 * hevc_mc_chroma_stride
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = buf[base + j * hevc_mc_chroma_stride + i] << 6
      }
    }
  } else if my == 0 {
    let f = hevc_epel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_h(buf, row + i, f)
      }
    }
  } else if mx == 0 {
    let f = hevc_epel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, f)
      }
    }
  } else {
    let fh = hevc_epel_filters[mx]
    let fv = hevc_epel_filters[my]
    let tmp : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 3) {
      let row = j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh)
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_v(tmp, tbase + j * hevc_mc_max_pb + i, fv) >> 6
      }
    }
  }
}

///|
/// Weighted uni chroma. `ox` is the remapped `chroma_offset_lx`. */
fn hevc_chroma_mc_uni_w(
  ref_plane : Array[Int32],
  ref_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  denom : Int32,
  wx : Int32,
  ox : Int32,
) -> Unit {
  let shift = denom + 6
  let offset = 1 << (shift - 1)
  let scratch : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_chroma_mc_raw(
    ref_plane,
    ref_stride,
    rw,
    rh,
    scratch,
    bw,
    x0,
    y0,
    mvx,
    mvy,
    bw,
    bh,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let f = scratch[j * bw + i]
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(((f * wx + offset) >> shift) + ox)
    }
  }
}

///|
/// `chroma_mc_bi` without weights:
/// dst = clip((interp(ref1) + interp(ref0) + 64) >> 7). */
fn hevc_chroma_mc_bi(
  ref0_plane : Array[Int32],
  ref0_stride : Int32,
  ref1_plane : Array[Int32],
  ref1_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
  bw : Int32,
  bh : Int32,
) -> Unit {
  let buf : FixedArray[Int32] = FixedArray::make(
    hevc_mc_chroma_stride * hevc_mc_chroma_stride,
    0,
  )
  let tmp : FixedArray[Int32] = FixedArray::make(
    hevc_mc_max_pb * (hevc_mc_max_pb + 8),
    0,
  )
  let x_off0 = x0 + (mv0x >> 3)
  let y_off0 = y0 + (mv0y >> 3)
  hevc_fill_edge(
    buf,
    hevc_mc_chroma_stride,
    ref0_plane,
    ref0_stride,
    rw,
    rh,
    x_off0,
    y_off0,
    1,
    1,
    2,
    2,
    bw,
    bh,
  )
  let mx0 = mv0x & 7
  let my0 = mv0y & 7
  let base = 1 + 1 * hevc_mc_chroma_stride
  if mx0 == 0 && my0 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = buf[base + j * hevc_mc_chroma_stride + i] << 6
      }
    }
  } else if my0 == 0 {
    let f = hevc_epel_filters[mx0]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, f)
      }
    }
  } else if mx0 == 0 {
    let f = hevc_epel_filters[my0]
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, f)
      }
    }
  } else {
    let fh = hevc_epel_filters[mx0]
    let fv = hevc_epel_filters[my0]
    let tmp2 : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 3) {
      let row = j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh)
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_v(tmp2, tbase + j * hevc_mc_max_pb + i, fv) >> 6
      }
    }
  }
  let x_off1 = x0 + (mv1x >> 3)
  let y_off1 = y0 + (mv1y >> 3)
  hevc_fill_edge(
    buf,
    hevc_mc_chroma_stride,
    ref1_plane,
    ref1_stride,
    rw,
    rh,
    x_off1,
    y_off1,
    1,
    1,
    2,
    2,
    bw,
    bh,
  )
  let mx1 = mv1x & 7
  let my1 = mv1y & 7
  if mx1 == 0 && my1 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((buf[base + j * hevc_mc_chroma_stride + i] << 6) + tmp[j * hevc_mc_max_pb + i] + 64) >> 7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else if my1 == 0 {
    let f = hevc_epel_filters[mx1]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        let v = (hevc_epel_h(buf, row + i, f) + tmp[j * hevc_mc_max_pb + i] + 64) >> 7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else if mx1 == 0 {
    let f = hevc_epel_filters[my1]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, f) +
        tmp[j * hevc_mc_max_pb + i] +
        64) >>
        7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  } else {
    let fh = hevc_epel_filters[mx1]
    let fv = hevc_epel_filters[my1]
    let tmp2 : FixedArray[Int32] = FixedArray::make(
      hevc_mc_max_pb * (hevc_mc_max_pb + 8),
      0,
    )
    for j in 0..<(bh + 3) {
      let row = j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh)
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_epel_v(tmp2, tbase + j * hevc_mc_max_pb + i, fv) >> 6) +
        tmp[j * hevc_mc_max_pb + i] +
        64) >>
        7
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
      }
    }
  }
}

///|
/// Weighted bi chroma. */
fn hevc_chroma_mc_bi_w(
  ref0_plane : Array[Int32],
  ref0_stride : Int32,
  ref1_plane : Array[Int32],
  ref1_stride : Int32,
  rw : Int32,
  rh : Int32,
  dst : Array[Int32],
  dst_stride : Int32,
  x0 : Int32,
  y0 : Int32,
  mv0x : Int32,
  mv0y : Int32,
  mv1x : Int32,
  mv1y : Int32,
  bw : Int32,
  bh : Int32,
  denom : Int32,
  wx0 : Int32,
  wx1 : Int32,
  ox0 : Int32,
  ox1 : Int32,
) -> Unit {
  let log2_wd = denom + 6
  let wshift = log2_wd + 1
  let scratch0 : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_chroma_mc_raw(
    ref0_plane,
    ref0_stride,
    rw,
    rh,
    scratch0,
    bw,
    x0,
    y0,
    mv0x,
    mv0y,
    bw,
    bh,
  )
  let scratch1 : FixedArray[Int32] = FixedArray::make(bw * bh, 0)
  hevc_chroma_mc_raw(
    ref1_plane,
    ref1_stride,
    rw,
    rh,
    scratch1,
    bw,
    x0,
    y0,
    mv1x,
    mv1y,
    bw,
    bh,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let s2 = scratch0[j * bw + i]
      let f1 = scratch1[j * bw + i]
      let v = (f1 * wx1 + s2 * wx0 + (ox0 + ox1 + 1) * (1 << log2_wd)) >> wshift
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip_u8(v)
    }
  }
}
