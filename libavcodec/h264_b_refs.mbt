///|
/// FFmpeg 9.0.2 h264_refs.c default B lists and colocated motion history.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
priv struct H264SliceRefs {
  list0 : Array[H264RefPic]
  list1 : Array[H264RefPic]
  colocated : Array[H264MbInfo]
  colocated_mbaff : Bool
  colocated_field_picture : Bool
  long_pocs : Array[Int32]
  poc : Int32
  poc_top : Int32
  poc_bottom : Int32
}

///|
/// `add_sorted` order for B pictures: list 0 is past (descending POC) then
/// future (ascending), list 1 the reverse. Long-term references are appended
/// by `build_reference_list` in ascending long index, as in
/// `h264_initialise_ref_list`.
fn H264Decoder::b_references(
  self : H264Decoder,
  sh : H264SliceHeader,
  sps : H264Sps,
  cur_poc : Int32,
  poc_top : Int32,
  poc_bottom : Int32,
  long_pocs : Array[Int32],
  field_picture : Bool,
  structure : Int32,
) -> Result[H264SliceRefs, String] {
  let past = self.refs.filter(fn(entry) {
    entry.long_index < 0 && entry.pic.poc < cur_poc
  })
  let future = self.refs.filter(fn(entry) {
    entry.long_index < 0 && entry.pic.poc >= cur_poc
  })
  past.sort_by(fn(a, b) { b.pic.poc.compare(a.pic.poc) })
  future.sort_by(fn(a, b) { a.pic.poc.compare(b.pic.poc) })
  let order0 = past + future
  let order1 = future + past
  guard !self.refs.is_empty() else {
    return Err("no reference picture for a B slice")
  }
  // Compare the complete default lists after splitting pictures into fields,
  // before reordering/truncating to the active count. Swap field entries,
  // rather than parent pictures (h264_initialise_ref_list).
  let longs = self.refs.filter(fn(entry) { entry.long_index >= 0 })
  longs.sort_by(fn(a, b) { a.long_index.compare(b.long_index) })
  let defaults0 = if field_picture {
    h264_def_list(order0, structure) + h264_def_list(longs, structure)
  } else {
    h264_frame_def_list(order0) + h264_frame_def_list(longs)
  }
  let defaults1 = if field_picture {
    h264_def_list(order1, structure) + h264_def_list(longs, structure)
  } else {
    h264_frame_def_list(order1) + h264_frame_def_list(longs)
  }
  let mut same = defaults0.length() > 1 &&
    defaults0.length() == defaults1.length()
  if same {
    for i in 0..<defaults0.length() {
      if defaults0[i].0.identity != defaults1[i].0.identity {
        same = false
        break
      }
    }
  }
  let curr_pic_num = if field_picture {
    2 * sh.frame_num + 1
  } else {
    sh.frame_num
  }
  let max_pic_num = if field_picture {
    1 << (sps.log2_max_frame_num + 1)
  } else {
    1 << sps.log2_max_frame_num
  }
  let list0 = match
    self.build_reference_list(
      order0,
      field_picture,
      structure,
      sh.num_ref_idx_l0_active,
      sh.ref_mod_l0_ops,
      sh.ref_mod_l0_vals,
      curr_pic_num,
      max_pic_num,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let list1 = match
    self.build_reference_list(
      order1,
      field_picture,
      structure,
      sh.num_ref_idx_l1_active,
      sh.ref_mod_l1_ops,
      sh.ref_mod_l1_vals,
      curr_pic_num,
      max_pic_num,
      swap_first=same,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard list1.length() > 0 else {
    return Err("no reference picture for a B slice")
  }
  // The colocated picture is list 1 entry 0; field views keep the parent
  // picture's macroblock state (`H264Picture.mb_type`).
  let entry = match
    self.refs.search_by(fn(entry) { entry.pic.identity == list1[0].identity }) {
    Some(index) => self.refs[index]
    None => return Err("missing B colocated picture")
  }
  Ok({
    list0,
    list1,
    colocated: entry.infos,
    colocated_mbaff: entry.mbaff,
    colocated_field_picture: entry.field_picture,
    long_pocs,
    poc: cur_poc,
    poc_top,
    poc_bottom,
  })
}
