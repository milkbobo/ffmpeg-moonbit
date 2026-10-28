///|
/// Order a finite decoded sequence without mixing POC resets at IDR/MMCO5.
/// The decode-order APIs remain useful for callers doing their own timing.
fn h264_display_order_impl(frames : Array[H264Frame]) -> Array[H264Frame] {
  let out : Array[H264Frame] = []
  let pending : Array[H264Frame] = []
  let mut epoch = -1
  for frame in frames {
    if frame.epoch != epoch {
      if !frame.no_output_prior {
        pending.sort_by(fn(a, b) { a.poc.compare(b.poc) })
        for delayed in pending {
          out.push(delayed)
        }
      }
      pending.clear()
      epoch = frame.epoch
    }
    pending.push(frame)
    if pending.length() > frame.reorder_depth {
      pending.sort_by(fn(a, b) { a.poc.compare(b.poc) })
      out.push(pending.remove(0))
    }
  }
  pending.sort_by(fn(a, b) { a.poc.compare(b.poc) })
  for delayed in pending {
    out.push(delayed)
  }
  out
}

///|
/// Re-exported for blackbox EC regression tests.
pub fn h264_display_order(frames : Array[H264Frame]) -> Array[H264Frame] {
  h264_display_order_impl(frames)
}

///|
/// Decode a complete finite Annex B stream in presentation order, draining
/// delayed B pictures at EOF. Each reset of the POC starts a new output epoch.
pub fn h264_decode_annexb_display_frames(
  data : Bytes,
  skip_loop_filter : Bool,
) -> Result[Array[H264Frame], String] {
  match h264_decode_annexb_frames(data, skip_loop_filter) {
    Ok(frames) => Ok(h264_display_order(frames))
    Err(error) => Err(error)
  }
}

///|
/// Decode a finite sequence of AVC access units in presentation order,
/// including delayed B pictures at the end of the sample array.
pub fn h264_decode_avc_display_frames(
  extradata : Bytes,
  samples : Array[Bytes],
  skip_loop_filter : Bool,
) -> Result[Array[H264Frame], String] {
  match h264_decode_avc_frames(extradata, samples, skip_loop_filter) {
    Ok(frames) => Ok(h264_display_order(frames))
    Err(error) => Err(error)
  }
}
