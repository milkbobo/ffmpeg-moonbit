///|
/// MoonBit port of the HEVC intra predictors from FFmpeg 9.0.2
/// `libavcodec/hevc/pred_template.c` (`pred_planar`, `pred_dc`,
/// `pred_angular`) for 8-bit samples.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Reference layout: `top`/`left` have `2*size + 1` entries with index 0 as the
/// above-left / below-left corner, i.e. the C arrays passed as `top`/`left`
/// minus one (`top[0]` here equals the C `top[-1]`). This matches the C call
/// site exactly, so the ported formulas use the same indices.
///
/// Out of scope here: reference-sample substitution/availability rules,
/// 3-tap and strong smoothing filters (handled by the caller once the
/// neighbouring blocks are decoded), and high bit depths.

///|
let hevc_intra_angles : FixedArray[Int32] = [
  32, 26, 21, 17, 13, 9, 5, 2, 0, -2, -5, -9, -13, -17, -21, -26, -32, -26, -21,
  -17, -13, -9, -5, -2, 0, 2, 5, 9, 13, 17, 21, 26, 32,
]

///|
let hevc_intra_inv_angles : FixedArray[Int32] = [
  -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910,
  -1638, -4096,
]

///|
fn hevc_clip_pixel(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// `pred_planar`: `top[size]`/`left[size]` are the above-right / below-left
/// extension samples. */
pub fn hevc_pred_planar(
  dst : Array[Int32],
  stride : Int32,
  size : Int32,
  top : Array[Int32],
  left : Array[Int32],
) -> Unit {
  let shift = 1
  let mut log2 = 0
  while 1 << log2 < size {
    log2 = log2 + 1
  }
  let top_right = top[size + 1]
  let left_bottom = left[size + 1]
  for y in 0..<size {
    for x in 0..<size {
      let v = (size - 1 - x) * left[y + 1] +
        (x + 1) * top_right +
        (size - 1 - y) * top[x + 1] +
        (y + 1) * left_bottom +
        size
      dst[y * stride + x] = v >> (log2 + shift)
    }
  }
}

///|
/// `pred_dc`; `c_idx == 0 && size < 32` enables the corner/edge smoothing. */
pub fn hevc_pred_dc(
  dst : Array[Int32],
  stride : Int32,
  size : Int32,
  top : Array[Int32],
  left : Array[Int32],
  c_idx : Int32,
) -> Unit {
  let mut log2 = 0
  while 1 << log2 < size {
    log2 = log2 + 1
  }
  let mut dc = size
  for i in 0..<size {
    dc = dc + left[i + 1] + top[i + 1]
  }
  dc = dc >> (log2 + 1)
  for y in 0..<size {
    for x in 0..<size {
      dst[y * stride + x] = dc
    }
  }
  if c_idx == 0 && size < 32 {
    dst[0] = (left[1] + 2 * dc + top[1] + 2) >> 2
    for x in 1..<size {
      dst[x] = (top[x + 1] + 3 * dc + 2) >> 2
    }
    for y in 1..<size {
      dst[y * stride] = (left[y + 1] + 3 * dc + 2) >> 2
    }
  }
}

///|
/// `pred_angular` for modes 2..34. `top`/`left` use the corner-at-0 layout.
pub fn hevc_pred_angular(
  dst : Array[Int32],
  stride : Int32,
  size : Int32,
  top : Array[Int32],
  left : Array[Int32],
  c_idx : Int32,
  mode : Int32,
) -> Unit {
  if mode < 2 || mode > 34 {
    return
  }
  let angle = hevc_intra_angles[mode - 2]
  let last = (size * angle) >> 5
  let off = size
  let refs : Array[Int32] = Array::make(4 * size + 4, 0)
  if mode >= 18 {
    for k in 0..<=(2 * size) {
      refs[off + k] = top[k]
    }
    if angle < 0 && last < -1 {
      for x in last..<=-1 {
        let v = (x * hevc_intra_inv_angles[mode - 11] + 128) >> 8
        refs[off + x] = left[v]
      }
    }
    for y in 0..<size {
      let idx = ((y + 1) * angle) >> 5
      let fact = ((y + 1) * angle) & 31
      for x in 0..<size {
        let v = if fact != 0 {
          (
            (32 - fact) * refs[off + x + idx + 1] +
            fact * refs[off + x + idx + 2] +
            16
          ) >>
          5
        } else {
          refs[off + x + idx + 1]
        }
        dst[y * stride + x] = v
      }
    }
    if mode == 26 && c_idx == 0 && size < 32 {
      for y in 0..<size {
        dst[y * stride] = hevc_clip_pixel(
          top[1] + ((left[y + 1] - left[0]) >> 1),
        )
      }
    }
  } else {
    for k in 0..<=(2 * size) {
      refs[off + k] = left[k]
    }
    if angle < 0 && last < -1 {
      for x in last..<=-1 {
        let v = (x * hevc_intra_inv_angles[mode - 11] + 128) >> 8
        refs[off + x] = top[v]
      }
    }
    for x in 0..<size {
      let idx = ((x + 1) * angle) >> 5
      let fact = ((x + 1) * angle) & 31
      for y in 0..<size {
        let v = if fact != 0 {
          (
            (32 - fact) * refs[off + y + idx + 1] +
            fact * refs[off + y + idx + 2] +
            16
          ) >>
          5
        } else {
          refs[off + y + idx + 1]
        }
        dst[y * stride + x] = v
      }
    }
    if mode == 10 && c_idx == 0 && size < 32 {
      for x in 0..<size {
        dst[x] = hevc_clip_pixel(left[1] + ((top[x + 1] - top[0]) >> 1))
      }
    }
  }
}
