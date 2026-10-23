///|
/// H.264 reference-list construction for frame and field pictures, after
/// FFmpeg 9.0.2 `h264_refs.c` (`h264_initialise_ref_list`, `build_def_list`,
/// `pic_as_field`, `split_field_copy`) and the `ff_h264_build_ref_list`
/// modification pass. LGPL-2.1-or-later.
/// Copyright (c) 2003 Michael Niedermayer.
///
/// A DPB entry may be a frame-coded picture (reference mask 3) or a
/// field-coded picture whose decoded field(s) set bits 1 (top) and 2
/// (bottom). Field pictures address each field of every reference separately:
/// `build_def_list` interleaves the same-parity and opposite-parity fields of
/// the ordered reference pictures.

///|
/// `pic_as_field`: a field view of a reference picture (doubled stride, one
/// extra line for the bottom field).
fn h264_field_view(pic : H264RefPic, parity : Int32) -> H264RefPic {
  {
    ..pic,
    ystride: pic.ystride * 2,
    cstride: pic.cstride * 2,
    height: pic.height / 2,
    cheight: pic.cheight / 2,
    base_y: if parity == 2 {
      pic.ystride
    } else {
      0
    },
    base_u: if parity == 2 {
      pic.cstride
    } else {
      0
    },
    base_v: if parity == 2 {
      pic.cstride
    } else {
      0
    },
    parity,
    poc: if parity == 2 {
      pic.field_poc_bottom
    } else {
      pic.field_poc_top
    },
  }
}

///|
/// `build_def_list` for a field picture: walk the ordered pictures twice
/// (same parity first, opposite parity second) and emit one field view per
/// matching picture, alternating same/opposite.
fn h264_def_list(
  entries : Array[H264DpbEntry],
  sel : Int32,
) -> Array[(H264RefPic, Int32)] {
  let out : Array[(H264RefPic, Int32)] = []
  let n = entries.length()
  let mut same = 0
  let mut opp = 0
  while same < n || opp < n {
    while same < n && (entries[same].reference & sel) == 0 {
      same = same + 1
    }
    while opp < n && (entries[opp].reference & (sel ^ 3)) == 0 {
      opp = opp + 1
    }
    if same < n {
      out.push((h264_field_view(entries[same].pic, sel), sel))
      same = same + 1
    }
    if opp < n {
      out.push((h264_field_view(entries[opp].pic, sel ^ 3), sel ^ 3))
      opp = opp + 1
    }
  }
  out
}

///|
/// `build_def_list` for a frame picture: whole pictures in order. Entries
/// holding only one field are kept here (with their partial mask) and are
/// replaced by `default_ref` in the missing-reference pass, exactly like the
/// C, so that their list position still shifts the other entries.
fn h264_frame_def_list(
  entries : Array[H264DpbEntry],
) -> Array[(H264RefPic, Int32)] {
  let out : Array[(H264RefPic, Int32)] = []
  for entry in entries {
    if (entry.reference & 3) != 0 {
      out.push((entry.pic, entry.reference))
    }
  }
  out
}

///|
/// `pic_num_extract`: picture number without wrapping plus the structure of
/// the field it describes. Field pictures use doubled picture numbers whose
/// low bit selects the opposite (`0`) or same (`1`) parity field.
fn h264_pic_num_extract(
  pic_num : Int32,
  structure : Int32,
  field_picture : Bool,
) -> (Int32, Int32) {
  if !field_picture {
    return (pic_num, 3)
  }
  let extracted = if (pic_num & 1) == 0 { structure ^ 3 } else { structure }
  (pic_num >> 1, extracted)
}

