///|
/// `AVVideoHintType` selector: the rectangles delimit the UNCHANGED areas
/// (the rest of the frame is assumed changed). Matches the `§424e` binding's
/// `X264VideoHintKind::Constant` selector.
pub let h264_video_hint_constant : Int32 = 1

///|
/// `AVVideoHintType` selector: the rectangles delimit the CHANGED areas
/// (the rest is assumed unchanged).
pub let h264_video_hint_changed : Int32 = 2

///|
/// One pixel rectangle of an `H264VideoHint` (`AVVideoRect`): `x`/`y` is the
/// top-left corner, `width`/`height` the extent. No alignment requirement —
/// upstream clamps to the 16px macroblock grid with the kind's rounding.
pub(all) struct H264VideoRect {
  x : Int32
  y : Int32
  width : Int32
  height : Int32
}

///|
/// Per-macroblock motion hint (libx264.c's `setup_mb_info` → x264
/// `mb_info`): rectangles telling the encoder which areas of the picture did
/// (`h264_video_hint_changed`) or did not (`h264_video_hint_constant`)
/// change since the previous picture. Macroblocks the hint marks constant
/// are forced to skip (no motion search, no residual) — x264 trusts the
/// hint unconditionally. An empty `rects` array is legal: with `Constant`
/// it claims the whole frame changed, with `Changed` that nothing did.
pub(all) struct H264VideoHint {
  kind : Int32
  rects : Array[H264VideoRect]
}

///|
/// `MB_FLOOR`/`MB_CEIL` from libx264.c, clamped into the frame's grid (C
/// truncates negative coordinates toward zero; clamping reproduces that at
/// the left/top edge and keeps malformed rectangles safe).
fn h264_hint_floor(v : Int32, limit : Int32) -> Int32 {
  h264_roi_clampi(v / 16, 0, limit)
}

///|
fn h264_hint_ceil(v : Int32, limit : Int32) -> Int32 {
  h264_roi_clampi((v + 15) / 16, 0, limit)
}

///|
/// Validate a hint (`kind` must be the constant or changed selector).
fn h264_hint_validate(hint : H264VideoHint) -> Result[Unit, String] {
  if hint.kind != h264_video_hint_constant &&
    hint.kind != h264_video_hint_changed {
    return Err(
      "h264 enc: unsupported video hint kind \{hint.kind} (1 = constant, 2 = changed)",
    )
  }
  Ok(())
}

///|
/// Expand one per-picture hint into per-MB "constant" flags (true = the MB
/// is unchanged and must skip). `None` yields an empty array (no hint).
/// `Constant` rects mark only the macroblocks FULLY inside (`ceil` start /
/// `floor` end); `Changed` rects clear every intersecting MB (`floor` /
/// `ceil`) from the all-constant default.
fn h264_hint_constants(
  hint : H264VideoHint?,
  mb_width : Int32,
  mb_height : Int32,
) -> Result[Array[Bool], String] {
  let h = match hint {
    Some(h) => h
    None => return Ok([])
  }
  match h264_hint_validate(h) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let n = mb_width * mb_height
  let constant = h.kind == h264_video_hint_constant
  let flags : Array[Bool] = Array::make(n, !constant)
  for rect in h.rects {
    let startx = if constant {
      h264_hint_ceil(rect.x, mb_width)
    } else {
      h264_hint_floor(rect.x, mb_width)
    }
    let endx = if constant {
      h264_hint_floor(rect.x + rect.width, mb_width)
    } else {
      h264_hint_ceil(rect.x + rect.width, mb_width)
    }
    let starty = if constant {
      h264_hint_ceil(rect.y, mb_height)
    } else {
      h264_hint_floor(rect.y, mb_height)
    }
    let endy = if constant {
      h264_hint_floor(rect.y + rect.height, mb_height)
    } else {
      h264_hint_ceil(rect.y + rect.height, mb_height)
    }
    for y = starty; y < endy; y = y + 1 {
      for x = startx; x < endx; x = x + 1 {
        flags[y * mb_width + x] = constant
      }
    }
  }
  Ok(flags)
}

///|
/// Pick the hint of display position `i` from a per-frame hint array (short
/// or empty arrays mean "no hint").
fn h264_hint_at(hints : Array[H264VideoHint?], i : Int32) -> H264VideoHint? {
  if i >= 0 && i < hints.length() {
    hints[i]
  } else {
    None
  }
}

///|
/// This macroblock's hint flag (false when no hint is active).
fn h264_hint_is_constant(flags : Array[Bool], mb_idx : Int32) -> Bool {
  if mb_idx >= 0 && mb_idx < flags.length() {
    flags[mb_idx]
  } else {
    false
  }
}
