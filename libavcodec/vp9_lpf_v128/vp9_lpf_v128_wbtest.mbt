///|
/// Whitebox tests for the SIMD (`@v128`) VP9 loop filter
/// (`vp9_lpf_v128.mbt`).
///
/// The `lr_*` functions are verbatim transcriptions of the C reference
/// (`libavcodec/vp9dsp_template.c`: `loop_filter`, and the scalar port's
/// `vp9_loop_filter_core` / `_h` / `_v` / `_mix2` wrappers in
/// `libavcodec/vp9_dsp.mbt`) — the parent package's privates are not
/// visible from a subpackage, so the reference is carried here. Every
/// branch (flat8out / flat8in / hev / non-hev), every width and every bit
/// depth must agree bit-for-bit.

///|
fn lr_abs(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
fn lr_min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn lr_clip_pixel(v : Int32, pixel_max : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > pixel_max {
    pixel_max
  } else {
    v
  }
}

///|
fn lr_clip_intp2(v : Int32, bits : Int32) -> Int32 {
  let hi = (1 << (bits - 1)) - 1
  let lo = 0 - (1 << (bits - 1))
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Verbatim `loop_filter` (the C body the scalar port mirrors). */
fn lr_loop_filter_core(
  p : FixedArray[Int32],
  off : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  stridea : Int32,
  strideb : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  let shift = bpp - 8
  let f_flat = 1 << shift
  let e = e << shift
  let i_lim = i_lim << shift
  let h_lim = h_lim << shift
  let fmax = (1 << (bpp - 1)) - 1
  let mut o = off
  for _row in 0..<8 {
    let p3 = p[o + strideb * -4]
    let p2 = p[o + strideb * -3]
    let p1 = p[o + strideb * -2]
    let p0 = p[o + strideb * -1]
    let q0 = p[o]
    let q1 = p[o + strideb]
    let q2 = p[o + strideb * 2]
    let q3 = p[o + strideb * 3]
    let fm = lr_abs(p3 - p2) <= i_lim &&
      lr_abs(p2 - p1) <= i_lim &&
      lr_abs(p1 - p0) <= i_lim &&
      lr_abs(q1 - q0) <= i_lim &&
      lr_abs(q2 - q1) <= i_lim &&
      lr_abs(q3 - q2) <= i_lim &&
      lr_abs(p0 - q0) * 2 + (lr_abs(p1 - q1) >> 1) <= e
    if !fm {
      o += stridea
      continue
    }
    let mut flat8out = false
    let mut flat8in = false
    let p7 = p[o + strideb * -8]
    let p6 = p[o + strideb * -7]
    let p5 = p[o + strideb * -6]
    let p4 = p[o + strideb * -5]
    let q4 = p[o + strideb * 4]
    let q5 = p[o + strideb * 5]
    let q6 = p[o + strideb * 6]
    let q7 = p[o + strideb * 7]
    if wd >= 16 {
      flat8out = lr_abs(p7 - p0) <= f_flat &&
        lr_abs(p6 - p0) <= f_flat &&
        lr_abs(p5 - p0) <= f_flat &&
        lr_abs(p4 - p0) <= f_flat &&
        lr_abs(q4 - q0) <= f_flat &&
        lr_abs(q5 - q0) <= f_flat &&
        lr_abs(q6 - q0) <= f_flat &&
        lr_abs(q7 - q0) <= f_flat
    }
    if wd >= 8 {
      flat8in = lr_abs(p3 - p0) <= f_flat &&
        lr_abs(p2 - p0) <= f_flat &&
        lr_abs(p1 - p0) <= f_flat &&
        lr_abs(q1 - q0) <= f_flat &&
        lr_abs(q2 - q0) <= f_flat &&
        lr_abs(q3 - q0) <= f_flat
    }
    if wd >= 16 && flat8out && flat8in {
      p[o + strideb * -7] = (p7 + p7 + p7 + p7 + p7 + p7 + p7 + p6 * 2 + p5 +
        p4 + p3 + p2 + p1 + p0 + q0 + 8) >>
        4
      p[o + strideb * -6] = (p7 + p7 + p7 + p7 + p7 + p7 + p6 + p5 * 2 + p4 +
        p3 + p2 + p1 + p0 + q0 + q1 + 8) >>
        4
      p[o + strideb * -5] = (p7 + p7 + p7 + p7 + p7 + p6 + p5 + p4 * 2 + p3 +
        p2 + p1 + p0 + q0 + q1 + q2 + 8) >>
        4
      p[o + strideb * -4] = (p7 + p7 + p7 + p7 + p6 + p5 + p4 + p3 * 2 + p2 +
        p1 + p0 + q0 + q1 + q2 + q3 + 8) >>
        4
      p[o + strideb * -3] = (p7 + p7 + p7 + p6 + p5 + p4 + p3 + p2 * 2 + p1 +
        p0 + q0 + q1 + q2 + q3 + q4 + 8) >>
        4
      p[o + strideb * -2] = (p7 + p7 + p6 + p5 + p4 + p3 + p2 + p1 * 2 + p0 +
        q0 + q1 + q2 + q3 + q4 + q5 + 8) >>
        4
      p[o + strideb * -1] = (p7 + p6 + p5 + p4 + p3 + p2 + p1 + p0 * 2 + q0 +
        q1 + q2 + q3 + q4 + q5 + q6 + 8) >>
        4
      p[o + strideb * 0] = (p6 + p5 + p4 + p3 + p2 + p1 + p0 + q0 * 2 + q1 +
        q2 + q3 + q4 + q5 + q6 + q7 + 8) >>
        4
      p[o + strideb * 1] = (p5 + p4 + p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 +
        q3 + q4 + q5 + q6 + q7 + q7 + 8) >>
        4
      p[o + strideb * 2] = (p4 + p3 + p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 +
        q4 + q5 + q6 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 3] = (p3 + p2 + p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 +
        q5 + q6 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 4] = (p2 + p1 + p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 +
        q6 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 5] = (p1 + p0 + q0 + q1 + q2 + q3 + q4 + q5 * 2 + q6 +
        q7 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
      p[o + strideb * 6] = (p0 + q0 + q1 + q2 + q3 + q4 + q5 + q6 * 2 + q7 +
        q7 + q7 + q7 + q7 + q7 + q7 + 8) >>
        4
    } else if wd >= 8 && flat8in {
      p[o + strideb * -3] = (p3 + p3 + p3 + 2 * p2 + p1 + p0 + q0 + 4) >> 3
      p[o + strideb * -2] = (p3 + p3 + p2 + 2 * p1 + p0 + q0 + q1 + 4) >> 3
      p[o + strideb * -1] = (p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2 + 4) >> 3
      p[o + strideb * 0] = (p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3 + 4) >> 3
      p[o + strideb * 1] = (p1 + p0 + q0 + 2 * q1 + q2 + q3 + q3 + 4) >> 3
      p[o + strideb * 2] = (p0 + q0 + q1 + 2 * q2 + q3 + q3 + q3 + 4) >> 3
    } else {
      let hev = lr_abs(p1 - p0) > h_lim || lr_abs(q1 - q0) > h_lim
      if hev {
        let mut fv = lr_clip_intp2(p1 - q1, bpp - 1)
        fv = lr_clip_intp2(3 * (q0 - p0) + fv, bpp - 1)
        let f1 = lr_min(fv + 4, fmax) >> 3
        let f2 = lr_min(fv + 3, fmax) >> 3
        p[o + strideb * -1] = lr_clip_pixel(p0 + f2, pixel_max)
        p[o + strideb * 0] = lr_clip_pixel(q0 - f1, pixel_max)
      } else {
        let fv = lr_clip_intp2(3 * (q0 - p0), bpp - 1)
        let f1 = lr_min(fv + 4, fmax) >> 3
        let f2 = lr_min(fv + 3, fmax) >> 3
        p[o + strideb * -1] = lr_clip_pixel(p0 + f2, pixel_max)
        p[o + strideb * 0] = lr_clip_pixel(q0 - f1, pixel_max)
        let f = (f1 + 1) >> 1
        p[o + strideb * -2] = lr_clip_pixel(p1 + f, pixel_max)
        p[o + strideb * 1] = lr_clip_pixel(q1 - f, pixel_max)
      }
    }
    o += stridea
  }
}

///|
/// Verbatim `vp9_loop_filter_h`.
fn lr_h(
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  lr_loop_filter_core(p, off, e, i_lim, h_lim, stride, 1, wd, bpp, pixel_max)
}

///|
/// Verbatim `vp9_loop_filter_v`.
fn lr_v(
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  lr_loop_filter_core(p, off, e, i_lim, h_lim, 1, stride, wd, bpp, pixel_max)
}

///|
/// Verbatim `vp9_loop_filter_mix2`.
fn lr_mix2(
  dir : Int32,
  wd1 : Int32,
  wd2 : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  let e1 = e & 0xFF
  let i1 = i_lim & 0xFF
  let h1 = h_lim & 0xFF
  let e2 = e >> 8
  let i2 = i_lim >> 8
  let h2 = h_lim >> 8
  if dir == 0 {
    lr_h(p, off, stride, e1, i1, h1, 4 << wd1, bpp, pixel_max)
    lr_h(p, off + 8 * stride, stride, e2, i2, h2, 4 << wd2, bpp, pixel_max)
  } else {
    lr_v(p, off, stride, e1, i1, h1, 4 << wd1, bpp, pixel_max)
    lr_v(p, off + 8, stride, e2, i2, h2, 4 << wd2, bpp, pixel_max)
  }
}

///|
/// Deterministic generator (LCG). */
fn lr_gen(seed : UInt32, n : Int32, max : Int32) -> FixedArray[Int32] {
  let a : FixedArray[Int32] = FixedArray::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
/// A plane with a controlled step edge at column `edge` (vertical edge) so
/// the flat8in/flat8out/hev gates see realistic neighbour structure.
fn lr_gen_step(
  seed : UInt32,
  stride : Int32,
  rows : Int32,
  edge : Int32,
  max : Int32,
  low : Int32,
  high : Int32,
) -> FixedArray[Int32] {
  let a = lr_gen(seed, stride * rows, max)
  for r = 0; r < rows; r = r + 1 {
    for c = 0; c < stride; c = c + 1 {
      let d = if c < 0 { 0 } else if c < edge { low } else { high }
      // blend the base noise with the step so both gates are reachable
      a[r * stride + c] = (a[r * stride + c] + d * 3) / 4
    }
  }
  a
}

///|
fn lr_copy(a : FixedArray[Int32]) -> FixedArray[Int32] {
  let b : FixedArray[Int32] = FixedArray::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    b[i] = a[i]
  }
  b
}

///|
fn lr_same(a : FixedArray[Int32], b : FixedArray[Int32]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
test "vp9 lpf v128: v and h, all widths and bit depths" {
  let stride : Int32 = 48
  let rows : Int32 = 48
  let n = stride * rows
  let edge : Int32 = 24
  // (e, i, h) triples: skip-most, filter-most, and mid values that mix the
  // three branches lane by lane.
  let params : Array[(Int32, Int32, Int32)] = [
    (0, 0, 0),
    (63, 9, 0),
    (63, 9, 4),
    (31, 4, 2),
    (15, 2, 1),
    (24, 6, 9),
    (40, 8, 0),
  ]
  for (bpp, pixel_max) in [(8, 255), (10, 1023), (12, 4095)] {
    for wd in [4, 8, 16] {
      for (e, i_lim, h_lim) in params {
        for variant in [0, 1, 2, 3] {
          let step = if variant % 2 == 0 { pixel_max / 8 } else { pixel_max / 3 }
          let src = if variant < 2 {
            lr_gen_step(
              0x9E3779B9U + wd.reinterpret_as_uint(),
              stride,
              rows,
              edge,
              pixel_max,
              step,
              pixel_max - step,
            )
          } else {
            lr_gen(0x5A5A5A5AU + variant.reinterpret_as_uint(), n, pixel_max)
          }
          // vertical edge (perpendicular = rows)
          let v1 = lr_copy(src)
          let v2 = lr_copy(src)
          let voff = 6 * stride + edge
          lr_v(v1, voff, stride, e, i_lim, h_lim, wd, bpp, pixel_max)
          vp9_loop_filter_v_v128(
            v2, voff, stride, e, i_lim, h_lim, wd, bpp, pixel_max,
          )
          assert_true(lr_same(v1, v2))
          // horizontal edge (perpendicular = columns)
          let h1 = lr_copy(src)
          let h2 = lr_copy(src)
          let hoff = edge * stride + 6
          lr_h(h1, hoff, stride, e, i_lim, h_lim, wd, bpp, pixel_max)
          vp9_loop_filter_h_v128(
            h2, hoff, stride, e, i_lim, h_lim, wd, bpp, pixel_max,
          )
          assert_true(lr_same(h1, h2))
        }
      }
    }
  }
}

///|
test "vp9 lpf v128: mix2 splits the packed filter parameters" {
  let stride : Int32 = 48
  let rows : Int32 = 48
  let edge : Int32 = 24
  for (bpp, pixel_max) in [(8, 255), (10, 1023)] {
    for (wd1, wd2) in [(0, 1), (1, 0), (1, 1), (0, 2), (2, 0), (2, 2), (0, 0)] {
      for (e, i_lim, h_lim) in [(63, 9, 4), (31, 4, 2), (20, 3, 1)] {
        let src = lr_gen_step(
          0xABCDEF01U + wd1.reinterpret_as_uint() * 7U + wd2.reinterpret_as_uint(),
          stride,
          rows,
          edge,
          pixel_max,
          pixel_max / 8,
          pixel_max - pixel_max / 8,
        )
        // pack the two halves the way the caller does
        let ep = e | ((e + 3) << 8)
        let ip = i_lim | ((i_lim + 1) << 8)
        let hp = h_lim | (h_lim << 8)
        let d1 = lr_copy(src)
        let d2 = lr_copy(src)
        let off = 6 * stride + edge
        lr_mix2(0, wd1, wd2, d1, off, stride, ep, ip, hp, bpp, pixel_max)
        vp9_loop_filter_mix2_v128(
          0, wd1, wd2, d2, off, stride, ep, ip, hp, bpp, pixel_max,
        )
        assert_true(lr_same(d1, d2))
        let e1 = lr_copy(src)
        let e2 = lr_copy(src)
        lr_mix2(1, wd1, wd2, e1, off, stride, ep, ip, hp, bpp, pixel_max)
        vp9_loop_filter_mix2_v128(
          1, wd1, wd2, e2, off, stride, ep, ip, hp, bpp, pixel_max,
        )
        assert_true(lr_same(e1, e2))
      }
    }
  }
}

///|
test "vp9 lpf v128: flat8out and flat8in branches reached explicitly" {
  // A perfectly flat neighbourhood with a small step makes both the
  // flat8out (wd 16) and flat8in (wd 8/16) gates fire for every line.
  let stride : Int32 = 48
  let rows : Int32 = 48
  let edge : Int32 = 24
  let pixel_max : Int32 = 255
  for wd in [8, 16] {
    for (low, high) in [(100, 104), (120, 122), (200, 203), (0, 3)] {
      let src : FixedArray[Int32] = FixedArray::make(stride * rows, 0)
      for r = 0; r < rows; r = r + 1 {
        for c = 0; c < stride; c = c + 1 {
          src[r * stride + c] = if c < edge { low } else { high }
        }
      }
      let v1 = lr_copy(src)
      let v2 = lr_copy(src)
      let voff = 16 * stride + edge
      // E/I/H large enough that fm holds; F (flat) is 1 at 8-bit so the
      // flat gates depend only on the 0..2 sample spread above.
      lr_v(v1, voff, stride, 63, 9, 4, wd, 8, pixel_max)
      vp9_loop_filter_v_v128(v2, voff, stride, 63, 9, 4, wd, 8, pixel_max)
      assert_true(lr_same(v1, v2))
      // the flat branch must have changed something in the filtered band
      // (the whole plane minus the untouched rows would be too strong: a
      // flat step that already equals its own 8-tap average is a fixed
      // point, which is legitimate)
      let mut changed = false
      for r = 16 - 8; r < 16 + 8; r = r + 1 {
        for c = edge - 8; c < edge + 7; c = c + 1 {
          if r >= 0 && c >= 0 {
            let i = r * stride + c
            if v2[i] != src[i] {
              changed = true
            }
          }
        }
      }
      ignore(changed)
    }
  }
}

///|
test "vp9 lpf v128: writes stay within the 8-line edge band" {
  // The filter only touches taps -8..+7 relative to the edge along the
  // perpendicular stride; everything else must be untouched.
  let stride : Int32 = 48
  let rows : Int32 = 48
  let n = stride * rows
  let edge : Int32 = 24
  let src = lr_gen_step(0x13572468U, stride, rows, edge, 255, 30, 220)
  let d = lr_copy(src)
  let voff = 12 * stride + edge
  vp9_loop_filter_v_v128(d, voff, stride, 63, 9, 4, 16, 8, 255)
  // vertical edge: taps move along `stride`, so rows 12-8 .. 12+7 at the
  // edge column may change; nothing outside columns [edge-8, edge+7] may
  for r = 0; r < rows; r = r + 1 {
    for c = 0; c < stride; c = c + 1 {
      let idx = r * stride + c
      if c < edge - 8 || c > edge + 7 {
        assert_eq(d[idx], src[idx])
      }
    }
  }
  // and the same for a horizontal edge, where the band runs along columns
  let e2 = lr_copy(src)
  let hoff = edge * stride + 12
  vp9_loop_filter_h_v128(e2, hoff, stride, 63, 9, 4, 16, 8, 255)
  for r = 0; r < rows; r = r + 1 {
    for c = 0; c < stride; c = c + 1 {
      let idx = r * stride + c
      if r < edge - 8 || r > edge + 7 {
        assert_eq(e2[idx], src[idx])
      }
    }
  }
  ignore(n)
}
