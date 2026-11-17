///|
/// One `AVRegionOfInterest` region for per-macroblock quantisation deltas
/// (libx264.c's `setup_roi`, `§424c` binding semantics). The rectangle is in
/// pixels, exclusive at `right` / `bottom`, and is clipped to the 16px
/// macroblock grid. `qoffset_num / qoffset_den` is the normalised quality
/// offset in -1..+1 (negative = better quality, positive = worse); upstream
/// scales it by the QP range and clamps per macroblock. When regions overlap
/// the FIRST entry of the list wins (upstream iterates in reverse).
///
/// ROI requires adaptive quantisation to be enabled (`aq=true`); with AQ off
/// upstream warns once and silently skips the ROI (this port skips it
/// silently) and no region is validated.
pub(all) struct H264Roi {
  top : Int32
  bottom : Int32
  left : Int32
  right : Int32
  qoffset_num : Int32
  qoffset_den : Int32
}

///|
/// Clamp helper (the core `clamp` is not imported here).
fn h264_roi_clampi(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Validate a region list: `qoffset.den` must not be zero (upstream rejects
/// it at the safe boundary with `EINVAL`). Returns the exact reason.
fn h264_roi_validate(rois : Array[H264Roi]) -> Result[Unit, String] {
  for roi in rois {
    if roi.qoffset_den == 0 {
      return Err("h264 enc: roi qoffset.den must not be zero")
    }
  }
  Ok(())
}

///|
/// Per-macroblock QP offsets for one ROI map (`libx264.c` `setup_roi`):
/// every MB touched by a region takes `qoffset * qp_range` (truncated toward
/// zero and clipped to `+-qp_range`), and the first region wins overlaps.
/// `bit_depth` enters the QP range exactly like upstream
/// (`51 + 6 * (bit_depth - 8)`). Callers validate the list first.
fn h264_roi_offsets(
  rois : Array[H264Roi],
  mb_width : Int32,
  mb_height : Int32,
  bit_depth : Int32,
) -> Array[Int32] {
  let off : Array[Int32] = Array::make(mb_width * mb_height, 0)
  if rois.is_empty() {
    return off
  }
  let qp_range = 51 + 6 * (bit_depth - 8)
  let lo = -qp_range.to_int64()
  let hi = qp_range.to_int64()
  for i = rois.length() - 1; i >= 0; i = i - 1 {
    let roi = rois[i]
    let scaled = roi.qoffset_num.to_int64() *
      qp_range.to_int64() /
      roi.qoffset_den.to_int64()
    let q = if scaled < lo {
      -qp_range
    } else if scaled > hi {
      qp_range
    } else {
      scaled.to_int()
    }
    // `FFMIN` caps the grid: top/16 truncates toward zero like C, the other
    // edges round up.
    let starty = h264_roi_clampi(roi.top / 16, 0, mb_height)
    let endy = h264_roi_clampi((roi.bottom + 15) / 16, 0, mb_height)
    let startx = h264_roi_clampi(roi.left / 16, 0, mb_width)
    let endx = h264_roi_clampi((roi.right + 15) / 16, 0, mb_width)
    for y = starty; y < endy; y = y + 1 {
      for x = startx; x < endx; x = x + 1 {
        off[y * mb_width + x] = q
      }
    }
  }
  off
}

///|
/// Validate and expand one ROI map, or return an empty map when the ROI is
/// inactive (`aq=false` or no regions — upstream warns and skips the ROI
/// when AQ is off, without validating it).
fn h264_roi_offsets_for(
  rois : Array[H264Roi],
  aq : Bool,
  mb_width : Int32,
  mb_height : Int32,
  bit_depth : Int32,
) -> Result[Array[Int32], String] {
  if !aq || rois.is_empty() {
    return Ok([])
  }
  match h264_roi_validate(rois) {
    Ok(_) => Ok(h264_roi_offsets(rois, mb_width, mb_height, bit_depth))
    Err(e) => Err(e)
  }
}

///|
/// This macroblock's ROI QP offset (zero when no map is active).
fn h264_roi_off_at(off : Array[Int32], mb_idx : Int32) -> Int32 {
  if mb_idx >= 0 && mb_idx < off.length() {
    off[mb_idx]
  } else {
    0
  }
}
