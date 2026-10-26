///|
/// refmvs data retained in one AV1 reference slot. `ref_poc` is the seven
/// order hints used while decoding this picture, as in dav1d `refs[i].refpoc`.
/// `coded_width` is the ref's coded grid (dav1d `frame_hdr->width[0]`): the
/// temporal-MV same-size gate compares 8-aligned coded widths.
pub(all) struct Av1RefmvsReference {
  poc : Int32
  coded_width : Int32
  height : Int32
  ref_poc : FixedArray[Int32]
  rp : FixedArray[Av1Rtb]?
}

///|
/// The eight AV1 reference slots used to carry temporal MV maps across
/// frames. Refreshing several slots points them at the same completed frame.
pub(all) struct Av1RefmvsReferenceStore {
  slots : FixedArray[Av1RefmvsReference?]
}

///|
pub fn av1_refmvs_reference_store_new() -> Av1RefmvsReferenceStore {
  { slots: FixedArray::make(8, None), }
}

///|
/// Refmvs state and reference order hints for the picture being decoded.
pub(all) struct Av1RefmvsPreparedFrame {
  state : Av1RefmvsFrameState
  poc : Int32
  coded_width : Int32
  height : Int32
  ref_poc : FixedArray[Int32]
}

///|
/// Refresh reference slots after the frame has finished saving temporal MVs.
/// `rp` is shared with all refreshed slots, matching dav1d's refcounted map.
pub fn Av1RefmvsReferenceStore::refresh(
  self : Av1RefmvsReferenceStore,
  frame : Av1RefmvsPreparedFrame,
  refresh_mask : Int32,
) -> Unit {
  let reference : Av1RefmvsReference = {
    poc: frame.poc,
    coded_width: frame.coded_width,
    height: frame.height,
    ref_poc: frame.ref_poc.copy(),
    rp: Some(frame.state.rp),
  }
  for slot in 0..<8 {
    if (refresh_mask & (1 << slot)) != 0 {
      self.slots[slot] = Some(reference)
    }
  }
}

///|
/// Key and intra-only frames have no retained refmvs map in dav1d's normal
/// path, but still refresh reference pictures and their order hints.
pub fn Av1RefmvsReferenceStore::refresh_without_mvs(
  self : Av1RefmvsReferenceStore,
  poc : Int32,
  coded_width : Int32,
  height : Int32,
  refresh_mask : Int32,
) -> Unit {
  let reference : Av1RefmvsReference = {
    poc,
    coded_width,
    height,
    ref_poc: FixedArray::make(7, 0),
    rp: None,
  }
  for slot in 0..<8 {
    if (refresh_mask & (1 << slot)) != 0 {
      self.slots[slot] = Some(reference)
    }
  }
}

