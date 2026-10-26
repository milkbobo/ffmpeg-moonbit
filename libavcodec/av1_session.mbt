///|
/// Completed reference picture and entropy/segmentation state. The motion
/// maps live in the matching slot of the refmvs reference store.
struct Av1ReferenceSlot {
  state : Av1RefSlotState
  picture : Av1FrameOutput
  cdf : Av1CdfCtx
  segmap : FixedArray[Byte]?
  coded_width : Int32
}

///|
/// A single AV1 coded-video sequence, with eight reference slots. Packets
/// contain frame headers and tile groups, with at most one shown frame.
/// Film grain, intrabc and superres are currently rejected explicitly.
pub struct Av1Decoder {
  mut sequence : Av1SequenceParameters?
  mut sequence_payload : Bytes?
  slots : FixedArray[Av1ReferenceSlot?]
  motion : Av1RefmvsReferenceStore
}

///|
pub fn Av1Decoder::new() -> Av1Decoder {
  {
    sequence: None,
    sequence_payload: None,
    slots: FixedArray::make(8, None),
    motion: av1_refmvs_reference_store_new(),
  }
}

///|
/// Decode a size-delimited OBU packet. Hidden frames update references and
/// return None; show-existing returns the saved, already-filtered picture.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.Av1Decoder::new()
///   assert_true(decoder.decode_packet(b"") is Ok(None))
/// }
/// ```
pub fn Av1Decoder::decode_packet(
  self : Av1Decoder,
  packet : Bytes,
) -> Result[Av1FrameOutput?, String] {
  let mut pos = 0
  let mut frames = 0
  let starts : Array[Int32] = []
  let mut new_sequence : Bytes? = None
  while pos < packet.length() {
    let byte = packet[pos].to_int()
    if (byte & 0x81) != 0 || (byte & 2) == 0 {
      return Err("av1: invalid size-delimited OBU header")
    }
    let extension = (byte & 4) != 0
    if extension &&
      (pos + 1 >= packet.length() || (packet[pos + 1].to_int() & 7) != 0) {
      return Err("av1: invalid OBU extension")
    }
    let off = Ref(pos + 1 + (if extension { 1 } else { 0 }))
    let size = av1_leb128(packet[:], off)
    if size < 0 || off.val > packet.length() - size {
      return Err("av1: bad OBU size")
    }
    let typ = (byte >> 3) & 15
    if typ == 1 {
      new_sequence = Some(packet[off.val:off.val + size].to_owned())
    }
    if typ == 3 || typ == 6 {
      frames += 1
      starts.push(pos)
    }
    pos = off.val + size
  }
  if frames > 1 {
    let mut shown : Av1FrameOutput? = None
    for i in 0..<frames {
      let start = if i == 0 { 0 } else { starts[i] }
      let end = if i + 1 < frames { starts[i + 1] } else { packet.length() }
      match self.decode_packet(packet[start:end].to_owned()) {
        Ok(Some(p)) => {
          if shown is Some(_) {
            return Err("av1: packet contains multiple shown frames")
          }
          shown = Some(p)
        }
        Ok(None) => ()
        Err(e) => return Err(e)
      }
    }
    return Ok(shown)
  }
  if new_sequence is Some(payload) {
    let seq = match av1_parse_sequence_header(packet) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if self.sequence_payload != Some(payload) {
      for i in 0..<8 {
        self.slots[i] = None
        self.motion.slots[i] = None
      }
    }
    self.sequence = Some(seq)
    self.sequence_payload = Some(payload)
  }
  if frames == 0 {
    return Ok(None)
  }
  guard self.sequence is Some(seq) else {
    return Err("av1: missing sequence header")
  }
  let states : Array[Av1RefSlotState] = []
  for slot in self.slots {
    states.push(
      match slot {
        Some(s) => s.state
        None => av1_ref_slot_state_default()
      },
    )
  }
  let hdr = match av1_parse_frame_header(packet, seq, ref_slots=states) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if hdr.show_existing_frame {
    guard self.slots[hdr.frame_to_show_map_idx] is Some(slot) else {
      return Err("av1: missing show-existing reference")
    }
    if slot.state.header is Some(h) && h.frame_type == av1_frame_key {
      let motion = self.motion.slots[hdr.frame_to_show_map_idx]
      for i in 0..<8 {
        self.slots[i] = Some(slot)
        self.motion.slots[i] = motion
      }
    }
    return Ok(Some(slot.picture))
  }
  if hdr.apply_grain {
    return Err("PATCHWELCOME: AV1 film grain")
  }
  if hdr.allow_intrabc {
    return Err("PATCHWELCOME: AV1 intrabc")
  }
  if hdr.use_superres {
    return Err("av1: superres unsupported")
  }
  let primary = if hdr.primary_ref_frame == 7 {
    None
  } else {
    self.slots[hdr.ref_frame_idx[hdr.primary_ref_frame]]
  }
  let input = if hdr.primary_ref_frame == 7 {
    av1_cdf_copy_defaults(hdr.base_q_idx)
  } else {
    match primary {
      Some(s) => s.cdf
      None => return Err("av1: missing primary reference")
    }
  }
  let previous = match primary {
    Some(s) if (s.coded_width + 7) >> 3 == (hdr.width + 7) >> 3 &&
      (s.picture.height + 7) >> 3 == (hdr.height + 7) >> 3 &&
      (hdr.segmentation_temporal_update || !hdr.segmentation_update_map) =>
      s.segmap
    _ => None
  }
  let inter = if hdr.frame_type == av1_frame_inter ||
    hdr.frame_type == av1_frame_switch {
    let pictures : Array[Av1FrameOutput] = []
    for i in 0..<7 {
      guard self.slots[hdr.ref_frame_idx[i]] is Some(slot) else {
        return Err("av1: missing inter reference")
      }
      let p = slot.picture
      if hdr.width * 2 < p.width ||
        hdr.height * 2 < p.height ||
        hdr.width > p.width * 16 ||
        hdr.height > p.height * 16 ||
        p.bitdepth != seq.bitdepth ||
        p.mono != seq.monochrome ||
        p.ss_h != (if seq.chroma_subsampling_x { 1 } else { 0 }) ||
        p.ss_v != (if seq.chroma_subsampling_y { 1 } else { 0 }) {
        return Err("av1: incompatible reference picture")
      }
      pictures.push(p)
    }
    let prepared = match self.motion.prepare_header(seq, hdr) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let planes = (pl : Int32) => {
      FixedArray::makei(7, i => {
        let p = pictures[i]
        {
          src: if pl == 0 {
            p.y
          } else if pl == 1 {
            p.u
          } else {
            p.v
          },
          stride: if pl == 0 {
            p.y_stride
          } else {
            p.uv_stride
          },
          width: p.width,
          height: p.height,
        }
      })
    }
    let scaled = FixedArray::makei(7, i => {
      pictures[i].width != hdr.width || pictures[i].height != hdr.height
    })
    let global_motion = FixedArray::makei(7, i => {
      if hdr.gm_types[i] <= 1 || hdr.force_integer_mv || scaled[i] {
        None
      } else {
        let wm : Av1WarpedMotion = {
          typ: hdr.gm_types[i],
          matrix: FixedArray::makei(6, j => hdr.gm_matrices[i][j]),
          alpha: 0,
          beta: 0,
          gamma: 0,
          delta: 0,
        }
        if av1_warpmv_get_shear_params(wm) {
          None
        } else {
          Some(wm)
        }
      }
    })
    Some({
      prepared,
      y: planes(0),
      u: planes(1),
      v: planes(2),
      scaled,
      global_motion,
    })
  } else {
    None
  }
  let tiles = match av1_extract_tiles(packet, hdr) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let payloads = tiles.map(t => t.data)
  let decoded = match
    av1_decode_frame_payloads(seq, hdr, payloads, input, inter, previous) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let slot : Av1ReferenceSlot = {
    state: av1_ref_slot_state_from_header(hdr),
    picture: decoded.picture,
    cdf: decoded.cdf,
    segmap: if hdr.segmentation_enabled {
      Some(decoded.segmap)
    } else {
      None
    },
    coded_width: hdr.width,
  }
  for i in 0..<8 {
    if (hdr.refresh_frame_flags & (1 << i)) != 0 {
      self.slots[i] = Some(slot)
    }
  }
  match inter {
    Some(fr) => self.motion.refresh(fr.prepared, hdr.refresh_frame_flags)
    None =>
      self.motion.refresh_without_mvs(
        hdr.order_hint,
        hdr.width,
        hdr.height,
        hdr.refresh_frame_flags,
      )
  }
  Ok(if hdr.show_frame { Some(decoded.picture) } else { None })
}
