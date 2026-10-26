///|
/// Edge node tree from dav1d intra_edge.c: per-partition EdgeFlags for
/// intra edge availability decisions in decode_sb.
priv struct Av1EdgeNode {
  o : Int32
  h : (Int32, Int32)
  v : (Int32, Int32)
  h4 : Int32
  v4 : Int32
  /// For BL_8X8 tips: three 4x4 split edge flags.
  tip : (Int32, Int32, Int32)
  /// Child nodes for BL>8x8 branches (empty for tips).
  split : Array[Av1EdgeNode]
}

///|
fn av1_init_edges(
  _o : Int32,
  bl : Int32,
  edge_flags : Int32,
) -> (
  Int32,
  (Int32, Int32),
  (Int32, Int32),
  Int32,
  Int32,
  (Int32, Int32, Int32),
) {
  let oe = edge_flags
  let h0 = edge_flags | av1_edge_all_left_has_bottom
  let v0 = edge_flags | av1_edge_all_top_has_right
  let (h1, v1) = if bl == 4 {
    (
      edge_flags & (av1_edge_all_left_has_bottom | av1_edge_i420_top_has_right),
      edge_flags &
      (
        av1_edge_all_top_has_right |
        av1_edge_i420_left_has_bottom |
        av1_edge_i422_left_has_bottom
      ),
    )
  } else {
    (
      edge_flags & av1_edge_all_left_has_bottom,
      edge_flags & av1_edge_all_top_has_right,
    )
  }
  let (h4, v4) = if bl == 4 {
    (0, 0)
  } else {
    let h4b = av1_edge_all_left_has_bottom
    let v4b = av1_edge_all_top_has_right
    if bl == 3 {
      // BL_16X16
      (
        h4b | (edge_flags & av1_edge_i420_top_has_right),
        v4b |
        (
          edge_flags &
          (av1_edge_i420_left_has_bottom | av1_edge_i422_left_has_bottom)
        ),
      )
    } else {
      (h4b, v4b)
    }
  }
  let tip = if bl == 4 {
    (
      (edge_flags & av1_edge_all_top_has_right) | av1_edge_i422_left_has_bottom,
      edge_flags | av1_edge_i444_top_has_right,
      edge_flags &
      (
        av1_edge_i420_top_has_right |
        av1_edge_i420_left_has_bottom |
        av1_edge_i422_left_has_bottom
      ),
    )
  } else {
    (0, 0, 0)
  }
  (oe, (h0, h1), (v0, v1), h4, v4, tip)
}

///|
fn av1_init_mode_node(
  bl : Int32,
  top_has_right : Bool,
  left_has_bottom : Bool,
) -> Av1EdgeNode {
  let edge_flags = (if top_has_right { av1_edge_all_top_has_right } else { 0 }) |
    (if left_has_bottom { av1_edge_all_left_has_bottom } else { 0 })
  let (o, h, v, h4, v4, tip) = av1_init_edges(0, bl, edge_flags)
  if bl == 3 {
    // BL_16X16: children are tips (BL_8X8)
    let split = []
    for n in 0..<4 {
      let ef = (if n == 3 || (n == 1 && not(top_has_right)) {
          0
        } else {
          av1_edge_all_top_has_right
        }) |
        (if n == 0 || (n == 2 && left_has_bottom) {
          av1_edge_all_left_has_bottom
        } else {
          0
        })
      let (co, ch, cv, ch4, cv4, ctip) = av1_init_edges(0, bl + 1, ef)
      split.push({
        o: co,
        h: ch,
        v: cv,
        h4: ch4,
        v4: cv4,
        tip: ctip,
        split: [],
      })
    }
    { o, h, v, h4, v4, tip, split, }
  } else {
    let split = []
    for n in 0..<4 {
      split.push(
        av1_init_mode_node(
          bl + 1,
          not(n == 3 || (n == 1 && not(top_has_right))),
          n == 0 || (n == 2 && left_has_bottom),
        ),
      )
    }
    { o, h, v, h4, v4, tip, split, }
  }
}

///|
fn not(b : Bool) -> Bool {
  !b
}

///|
/// The intra edge trees for BL_128X128 (root=0) and BL_64X64 (root=1).
fn av1_intra_edge_tree(root_bl : Int32) -> Av1EdgeNode {
  if root_bl == 0 {
    av1_init_mode_node(0, true, false)
  } else {
    av1_init_mode_node(1, true, false)
  }
}

