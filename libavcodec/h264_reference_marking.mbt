///|
/// Reference marking from FFmpeg 9.0.2 h264_refs.c
/// (`ff_h264_execute_ref_pic_marking`, `generate_sliding_window_mmcos`,
/// `remove_short`). Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
///
/// Field pictures mark each field separately: the first decoded field inserts
/// the picture into the short/long lists with its structure bit, and the
/// complementary second field just sets the other bit (`current_ref_assigned
/// == 0` and `short_ref[0] == cur_pic_ptr`). Reference masks are the H.264
/// `PICT_TOP_FIELD` (1) / `PICT_BOTTOM_FIELD` (2) bits.
fn H264Decoder::mark_reference(
  self : H264Decoder,
  pic : H264RefPic,
  infos : Array[H264MbInfo],
  sh : H264SliceHeader,
  sps : H264Sps,
  idr : Bool,
  field_picture : Bool,
  structure : Int32,
  second_field : Bool,
) -> Result[Unit, String] {
  let refs = if idr { [] } else { self.refs.copy() }
  let capacity = sps.ref_frame_count.max(1)
  let mut current_long = if idr && sh.long_term_reference { 0 } else { -1 }
  let mut frame_num = sh.frame_num
  let mut poc = pic.poc
  let mut current_ref_assigned = false
  if !idr && sh.adaptive_ref_marking {
    for (opcode, short, long) in sh.mmco {
      if opcode == 1 || opcode == 3 {
        let curr_pic_num = if field_picture {
          2 * sh.frame_num + 1
        } else {
          sh.frame_num
        }
        let max_pic_num = 1 <<
          (sps.log2_max_frame_num + (if field_picture { 1 } else { 0 }))
        let short_pic_num = (curr_pic_num - short - 1) & (max_pic_num - 1)
        let (target, target_structure) = h264_pic_num_extract(
          short_pic_num, structure, field_picture,
        )
        let index = refs.search_by(fn(entry) {
          entry.long_index < 0 && entry.frame_num == target
        })
        // FFmpeg only logs "mmco: unref short failure" and continues.
        guard index is Some(index) else { continue }
        let entry = refs.remove(index)
        if opcode == 1 {
          let mask = entry.reference & (target_structure ^ 3)
          if mask != 0 {
            refs.insert(index, { ..entry, reference: mask, })
          }
        } else {
          for i = refs.length() - 1; i >= 0; i = i - 1 {
            if refs[i].long_index == long {
              ignore(refs.remove(i))
            }
          }
          refs.push({ ..entry, long_index: long, })
        }
      } else if opcode == 2 {
        let (target, target_structure) = h264_pic_num_extract(
          short, structure, field_picture,
        )
        for i = refs.length() - 1; i >= 0; i = i - 1 {
          if refs[i].long_index == target {
            let entry = refs[i]
            let mask = entry.reference & (target_structure ^ 3)
            if mask != 0 {
              refs[i] = { ..entry, reference: mask, }
            } else {
              ignore(refs.remove(i))
            }
          }
        }
      } else if opcode == 4 || opcode == 6 {
        for i = refs.length() - 1; i >= 0; i = i - 1 {
          let n = refs[i].long_index
          if n >= 0 &&
            ((opcode == 4 && n >= long) || (opcode == 6 && n == long)) {
            ignore(refs.remove(i))
          }
        }
        if opcode == 6 {
          current_long = long
        }
      } else if opcode == 5 {
        refs.clear()
        frame_num = 0
        poc = 0
      }
    }
  } else if !idr {
    // `generate_sliding_window_mmcos`: a full DPB drops the oldest picture.
    // The second field of an already-referenced pair does not trigger this.
    let mut pair_present = false
    if field_picture && second_field {
      pair_present = refs.any(fn(entry) { entry.pic.identity == pic.identity })
    }
    if !pair_present && refs.length() >= capacity {
      for i = refs.length() - 1; i >= 0; i = i - 1 {
        if refs[i].long_index < 0 {
          ignore(refs.remove(i))
          break
        }
      }
    }
  }
  if current_long >= 0 {
    // MMCO 6 / IDR long-term reference: the current picture becomes long.
    for i = refs.length() - 1; i >= 0; i = i - 1 {
      if refs[i].long_index == current_long {
        ignore(refs.remove(i))
      }
    }
    let mut mask = if field_picture { structure } else { 3 }
    if field_picture && second_field {
      match refs.search_by(fn(entry) { entry.pic.identity == pic.identity }) {
        Some(index) => {
          let entry = refs.remove(index)
          mask = entry.reference | structure
        }
        None => ()
      }
    }
    refs.insert(0, {
      mbaff: sps.mb_aff != 0 && !field_picture,
      field_picture,
      frame_num,
      long_index: current_long,
      pic: { ..pic, poc, },
      infos,
      reference: mask,
    })
    current_ref_assigned = true
  }
  if !current_ref_assigned {
    let mut updated = false
    if field_picture && second_field {
      // Second field of a complementary pair: OR the structure bit into the
      // picture the first field inserted (`current_ref_assigned == 0` path).
      match refs.search_by(fn(entry) { entry.pic.identity == pic.identity }) {
        Some(index) => {
          let entry = refs[index]
          refs[index] = {
            ..entry,
            pic: { ..pic, poc, },
            reference: entry.reference | structure,
          }
          updated = true
        }
        None => ()
      }
    }
    if !updated {
      if current_long < 0 {
        for i = refs.length() - 1; i >= 0; i = i - 1 {
          if refs[i].long_index < 0 && refs[i].frame_num == frame_num {
            ignore(refs.remove(i))
          }
        }
      }
      refs.insert(0, {
        mbaff: sps.mb_aff != 0 && !field_picture,
        field_picture,
        frame_num,
        long_index: current_long,
        pic: { ..pic, poc, },
        infos,
        reference: if field_picture {
          structure
        } else {
          3
        },
      })
    }
  }
  // ff_h264_execute_ref_pic_marking tolerates an overflowing DPB after
  // explicit MMCOs: discard the oldest short reference, or a long reference
  // when no short reference remains. A half-referenced field pair still
  // occupies one picture slot.
  while refs.length() > capacity {
    let mut victim = -1
    for i = refs.length() - 1; i >= 0; i = i - 1 {
      if refs[i].long_index < 0 {
        victim = i
        break
      }
    }
    if victim < 0 {
      victim = 0
      for i in 1..<refs.length() {
        if refs[i].long_index < refs[victim].long_index {
          victim = i
        }
      }
    }
    ignore(refs.remove(victim))
  }
  self.refs.clear()
  for entry in refs {
    self.refs.push(entry)
  }
  Ok(())
}