///|
/// Default list plus `ref_pic_list_modification` and the missing-reference
/// pass (`ff_h264_build_ref_list`). `order` is the ordered short-term
/// reference set: MRU order for P slices, POC order for B slices.
fn H264Decoder::build_reference_list(
  self : H264Decoder,
  order : Array[H264DpbEntry],
  field_picture : Bool,
  structure : Int32,
  count : Int32,
  mod_ops : Array[Int32],
  mod_vals : Array[Int32],
  curr_pic_num : Int32,
  max_pic_num : Int32,
  swap_first~ : Bool = false,
  other_default~ : (H264RefPic, Int32)? = None,
) -> Result[Array[H264RefPic], String] {
  if count <= 0 {
    return Ok([])
  }
  let longs : Array[H264DpbEntry] = self.refs.filter(fn(entry) {
    entry.long_index >= 0
  })
  longs.sort_by(fn(a, b) { a.long_index.compare(b.long_index) })
  let short_entries = order.filter(fn(entry) { entry.long_index < 0 })
  let shorts = if field_picture {
    h264_def_list(short_entries, structure)
  } else {
    h264_frame_def_list(short_entries)
  }
  let long_views = if field_picture {
    h264_def_list(longs, structure)
  } else {
    h264_frame_def_list(longs)
  }
  let defaults = shorts + long_views
  if swap_first && defaults.length() > 1 {
    let first = defaults[0]
    defaults[0] = defaults[1]
    defaults[1] = first
  }
  // `h->default_ref[list] = sl->ref_list[list][0]`, captured before the
  // modification pass replaces entries.
  let default_view : (H264RefPic, Int32)? = if defaults.length() > 0 {
    Some(defaults[0])
  } else {
    None
  }
  let slots : Array[(H264RefPic, Int32)?] = []
  for i = 0; i < count; i = i + 1 {
    slots.push(if i < defaults.length() { Some(defaults[i]) } else { None })
  }
  let mut pred = curr_pic_num
  for k = 0; k < mod_ops.length(); k = k + 1 {
    let op = mod_ops[k]
    let diff = mod_vals[k] + 1
    if k >= count || (op != 2 && diff > max_pic_num) {
      return Err("EINVAL")
    }
    let is_long = op == 2
    let (target, target_structure) = if is_long {
      h264_pic_num_extract(mod_vals[k], structure, field_picture)
    } else {
      pred = if op == 0 { pred - diff } else { pred + diff }
      pred = pred & (max_pic_num - 1)
      h264_pic_num_extract(pred, structure, field_picture)
    }
    // `case 0/1`: newest short reference with that frame_num and field;
    // `case 2`: the long-term entry at that index.
    let mut found : H264DpbEntry? = None
    if is_long {
      for entry in longs {
        if entry.long_index == target {
          found = Some(entry)
          break
        }
      }
    } else {
      for i = self.refs.length() - 1; i >= 0; i = i - 1 {
        let entry = self.refs[i]
        if entry.long_index < 0 &&
          entry.frame_num == target &&
          (entry.reference & target_structure) != 0 {
          found = Some(entry)
          break
        }
      }
    }
    let entry = match found {
      Some(value) => value
      None => return Err("reference picture missing during reorder")
    }
    let view = if field_picture {
      h264_field_view(entry.pic, target_structure)
    } else {
      entry.pic
    }
    let mask = if field_picture { target_structure } else { entry.reference }
    let mut i = k
    while i + 1 < count {
      let duplicate = match slots[i] {
        Some(slot) =>
          slot.0.identity == view.identity && slot.0.parity == view.parity
        None => false
      }
      if duplicate {
        break
      }
      i = i + 1
    }
    while i > k {
      slots[i] = slots[i - 1]
      i = i - 1
    }
    slots[k] = Some((view, mask))
  }
  // Missing-reference pass: entries without a parent, and frame-picture
  // entries that only cover one field, are replaced by `default_ref` when it
  // is usable.
  for i = 0; i < count; i = i + 1 {
    let valid = match slots[i] {
      Some(slot) => field_picture || (slot.1 & 3) == 3
      None => false
    }
    if !valid {
      match default_view {
        Some(view) =>
          if field_picture || (view.1 & 3) == 3 {
            slots[i] = Some(view)
          } else {
            return Err("missing reference picture")
          }
        None => return Err("missing reference picture")
      }
    }
    // ff_h264_build_ref_list: noref_gray defaults to true. Once an intra
    // picture established a non-gray reference, replace a reordered gray
    // gap with a usable default from this list, then the other B list.
    let current = slots[i].unwrap()
    if self.non_gray && self.reference_is_gray(current.0) {
      for candidate in [default_view, other_default] {
        if candidate is Some(view) &&
          !self.reference_is_gray(view.0) &&
          (field_picture || (view.1 & 3) == 3) {
          slots[i] = Some(view)
          break
        }
      }
    }
  }
  let out : Array[H264RefPic] = []
  for slot in slots {
    out.push(slot.unwrap().0)
  }
  Ok(out)
}
