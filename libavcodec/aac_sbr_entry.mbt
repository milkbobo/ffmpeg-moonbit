///|
/// Frame-entry wiring of SBR into the AAC decoder: FFmpeg 9.0.2
/// `aacdec.c` `decode_extension_payload` gating (EXT_SBR_DATA /
/// EXT_SBR_DATA_CRC) and the `ff_aac_sbr_apply` per-element pass of
/// `spectral_to_sample`. LGPL-2.1-or-later.

///|
/// Extension payload ids inside TYPE_FIL (`extension_type`).
let aac_ext_sbr_data : Int32 = 13

///|
let aac_ext_sbr_data_crc : Int32 = 14

///|
/// TYPE_FIL dispatch (`decode_extension_payload` + the FIL loop of the raw
/// data block): reads the fill count, then one 4-bit extension type. SBR
/// payloads follow the C's signalling gate; everything else is skipped.
/// `elem_key` is the previous audio element's key (-1 before any), `elem`
/// its type. The whole payload is consumed on every path, as in the C.
fn AacDecoder::decode_fill_element(
  self : AacDecoder,
  gb : BitReader,
  elem_key : Int32,
  elem : Int32,
) -> Result[Unit, String] {
  let cnt = gb.read(4).reinterpret_as_int()
  let mut n = cnt
  if cnt == 15 {
    n = cnt + gb.read(8).reinterpret_as_int() - 1
  }
  if n < 0 || gb.bits_left() < 8 * n {
    return Err("filler overruns the frame")
  }
  if n == 0 {
    return Ok(())
  }
  let ext = gb.read(4).reinterpret_as_int()
  if ext != aac_ext_sbr_data && ext != aac_ext_sbr_data_crc {
    // EXT_FILL / EXT_FILL_DATA / EXT_DYNAMIC_RANGE / reserved: skipped.
    gb.skip(8 * n - 4)
    return Ok(())
  }
  // EXT_SBR_DATA(_CRC)
  if elem_key < 0 {
    // "SBR was found before the first channel element." — payload consumed.
    gb.skip(8 * n - 4)
    return Ok(())
  }
  if self.sbr_signalling == 0 {
    // "SBR signaled to be not-present but was found in the bitstream."
    gb.skip(8 * n - 4)
    return Ok(())
  }
  if self.sbr_signalling == -1 && self.frames_decoded > 0 {
    // "Implicit SBR was found with a first occurrence after the first frame."
    gb.skip(8 * n - 4)
    return Ok(())
  }
  if self.ps_signalling == -1 &&
    self.frames_decoded == 0 &&
    self.layout.length() == 1 {
    // Mono + unknown PS: implicit HE-AACv2 (outputs stereo).
    self.sbr_signalling = 1
    self.ps_signalling = 1
  } else {
    self.sbr_signalling = 1
  }
  let sbr = match self.sbr_states.get(elem_key) {
    Some(v) => v
    None => {
      let v = aac_new_sbr(elem)
      v.core_sample_rate = self.config.sample_rate
      self.sbr_states[elem_key] = v
      v
    }
  }
  sbr.core_sample_rate = self.config.sample_rate
  sbr.ps_allowed = self.ps_signalling != 0
  match
    sbr.decode_extension(
      gb,
      ext == aac_ext_sbr_data_crc,
      n,
      elem,
      self.config.frame_length_short,
    ) {
    Ok(_) => Ok(())
    Err(e) => Err(e)
  }
}

///|
/// Per-element SBR application pass (`ff_aac_sbr_apply` inside
/// spectral_to_sample): doubles each element's channels to the SBR rate.
/// `out` is the frame's per-channel PCM in layout order; element channels
/// are adjacent. A mono implicit-PS element expands to two outputs.
fn AacDecoder::apply_sbr(
  self : AacDecoder,
  out : Array[AacPcm],
  layout : Array[AacLayoutChannel],
) -> Result[Unit, String] {
  if self.sbr_states.length() == 0 {
    return Ok(())
  }
  let ext_rate = if self.config.ext_sample_rate > 0 {
    self.config.ext_sample_rate
  } else {
    2 * self.config.sample_rate
  }
  let ps_enabled = self.ps_signalling == 1
  let mut i = 0
  while i < layout.length() {
    let elem_key = layout[i].key() & -2
    let is_cpe = layout[i].element_type == 1
    let elem_ch = if is_cpe { 2 } else { 1 }
    let sbr = match self.sbr_states.get(elem_key) {
      Some(v) => v
      None => {
        i = i + elem_ch
        continue
      }
    }
    if sbr.id_aac != layout[i].element_type {
      // "element type mismatch" — pure upsampling from here on.
      sbr.turnoff()
    }
    let channels : Array[Array[Double]] = [out[i].samples]
    if elem_ch == 2 {
      channels.push(out[i + 1].samples)
    }
    let nch = match
      sbr.apply(channels, self.config.frame_length_short, ext_rate, ps_enabled) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    // channels[0] (and [1] for CPE) were resized in place; only the
    // implicit-PS mono expansion adds an output channel.
    if nch > elem_ch {
      out.insert(i + 1, { samples: channels[1], })
    }
    i = i + nch
  }
  Ok(())
}
