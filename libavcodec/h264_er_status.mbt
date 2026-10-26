///|
/// H.264 use of FFmpeg's error_resilience.c status table. Data partitioning
/// is not decoded by FFmpeg 9.0.2, so all three error classes end together.
/// LGPL-2.1-or-later.

///|
priv struct H264ErSpan {
  start : Int32
  end : Int32
  failed : Bool
}

///|
/// `h264_slice_init`: `mb_y = (first_mb_addr / mb_width) << FIELD_OR_MBAFF_PICTURE`.
/// An MBAFF frame addresses macroblock pairs, so the raster start of a slice
/// doubles its pair row. Field pictures keep their own address space and are
/// handled by the field path instead.
fn h264_er_raster_start(
  first_mb : Int32,
  mb_width : Int32,
  mb_aff : Bool,
) -> Int32 {
  if !mb_aff || mb_width <= 0 {
    return first_mb
  }
  first_mb / mb_width * 2 * mb_width + first_mb % mb_width
}

///|
fn h264_er_status(mb_count : Int32, spans : Array[H264ErSpan]) -> Array[Int32] {
  // ff_er_frame_start: ER_MB_ERROR | VP_START | ER_MB_END.
  let status = Array::make(mb_count, 127)
  for span in spans {
    let start = span.start.max(0).min(mb_count - 1)
    let end = span.end.max(0).min(mb_count - 1)
    if end < start {
      continue
    }
    for i = start; i < end; i = i + 1 {
      status[i] = 0
    }
    status[end] = if span.failed { 14 } else { 112 }
    status[start] = status[start] | 1
  }
  // ff_er_frame_end: overlapping slices. A start marker resets the span.
  for error_type = 1; error_type <= 3; error_type = error_type + 1 {
    let mut end_ok = false
    for i = mb_count - 1; i >= 0; i = i - 1 {
      let old = status[i]
      if (old & (1 << error_type)) != 0 || (old & (8 << error_type)) != 0 {
        end_ok = true
      }
      if !end_ok {
        status[i] = status[i] | (1 << error_type)
      }
      if (old & 1) != 0 {
        end_ok = false
      }
    }
  }
  // Backward propagation from a damaged MB, capped at 50 MBs and bounded by
  // the start of its slice. FFmpeg applies this separately to AC/DC/MV.
  for error_type = 1; error_type <= 3; error_type = error_type + 1 {
    let mut distance = 9999999
    for i = mb_count - 1; i >= 0; i = i - 1 {
      let old = status[i]
      distance += 1
      if (old & (1 << error_type)) != 0 {
        distance = 0
      }
      if distance < 50 {
        status[i] = status[i] | (1 << error_type)
      }
      if (old & 1) != 0 {
        distance = 9999999
      }
    }
  }
  // Forward propagation of macroblock errors until the next slice start.
  let mut error = 0
  for i = 0; i < mb_count; i = i + 1 {
    let old = status[i]
    if (old & 1) != 0 {
      error = old & 14
    } else {
      error = error | (old & 14)
      status[i] = status[i] | error
    }
  }
  status
}
