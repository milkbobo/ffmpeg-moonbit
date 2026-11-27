///|
/// Return the byte length and samples per channel of a FLAC frame at offset.
/// The frame is walked without reconstructing PCM. CRC checking is left to
/// the container.
pub fn flac_frame_extent(
  data : Bytes,
  offset : Int32,
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
) -> Result[(Int32, Int32), String] {
  guard offset >= 0 && offset <= data.length() - 8 && bits >= 4 && bits <= 32 else {
    return Err("flac: invalid frame offset or sample depth")
  }
  // STREAMINFO represents a frame's byte size with 24 bits. Limit the
  // per-frame reader so byte offsets can address the full input buffer.
  let gb : BitReader = {
    bytes: data,
    byte_offset: offset,
    pos: 0,
    size_bits: (data.length() - offset).min(0xFFFFFF) * 8,
  }
  let frame = match flac_frame_header(gb, bits) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if frame.channels != channels ||
    (frame.sample_rate != 0 && frame.sample_rate != sample_rate) {
    return Err("flac: frame parameters differ from STREAMINFO")
  }
  for channel in 0..<frame.channels {
    match flac_skip_subframe(gb, frame, channel) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if gb.bits_left() < 16 {
      return Err("flac: truncated audio frame")
    }
  }
  gb.align()
  gb.skip(16)
  if gb.bits_left() < 0 {
    return Err("flac: truncated frame CRC")
  }
  Ok((gb.count() / 8, frame.blocksize))
}

///|
fn flac_skip_subframe(
  gb : BitReader,
  frame : FlacFrame,
  channel : Int32,
) -> Result[Unit, String] {
  let (stype, bps, _) = match
    flac_subframe_header(gb, channel, frame.ch_mode, frame.bps) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if stype <= 1 {
    gb.skip(if stype == 0 { bps } else { bps * frame.blocksize })
    return Ok(())
  }
  let order = if stype >= 8 && stype <= 12 {
    stype & 7
  } else if stype >= 32 {
    (stype & 31) + 1
  } else {
    return Err("flac: invalid subframe type")
  }
  if order > frame.blocksize {
    return Err("flac: predictor order exceeds block size")
  }
  gb.skip(order * bps)
  if stype >= 32 {
    let precision = gb.read(4).reinterpret_as_int() + 1
    if precision == 16 || flac_sbits(gb, 5) < 0 {
      return Err("flac: invalid LPC parameters")
    }
    gb.skip(order * precision)
  }
  let (rice_bits, partitions, samples) = match
    flac_residual_header(gb, order, frame.blocksize) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let escape = (1 << rice_bits) - 1
  for i in 0..<partitions {
    let count = if i == 0 { samples - order } else { samples }
    let param = gb.read(rice_bits).reinterpret_as_int()
    if param == escape {
      gb.skip(gb.read(5).reinterpret_as_int() * count)
    } else {
      for _ in 0..<count {
        let _ = flac_unary(gb)
        if gb.bits_left() < param + 1 {
          return Err("flac: truncated residual")
        }
        gb.skip(param)
      }
    }
  }
  Ok(())
}
