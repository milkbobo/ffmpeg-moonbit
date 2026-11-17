///|
/// `§431`: per-picture type request, mirroring libx264.c's `X264_frame`
/// switch on `frame->pict_type` — the same vocabulary as the `§424a`
/// binding's `X264PictType`. `Auto` lets the stream schedule pick the type
/// (the first picture is always the IDR, odd display positions are B
/// pictures with `b_slices`); `Keyframe` codes a non-IDR I picture (an
/// open-GOP keyframe: a new prediction chain without resetting POC, the
/// reference chain or the parameter sets); `Idr` starts an independent GOP
/// exactly like `force_idr = true`; `P` / `B` pin the slice type.
pub let h264_pict_type_auto : Int32 = 0

///|
pub let h264_pict_type_keyframe : Int32 = 1

///|
pub let h264_pict_type_idr : Int32 = 2

///|
pub let h264_pict_type_p : Int32 = 3

///|
pub let h264_pict_type_b : Int32 = 4

///|
/// Validate one per-picture type request.
fn h264_pict_type_validate(pict_type : Int32) -> Result[Unit, String] {
  if pict_type < h264_pict_type_auto || pict_type > h264_pict_type_b {
    return Err(
      "h264 enc: unsupported pict_type \{pict_type} (0 = auto, 1 = keyframe, 2 = idr, 3 = p, 4 = b)",
    )
  }
  Ok(())
}

///|
/// Validate a per-display-position request array: empty means "auto
/// everywhere"; otherwise it must match the frame count and every value
/// must be one of the five selectors.
fn h264_pict_types_validate(
  requests : Array[Int32],
  n : Int32,
) -> Result[Unit, String] {
  if requests.length() == 0 {
    return Ok(())
  }
  if requests.length() != n {
    return Err(
      "h264 enc: pict_types must be empty or match the frame count (\{n})",
    )
  }
  for r in requests {
    match h264_pict_type_validate(r) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// Whether any position asks for something other than `Auto`.
fn h264_pict_types_forced(requests : Array[Int32]) -> Bool {
  requests.any(r => r != h264_pict_type_auto)
}

///|
/// Expand the per-display-position requests into a coding-order schedule of
/// `(display position, type)` pairs. Mirrors the streaming scheduler
/// (`H264StreamEncoder::push_frame`): the first picture and every `Idr`
/// request start a new GOP (a pending B closes as a tail P first);
/// `Keyframe` and `P` close the pending B and code themselves; a `B`
/// request parks until the following picture serves as its future
/// reference; `Auto` reproduces the default schedule (odd display
/// positions are B pictures with `b_slices`, everything is a P without).
/// A forced B without `b_slices` is rejected (POC type 2 cannot express
/// frame reordering).
fn h264_pict_type_plan(
  requests : Array[Int32],
  b_slices : Bool,
) -> Result[Array[(Int32, Int32)], String] {
  let n = requests.length()
  let plan : Array[(Int32, Int32)] = []
  let mut pending : Int32 = -1
  for i = 0; i < n; i = i + 1 {
    let req = requests[i]
    if i == 0 || req == h264_pict_type_idr {
      if pending >= 0 {
        plan.push((pending, h264_pict_type_p))
        pending = -1
      }
      plan.push((i, h264_pict_type_idr))
    } else if req == h264_pict_type_keyframe {
      if pending >= 0 {
        plan.push((pending, h264_pict_type_p))
        pending = -1
      }
      plan.push((i, h264_pict_type_keyframe))
    } else if req == h264_pict_type_p {
      plan.push((i, h264_pict_type_p))
      if pending >= 0 {
        plan.push((pending, h264_pict_type_b))
        pending = -1
      }
    } else if req == h264_pict_type_b {
      if !b_slices {
        return Err("h264 enc: forced B requires b_slices (POC type 0)")
      }
      if pending >= 0 {
        plan.push((pending, h264_pict_type_p))
        pending = -1
      }
      pending = i
    } else if pending >= 0 {
      plan.push((i, h264_pict_type_p))
      plan.push((pending, h264_pict_type_b))
      pending = -1
    } else if b_slices && i % 2 == 1 {
      pending = i
    } else {
      plan.push((i, h264_pict_type_p))
    }
  }
  if pending >= 0 {
    plan.push((pending, h264_pict_type_p))
  }
  Ok(plan)
}
