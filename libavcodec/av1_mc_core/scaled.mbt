///|
/// Scaled-reference motion compensation and superres resize, port of dav1d
/// 1.5.1 `src/mc_tmpl.c`: `put_8tap_scaled_c`, `prep_8tap_scaled_c`,
/// `put_bilin_scaled_c`, `prep_bilin_scaled_c` and `resize_c`.
///
/// dav1d's ring-buffer implementations are re-expressed as direct 2D
/// evaluation: for output pixel (x, y) the source position is
/// `(mx + x*dx, my + y*dy)` in 1/1024 units, with 8-tap phases
/// `(pos >> 6) & 15` selecting `av1_mc_subpel_filters` rows; the ring buffer
/// only memoizes intermediate rows, so results are bit-exact identical.

///|
/// One horizontal intermediate of a source row: 8-tap filtered (phase
/// `hph`, filter row `hf_row`) or phase-0 copy, at `ib` intermediate bits.
fn av1_mc_scaled_h_mid(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  row : Int32,
  sx : Int32,
  hph : Int32,
  hf_row : Int32,
  ib : Int32,
) -> Int32 {
  if hph == 0 {
    av1_mc_sample(src, stride, width, height, sx, row) << ib
  } else {
    let off = (hf_row * 15 + hph - 1) * 8
    let mut sum = 0
    for tap in 0..<8 {
      sum += av1_mc_subpel_filters[off + tap] *
        av1_mc_sample(src, stride, width, height, sx + tap - 3, row)
    }
    (sum + (1 << (5 - ib))) >> (6 - ib)
  }
}

///|
/// One bilinear horizontal intermediate (`FILTER_BILIN_RND` at `4-ib`).
fn av1_mc_scaled_bilin_mid(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  row : Int32,
  sx : Int32,
  hph : Int32,
  ib : Int32,
) -> Int32 {
  let a = av1_mc_sample(src, stride, width, height, sx, row)
  let b = av1_mc_sample(src, stride, width, height, sx + 1, row)
  // ((1 << (4 - ib)) >> 1): 0 for ib=4, 2 for ib=2, as in FILTER_BILIN_RND.
  let rnd = 1 << (4 - ib) >> 1
  (16 * a + hph * (b - a) + rnd) >> (4 - ib)
}

///|
/// Scaled single-reference MC. `filter_type` is the dav1d `Filter2d` value
/// (9 = bilinear); `mx`/`my` are fractional start phases in 1/1024 units and
/// `dx`/`dy` the per-output-pixel steps. Output is a packed pixel block.
pub fn av1_mc_put_scaled(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  dx : Int32,
  dy : Int32,
  filter_type : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(w * h, 0)
  let max_pixel = (1 << bitdepth) - 1
  let ib = if bitdepth == 12 { 2 } else { 4 }
  if filter_type == 9 {
    for y in 0..<h {
      let pos_y = my + y * dy
      let sy = pos_y >> 10
      let vph = (pos_y >> 6) & 15
      for x in 0..<w {
        let pos_x = mx + x * dx
        let sx = pos_x >> 10
        let hph = (pos_x >> 6) & 15
        let m1 = av1_mc_scaled_bilin_mid(
          src, stride, width, height, sy, sx, hph, ib,
        )
        let m2 = av1_mc_scaled_bilin_mid(
          src,
          stride,
          width,
          height,
          sy + 1,
          sx,
          hph,
          ib,
        )
        dst[y * w + x] = av1_mc_clip(
          (16 * m1 + vph * (m2 - m1) + (1 << (3 + ib))) >> (4 + ib),
          0,
          max_pixel,
        )
      }
    }
    return dst
  }
  let h1d = if filter_type < 3 { 0 } else if filter_type < 6 { 2 } else { 1 }
  let v1d = filter_type % 3
  let hf_row = if w > 4 { h1d } else { 3 + (h1d & 1) }
  let vf_row = if h > 4 { v1d } else { 3 + (v1d & 1) }
  for y in 0..<h {
    let pos_y = my + y * dy
    let sy = pos_y >> 10
    let vph = (pos_y >> 6) & 15
    let voff = if vph == 0 { -1 } else { (vf_row * 15 + vph - 1) * 8 }
    for x in 0..<w {
      let pos_x = mx + x * dx
      let sx = pos_x >> 10
      let hph = (pos_x >> 6) & 15
      if voff < 0 {
        let mid = av1_mc_scaled_h_mid(
          src, stride, width, height, sy, sx, hph, hf_row, ib,
        )
        dst[y * w + x] = av1_mc_clip(
          (mid + (1 << (ib - 1))) >> ib,
          0,
          max_pixel,
        )
      } else {
        let mut acc = 0
        for tap in 0..<8 {
          let mid = av1_mc_scaled_h_mid(
            src,
            stride,
            width,
            height,
            sy + tap - 3,
            sx,
            hph,
            hf_row,
            ib,
          )
          acc += av1_mc_subpel_filters[voff + tap] * mid
        }
        dst[y * w + x] = av1_mc_clip(
          (acc + (1 << (5 + ib))) >> (6 + ib),
          0,
          max_pixel,
        )
      }
    }
  }
  dst
}

