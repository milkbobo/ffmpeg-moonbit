///|
/// HEVC reference picture management, ported from FFmpeg 9.0.2
/// `libavcodec/hevc/refs.c` (`ff_hevc_set_new_ref`, `ff_hevc_frame_rps`,
/// `ff_hevc_slice_rpl`, `find_ref_idx`, `add_candidate_ref`,
/// `generate_missing_ref`) and `libavcodec/hevc/mvs.c` (`mv_scale`,
/// `check_mvset`).
///
/// Multi-layer (`inter_layer_pred`), `pps_curr_pic_ref` and ref-list
/// modification are out of scope (rejected upstream).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `PF_INTRA` / `PF_L0` / `PF_L1` / `PF_BI`. */
pub let hevc_pf_intra : Int32 = 0

///|
pub let hevc_pf_l0 : Int32 = 1

///|
pub let hevc_pf_l1 : Int32 = 2

///|
pub let hevc_pf_bi : Int32 = 3

///|
/// Motion vector in quarter-luma-pel units. */
pub struct HevcMv {
  mut x : Int32
  mut y : Int32
}

///|
fn hevc_mv_new() -> HevcMv {
  { x: 0, y: 0, }
}

///|
/// One prediction unit's motion information (C `struct MvField`). */
pub struct HevcMvField {
  mut pred_flag : Int32
  mv0 : HevcMv
  mv1 : HevcMv
  mut ref_idx0 : Int32
  mut ref_idx1 : Int32
}

///|
fn hevc_mv_field_new() -> HevcMvField {
  {
    pred_flag: 0,
    mv0: hevc_mv_new(),
    mv1: hevc_mv_new(),
    ref_idx0: 0,
    ref_idx1: 0,
  }
}

///|
fn HevcMvField::copy_from(self : HevcMvField, o : HevcMvField) -> Unit {
  self.pred_flag = o.pred_flag
  self.mv0.x = o.mv0.x
  self.mv0.y = o.mv0.y
  self.mv1.x = o.mv1.x
  self.mv1.y = o.mv1.y
  self.ref_idx0 = o.ref_idx0
  self.ref_idx1 = o.ref_idx1
}

///|
/// A decoded picture kept in the DPB. */
pub struct HevcRefFrame {
  /// DPB slot index, used as identity (MoonBit `==` on structs is structural).
  slot : Int32
  mut poc : Int32
  pic : HevcPicture
  /// Per-min-PU motion information (zeroed = `PF_INTRA`), C `tab_mvf`.
  tab_mvf : Array[HevcMvField]
  /// Reference lists that were active while this picture was decoded
  /// (`ff_hevc_get_ref_list` for a single-slice picture).
  rpl0 : HevcRefPicList
  rpl1 : HevcRefPicList
  mut short_ref : Bool
  mut long_ref : Bool
  mut unavailable : Bool
  mut in_use : Bool
}

///|
/// One entry of a reference picture list (C `RefPicList`). */
pub struct HevcRplEntry {
  poc : Int32
  is_long_term : Bool
  frame : HevcRefFrame
}

///|
pub struct HevcRefPicList {
  entries : Array[HevcRplEntry]
}

///|
fn hevc_ref_pic_list_new() -> HevcRefPicList {
  { entries: [], }
}

///|
fn HevcRefPicList::nb_refs(self : HevcRefPicList) -> Int32 {
  self.entries.length()
}

///|
fn HevcRefPicList::poc(self : HevcRefPicList, idx : Int32) -> Int32 {
  self.entries[idx].poc
}

///|
fn HevcRefPicList::is_long_term(self : HevcRefPicList, idx : Int32) -> Bool {
  self.entries[idx].is_long_term
}

///|
fn HevcRefPicList::clear(self : HevcRefPicList) -> Unit {
  self.entries.clear()
}

///|
fn HevcRefPicList::push(
  self : HevcRefPicList,
  poc : Int32,
  is_long_term : Bool,
  frame : HevcRefFrame,
) -> Unit {
  self.entries.push({ poc, is_long_term, frame, })
}

///|
/// RPS candidate-list indices (C `ST_CURR_BEF`...); inter-layer lists are
/// unused in this port. */
let hevc_rps_st_curr_bef : Int32 = 0

///|
let hevc_rps_st_curr_aft : Int32 = 1

///|
let hevc_rps_st_foll : Int32 = 2

///|
let hevc_rps_lt_curr : Int32 = 3

///|
let hevc_rps_lt_foll : Int32 = 4

///|
let hevc_rps_nb_types : Int32 = 5

///|
/// Long-term RPS (C `LongTermRPS`); POCs are absolute once resolved. */
pub struct HevcLongTermRps {
  poc : Array[Int32]
  used : Array[Bool]
  poc_msb_present : Array[Bool]
  mut nb_refs : Int32
}

