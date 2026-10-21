///|
/// HEVC deblocking filter, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/filter.c` and `libavcodec/h26x/h2656_deblock_template.c`
/// for 8-bit 4:2:0 all-intra pictures with a single slice (no tiles, no PCM,
/// no transquant bypass).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_tctable : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20,
  22, 24,
]

///|
let hevc_betatable : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6, 7, 8, 9, 10, 11, 12, 13, 14,
  15, 16, 17, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50,
  52, 54, 56, 58, 60, 62, 64,
]

///|
let hevc_deblock_qp_c : FixedArray[Int32] = [
  29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37,
]

///|
fn hevc_clip_i(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn hevc_abs_i(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
/// `get_qPy`: luma QP of the min-CB containing `(x, y)`. */
fn hevc_qp_at(
  sps : HevcSps,
  qp_tab : Array[Int32],
  x : Int32,
  y : Int32,
) -> Int32 {
  qp_tab[(x >> sps.log2_min_cb_size) +
  (y >> sps.log2_min_cb_size) * sps.min_cb_width]
}

///|
/// `TC_CALC(qp, bs)`. */
fn hevc_tc_calc(qp : Int32, bs : Int32, tc_offset : Int32) -> Int32 {
  hevc_tctable[hevc_clip_i(qp + 2 * (bs - 1) + (tc_offset & -2), 0, 53)]
}

///|
/// `chroma_tc` for the deblock filter (PPS offsets only). */
fn hevc_chroma_tc(
  pps : HevcPps,
  qp_y : Int32,
  c_idx : Int32,
  tc_offset : Int32,
) -> Int32 {
  let offset = if c_idx == 1 { pps.cb_qp_offset } else { pps.cr_qp_offset }
  let qp_i = hevc_clip_i(qp_y + offset, 0, 57)
  let qp = if qp_i < 30 {
    qp_i
  } else if qp_i > 43 {
    qp_i - 6
  } else {
    hevc_deblock_qp_c[qp_i - 30]
  }
  hevc_tctable[hevc_clip_i(qp + 2 + tc_offset, 0, 53)]
}

///|
/// One four-sample luma line group. */
fn hevc_luma_group(
  plane : Array[Int32],
  base : Int32,
  xp : Int32,
  yp : Int32,
  beta : Int32,
  tc : Int32,
) -> Unit {
  let p3 = plane[base - 4 * xp]
  let p2 = plane[base - 3 * xp]
  let p1 = plane[base - 2 * xp]
  let p0 = plane[base - xp]
  let q0 = plane[base]
  let q1 = plane[base + xp]
  let q2 = plane[base + 2 * xp]
  let q3 = plane[base + 3 * xp]
  let dp0 = hevc_abs_i(p2 - 2 * p1 + p0)
  let dq0 = hevc_abs_i(q2 - 2 * q1 + q0)
  let dp3 = hevc_abs_i(
    plane[base - 3 * xp + 3 * yp] -
    2 * plane[base - 2 * xp + 3 * yp] +
    plane[base - 1 * xp + 3 * yp],
  )
  let dq3 = hevc_abs_i(
    plane[base + 2 * xp + 3 * yp] -
    2 * plane[base + xp + 3 * yp] +
    plane[base + 3 * yp],
  )
  let d0 = dp0 + dq0
  let d3 = dp3 + dq3
  if d0 + d3 < beta {
    let beta_3 = beta >> 3
    let beta_2 = beta >> 2
    let tc25 = (tc * 5 + 1) >> 1
    let tp3 = plane[base - 4 * xp + 3 * yp]
    let tp0 = plane[base - 1 * xp + 3 * yp]
    let tq0 = plane[base + 3 * yp]
    let tq3 = plane[base + 3 * xp + 3 * yp]
    let strong = hevc_abs_i(p3 - p0) + hevc_abs_i(q3 - q0) < beta_3 &&
      hevc_abs_i(p0 - q0) < tc25 &&
      hevc_abs_i(tp3 - tp0) + hevc_abs_i(tq3 - tq0) < beta_3 &&
      hevc_abs_i(tp0 - tq0) < tc25 &&
      d0 << 1 < beta_2 &&
      d3 << 1 < beta_2
    if strong {
      let tc2 = tc << 1
      for d in 0..<4 {
        let b = base + d * yp
        let pp3 = plane[b - 4 * xp]
        let pp2 = plane[b - 3 * xp]
        let pp1 = plane[b - 2 * xp]
        let pp0 = plane[b - xp]
        let qq0 = plane[b]
        let qq1 = plane[b + xp]
        let qq2 = plane[b + 2 * xp]
        let qq3 = plane[b + 3 * xp]
        plane[b - xp] = hevc_clip_i(
          pp0 +
          hevc_clip_i(
            ((pp2 + 2 * pp1 + 2 * pp0 + 2 * qq0 + qq1 + 4) >> 3) - pp0,
            -tc2,
            tc2,
          ),
          0,
          255,
        )
        plane[b - 2 * xp] = hevc_clip_i(
          pp1 + hevc_clip_i(((pp2 + pp1 + pp0 + qq0 + 2) >> 2) - pp1, -tc2, tc2),
          0,
          255,
        )
        plane[b - 3 * xp] = hevc_clip_i(
          pp2 +
          hevc_clip_i(
            ((2 * pp3 + 3 * pp2 + pp1 + pp0 + qq0 + 4) >> 3) - pp2,
            -tc2,
            tc2,
          ),
          0,
          255,
        )
        plane[b] = hevc_clip_i(
          qq0 +
          hevc_clip_i(
            ((pp1 + 2 * pp0 + 2 * qq0 + 2 * qq1 + qq2 + 4) >> 3) - qq0,
            -tc2,
            tc2,
          ),
          0,
          255,
        )
        plane[b + xp] = hevc_clip_i(
          qq1 + hevc_clip_i(((pp0 + qq0 + qq1 + qq2 + 2) >> 2) - qq1, -tc2, tc2),
          0,
          255,
        )
        plane[b + 2 * xp] = hevc_clip_i(
          qq2 +
          hevc_clip_i(
            ((2 * qq3 + 3 * qq2 + qq1 + qq0 + pp0 + 4) >> 3) - qq2,
            -tc2,
            tc2,
          ),
          0,
          255,
        )
      }
    } else {
      let mut nd_p = 1
      let mut nd_q = 1
      if dp0 + dp3 < (beta + (beta >> 1)) >> 3 {
        nd_p = 2
      }
      if dq0 + dq3 < (beta + (beta >> 1)) >> 3 {
        nd_q = 2
      }
      let tc_2 = tc >> 1
      for d in 0..<4 {
        let b = base + d * yp
        let pp2 = plane[b - 3 * xp]
        let pp1 = plane[b - 2 * xp]
        let pp0 = plane[b - xp]
        let qq0 = plane[b]
        let qq1 = plane[b + xp]
        let qq2 = plane[b + 2 * xp]
        let mut delta0 = (9 * (qq0 - pp0) - 3 * (qq1 - pp1) + 8) >> 4
        if hevc_abs_i(delta0) < 10 * tc {
          delta0 = hevc_clip_i(delta0, -tc, tc)
          plane[b - xp] = hevc_clip_i(pp0 + delta0, 0, 255)
          plane[b] = hevc_clip_i(qq0 - delta0, 0, 255)
          if nd_p > 1 {
            let deltap1 = hevc_clip_i(
              (((pp2 + pp0 + 1) >> 1) - pp1 + delta0) >> 1,
              -tc_2,
              tc_2,
            )
            plane[b - 2 * xp] = hevc_clip_i(pp1 + deltap1, 0, 255)
          }
          if nd_q > 1 {
            let deltaq1 = hevc_clip_i(
              (((qq2 + qq0 + 1) >> 1) - qq1 - delta0) >> 1,
              -tc_2,
              tc_2,
            )
            plane[b + xp] = hevc_clip_i(qq1 + deltaq1, 0, 255)
          }
        }
      }
    }
  }
}

///|
/// `hevc_loop_filter_luma`: two groups of four samples. Groups that fall
/// outside the plane are skipped (FFmpeg writes them into frame padding).
fn hevc_deblock_luma(
  plane : Array[Int32],
  base : Int32,
  stride : Int32,
  vertical : Bool,
  beta : Int32,
  tc0 : Int32,
  tc1 : Int32,
) -> Unit {
  let xp = if vertical { 1 } else { stride }
  let yp = if vertical { stride } else { 1 }
  if base < plane.length() {
    hevc_luma_group(plane, base, xp, yp, beta, tc0)
  }
  if base + 4 * yp < plane.length() {
    hevc_luma_group(plane, base + 4 * yp, xp, yp, beta, tc1)
  }
}

///|
/// `hevc_loop_filter_chroma`: two groups of four samples. */
fn hevc_deblock_chroma(
  plane : Array[Int32],
  base : Int32,
  stride : Int32,
  vertical : Bool,
  tc0 : Int32,
  tc1 : Int32,
) -> Unit {
  let xp = if vertical { 1 } else { stride }
  let yp = if vertical { stride } else { 1 }
  for j in 0..<2 {
    let tc = if j == 0 { tc0 } else { tc1 }
    let group = base + j * 4 * yp
    if tc > 0 && group < plane.length() {
      for d in 0..<4 {
        let b = group + d * yp
        let p1 = plane[b - 2 * xp]
        let p0 = plane[b - xp]
        let q0 = plane[b]
        let q1 = plane[b + xp]
        let delta0 = hevc_clip_i(((q0 - p0) * 4 + p1 - q1 + 4) >> 3, -tc, tc)
        plane[b - xp] = hevc_clip_i(p0 + delta0, 0, 255)
        plane[b] = hevc_clip_i(q0 - delta0, 0, 255)
      }
    }
  }
}

///|
/// `deblocking_filter_CTB` for a single-slice, no-tile, all-intra picture.
pub fn hevc_deblock_picture(
  pic : HevcPicture,
  sps : HevcSps,
  pps : HevcPps,
  sh : HevcSliceHeader,
  qp_y_tab : Array[Int32],
  vertical_bs : Array[Int32],
  horizontal_bs : Array[Int32],
  bs_width : Int32,
) -> Unit {
  if sh.disable_deblocking_filter_flag {
    return
  }
  let ctb_size = 1 << sps.log2_ctb_size
  let tc_offset = sh.tc_offset
  let beta_offset = sh.beta_offset
  let y_plane = pic.y
  let stride_y = pic.width
  let cb_plane = pic.cb
  let cr_plane = pic.cr
  let cstride = pic.plane_stride(1)

  for ctb in 0..<sps.ctb_size {
    let x0 = (ctb % sps.ctb_width) << sps.log2_ctb_size
    let y0 = (ctb / sps.ctb_width) << sps.log2_ctb_size
    let mut x_end = x0 + ctb_size
    if x_end > sps.width {
      x_end = sps.width
    }
    let mut y_end = y0 + ctb_size
    if y_end > sps.height {
      y_end = sps.height
    }
    let mut x_end2 = x_end
    if x_end2 != sps.width {
      x_end2 = x_end2 - 8
    }

    // Luma
    let mut y = y0
    while y < y_end {
      let mut x = if x0 > 0 { x0 } else { 8 }
      while x < x_end {
        let bs0 = vertical_bs[(x + y * bs_width) >> 2]
        let bs1 = vertical_bs[(x + (y + 4) * bs_width) >> 2]
        if bs0 != 0 || bs1 != 0 {
          let qp = (
              hevc_qp_at(sps, qp_y_tab, x - 1, y) +
              hevc_qp_at(sps, qp_y_tab, x, y) +
              1
            ) >>
            1
          let beta = hevc_betatable[hevc_clip_i(qp + beta_offset, 0, 51)]
          let tc0 = if bs0 != 0 { hevc_tc_calc(qp, bs0, tc_offset) } else { 0 }
          let tc1 = if bs1 != 0 { hevc_tc_calc(qp, bs1, tc_offset) } else { 0 }
          hevc_deblock_luma(
            y_plane,
            y * stride_y + x,
            stride_y,
            true,
            beta,
            tc0,
            tc1,
          )
        }
        x = x + 8
      }
      if y != 0 {
        let mut x = if x0 > 0 { x0 - 8 } else { 0 }
        while x < x_end2 {
          let bs0 = horizontal_bs[(x + y * bs_width) >> 2]
          let bs1 = horizontal_bs[(x + 4 + y * bs_width) >> 2]
          if bs0 != 0 || bs1 != 0 {
            let qp = (
                hevc_qp_at(sps, qp_y_tab, x, y - 1) +
                hevc_qp_at(sps, qp_y_tab, x, y) +
                1
              ) >>
              1
            let beta = hevc_betatable[hevc_clip_i(qp + beta_offset, 0, 51)]
            let tc0 = if bs0 != 0 {
              hevc_tc_calc(qp, bs0, tc_offset)
            } else {
              0
            }
            let tc1 = if bs1 != 0 {
              hevc_tc_calc(qp, bs1, tc_offset)
            } else {
              0
            }
            hevc_deblock_luma(
              y_plane,
              y * stride_y + x,
              stride_y,
              false,
              beta,
              tc0,
              tc1,
            )
          }
          x = x + 8
        }
      }
      y = y + 8
    }

    // Chroma
    for chroma in 1..<=2 {
      let h = 1 << sps.hshift[chroma]
      let v = 1 << sps.vshift[chroma]
      let plane = if chroma == 1 { cb_plane } else { cr_plane }
      let mut y = y0
      while y < y_end {
        let mut x = if x0 > 0 { x0 } else { 8 * h }
        while x < x_end {
          let bs0 = vertical_bs[(x + y * bs_width) >> 2]
          let bs1 = vertical_bs[(x + (y + 4 * v) * bs_width) >> 2]
          if bs0 == 2 || bs1 == 2 {
            let qp0 = (
                hevc_qp_at(sps, qp_y_tab, x - 1, y) +
                hevc_qp_at(sps, qp_y_tab, x, y) +
                1
              ) >>
              1
            let qp1 = (
                hevc_qp_at(sps, qp_y_tab, x - 1, y + 4 * v) +
                hevc_qp_at(sps, qp_y_tab, x, y + 4 * v) +
                1
              ) >>
              1
            let tc0 = if bs0 == 2 {
              hevc_chroma_tc(pps, qp0, chroma, tc_offset)
            } else {
              0
            }
            let tc1 = if bs1 == 2 {
              hevc_chroma_tc(pps, qp1, chroma, tc_offset)
            } else {
              0
            }
            hevc_deblock_chroma(
              plane,
              (y >> sps.vshift[chroma]) * cstride + (x >> sps.hshift[chroma]),
              cstride,
              true,
              tc0,
              tc1,
            )
          }
          x = x + 8 * h
        }
        if y != 0 {
          let mut x_end2c = x_end
          if x_end != sps.width {
            x_end2c = x_end - 8 * h
          }
          let mut x = if x0 > 0 { x0 - 8 * h } else { 0 }
          while x < x_end2c {
            let bs0 = horizontal_bs[(x + y * bs_width) >> 2]
            let bs1 = horizontal_bs[(x + 4 * h + y * bs_width) >> 2]
            if bs0 == 2 || bs1 == 2 {
              let qp0 = if bs0 == 2 {
                (
                  hevc_qp_at(sps, qp_y_tab, x, y - 1) +
                  hevc_qp_at(sps, qp_y_tab, x, y) +
                  1
                ) >>
                1
              } else {
                0
              }
              let qp1 = if bs1 == 2 {
                (
                  hevc_qp_at(sps, qp_y_tab, x + 4 * h, y - 1) +
                  hevc_qp_at(sps, qp_y_tab, x + 4 * h, y) +
                  1
                ) >>
                1
              } else {
                0
              }
              let tc0 = if bs0 == 2 {
                hevc_chroma_tc(pps, qp0, chroma, tc_offset)
              } else {
                0
              }
              let tc1 = if bs1 == 2 {
                hevc_chroma_tc(pps, qp1, chroma, tc_offset)
              } else {
                0
              }
              hevc_deblock_chroma(
                plane,
                (y >> sps.vshift[chroma]) * cstride + (x >> sps.hshift[chroma]),
                cstride,
                false,
                tc0,
                tc1,
              )
            }
            x = x + 8 * h
          }
        }
        y = y + 8 * v
      }
    }
  }
}
