///|
/// MoonBit port of the 8-bit H.264 intra prediction kernels from FFmpeg 9.0.2
/// `libavcodec/h264pred_template.c`, together with the availability-driven
/// mode remapping of `ff_h264_check_intra4x4_pred_mode` and
/// `ff_h264_check_intra_pred_mode` (`libavcodec/h264_parse.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2003-2011
/// Michael Niedermayer <michaelni@gmx.at>. This port keeps the same license.
///
/// Unlike FFmpeg, prediction reads the reconstructed neighbours directly from
/// the frame planes instead of the per-macroblock border buffers; the sample
/// values are identical.
///
/// Scope: 4x4 (nine modes plus the DC edge variants), 16x16 luma (four modes)
/// and 8x8 chroma (four modes) for 4:2:0 8-bit. 8x8 luma prediction
/// (High-profile transform_8x8) and 4:2:2/4:4:4 are not ported.

///|
/// 4x4 prediction modes. */
let h264_pred_vert : Int32 = 0

///|
/// `HOR_PRED`. */
let h264_pred_hor : Int32 = 1

///|
/// `DC_PRED`. */
let h264_pred_dc : Int32 = 2

///|
/// `DIAG_DOWN_LEFT_PRED`. */
let h264_pred_ddl : Int32 = 3

///|
/// `DIAG_DOWN_RIGHT_PRED`. */
let h264_pred_ddr : Int32 = 4

///|
/// `VERT_RIGHT_PRED`. */
let h264_pred_vr : Int32 = 5

///|
/// `HOR_DOWN_PRED`. */
let h264_pred_hd : Int32 = 6

///|
/// `VERT_LEFT_PRED`. */
let h264_pred_vl : Int32 = 7

///|
/// `HOR_UP_PRED`. */
let h264_pred_hu : Int32 = 8

///|
/// `LEFT_DC_PRED`. */
let h264_pred_left_dc : Int32 = 9

///|
/// `TOP_DC_PRED`. */
let h264_pred_top_dc : Int32 = 10

///|
/// `DC_128_PRED`. */
let h264_pred_128_dc : Int32 = 11

///|
/// 8x8/16x16 prediction modes (`DC_PRED8x8` and friends). */
let h264_pred8_dc : Int32 = 0

///|
/// `HOR_PRED8x8`. */
let h264_pred8_hor : Int32 = 1

///|
/// `VERT_PRED8x8`. */
let h264_pred8_vert : Int32 = 2

///|
/// `PLANE_PRED8x8`. */
let h264_pred8_plane : Int32 = 3

///|
/// `LEFT_DC_PRED8x8`. */
let h264_pred8_left_dc : Int32 = 4

///|
/// `TOP_DC_PRED8x8`. */
let h264_pred8_top_dc : Int32 = 5

///|
/// `DC_128_PRED8x8`. */
let h264_pred8_128_dc : Int32 = 6

///|
/// `ff_h264_check_intra4x4_pred_mode` for one block: unavailable edges remap
/// DC to the one-sided variants and reject modes that need missing samples.
fn h264_check_intra4x4_mode(
  mode : Int32,
  top : Bool,
  left : Bool,
) -> Result[Int32, String] {
  let mut m = mode
  if !top {
    m = match m {
      1 => 1
      2 => h264_pred_left_dc
      8 => 8
      _ => return Err("intra4x4 mode needs unavailable top samples")
    }
  }
  if !left {
    m = match m {
      0 => 0
      2 => h264_pred_top_dc
      3 => 3
      7 => 7
      9 => h264_pred_128_dc
      _ => return Err("intra4x4 mode needs unavailable left samples")
    }
  }
  Ok(m)
}

///|
/// `ff_h264_check_intra_pred_mode` for 16x16 luma / 8x8 chroma (the MBAFF
/// "mad cow" variants only apply with constrained intra prediction and are
/// not reachable in this decoder).
fn h264_check_intra_pred_mode(
  mode : Int32,
  top : Bool,
  left : Bool,
) -> Result[Int32, String] {
  let mut m = mode
  if !top {
    m = match m {
      0 => h264_pred8_left_dc
      1 => 1
      _ => return Err("intra prediction mode needs unavailable top samples")
    }
  }
  if !left {
    m = match m {
      0 => h264_pred8_top_dc
      2 => 2
      4 => h264_pred8_128_dc
      _ => return Err("intra prediction mode needs unavailable left samples")
    }
  }
  Ok(m)
}

