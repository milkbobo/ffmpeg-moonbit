///|
/// AV1 loop restoration (LR): per-unit syntax + Wiener/SGR filters.
///
/// Port of dav1d 1.5.1 `src/decode.c` `read_restoration_info`,
/// `src/looprestoration_tmpl.c` (C reference filters) and the single-unit
/// geometry of `src/lr_apply_tmpl.c`. dav1d is BSD-2-Clause
/// (Copyright © 2018, VideoLAN and dav1d authors); this port keeps the same
/// algorithm with LGPL-2.1-or-later packaging.

///|
/// `dav1d_sgr_params[16][2]`: (s0, s1) for the 3x3 / 5x5 self-guided filter.
let av1_sgr_params : FixedArray[Int32] = [
  140, 3236, 112, 2158, 93, 1618, 80, 1438, 70, 1295, 58, 1177, 47, 1079, 37, 996, 30, 925, 25, 863, 0, 2589, 0, 1618, 0, 1177, 0, 925, 56, 0, 22, 0,
]

///|
/// One restoration unit's parameters (`Av1RestorationUnit`).
priv struct Av1RestorationUnit {
  /// 0 = none, 2 = Wiener, 3..18 = SGRPROJ with index `type - 3`.
  mut typ : Int32
  filter_v : FixedArray[Int32]
  filter_h : FixedArray[Int32]
  sgr_weights : FixedArray[Int32]
}

///|
fn av1_restoration_unit_new() -> Av1RestorationUnit {
  {
    typ: 0,
    filter_v: FixedArray::make(3, 0),
    filter_h: FixedArray::make(3, 0),
    sgr_weights: FixedArray::make(2, 0),
  }
}

///|
/// `ts->lr_ref[p]` initial values from dav1d's `setup_tile`.
fn av1_restoration_unit_default() -> Av1RestorationUnit {
  {
    typ: 0,
    filter_v: [3, -7, 15],
    filter_h: [3, -7, 15],
    sgr_weights: [-32, 31],
  }
}

///|
/// `read_restoration_info`: decode one unit's filter parameters. Returns the
/// unit; the caller stores it and updates `lr_prev` when the type is not NONE.
fn Av1TileCtx::read_restoration_info(
  self : Av1TileCtx,
  p : Int32,
  frame_type : Int32,
) -> Av1RestorationUnit {
  let unit = av1_restoration_unit_new()
  if frame_type == 1 {
    // switchable: NONE / WIENER / SGRPROJ
    let filter = self.msac.decode_symbol_adapt(
      self.cdf.restore_switchable, 0, 2,
    )
    unit.typ = filter + (if filter > 0 { 1 } else { 0 })
  } else {
    let on = self.msac.decode_bool_adapt(
      if frame_type == 2 {
        self.cdf.restore_wiener
      } else {
        self.cdf.restore_sgrproj
      },
      0,
    )
    unit.typ = if on != 0 { frame_type } else { 0 }
  }
  let prev = self.lr_prev[p]
  if unit.typ == 2 {
    unit.filter_v[0] = if p != 0 {
      0
    } else {
      self.msac.decode_subexp(prev.filter_v[0] + 5, 16, 1) - 5
    }
    unit.filter_v[1] = self.msac.decode_subexp(prev.filter_v[1] + 23, 32, 2) - 23
    unit.filter_v[2] = self.msac.decode_subexp(prev.filter_v[2] + 17, 64, 3) - 17
    unit.filter_h[0] = if p != 0 {
      0
    } else {
      self.msac.decode_subexp(prev.filter_h[0] + 5, 16, 1) - 5
    }
    unit.filter_h[1] = self.msac.decode_subexp(prev.filter_h[1] + 23, 32, 2) - 23
    unit.filter_h[2] = self.msac.decode_subexp(prev.filter_h[2] + 17, 64, 3) - 17
    unit.sgr_weights[0] = prev.sgr_weights[0]
    unit.sgr_weights[1] = prev.sgr_weights[1]
  } else if unit.typ >= 3 {
    let idx = self.msac.decode_bools(4).reinterpret_as_int()
    unit.typ = 3 + idx
    let s0 = av1_sgr_params[idx * 2]
    let s1 = av1_sgr_params[idx * 2 + 1]
    unit.sgr_weights[0] = if s0 != 0 {
      self.msac.decode_subexp(prev.sgr_weights[0] + 96, 128, 4) - 96
    } else {
      0
    }
    unit.sgr_weights[1] = if s1 != 0 {
      self.msac.decode_subexp(prev.sgr_weights[1] + 32, 128, 4) - 32
    } else {
      95
    }
    unit.filter_v[0] = prev.filter_v[0]
    unit.filter_v[1] = prev.filter_v[1]
    unit.filter_v[2] = prev.filter_v[2]
    unit.filter_h[0] = prev.filter_h[0]
    unit.filter_h[1] = prev.filter_h[1]
    unit.filter_h[2] = prev.filter_h[2]
  }
  if unit.typ == 2 {
  } else if unit.typ >= 3 {
  }
  unit
}

///|
/// Read the restoration units whose top-left corner lies in the current
/// superblock (dav1d's per-SB loop in `decode_tile_sbrow`).
fn Av1TileCtx::read_restoration_sb(self : Av1TileCtx) -> Unit {
  let f = self.f
  if !f.lr_active {
    return
  }
  let hdr = f.hdr
  for p in 0..<3 {
    if (f.restore_planes & (1 << p)) == 0 {
      continue
    }
    let chroma = p != 0
    let ss_v = if chroma { f.ss_v } else { 0 }
    let ss_h = if chroma { f.ss_h } else { 0 }
    let unit_size = 1 << hdr.lr_unit_size[if chroma { 1 } else { 0 }]
    let mask = unit_size - 1
    let y = (self.by * 4) >> ss_v
    let plane_h = (hdr.height + ss_v) >> ss_v
    if (y & mask) != 0 {
      continue
    }
    let half = unit_size >> 1
    if y != 0 && y + half > plane_h {
      continue
    }
    let x = (self.bx * 4) >> ss_h
    let plane_w = (hdr.width + ss_h) >> ss_h
    if (x & mask) != 0 {
      continue
    }
    if x != 0 && x + half > plane_w {
      continue
    }
    let sb_idx = (self.by >> 5) * f.sb128w + (self.bx >> 5)
    let unit_idx = ((self.by & 16) >> 3) + ((self.bx & 16) >> 4)
    let unit = self.read_restoration_info(p, hdr.lr_type[p])
    let lfm = f.lf_mask[sb_idx]
    lfm.lr[p * 4 + unit_idx] = unit
    if unit.typ != 0 {
      self.lr_prev[p] = unit
    }
  }
}
