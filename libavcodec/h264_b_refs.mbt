///|
/// FFmpeg 9.0.2 h264_refs.c default B lists and colocated motion history.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
priv struct H264SliceRefs {
  list0 : Array[H264RefPic]
  list1 : Array[H264RefPic]
  colocated : Array[H264MbInfo]
  long_pocs : Array[Int32]
  poc : Int32
  poc_top : Int32
  poc_bottom : Int32
}

///|
fn H264Decoder::b_references(
  self : H264Decoder, sh : H264SliceHeader, sps : H264Sps, poc : Int32,
  poc_top : Int32, poc_bottom : Int32, long_pocs : Array[Int32],
) -> Result[H264SliceRefs, String] {
  let past = self.refs.filter(fn(entry) { entry.long_index < 0 && entry.pic.poc < poc })
  let future = self.refs.filter(fn(entry) { entry.long_index < 0 && entry.pic.poc >= poc })
  let longs = self.refs.filter(fn(entry) { entry.long_index >= 0 })
  past.sort_by(fn(a, b) { b.pic.poc.compare(a.pic.poc) })
  future.sort_by(fn(a, b) { a.pic.poc.compare(b.pic.poc) })
  longs.sort_by(fn(a, b) { a.long_index.compare(b.long_index) })
  let order0 = past + future + longs
  let order1 = future + past + longs
  guard !order0.is_empty() else { return Err("no reference picture for a B slice") }
  if order0.length() > 1 && order0.map(fn(entry) { entry.pic.poc }) == order1.map(fn(entry) { entry.pic.poc }) {
    let first = order1[0]; order1[0] = order1[1]; order1[1] = first
  }
  let list0 = match self.ref_list0(sh.num_ref_idx_l0_active, sh.ref_mod_l0_ops, sh.ref_mod_l0_vals,
    sh.frame_num, 1 << sps.log2_max_frame_num, order=order0) { Ok(value) => value; Err(error) => return Err(error) }
  let list1 = match self.ref_list0(sh.num_ref_idx_l1_active, sh.ref_mod_l1_ops, sh.ref_mod_l1_vals,
    sh.frame_num, 1 << sps.log2_max_frame_num, order=order1) { Ok(value) => value; Err(error) => return Err(error) }
  let col = self.refs.search_by(fn(entry) { entry.pic.poc == list1[0].poc })
  guard col is Some(index) else { return Err("missing B colocated picture") }
  Ok({ list0, list1, colocated: self.refs[index].infos, long_pocs, poc, poc_top, poc_bottom })
}