///|
/// Gather the seven picture references in frame-header order, reject missing
/// slots, then apply dav1d's coded-size gate to each temporal MV map.
/// `ref_slots` contains seven indices into the eight reference slots, and
/// `coded_width`/`height` describe the current frame's coded grid.
pub fn Av1RefmvsReferenceStore::prepare_frame(
  self : Av1RefmvsReferenceStore,
  ref_slots : Array[Int32],
  order_hint_bits : Int32,
  poc : Int32,
  coded_width : Int32,
  height : Int32,
  use_ref_frame_mvs : Bool,
  rf : Av1Rf,
  sbsz : Int32,
) -> Result[Av1RefmvsPreparedFrame, String] {
  if ref_slots.length() != 7 ||
    coded_width <= 0 ||
    height <= 0 ||
    (sbsz != 16 && sbsz != 32) {
    return Err("av1 refmvs: invalid frame geometry or reference list")
  }
  let iw8 = (coded_width + 7) >> 3
  let ih8 = (height + 7) >> 3
  let rp_stride = (coded_width + 127) >> 7 << 4
  let ref_poc = FixedArray::make(7, 0)
  let has_tmvs = FixedArray::make(7, false)
  let ref_ref_poc : FixedArray[FixedArray[Int32]] = FixedArray::makei(7, _ => {
    FixedArray::make(7, 0)
  })
  let empty_map : FixedArray[Av1Rtb] = FixedArray::makei(rp_stride * ih8, _ => {
    mv: (0, 0),
    ref_: 0,
  })
  let rp_ref : FixedArray[FixedArray[Av1Rtb]] = FixedArray::make(7, empty_map)
  for i in 0..<7 {
    let slot = ref_slots[i]
    if slot < 0 || slot >= 8 {
      return Err("av1 refmvs: reference slot outside 0..7")
    }
    let reference = match self.slots[slot] {
      Some(v) => v
      None => return Err("av1 refmvs: missing reference slot")
    }
    ref_poc[i] = reference.poc
    for j in 0..<7 {
      ref_ref_poc[i][j] = reference.ref_poc[j]
    }
    // dav1d compares the ref's 8-aligned coded width (`width[0]`) with the
    // current frame's `bw`, so superres references only share temporal
    // motion when their coded grids match.
    let ref_iw8 = (reference.coded_width + 7) >> 3
    let ref_ih8 = (reference.height + 7) >> 3
    if ref_iw8 == iw8 && ref_ih8 == ih8 {
      if reference.rp is Some(map) {
        if map.length() >= rp_stride * ih8 {
          has_tmvs[i] = true
          rp_ref[i] = map
        }
      }
    }
  }
  let init = av1_refmvs_init_frame(
    order_hint_bits, poc, use_ref_frame_mvs, ref_poc, has_tmvs, ref_ref_poc,
  )
  let frame_rf : Av1Rf = {
    iw4: iw8 * 2,
    ih4: ih8 * 2,
    sign_bias: init.sign_bias,
    pocdiff: init.pocdiff,
    hp: rf.hp,
    force_integer_mv: rf.force_integer_mv,
    use_ref_frame_mvs: init.use_ref_frame_mvs,
    gm_types: rf.gm_types,
    gm_matrices: rf.gm_matrices,
  }
  {
    state: av1_refmvs_frame_state_new(
      frame_rf,
      init,
      rp_ref,
      rp_stride,
      iw8,
      ih8,
      sbsz,
      hdr_use_ref_frame_mvs=use_ref_frame_mvs,
    ),
    poc,
    coded_width,
    height,
    ref_poc,
  }
  |> Ok
}

///|
/// Initialize refmvs directly from a parsed AV1 inter/switch frame header.
/// Reference-slot contents come from completed earlier frames.
pub fn Av1RefmvsReferenceStore::prepare_header(
  self : Av1RefmvsReferenceStore,
  seq : Av1SequenceParameters,
  hdr : Av1FrameHeader,
) -> Result[Av1RefmvsPreparedFrame, String] {
  if hdr.frame_type != av1_frame_inter && hdr.frame_type != av1_frame_switch {
    return Err("av1 refmvs: expected inter or switch frame")
  }
  if hdr.ref_frame_idx.length() != 7 ||
    hdr.gm_types.length() != 7 ||
    hdr.gm_matrices.length() != 7 {
    return Err("av1 refmvs: incomplete reference or global-motion header")
  }
  let refs : Array[Int32] = []
  let gm_types = FixedArray::make(7, 0)
  let gm_matrices : FixedArray[FixedArray[Int32]] = FixedArray::makei(7, _ => {
    FixedArray::make(6, 0)
  })
  for i in 0..<7 {
    if hdr.gm_matrices[i].length() != 6 {
      return Err("av1 refmvs: incomplete global-motion matrix")
    }
    refs.push(hdr.ref_frame_idx[i])
    gm_types[i] = hdr.gm_types[i]
    for j in 0..<6 {
      gm_matrices[i][j] = hdr.gm_matrices[i][j]
    }
  }
  let rf : Av1Rf = {
    iw4: 0,
    ih4: 0,
    sign_bias: FixedArray::make(7, 0),
    pocdiff: FixedArray::make(7, 0),
    hp: hdr.allow_high_precision_mv,
    force_integer_mv: hdr.force_integer_mv,
    use_ref_frame_mvs: false,
    gm_types,
    gm_matrices,
  }
  self.prepare_frame(
    refs,
    seq.order_hint_bits,
    hdr.order_hint,
    hdr.width,
    hdr.height,
    hdr.use_ref_frame_mvs,
    rf,
    if seq.use_128x128_superblock {
      32
    } else {
      16
    },
  )
}
