///|
/// HEVC motion compensation: luma 8-tap qpel / chroma 4-tap epel interpolation
/// for uni/bi prediction, with and without explicit weights, plus the
/// `ff_emulated_edge_mc` boundary replication. Ported from FFmpeg 9.0.2
/// `libavcodec/h26x/h2656_inter_template.c` (uni/weighted paths) and
/// `libavcodec/hevc/dsp_template.c` (bi paths).
///
/// Bit depth: the C normalizes every filter sum to an 8-bit-equivalent scale
/// (`>> (BIT_DEPTH - 8)`, truncating) and shifts back by `14 - BIT_DEPTH`
/// (`15 - BIT_DEPTH` for bi), so the arithmetic below mirrors that chain
/// exactly instead of interpolating at native precision. For 8-bit all
/// normalizations are the identity and the formulas reduce to the classic
/// `(f + 32) >> 6` / `(a + b + 64) >> 7`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// HEVC luma qpel filters (8-tap, per quarter-pel fraction; the C stores 16
/// taps per row, only the first 8 are used). Sum = 64. */
let hevc_qpel_filters : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0, 0, 0, 0, 0],
  [-1, 4, -10, 58, 17, -5, 1, 0],
  [-1, 4, -11, 40, 40, -11, 4, -1],
  [0, 1, -5, 17, 58, -10, 4, -1],
]

///|
/// HEVC chroma epel filters (4-tap, per eighth-pel fraction, sum = 64). */
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
/// `av_clip_uintp2(v, BIT_DEPTH)`: clip a sample to the coded bit depth. */
fn hevc_mc_clip(v : Int32, bd : Int32) -> Int32 {
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
/// `ff_emulated_edge_mc`: copy the window of `block_w` x `block_h` whose top
/// left sample sits at `(x, y)`, padded by `ex_l`/`ex_t` columns/rows before
/// the block, replicating out-of-bounds samples from the picture edge. */
fn hevc_fill_edge(
  buf : FixedArray[Int32],
  buf_stride : Int32,
  plane : Array[Int32],
  plane_stride : Int32,
  rw : Int32,
  rh : Int32,
  x : Int32,
  y : Int32,
  ex_l : Int32,
  ex_t : Int32,
  ex_r : Int32,
  ex_b : Int32,
  block_w : Int32,
  block_h : Int32,
) -> Unit {
  let w = block_w + ex_l + ex_r
  let h = block_h + ex_t + ex_b
  let src_x = x - ex_l
  let src_y = y - ex_t
  let mut j = 0
  while j < h {
    let sy = src_y + j
    let row = if sy < 0 {
      0
    } else if sy >= rh {
      rh - 1
    } else {
      sy
    }
    let mut i = 0
    while i < w {
      let sx = src_x + i
      let col = if sx < 0 {
        0
      } else if sx >= rw {
        rw - 1
      } else {
        sx
      }
      buf[j * buf_stride + i] = plane[row * plane_stride + col]
      i = i + 1
    }
    j = j + 1
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
fn hevc_qpel_v(
  buf : FixedArray[Int32],
  idx : Int32,
  stride : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * buf[idx - 3 * stride] +
  f[1] * buf[idx - 2 * stride] +
  f[2] * buf[idx - stride] +
  f[3] * buf[idx] +
  f[4] * buf[idx + stride] +
  f[5] * buf[idx + 2 * stride] +
  f[6] * buf[idx + 3 * stride] +
  f[7] * buf[idx + 4 * stride]
}

///|
/// Horizontal 4-tap filter: `sum f[k] * row[i + k - 1]`. */
fn hevc_epel_h(row : FixedArray[Int32], i : Int32, f : FixedArray[Int32]) -> Int32 {
  f[0] * row[i - 1] + f[1] * row[i] + f[2] * row[i + 1] + f[3] * row[i + 2]
}

///|
/// Vertical 4-tap filter over a MAX_PB_SIZE-stride int buffer. */
fn hevc_epel_v(
  buf : FixedArray[Int32],
  idx : Int32,
  stride : Int32,
  f : FixedArray[Int32],
) -> Int32 {
  f[0] * buf[idx - stride] +
  f[1] * buf[idx] +
  f[2] * buf[idx + stride] +
  f[3] * buf[idx + 2 * stride]
}

///|
/// `luma_mc_uni` without the weight flag. Writes `bw` x `bh` samples at
/// `(x0, y0)` of the destination plane. `bd` is the coded bit depth. */
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
  bd : Int32,
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
  let norm = bd - 8
  let shift = 14 - bd
  let offset = 1 << (shift - 1)
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
        let v = (hevc_qpel_h(buf, row + i, f) >> norm) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
      }
    }
  } else if mx == 0 {
    let f = hevc_qpel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, hevc_mc_luma_stride, f) >> norm) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
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
      let row = 3 + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_qpel_v(tmp, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
      }
    }
  }
}