///|
fn new_hevc_long_term_rps() -> HevcLongTermRps {
  {
    poc: Array::make(16, 0),
    used: Array::make(16, false),
    poc_msb_present: Array::make(16, false),
    nb_refs: 0,
  }
}

///|
/// The reference-picture decoder state shared by all pictures of a stream. */
pub struct HevcDpb {
  /// Fixed slot pool (C `HEVCFrame DPB[32]`; 16 usable refs + missing ones).
  slots : Array[HevcRefFrame]
  width : Int32
  height : Int32
  cw : Int32
  ch : Int32
  min_pu_width : Int32
  min_pu_height : Int32
  /// `s->rps[]` candidate lists for the picture being decoded.
  rps : Array[HevcRefPicList]
  /// The picture currently being decoded.
  mut cur : HevcRefFrame
  /// `s->collocated_ref`.
  mut collocated : HevcRefFrame
}

///|
fn hevc_dpb_new(
  width : Int32,
  height : Int32,
  cw : Int32,
  ch : Int32,
  min_pu_width : Int32,
  min_pu_height : Int32,
) -> HevcDpb {
  let slots : Array[HevcRefFrame] = []
  for i in 0..<40 {
    let tab_mvf : Array[HevcMvField] = []
    for _ in 0..<(min_pu_width * min_pu_height) {
      tab_mvf.push(hevc_mv_field_new())
    }
    slots.push({
      slot: i,
      poc: 0,
      pic: hevc_picture_new(width, height, cw, ch),
      tab_mvf,
      rpl0: hevc_ref_pic_list_new(),
      rpl1: hevc_ref_pic_list_new(),
      short_ref: false,
      long_ref: false,
      unavailable: false,
      in_use: false,
    })
  }
  {
    slots,
    width,
    height,
    cw,
    ch,
    min_pu_width,
    min_pu_height,
    rps: {
      let arr : Array[HevcRefPicList] = []
      for _ in 0..<hevc_rps_nb_types {
        arr.push(hevc_ref_pic_list_new())
      }
      arr
    },
    cur: slots[0],
    collocated: slots[0],
  }
}

///|
fn HevcDpb::reset_rps(self : HevcDpb) -> Unit {
  for lst in self.rps {
    lst.clear()
  }
}

///|
/// `mark_ref`: set exactly one reference flag. */
fn hevc_mark_ref(
  frame : HevcRefFrame,
  short_ref : Bool,
  long_ref : Bool,
) -> Unit {
  frame.short_ref = short_ref
  frame.long_ref = long_ref
}

///|
/// `find_ref_idx`: find an in-use frame by (possibly masked) POC. */
fn HevcDpb::find_ref_idx(
  self : HevcDpb,
  poc : Int32,
  use_msb : Bool,
  log2_max_poc_lsb : Int32,
  cur_poc : Int32,
) -> HevcRefFrame? {
  let mask = if use_msb { -1 } else { (1 << log2_max_poc_lsb) - 1 }
  for frame in self.slots {
    if frame.in_use {
      if (frame.poc & mask) == poc && (use_msb || frame.poc != cur_poc) {
        return Some(frame)
      }
    }
  }
  None
}

///|
/// `generate_missing_ref`: claim a free slot filled with mid-grey. */
fn HevcDpb::generate_missing_ref(self : HevcDpb, poc : Int32) -> HevcRefFrame? {
  for frame in self.slots {
    if !frame.in_use {
      let pic = frame.pic
      pic.y.fill(128)
      pic.cb.fill(128)
      pic.cr.fill(128)
      for i in 0..<frame.tab_mvf.length() {
        frame.tab_mvf[i] = hevc_mv_field_new()
      }
      frame.rpl0.clear()
      frame.rpl1.clear()
      frame.poc = poc
      frame.short_ref = false
      frame.long_ref = false
      frame.unavailable = true
      frame.in_use = true
      return Some(frame)
    }
  }
  None
}

///|
/// `add_candidate_ref`. */
fn HevcDpb::add_candidate_ref(
  self : HevcDpb,
  list_idx : Int32,
  poc : Int32,
  short_ref : Bool,
  long_ref : Bool,
  use_msb : Bool,
  log2_max_poc_lsb : Int32,
  cur_poc : Int32,
) -> Unit {
  let frame = self.find_ref_idx(poc, use_msb, log2_max_poc_lsb, cur_poc)
  match frame {
    Some(f) => if f.slot == self.cur.slot { return }
    None => ()
  }
  let f = match frame {
    Some(f) => f
    None =>
      match self.generate_missing_ref(poc) {
        Some(f) => f
        None => return
      }
  }
  self.rps[list_idx].push(poc, false, f)
  hevc_mark_ref(f, short_ref, long_ref)
}