///|
/// `pred4x4`: nine modes plus the DC edge variants, 8-bit. */
fn h264_pred4x4(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
  topright : Bool,
) -> Result[Unit, String] {
  if mode == h264_pred_vert {
    if !top {
      return Err("vertical prediction without top samples")
    }
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = dst[off - stride + i]
      }
    }
  } else if mode == h264_pred_hor {
    if !left {
      return Err("horizontal prediction without left samples")
    }
    for j = 0; j < 4; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == h264_pred_dc {
    let mut sum = 0
    if top {
      for i = 0; i < 4; i = i + 1 {
        sum = sum + dst[off - stride + i]
      }
    }
    if left {
      for i = 0; i < 4; i = i + 1 {
        sum = sum + dst[off - 1 + i * stride]
      }
    }
    let dc = if top && left {
      (sum + 4) >> 3
    } else if top || left {
      (sum + 2) >> 2
    } else {
      128
    }
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = dc
      }
    }
  } else if mode == h264_pred_left_dc {
    if !left {
      return Err("left DC without left samples")
    }
    let mut sum = 0
    for i = 0; i < 4; i = i + 1 {
      sum = sum + dst[off - 1 + i * stride]
    }
    let dc = (sum + 2) >> 2
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = dc
      }
    }
  } else if mode == h264_pred_top_dc {
    if !top {
      return Err("top DC without top samples")
    }
    let mut sum = 0
    for i = 0; i < 4; i = i + 1 {
      sum = sum + dst[off - stride + i]
    }
    let dc = (sum + 2) >> 2
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = dc
      }
    }
  } else if mode == h264_pred_128_dc {
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = 128
      }
    }
  } else {
    let t : Array[Int32] = Array::make(8, 0)
    let l : Array[Int32] = Array::make(4, 0)
    let o : Array[Int32] = Array::make(16, 0)
    if mode == h264_pred_ddl ||
      mode == h264_pred_vl ||
      mode == h264_pred_ddr ||
      mode == h264_pred_vr ||
      mode == h264_pred_hd {
      if !top {
        return Err("prediction mode needs top samples")
      }
      for i = 0; i < 4; i = i + 1 {
        t[i] = dst[off - stride + i]
      }
      if topright {
        for i = 4; i < 8; i = i + 1 {
          t[i] = dst[off - stride + i]
        }
      } else {
        for i = 4; i < 8; i = i + 1 {
          t[i] = t[3]
        }
      }
    }
    if mode == h264_pred_ddr ||
      mode == h264_pred_vr ||
      mode == h264_pred_hd ||
      mode == h264_pred_hu {
      if !left {
        return Err("prediction mode needs left samples")
      }
      for i = 0; i < 4; i = i + 1 {
        l[i] = dst[off - 1 + i * stride]
      }
    }
    let mut lt = 0
    if mode == h264_pred_ddr || mode == h264_pred_vr || mode == h264_pred_hd {
      if !top || !left {
        return Err("prediction mode needs both edges")
      }
      lt = dst[off - stride - 1]
    }
    let put = fn(x : Int32, y : Int32, v : Int32) -> Unit {
      o[y * 4 + x] = h264_clip8(v)
    }
    if mode == h264_pred_ddl {
      put(0, 0, (t[0] + t[2] + 2 * t[1] + 2) >> 2)
      put(1, 0, (t[1] + t[3] + 2 * t[2] + 2) >> 2)
      put(0, 1, (t[1] + t[3] + 2 * t[2] + 2) >> 2)
      put(2, 0, (t[2] + t[4] + 2 * t[3] + 2) >> 2)
      put(1, 1, (t[2] + t[4] + 2 * t[3] + 2) >> 2)
      put(0, 2, (t[2] + t[4] + 2 * t[3] + 2) >> 2)
      put(3, 0, (t[3] + t[5] + 2 * t[4] + 2) >> 2)
      put(2, 1, (t[3] + t[5] + 2 * t[4] + 2) >> 2)
      put(1, 2, (t[3] + t[5] + 2 * t[4] + 2) >> 2)
      put(0, 3, (t[3] + t[5] + 2 * t[4] + 2) >> 2)
      put(3, 1, (t[4] + t[6] + 2 * t[5] + 2) >> 2)
      put(2, 2, (t[4] + t[6] + 2 * t[5] + 2) >> 2)
      put(1, 3, (t[4] + t[6] + 2 * t[5] + 2) >> 2)
      put(3, 2, (t[5] + t[7] + 2 * t[6] + 2) >> 2)
      put(2, 3, (t[5] + t[7] + 2 * t[6] + 2) >> 2)
      put(3, 3, (t[6] + 3 * t[7] + 2) >> 2)
    } else if mode == h264_pred_ddr {
      put(0, 3, (l[3] + 2 * l[2] + l[1] + 2) >> 2)
      put(0, 2, (l[2] + 2 * l[1] + l[0] + 2) >> 2)
      put(1, 3, (l[2] + 2 * l[1] + l[0] + 2) >> 2)
      put(0, 1, (l[1] + 2 * l[0] + lt + 2) >> 2)
      put(1, 2, (l[1] + 2 * l[0] + lt + 2) >> 2)
      put(2, 3, (l[1] + 2 * l[0] + lt + 2) >> 2)
      put(0, 0, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(1, 1, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(2, 2, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(3, 3, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(1, 0, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(2, 1, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(3, 2, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(2, 0, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(3, 1, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(3, 0, (t[1] + 2 * t[2] + t[3] + 2) >> 2)
    } else if mode == h264_pred_vr {
      put(0, 0, (lt + t[0] + 1) >> 1)
      put(1, 2, (lt + t[0] + 1) >> 1)
      put(1, 0, (t[0] + t[1] + 1) >> 1)
      put(2, 2, (t[0] + t[1] + 1) >> 1)
      put(2, 0, (t[1] + t[2] + 1) >> 1)
      put(3, 2, (t[1] + t[2] + 1) >> 1)
      put(3, 0, (t[2] + t[3] + 1) >> 1)
      put(0, 1, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(1, 3, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(1, 1, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(2, 3, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(2, 1, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(3, 3, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(3, 1, (t[1] + 2 * t[2] + t[3] + 2) >> 2)
      put(0, 2, (lt + 2 * l[0] + l[1] + 2) >> 2)
      put(0, 3, (l[0] + 2 * l[1] + l[2] + 2) >> 2)
    } else if mode == h264_pred_hd {
      put(0, 0, (lt + l[0] + 1) >> 1)
      put(2, 1, (lt + l[0] + 1) >> 1)
      put(1, 0, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(3, 1, (l[0] + 2 * lt + t[0] + 2) >> 2)
      put(2, 0, (lt + 2 * t[0] + t[1] + 2) >> 2)
      put(3, 0, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(0, 1, (l[0] + l[1] + 1) >> 1)
      put(2, 2, (l[0] + l[1] + 1) >> 1)
      put(1, 1, (lt + 2 * l[0] + l[1] + 2) >> 2)
      put(3, 2, (lt + 2 * l[0] + l[1] + 2) >> 2)
      put(0, 2, (l[1] + l[2] + 1) >> 1)
      put(2, 3, (l[1] + l[2] + 1) >> 1)
      put(1, 2, (l[0] + 2 * l[1] + l[2] + 2) >> 2)
      put(3, 3, (l[0] + 2 * l[1] + l[2] + 2) >> 2)
      put(0, 3, (l[2] + l[3] + 1) >> 1)
      put(1, 3, (l[1] + 2 * l[2] + l[3] + 2) >> 2)
    } else if mode == h264_pred_vl {
      put(0, 0, (t[0] + t[1] + 1) >> 1)
      put(1, 0, (t[1] + t[2] + 1) >> 1)
      put(0, 2, (t[1] + t[2] + 1) >> 1)
      put(2, 0, (t[2] + t[3] + 1) >> 1)
      put(1, 2, (t[2] + t[3] + 1) >> 1)
      put(3, 0, (t[3] + t[4] + 1) >> 1)
      put(2, 2, (t[3] + t[4] + 1) >> 1)
      put(3, 2, (t[4] + t[5] + 1) >> 1)
      put(0, 1, (t[0] + 2 * t[1] + t[2] + 2) >> 2)
      put(1, 1, (t[1] + 2 * t[2] + t[3] + 2) >> 2)
      put(0, 3, (t[1] + 2 * t[2] + t[3] + 2) >> 2)
      put(2, 1, (t[2] + 2 * t[3] + t[4] + 2) >> 2)
      put(1, 3, (t[2] + 2 * t[3] + t[4] + 2) >> 2)
      put(3, 1, (t[3] + 2 * t[4] + t[5] + 2) >> 2)
      put(2, 3, (t[3] + 2 * t[4] + t[5] + 2) >> 2)
      put(3, 3, (t[4] + 2 * t[5] + t[6] + 2) >> 2)
    } else if mode == h264_pred_hu {
      put(0, 0, (l[0] + l[1] + 1) >> 1)
      put(1, 0, (l[0] + 2 * l[1] + l[2] + 2) >> 2)
      put(2, 0, (l[1] + l[2] + 1) >> 1)
      put(0, 1, (l[1] + l[2] + 1) >> 1)
      put(3, 0, (l[1] + 2 * l[2] + l[3] + 2) >> 2)
      put(1, 1, (l[1] + 2 * l[2] + l[3] + 2) >> 2)
      put(0, 2, (l[2] + l[3] + 1) >> 1)
      put(2, 1, (l[2] + l[3] + 1) >> 1)
      put(1, 2, (l[2] + 2 * l[3] + l[3] + 2) >> 2)
      put(3, 1, (l[2] + 2 * l[3] + l[3] + 2) >> 2)
      put(0, 3, l[3])
      put(1, 3, l[3])
      put(2, 2, l[3])
      put(2, 3, l[3])
      put(3, 2, l[3])
      put(3, 3, l[3])
    } else {
      return Err("unsupported intra4x4 prediction mode")
    }
    for j = 0; j < 4; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = o[j * 4 + i]
      }
    }
  }
  Ok(())
}

///|
/// `pred16x16_*`: 16x16 luma prediction (modes 0..3 plus DC edge variants). */
fn h264_pred16x16(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
) -> Result[Unit, String] {
  if mode == h264_pred8_vert {
    if !top {
      return Err("16x16 vertical prediction without top samples")
    }
    for j = 0; j < 16; j = j + 1 {
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = dst[off - stride + i]
      }
    }
  } else if mode == h264_pred8_hor {
    if !left {
      return Err("16x16 horizontal prediction without left samples")
    }
    for j = 0; j < 16; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == h264_pred8_dc ||
    mode == h264_pred8_left_dc ||
    mode == h264_pred8_top_dc ||
    mode == h264_pred8_128_dc {
    let mut dc = 128
    if mode == h264_pred8_dc {
      let mut sum = 0
      if top {
        for i = 0; i < 16; i = i + 1 {
          sum = sum + dst[off - stride + i]
        }
      }
      if left {
        for i = 0; i < 16; i = i + 1 {
          sum = sum + dst[off - 1 + i * stride]
        }
      }
      dc = if top && left {
        (sum + 16) >> 5
      } else if top || left {
        (sum + 8) >> 4
      } else {
        128
      }
    } else if mode == h264_pred8_left_dc {
      if !left {
        return Err("16x16 left DC without left samples")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - 1 + i * stride]
      }
      dc = (sum + 8) >> 4
    } else if mode == h264_pred8_top_dc {
      if !top {
        return Err("16x16 top DC without top samples")
      }
      let mut sum = 0
      for i = 0; i < 16; i = i + 1 {
        sum = sum + dst[off - stride + i]
      }
      dc = (sum + 8) >> 4
    }
    for j = 0; j < 16; j = j + 1 {
      for i = 0; i < 16; i = i + 1 {
        dst[off + j * stride + i] = dc
      }
    }
  } else if mode == h264_pred8_plane {
    if !top || !left {
      return Err("16x16 plane prediction without both edges")
    }
    let mut h = dst[off - stride + 8] - dst[off - stride + 6]
    let mut v = dst[off + 8 * stride - 1] - dst[off + 6 * stride - 1]
    for k = 2; k <= 8; k = k + 1 {
      h = h + k * (dst[off - stride + 7 + k] - dst[off - stride + 7 - k])
      v = v +
        k * (dst[off + (7 + k) * stride - 1] - dst[off + (7 - k) * stride - 1])
    }
    h = (5 * h + 32) >> 6
    v = (5 * v + 32) >> 6
    let mut a = 16 * (dst[off + 15 * stride - 1] + dst[off - stride + 15] + 1) -
      7 * (v + h)
    for j = 0; j < 16; j = j + 1 {
      let mut b = a
      a = a + v
      for i4 = 0; i4 < 4; i4 = i4 + 1 {
        let p = off + j * stride + 4 * i4
        dst[p] = h264_clip8(b >> 5)
        dst[p + 1] = h264_clip8((b + h) >> 5)
        dst[p + 2] = h264_clip8((b + 2 * h) >> 5)
        dst[p + 3] = h264_clip8((b + 3 * h) >> 5)
        b = b + 4 * h
      }
    }
  } else {
    return Err("unsupported 16x16 prediction mode")
  }
  Ok(())
}

///|
/// `pred8x8_*`: 8x8 chroma prediction for 4:2:0. */
fn h264_pred8x8(
  dst : Array[Int32],
  off : Int32,
  stride : Int32,
  mode : Int32,
  top : Bool,
  left : Bool,
) -> Result[Unit, String] {
  if mode == h264_pred8_vert {
    if !top {
      return Err("8x8 vertical prediction without top samples")
    }
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = dst[off - stride + i]
      }
    }
  } else if mode == h264_pred8_hor {
    if !left {
      return Err("8x8 horizontal prediction without left samples")
    }
    for j = 0; j < 8; j = j + 1 {
      let v = dst[off - 1 + j * stride]
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == h264_pred8_dc {
    if !top || !left {
      return Err("8x8 DC prediction without both edges")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    let mut dc2 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - 1 + i * stride] + dst[off - stride + i]
      dc1 = dc1 + dst[off - stride + 4 + i]
      dc2 = dc2 + dst[off - 1 + (i + 4) * stride]
    }
    let v0 = (dc0 + 4) >> 3
    let v1 = (dc1 + 2) >> 2
    let v2 = (dc2 + 2) >> 2
    let v3 = (dc1 + dc2 + 4) >> 3
    for j = 0; j < 8; j = j + 1 {
      let lv = if j < 4 { v0 } else { v2 }
      let rv = if j < 4 { v1 } else { v3 }
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = lv
        dst[off + j * stride + 4 + i] = rv
      }
    }
  } else if mode == h264_pred8_left_dc {
    if !left {
      return Err("8x8 left DC without left samples")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - 1 + i * stride]
      dc1 = dc1 + dst[off - 1 + (i + 4) * stride]
    }
    let v0 = (dc0 + 2) >> 2
    let v1 = (dc1 + 2) >> 2
    for j = 0; j < 8; j = j + 1 {
      let v = if j < 4 { v0 } else { v1 }
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = v
      }
    }
  } else if mode == h264_pred8_top_dc {
    if !top {
      return Err("8x8 top DC without top samples")
    }
    let mut dc0 = 0
    let mut dc1 = 0
    for i = 0; i < 4; i = i + 1 {
      dc0 = dc0 + dst[off - stride + i]
      dc1 = dc1 + dst[off - stride + 4 + i]
    }
    let v0 = (dc0 + 2) >> 2
    let v1 = (dc1 + 2) >> 2
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 4; i = i + 1 {
        dst[off + j * stride + i] = v0
        dst[off + j * stride + 4 + i] = v1
      }
    }
  } else if mode == h264_pred8_128_dc {
    for j = 0; j < 8; j = j + 1 {
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = 128
      }
    }
  } else if mode == h264_pred8_plane {
    if !top || !left {
      return Err("8x8 plane prediction without both edges")
    }
    let mut h = dst[off - stride + 4] - dst[off - stride + 2]
    let mut v = dst[off + 4 * stride - 1] - dst[off + 2 * stride - 1]
    for k = 2; k <= 4; k = k + 1 {
      h = h + k * (dst[off - stride + 3 + k] - dst[off - stride + 3 - k])
      v = v +
        k * (dst[off + (3 + k) * stride - 1] - dst[off + (3 - k) * stride - 1])
    }
    h = (17 * h + 16) >> 5
    v = (17 * v + 16) >> 5
    let mut a = 16 * (dst[off + 7 * stride - 1] + dst[off - stride + 7] + 1) -
      3 * (v + h)
    for j = 0; j < 8; j = j + 1 {
      let b = a
      a = a + v
      for i = 0; i < 8; i = i + 1 {
        dst[off + j * stride + i] = h264_clip8((b + i * h) >> 5)
      }
    }
  } else {
    return Err("unsupported 8x8 prediction mode")
  }
  Ok(())
}