///|
/// `luma_mc_bi` without weights: the list-0 prediction is normalized into an
/// int16 scratch (`put_luma_*`), the list-1 side is interpolated inline and
/// the two are averaged in the 14-bit domain (`put_hevc_qpel_bi_*`). */
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
  bd : Int32,
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
  let norm = bd - 8
  let shift = 15 - bd
  let offset = 1 << (shift - 1)
  // list-0 prediction -> tmp (normalized, int16 range in the C)
  if mx0 == 0 && my0 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = buf[base + j * hevc_mc_luma_stride + i] << (14 - bd)
      }
    }
  } else if my0 == 0 {
    let f = hevc_qpel_filters[mx0]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, f) >> norm
      }
    }
  } else if mx0 == 0 {
    let f = hevc_qpel_filters[my0]
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, hevc_mc_luma_stride, f) >> norm
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
      let row = 3 + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_v(tmp2, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6
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
        let v = ((buf[base + j * hevc_mc_luma_stride + i] << (14 - bd)) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  } else if my1 == 0 {
    let f = hevc_qpel_filters[mx1]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        let v = ((hevc_qpel_h(buf, row + i, f) >> norm) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  } else if mx1 == 0 {
    let f = hevc_qpel_filters[my1]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, hevc_mc_luma_stride, f) >> norm) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
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
      let row = 3 + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_qpel_v(tmp2, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  }
}

///|
/// Weighted uni luma (`put_hevc_qpel_uni_w_*`): the raw interpolation is
/// normalized (`>> (bd-8)`), then `((raw * wx + offset) >> shift) + ox` with
/// `shift = denom + 14 - bd` and `ox` scaled by `1 << (bd-8)`. */
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
  bd : Int32,
) -> Unit {
  let shift = denom + 14 - bd
  let offset = 1 << (shift - 1)
  let oxs = ox * (1 << (bd - 8))
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
    bd,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let f = scratch[j * bw + i]
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(((f * wx + offset) >> shift) + oxs, bd)
    }
  }
}

///|
/// Raw luma interpolation (`put_luma_*`): writes the normalized value the C
/// keeps in its int16 scratch — integer `<< (14-bd)`, filtered `>> (bd-8)`,
/// and for hv the horizontal pass normalized before the vertical `>> 6`. */
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
  bd : Int32,
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
  let norm = bd - 8
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = buf[base + j * hevc_mc_luma_stride + i] << (14 - bd)
      }
    }
  } else if my == 0 {
    let f = hevc_qpel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_luma_stride
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_h(buf, row + i, f) >> norm
      }
    }
  } else if mx == 0 {
    let f = hevc_qpel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_v(buf, base + j * hevc_mc_luma_stride + i, hevc_mc_luma_stride, f) >> norm
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
      let row = 3 + j * hevc_mc_luma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_qpel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 3 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_qpel_v(tmp, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6
      }
    }
  }
}

///|
/// Weighted bi luma (`put_hevc_qpel_bi_w_*`):
/// dst = clip((F1 * wx1 + tmp * wx0 + (ox0 + ox1 + 1) << log2Wd) >> (log2Wd+1))
/// with `log2Wd = denom + 14 - bd` and the offsets scaled by `1 << (bd-8)`. */
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
  bd : Int32,
) -> Unit {
  let log2_wd = denom + 14 - bd
  let wshift = log2_wd + 1
  let ox0s = ox0 * (1 << (bd - 8))
  let ox1s = ox1 * (1 << (bd - 8))
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
    bd,
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
    bd,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let s2 = scratch0[j * bw + i]
      let f1 = scratch1[j * bw + i]
      let v = (f1 * wx1 + s2 * wx0 + (ox0s + ox1s + 1) * (1 << log2_wd)) >> wshift
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
    }
  }
}