///|
/// `get_partition_ctx`.
fn av1_get_partition_ctx(
  a : Av1BlockContext,
  l : Av1BlockContext,
  bl : Int32,
  yb8 : Int32,
  xb8 : Int32,
) -> Int32 {
  ((a.partition[xb8] >> (4 - bl)) & 1) +
  (((l.partition[yb8] >> (4 - bl)) & 1) << 1)
}

///|
/// `gather_left_partition_prob` / `gather_top_partition_prob` read raw CDF
/// slots at the partition cdf base.
fn av1_gather_left_partition_prob(
  cdf : FixedArray[UInt16],
  base : Int32,
  bl : Int32,
) -> UInt32 {
  let g = (i : Int32) => cdf[base + i].to_uint()
  let mut out = g(av1_partition_h - 1) -
    g(av1_partition_h) +
    (g(av1_partition_split - 1) - g(av1_partition_t_left))
  if bl != 0 {
    out = out + (g(av1_partition_h4 - 1) - g(av1_partition_h4))
  }
  out
}

///|
fn av1_gather_top_partition_prob(
  cdf : FixedArray[UInt16],
  base : Int32,
  bl : Int32,
) -> UInt32 {
  let g = (i : Int32) => cdf[base + i].to_uint()
  let mut out = g(av1_partition_v - 1) -
    g(av1_partition_t_top) +
    g(av1_partition_t_left - 1)
  if bl != 0 {
    out = out + (g(av1_partition_v4 - 1) - g(av1_partition_t_right))
  }
  out
}

