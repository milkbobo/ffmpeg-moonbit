///|
/// Neighbour data used by dav1d's inter reference context functions.
pub(all) struct Av1InterNeighbor {
  intra : Bool
  comp_type : Int32
  ref0 : Int32
  ref1 : Int32
  filter0 : Int32
  filter1 : Int32
}

///|
/// The seven reference-tree contexts in `src/env.h`: ref, fwd, fwd1,
/// fwd2, bwd, bwd1, and uni_p1, in that order. Missing neighbours are None.
pub fn av1_inter_ref_tree_ctx(
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
  tree : Int32,
) -> Int32 {
  let cnt = FixedArray::make(4, 0)
  for opt in [top, left] {
    if opt is Some(n) && !n.intra {
      for k in 0..<(if n.comp_type != 0 { 2 } else { 1 }) {
        let r = if k == 0 { n.ref0 } else { n.ref1 }
        if r >= 0 && r < 7 {
          match tree {
            0 =>
              cnt[if r >= 4 { 1 } else { 0 }] = cnt[if r >= 4 { 1 } else { 0 }] +
                1
            1 => if r < 4 { cnt[r] = cnt[r] + 1 }
            2 => if r < 2 { cnt[r] = cnt[r] + 1 }
            3 => if r >= 2 && r < 4 { cnt[r - 2] = cnt[r - 2] + 1 }
            4 | 5 => if r >= 4 { cnt[r - 4] = cnt[r - 4] + 1 }
            6 => if r >= 1 && r < 4 { cnt[r - 1] = cnt[r - 1] + 1 }
            _ => ()
          }
        }
      }
    }
  }
  let (a, b) = match tree {
    0 | 2 | 3 | 5 => (cnt[0], cnt[1])
    1 => (cnt[0] + cnt[1], cnt[2] + cnt[3])
    4 => (cnt[0] + cnt[1], cnt[2])
    6 => (cnt[0], cnt[1] + cnt[2])
    _ => (0, 0)
  }
  if a == b {
    1
  } else if a < b {
    0
  } else {
    2
  }
}

///|
/// `get_comp_ctx` for the reference-select symbol.
pub fn av1_inter_comp_ctx(
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
) -> Int32 {
  match (top, left) {
    (Some(a), Some(l)) =>
      if a.comp_type != 0 {
        if l.comp_type != 0 {
          4
        } else {
          2 + (if l.ref0 < 0 || l.ref0 >= 4 { 1 } else { 0 })
        }
      } else if l.comp_type != 0 {
        2 + (if a.ref0 < 0 || a.ref0 >= 4 { 1 } else { 0 })
      } else {
        (if l.ref0 >= 4 { 1 } else { 0 }) ^ (if a.ref0 >= 4 { 1 } else { 0 })
      }
    (Some(a), None) =>
      if a.comp_type != 0 {
        3
      } else if a.ref0 >= 4 {
        1
      } else {
        0
      }
    (None, Some(l)) =>
      if l.comp_type != 0 {
        3
      } else if l.ref0 >= 4 {
        1
      } else {
        0
      }
    (None, None) => 1
  }
}

///|
/// `get_comp_dir_ctx`: choose between bidirectional and unidirectional
/// compound reference trees.
pub fn av1_inter_comp_dir_ctx(
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
) -> Int32 {
  match (top, left) {
    (Some(a), Some(l)) => {
      if a.intra && l.intra {
        return 2
      }
      if a.intra || l.intra {
        let n = if a.intra { l } else { a }
        if n.comp_type == 0 {
          return 2
        }
        return 1 + 2 * (if av1_inter_uni_comp(n) { 1 } else { 0 })
      }
      let ac = a.comp_type != 0
      let lc = l.comp_type != 0
      if !ac && !lc {
        return 1 + 2 * (if (a.ref0 >= 4) == (l.ref0 >= 4) { 1 } else { 0 })
      }
      if !ac || !lc {
        let n = if ac { a } else { l }
        if !av1_inter_uni_comp(n) {
          return 1
        }
        return 3 + (if (a.ref0 >= 4) == (l.ref0 >= 4) { 1 } else { 0 })
      }
      let au = av1_inter_uni_comp(a)
      let lu = av1_inter_uni_comp(l)
      if !au && !lu {
        0
      } else if !au || !lu {
        2
      } else {
        3 + (if (a.ref0 == 4) == (l.ref0 == 4) { 1 } else { 0 })
      }
    }
    (Some(n), None) | (None, Some(n)) =>
      if n.intra || n.comp_type == 0 {
        2
      } else if av1_inter_uni_comp(n) {
        4
      } else {
        0
      }
    (None, None) => 2
  }
}

