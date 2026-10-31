///|
/// LOAS/LATM reader (ISO/IEC 14496-3 AudioMuxElement), following FFmpeg
/// 9.0.2 `libavcodec/aac/aacdec_latm.h::read_audio_mux_element` and
/// `libavformat/loasdec.c`: the StreamMuxConfig supplies the in-band
/// AudioSpecificConfig, and each PayloadMux slot is repacked byte-aligned so
/// the raw AAC decoder can consume it.
///
/// Only AAC-LC (single program, single layer, frameLengthType 0/1 and
/// audioMuxVersionA 0) is supported, matching the rest of this port.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Parsed LOAS elementary stream: the first StreamMuxConfig's
/// AudioSpecificConfig and the raw AAC access units in order.
pub struct LatmStream {
  asc : Bytes
  frames : Array[Bytes]
}

///|
/// `latm_get_value`: a 2-bit byte count followed by that many 8-bit groups.
fn latm_get_value(gb : BitReader) -> UInt32 {
  let length = gb.read(2).reinterpret_as_int()
  gb.read((length + 1) * 8)
}

///|
/// Repack `nbits` from the bit reader into MSB-first bytes (the final partial
/// byte is padded with zeros, like FFmpeg's `put_bits` flush).
fn latm_read_bytes(
  gb : BitReader,
  nbits : Int32,
) -> Result[Array[Byte], String] {
  if nbits < 0 || gb.bits_left() < nbits {
    return Err("latm: truncated payload")
  }
  let out : Array[Byte] = []
  let mut left = nbits
  while left >= 8 {
    out.push(gb.read(8).to_byte())
    left = left - 8
  }
  if left > 0 {
    out.push((gb.read(left).reinterpret_as_int() << (8 - left)).to_byte())
  }
  Ok(out)
}

///|
/// Parse a LOAS stream into its AudioSpecificConfig and raw AAC frames.
pub fn latm_parse_stream(data : Bytes) -> Result[LatmStream, String] {
  let frames : Array[Bytes] = []
  let mut asc : Bytes = b""
  let mut have_config = false
  let mut frame_length_type = -1
  let mut frame_length = 0
  let mut pos = 0
  while pos < data.length() {
    if data.length() - pos < 3 {
      return Err("latm: truncated LOAS header")
    }
    if data[pos].to_int() != 0x56 || (data[pos + 1].to_int() & 0xE0) != 0xE0 {
      return Err("latm: invalid LOAS sync word")
    }
    let mux_len = ((data[pos + 1].to_int() & 0x1F) << 8) |
      data[pos + 2].to_int()
    let start = pos + 3
    let end = start + mux_len
    if end > data.length() {
      return Err("latm: truncated LOAS frame")
    }
    let gb = BitReader::new(data[start:end].to_owned())
    if gb.read1() == 0 {
      // StreamMuxConfig
      let version = gb.read1() != 0
      let mut version_a = false
      if version {
        version_a = gb.read1() != 0
      }
      if version_a {
        return Err("latm: audioMuxVersionA is not supported")
      }
      if version {
        let _ = latm_get_value(gb) // taraFullness
      }
      let _ = gb.read1() // allStreamsSameTimeFraming
      let _ = gb.read(6) // numSubFrames
      if gb.read(4) != 0 {
        return Err("latm: multiple programs are not supported")
      }
      if gb.read(3) != 0 {
        return Err("latm: multiple layers are not supported")
      }
      if !version {
        // ASC length is implied by its syntax; decode a repacked copy of the
        // remaining bits, then rewind to advance by the consumed length.
        let start_bit = gb.count()
        let rest = match latm_read_bytes(gb, gb.bits_left()) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let parsed = match
          aac_parse_audio_specific_config(Bytes::from_array(rest)) {
          Ok(v) => v
          Err(e) => return Err("latm: " + e)
        }
        let asc_bits = parsed.bits_consumed
        let asc_bytes = (asc_bits + 7) / 8
        if asc_bits <= 0 || asc_bits > gb.count() - start_bit {
          return Err("latm: invalid ASC length")
        }
        let stored : Array[Byte] = []
        for i = 0; i < asc_bytes; i = i + 1 {
          stored.push(rest[i])
        }
        asc = Bytes::from_array(stored)
        gb.set_pos(start_bit + asc_bits)
      } else {
        let asc_len = latm_get_value(gb).reinterpret_as_int()
        if asc_len <= 0 || asc_len > gb.bits_left() {
          return Err("latm: invalid ASC length")
        }
        let stored = match latm_read_bytes(gb, asc_len) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let _ = match
          aac_parse_audio_specific_config(Bytes::from_array(stored)) {
          Ok(v) => v
          Err(e) => return Err("latm: " + e)
        }
        asc = Bytes::from_array(stored)
      }
      have_config = true
      frame_length_type = gb.read(3).reinterpret_as_int()
      if frame_length_type == 0 {
        let _ = gb.read(8) // latmBufferFullness
      } else if frame_length_type == 1 {
        if gb.bits_left() < 9 {
          return Err("latm: truncated frame length")
        }
        frame_length = gb.read(9).reinterpret_as_int()
      } else {
        return Err("latm: unsupported frameLengthType")
      }
      if gb.read1() != 0 {
        if version {
          let _ = latm_get_value(gb) // otherDataBits
        } else {
          let mut esc = true
          while esc {
            if gb.bits_left() < 9 {
              return Err("latm: truncated otherData")
            }
            esc = gb.read1() != 0
            let _ = gb.read(8)
          }
        }
      }
      if gb.read1() != 0 {
        if gb.bits_left() < 8 {
          return Err("latm: truncated config CRC")
        }
        let _ = gb.read(8)
      }
    } else if !have_config {
      return Err("latm: useSameStreamMux before StreamMuxConfig")
    }
    let slot_len = if frame_length_type == 0 {
      let mut total = 0
      let mut tmp = 255
      while tmp == 255 {
        if gb.bits_left() < 8 {
          return Err("latm: truncated PayloadLengthInfo")
        }
        tmp = gb.read(8).reinterpret_as_int()
        total = total + tmp
      }
      total
    } else if frame_length_type == 1 {
      frame_length
    } else {
      return Err("latm: unsupported frameLengthType")
    }
    if slot_len * 8 > gb.bits_left() {
      return Err("latm: incomplete frame")
    }
    if slot_len > 0 {
      let au = match latm_read_bytes(gb, slot_len * 8) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      frames.push(Bytes::from_array(au))
    }
    pos = end
  }
  if !have_config {
    return Err("latm: no StreamMuxConfig found")
  }
  Ok({ asc, frames, })
}