///|
/// `decode_sb` partition recursion (intra frames, pass 0).
fn Av1TileCtx::decode_sb(
  self : Av1TileCtx,
  bl : Int32,
  node : Av1EdgeNode,
) -> Bool raise Av1DecError {
  let f = self.f
  let hsz = 16 >> bl
  let have_h_split = f.bw > self.bx + hsz
  let have_v_split = f.bh > self.by + hsz
  if !have_h_split && !have_v_split {
    return self.decode_sb(bl + 1, node.split[0])
  }
  let bx8 = (self.bx & 31) >> 1
  let by8 = (self.by & 31) >> 1
  let ctx = av1_get_partition_ctx(f.a[self.a_idx], f.l, bl, by8, bx8)
  let pc_base = (bl * 4 + ctx) * 16
  let mut bp = av1_partition_none
  if have_h_split && have_v_split {
    bp = self.msac.decode_symbol_adapt(
      self.cdf.partition,
      pc_base,
      av1_partition_type_count[bl].to_int(),
    )
    let bs0 = av1_block_sizes[(bl * 10 + bp) * 2].to_int()
    let bs1 = av1_block_sizes[(bl * 10 + bp) * 2 + 1].to_int()
    match bp {
      0 =>
        // PARTITION_NONE
        self.decode_b(bl, bs0, 0, node.o)
      1 => {
        // H
        self.decode_b(bl, bs0, 1, node.h.0)
        self.by = self.by + hsz
        self.decode_b(bl, bs0, 1, node.h.1)
        self.by = self.by - hsz
      }
      2 => {
        // V
        self.decode_b(bl, bs0, 2, node.v.0)
        self.bx = self.bx + hsz
        self.decode_b(bl, bs0, 2, node.v.1)
        self.bx = self.bx - hsz
      }
      3 =>
        // SPLIT
        if bl == 4 {
          self.decode_b(4, 21, 3, av1_edge_all_tr_and_bl)
          self.bx = self.bx + 1
          self.decode_b(4, 21, 3, node.tip.0)
          self.bx = self.bx - 1
          self.by = self.by + 1
          self.decode_b(4, 21, 3, node.tip.1)
          self.bx = self.bx + 1
          self.decode_b(4, 21, 3, node.tip.2)
          self.bx = self.bx - 1
          self.by = self.by - 1
        } else {
          if self.decode_sb(bl + 1, node.split[0]) {
            return true
          }
          self.bx = self.bx + hsz
          if self.decode_sb(bl + 1, node.split[1]) {
            return true
          }
          self.bx = self.bx - hsz
          self.by = self.by + hsz
          if self.decode_sb(bl + 1, node.split[2]) {
            return true
          }
          self.bx = self.bx + hsz
          if self.decode_sb(bl + 1, node.split[3]) {
            return true
          }
          self.bx = self.bx - hsz
          self.by = self.by - hsz
        }
      4 => {
        // T_TOP_SPLIT
        self.decode_b(bl, bs0, 4, av1_edge_all_tr_and_bl)
        self.bx = self.bx + hsz
        self.decode_b(bl, bs0, 4, node.v.1)
        self.bx = self.bx - hsz
        self.by = self.by + hsz
        self.decode_b(bl, bs1, 4, node.h.1)
        self.by = self.by - hsz
      }
      5 => {
        // T_BOTTOM_SPLIT
        self.decode_b(bl, bs0, 5, node.h.0)
        self.by = self.by + hsz
        self.decode_b(bl, bs1, 5, node.v.0)
        self.bx = self.bx + hsz
        self.decode_b(bl, bs1, 5, 0)
        self.bx = self.bx - hsz
        self.by = self.by - hsz
      }
      6 => {
        // T_LEFT_SPLIT
        self.decode_b(bl, bs0, 6, av1_edge_all_tr_and_bl)
        self.by = self.by + hsz
        self.decode_b(bl, bs0, 6, node.h.1)
        self.by = self.by - hsz
        self.bx = self.bx + hsz
        self.decode_b(bl, bs1, 6, node.v.1)
        self.bx = self.bx - hsz
      }
      7 => {
        // T_RIGHT_SPLIT
        self.decode_b(bl, bs0, 7, node.v.0)
        self.bx = self.bx + hsz
        self.decode_b(bl, bs1, 7, node.h.0)
        self.by = self.by + hsz
        self.decode_b(bl, bs1, 7, 0)
        self.by = self.by - hsz
        self.bx = self.bx - hsz
      }
      8 => {
        // H4
        self.decode_b(bl, bs0, 8, node.h.0)
        self.by = self.by + (hsz >> 1)
        self.decode_b(bl, bs0, 8, node.h4)
        self.by = self.by + (hsz >> 1)
        self.decode_b(bl, bs0, 8, av1_edge_all_left_has_bottom)
        self.by = self.by + (hsz >> 1)
        if self.by < f.bh {
          self.decode_b(bl, bs0, 8, node.h.1)
        }
        self.by = self.by - ((hsz * 3) >> 1)
      }
      _ => {
        // V4
        self.decode_b(bl, bs0, 9, node.v.0)
        self.bx = self.bx + (hsz >> 1)
        self.decode_b(bl, bs0, 9, node.v4)
        self.bx = self.bx + (hsz >> 1)
        self.decode_b(bl, bs0, 9, av1_edge_all_top_has_right)
        self.bx = self.bx + (hsz >> 1)
        if self.bx < f.bw {
          self.decode_b(bl, bs0, 9, node.v.1)
        }
        self.bx = self.bx - ((hsz * 3) >> 1)
      }
    }
  } else if have_h_split {
    let is_split = self.msac.decode_bool(
      av1_gather_top_partition_prob(self.cdf.partition, pc_base, bl),
    )
    bp = if is_split != 0 { av1_partition_split } else { av1_partition_h }
    if is_split != 0 {
      if self.decode_sb(bl + 1, node.split[0]) {
        return true
      }
      self.bx = self.bx + hsz
      if self.decode_sb(bl + 1, node.split[1]) {
        return true
      }
      self.bx = self.bx - hsz
    } else {
      let bs = av1_block_sizes[(bl * 10 + av1_partition_h) * 2].to_int()
      self.decode_b(bl, bs, av1_partition_h, node.h.0)
    }
  } else {
    let is_split = self.msac.decode_bool(
      av1_gather_left_partition_prob(self.cdf.partition, pc_base, bl),
    )
    bp = if is_split != 0 { av1_partition_split } else { av1_partition_v }
    if is_split != 0 {
      if self.decode_sb(bl + 1, node.split[0]) {
        return true
      }
      self.by = self.by + hsz
      if self.decode_sb(bl + 1, node.split[2]) {
        return true
      }
      self.by = self.by - hsz
    } else {
      let bs = av1_block_sizes[(bl * 10 + av1_partition_v) * 2].to_int()
      self.decode_b(bl, bs, av1_partition_v, node.v.0)
    }
  }
  if bp != av1_partition_split || bl == 4 {
    let al_ctx = av1_al_part_ctx[(0 * 5 + bl) * 10 + bp].to_int()
    let al_ctx_l = av1_al_part_ctx[(1 * 5 + bl) * 10 + bp].to_int()
    let n = av1_imin(hsz, 16)
    for i in 0..<n {
      f.a[self.a_idx].partition[bx8 + i] = al_ctx
      f.l.partition[by8 + i] = al_ctx_l
    }
  }
  false
}