///|
/// Scaled MC keeping intermediate precision (dav1d `prep_*_scaled_c`):
/// returns biased `prep` samples for compound prediction.
pub fn av1_mc_prep_scaled(
  src : FixedArray[Int32],
  stride : Int32,
  width : Int32,
  height : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  dx : Int32,
  dy : Int32,
  filter_type : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(w * h, 0)
  let ib = if bitdepth == 12 { 2 } else { 4 }
  let bias = if bitdepth == 8 { 0 } else { 8192 }
  if filter_type == 9 {
    for y in 0..<h {
      let pos_y = my + y * dy
      let sy = pos_y >> 10
      let vph = (pos_y >> 6) & 15
      for x in 0..<w {
        let pos_x = mx + x * dx
        let sx = pos_x >> 10
        let hph = (pos_x >> 6) & 15
        let m1 = av1_mc_scaled_bilin_mid(
          src, stride, width, height, sy, sx, hph, ib,
        )
        let m2 = av1_mc_scaled_bilin_mid(
          src,
          stride,
          width,
          height,
          sy + 1,
          sx,
          hph,
          ib,
        )
        dst[y * w + x] = ((16 * m1 + vph * (m2 - m1) + 8) >> 4) - bias
      }
    }
    return dst
  }
  let h1d = if filter_type < 3 { 0 } else if filter_type < 6 { 2 } else { 1 }
  let v1d = filter_type % 3
  let hf_row = if w > 4 { h1d } else { 3 + (h1d & 1) }
  let vf_row = if h > 4 { v1d } else { 3 + (v1d & 1) }
  for y in 0..<h {
    let pos_y = my + y * dy
    let sy = pos_y >> 10
    let vph = (pos_y >> 6) & 15
    let voff = if vph == 0 { -1 } else { (vf_row * 15 + vph - 1) * 8 }
    for x in 0..<w {
      let pos_x = mx + x * dx
      let sx = pos_x >> 10
      let hph = (pos_x >> 6) & 15
      if voff < 0 {
        let mid = av1_mc_scaled_h_mid(
          src, stride, width, height, sy, sx, hph, hf_row, ib,
        )
        dst[y * w + x] = mid - bias
      } else {
        let mut acc = 0
        for tap in 0..<8 {
          let mid = av1_mc_scaled_h_mid(
            src,
            stride,
            width,
            height,
            sy + tap - 3,
            sx,
            hph,
            hf_row,
            ib,
          )
          acc += av1_mc_subpel_filters[voff + tap] * mid
        }
        dst[y * w + x] = ((acc + 32) >> 6) - bias
      }
    }
  }
  dst
}

///|
/// Superres horizontal upscale (`resize_c`): `dx`/`mx0` are in 1/16384
/// units, phases `mx >> 8` index `av1_mc_resize_filter`; each tap clamps
/// its own source column around the raw `src_x`. dav1d stores all taps
/// negated and rounds as `(-sum + 64) >> 7`. Returns a packed `dst_w * h`
/// block starting at `src_off` in `src`.
pub fn av1_mc_resize(
  src : FixedArray[Int32],
  src_off : Int32,
  stride : Int32,
  src_w : Int32,
  h : Int32,
  dst_w : Int32,
  dx : Int32,
  mx0 : Int32,
  bitdepth : Int32,
) -> FixedArray[Int32] {
  let dst = FixedArray::make(dst_w * h, 0)
  let max_pixel = (1 << bitdepth) - 1
  for y in 0..<h {
    let row = src_off + y * stride
    let mut mx = mx0
    let mut src_x = -1
    for x in 0..<dst_w {
      let foff = (mx >> 8) * 8
      // each tap clamps its own column around the raw (unclamped) src_x
      let cx = src_x
      let cl = fn(n : Int32) -> Int32 {
        if n < 0 {
          0
        } else if n > src_w - 1 {
          src_w - 1
        } else {
          n
        }
      }
      // dav1d negates the tap sum, then adds the +64 rounding bias outside
      let mut sum = av1_mc_resize_filter[foff] * src[row + cl(cx - 3)]
      sum += av1_mc_resize_filter[foff + 1] * src[row + cl(cx - 2)]
      sum += av1_mc_resize_filter[foff + 2] * src[row + cl(cx - 1)]
      sum += av1_mc_resize_filter[foff + 3] * src[row + cl(cx)]
      sum += av1_mc_resize_filter[foff + 4] * src[row + cl(cx + 1)]
      sum += av1_mc_resize_filter[foff + 5] * src[row + cl(cx + 2)]
      sum += av1_mc_resize_filter[foff + 6] * src[row + cl(cx + 3)]
      sum += av1_mc_resize_filter[foff + 7] * src[row + cl(cx + 4)]
      dst[y * dst_w + x] = av1_mc_clip((-sum + 64) >> 7, 0, max_pixel)
      mx += dx
      src_x += mx >> 14
      mx = mx & 0x3fff
    }
  }
  dst
}