///|
/// `chroma_mc_uni` (4:2:0, hshift = vshift = 1). `mvx`/`mvy` are luma MVs;
/// chroma positions and fractions derive from them. `bd` is the bit depth. */
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
  bd : Int32,
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
  let norm = bd - 8
  let shift = 14 - bd
  let offset = 1 << (shift - 1)
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
        let v = (hevc_epel_h(buf, row + i, f) >> norm) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
      }
    }
  } else if mx == 0 {
    let f = hevc_epel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, hevc_mc_chroma_stride, f) >> norm) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
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
      let row = 1 + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = (hevc_epel_v(tmp, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6) + offset
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v >> shift, bd)
      }
    }
  }
}

///|
/// Raw chroma interpolation (`put_chroma_*`): normalized values, same scheme
/// as the luma raw path. */
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
  bd : Int32,
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
  let norm = bd - 8
  if mx == 0 && my == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = buf[base + j * hevc_mc_chroma_stride + i] << (14 - bd)
      }
    }
  } else if my == 0 {
    let f = hevc_epel_filters[mx]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_h(buf, row + i, f) >> norm
      }
    }
  } else if mx == 0 {
    let f = hevc_epel_filters[my]
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, hevc_mc_chroma_stride, f) >> norm
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
      let row = 1 + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        out[j * out_stride + i] = hevc_epel_v(tmp, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6
      }
    }
  }
}

///|
/// Weighted uni chroma (`put_hevc_epel_uni_w_*`). `ox` is the remapped
/// `chroma_offset_lx`; same shift scheme as the luma weighted path. */
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
  bd : Int32,
) -> Unit {
  let shift = denom + 14 - bd
  let offset = 1 << (shift - 1)
  let oxs = ox * (1 << (bd - 8))
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
    bd,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let f = scratch[j * bw + i]
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(((f * wx + offset) >> shift) + oxs, bd)
    }
  }
}

///|
/// `chroma_mc_bi` without weights: same normalized averaging as the luma bi
/// path, with the 4-tap filters. */
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
  bd : Int32,
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
  let norm = bd - 8
  let shift = 15 - bd
  let offset = 1 << (shift - 1)
  if mx0 == 0 && my0 == 0 {
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = buf[base + j * hevc_mc_chroma_stride + i] << (14 - bd)
      }
    }
  } else if my0 == 0 {
    let f = hevc_epel_filters[mx0]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, f) >> norm
      }
    }
  } else if mx0 == 0 {
    let f = hevc_epel_filters[my0]
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, hevc_mc_chroma_stride, f) >> norm
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
      let row = 1 + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        tmp[j * hevc_mc_max_pb + i] = hevc_epel_v(tmp2, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6
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
        let v = ((buf[base + j * hevc_mc_chroma_stride + i] << (14 - bd)) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  } else if my1 == 0 {
    let f = hevc_epel_filters[mx1]
    for j in 0..<bh {
      let row = base + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        let v = ((hevc_epel_h(buf, row + i, f) >> norm) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  } else if mx1 == 0 {
    let f = hevc_epel_filters[my1]
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_epel_v(buf, base + j * hevc_mc_chroma_stride + i, hevc_mc_chroma_stride, f) >> norm) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
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
      let row = 1 + j * hevc_mc_chroma_stride
      for i in 0..<bw {
        tmp2[j * hevc_mc_max_pb + i] = hevc_epel_h(buf, row + i, fh) >> norm
      }
    }
    let tbase = 1 * hevc_mc_max_pb
    for j in 0..<bh {
      for i in 0..<bw {
        let v = ((hevc_epel_v(tmp2, tbase + j * hevc_mc_max_pb + i, hevc_mc_max_pb, fv) >> 6) +
        tmp[j * hevc_mc_max_pb + i] +
        offset) >>
        shift
        dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
      }
    }
  }
}

///|
/// Weighted bi chroma (`put_hevc_epel_bi_w_*`): same scheme as the luma
/// weighted bi path. */
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
  bd : Int32,
) -> Unit {
  let log2_wd = denom + 14 - bd
  let wshift = log2_wd + 1
  let ox0s = ox0 * (1 << (bd - 8))
  let ox1s = ox1 * (1 << (bd - 8))
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
    bd,
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
    bd,
  )
  for j in 0..<bh {
    for i in 0..<bw {
      let s2 = scratch0[j * bw + i]
      let f1 = scratch1[j * bw + i]
      let v = (f1 * wx1 + s2 * wx0 + (ox0s + ox1s + 1) * (1 << log2_wd)) >> wshift
      dst[(y0 + j) * dst_stride + x0 + i] = hevc_mc_clip(v, bd)
    }
  }
}