///|
fn av1_inter_uni_comp(n : Av1InterNeighbor) -> Bool {
  (n.ref0 < 4) == (n.ref1 < 4)
}

///|
/// `get_intra_ctx`, used to decide whether an inter-frame block is intra.
pub fn av1_inter_intra_ctx(
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
) -> Int32 {
  match (top, left) {
    (Some(a), Some(l)) => {
      let s = (if a.intra { 1 } else { 0 }) + (if l.intra { 1 } else { 0 })
      s + (if s == 2 { 1 } else { 0 })
    }
    (Some(a), None) => if a.intra { 2 } else { 0 }
    (None, Some(l)) => if l.intra { 2 } else { 0 }
    (None, None) => 0
  }
}

///|
/// `get_filter_ctx`; 3 is dav1d's unset switchable-filter sentinel.
pub fn av1_inter_filter_ctx(
  top : Av1InterNeighbor?,
  left : Av1InterNeighbor?,
  comp : Int32,
  dir : Int32,
  ref_idx : Int32,
) -> Int32 {
  let pick = (n : Av1InterNeighbor?) => {
    match n {
      Some(v) if v.ref0 == ref_idx || v.ref1 == ref_idx =>
        if dir == 0 {
          v.filter0
        } else {
          v.filter1
        }
      _ => 3
    }
  }
  let af = pick(top)
  let lf = pick(left)
  let f = if af == lf {
    af
  } else if af == 3 {
    lf
  } else if lf == 3 {
    af
  } else {
    3
  }
  comp * 4 + f
}

///|
/// `get_mask_comp_ctx`, including the ALTREF neighbour shortcut.
pub fn av1_inter_mask_comp_ctx(
  top : Av1InterNeighbor,
  left : Av1InterNeighbor,
) -> Int32 {
  let one = (n : Av1InterNeighbor) => {
    if n.comp_type >= 3 {
      1
    } else if n.ref0 == 6 {
      3
    } else {
      0
    }
  }
  let sum = one(top) + one(left)
  if sum < 5 {
    sum
  } else {
    5
  }
}

///|
/// `get_jnt_comp_ctx`; order hints are compared modulo their declared width.
pub fn av1_inter_jnt_comp_ctx(
  order_hint_bits : Int32,
  cur_poc : Int32,
  ref0_poc : Int32,
  ref1_poc : Int32,
  top : Av1InterNeighbor,
  left : Av1InterNeighbor,
) -> Int32 {
  let d0 = av1_get_poc_diff(order_hint_bits, ref0_poc, cur_poc)
  let d1 = av1_get_poc_diff(order_hint_bits, cur_poc, ref1_poc)
  let ad0 = if d0 < 0 { -d0 } else { d0 }
  let ad1 = if d1 < 0 { -d1 } else { d1 }
  3 * (if ad0 == ad1 { 1 } else { 0 }) +
  (if top.comp_type >= 2 || top.ref0 == 6 { 1 } else { 0 }) +
  (if left.comp_type >= 2 || left.ref0 == 6 { 1 } else { 0 })
}

///|
/// `get_drl_context` for two adjacent MV stack candidates.
pub fn av1_inter_drl_ctx(first_weight : Int32, next_weight : Int32) -> Int32 {
  if first_weight >= 640 {
    if next_weight < 640 {
      1
    } else {
      0
    }
  } else if next_weight < 640 {
    2
  } else {
    0
  }
}
