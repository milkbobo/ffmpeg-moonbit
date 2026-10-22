///|
/// Progressive reference marking from FFmpeg 9.0.2 h264_refs.c.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn H264Decoder::mark_reference(
  self : H264Decoder, pic : H264RefPic, infos : Array[H264MbInfo], sh : H264SliceHeader, sps : H264Sps, idr : Bool,
) -> Result[Unit, String] {
  let refs = if idr { [] } else { self.refs.copy() }
  let max_frame = 1 << sps.log2_max_frame_num
  let mut current_long = if idr && sh.long_term_reference { 0 } else { -1 }
  let mut frame_num = sh.frame_num
  let mut poc = pic.poc
  if !idr && sh.adaptive_ref_marking {
    for (opcode, short, long) in sh.mmco {
      if opcode == 1 || opcode == 3 {
        let target = (sh.frame_num - short - 1) & (max_frame - 1)
        let index = refs.search_by(fn(entry) { entry.long_index < 0 && entry.frame_num == target })
        guard index is Some(index) else { return Err("MMCO short reference missing") }
        let entry = refs.remove(index)
        if opcode == 3 {
          for i = refs.length() - 1; i >= 0; i = i - 1 {
            if refs[i].long_index == long { ignore(refs.remove(i)) }
          }
          refs.push({ ..entry, long_index: long })
        }
      } else if opcode == 2 || opcode == 4 || opcode == 6 {
        for i = refs.length() - 1; i >= 0; i = i - 1 {
          let n = refs[i].long_index
          if n >= 0 && ((opcode == 2 && n == short) || (opcode == 4 && n >= long) || (opcode == 6 && n == long)) {
            ignore(refs.remove(i))
          }
        }
        if opcode == 6 { current_long = long }
      } else if opcode == 5 {
        refs.clear()
        frame_num = 0
        poc = 0
      }
    }
  } else if !idr {
    let limit = sps.ref_frame_count.max(1)
    if refs.length() >= limit {
      let mut oldest = -1
      let mut oldest_wrap = 2147483647
      for i, entry in refs {
        let wrap = if entry.frame_num > sh.frame_num { entry.frame_num - max_frame } else { entry.frame_num }
        if entry.long_index < 0 && wrap < oldest_wrap { oldest = i; oldest_wrap = wrap }
      }
      guard oldest >= 0 else { return Err("DPB full of long-term references") }
      ignore(refs.remove(oldest))
    }
  }
  // A new short picture replaces any stale same-frame_num short reference.
  if current_long < 0 {
    for i = refs.length() - 1; i >= 0; i = i - 1 {
      if refs[i].long_index < 0 && refs[i].frame_num == frame_num { ignore(refs.remove(i)) }
    }
  }
  refs.insert(0, { frame_num, long_index: current_long, pic: { ..pic, poc }, infos })
  guard refs.length() <= sps.ref_frame_count.max(1) else { return Err("too many H.264 reference pictures") }
  self.refs.clear()
  for entry in refs { self.refs.push(entry) }
  Ok(())
}