///|
/// Claim a DPB slot for the picture about to be decoded (`ff_hevc_set_new_ref`
/// without the output/bookkeeping parts this port does not model). */
fn HevcDpb::set_new_ref(self : HevcDpb, poc : Int32) -> HevcRefFrame? {
  for frame in self.slots {
    if frame.in_use && frame.poc == poc {
      return None
    }
  }
  for frame in self.slots {
    if !frame.in_use {
      frame.pic.y.fill(0)
      frame.pic.cb.fill(0)
      frame.pic.cr.fill(0)
      for i in 0..<frame.tab_mvf.length() {
        frame.tab_mvf[i] = hevc_mv_field_new()
      }
      frame.rpl0.clear()
      frame.rpl1.clear()
      frame.poc = poc
      frame.short_ref = true
      frame.long_ref = false
      frame.unavailable = false
      frame.in_use = true
      self.cur = frame
      self.collocated = frame
      return Some(frame)
    }
  }
  None
}

///|
/// Release every reference flag (`ff_hevc_clear_refs`). */
fn HevcDpb::clear_refs(self : HevcDpb) -> Unit {
  for frame in self.slots {
    if frame.in_use && !frame.unavailable {
      frame.short_ref = false
      frame.long_ref = false
    }
  }
}

///|
/// Release slots that carry no flags at all (`ff_hevc_unref_frame(frame, 0)`
/// at the end of `ff_hevc_frame_rps`). */
fn HevcDpb::release_unused(self : HevcDpb) -> Unit {
  for frame in self.slots {
    if frame.in_use && !frame.short_ref && !frame.long_ref && !frame.unavailable {
      frame.in_use = false
    }
  }
}

///|
/// Drop `HEVC_FRAME_FLAG_UNAVAILABLE` slots (`unref_missing_refs`). */
fn HevcDpb::unref_missing_refs(self : HevcDpb) -> Unit {
  for frame in self.slots {
    if frame.in_use && frame.unavailable {
      frame.in_use = false
    }
  }
}

///|
/// `mv_scale` (H.265 8.5.3; C `mvs.c`). */
fn hevc_mv_scale(
  dst : HevcMv,
  src : HevcMv,
  td_in : Int32,
  tb_in : Int32,
) -> Unit {
  let mut td = td_in
  let mut tb = tb_in
  if td < -128 {
    td = -128
  } else if td > 127 {
    td = 127
  }
  if tb < -128 {
    tb = -128
  } else if tb > 127 {
    tb = 127
  }
  let tx = (0x4000 + (if td < 0 { -td } else { td }) / 2) / td
  let mut scale_factor = (tb * tx + 32) >> 6
  if scale_factor > 4095 {
    scale_factor = 4095
  } else if scale_factor < -4096 {
    scale_factor = -4096
  }
  let x = (
      scale_factor * src.x +
      127 +
      (if scale_factor * src.x < 0 { 1 } else { 0 })
    ) >>
    8
  let y = (
      scale_factor * src.y +
      127 +
      (if scale_factor * src.y < 0 { 1 } else { 0 })
    ) >>
    8
  dst.x = if x < -32768 { -32768 } else if x > 32767 { 32767 } else { x }
  dst.y = if y < -32768 { -32768 } else if y > 32767 { 32767 } else { y }
}

///|
/// `check_mvset` (H.265 8.5.3.1.8). */
fn hevc_check_mvset(
  mv_lx_col : HevcMv,
  mv_col : HevcMv,
  col_poc : Int32,
  poc : Int32,
  ref_pic_list : HevcRefPicList,
  ref_idx_lx : Int32,
  ref_pic_list_col : HevcRefPicList,
  ref_idx_col : Int32,
) -> Bool {
  let cur_lt = ref_pic_list.is_long_term(ref_idx_lx)
  let col_lt = ref_pic_list_col.is_long_term(ref_idx_col)
  if cur_lt != col_lt {
    mv_lx_col.x = 0
    mv_lx_col.y = 0
    return false
  }
  let col_poc_diff = col_poc - ref_pic_list_col.poc(ref_idx_col)
  let cur_poc_diff = poc - ref_pic_list.poc(ref_idx_lx)
  if cur_lt || col_poc_diff == cur_poc_diff || col_poc_diff == 0 {
    mv_lx_col.x = mv_col.x
    mv_lx_col.y = mv_col.y
  } else {
    hevc_mv_scale(mv_lx_col, mv_col, col_poc_diff, cur_poc_diff)
  }
  true
}
