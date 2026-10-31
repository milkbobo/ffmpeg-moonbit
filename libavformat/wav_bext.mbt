///|
/// Broadcast Wave (`bext`) metadata. The layout mirrors FFmpeg 9.0.2
/// `wavdec.c::wav_parse_bext_tag` / `wavenc.c::bwf_write_bext_chunk`:
/// five fixed strings, a 64-bit little-endian time reference, version 1,
/// a 64-byte UMID, 190 reserved bytes and an optional NUL-terminated coding
/// history.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct WavBext {
  description : String
  originator : String
  originator_reference : String
  origination_date : String
  origination_time : String
  time_reference : UInt64
  /// Raw 64-byte UMID; zeros when the file has none.
  umid : Bytes
  coding_history : String
}

///|
pub fn WavBext::new(
  description~ : String = "",
  originator~ : String = "",
  originator_reference~ : String = "",
  origination_date~ : String = "",
  origination_time~ : String = "",
  time_reference~ : UInt64 = 0UL,
  umid~ : Bytes = b"",
  coding_history~ : String = "",
) -> WavBext {
  {
    description,
    originator,
    originator_reference,
    origination_date,
    origination_time,
    time_reference,
    umid,
    coding_history,
  }
}

///|
fn wav_bext_u16(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() | (data[off + 1].to_int() << 8)
}

///|
fn wav_bext_u32(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() |
  (data[off + 1].to_int() << 8) |
  (data[off + 2].to_int() << 16) |
  (data[off + 3].to_int() << 24)
}

///|
fn wav_bext_u64(data : Bytes, off : Int32) -> UInt64 {
  let mut v : UInt64 = 0UL
  for i = 0; i < 8; i = i + 1 {
    v = v | (data[off + i].to_uint().to_uint64() << (8 * i))
  }
  v
}

///|
/// Fixed-width, NUL-padded string field.
fn wav_bext_string(payload : Bytes, off : Int32, len : Int32) -> String {
  let out : Array[Byte] = []
  for i = 0; i < len; i = i + 1 {
    let b = payload[off + i]
    if b == b'\x00' {
      break
    }
    out.push(b)
  }
  utf8_to_string(out)
}

///|
/// Locate and parse the `bext` chunk of a RIFF/RF64 WAVE file.
pub fn wav_read_bext(data : Bytes) -> WavBext? {
  if data.length() < 12 ||
    data[8] != b'W' ||
    data[9] != b'A' ||
    data[10] != b'V' ||
    data[11] != b'E' {
    return None
  }
  let mut pos = 12
  while pos + 8 <= data.length() {
    let is_bext = data[pos] == b'b' &&
      data[pos + 1] == b'e' &&
      data[pos + 2] == b'x' &&
      data[pos + 3] == b't'
    let size = wav_bext_u32(data, pos + 4)
    let start = pos + 8
    if size < 0 || start + size > data.length() {
      return None
    }
    if is_bext {
      if size < 602 {
        return None
      }
      let payload = data[start:start + size].to_owned()
      let version = wav_bext_u16(payload, 346)
      let umid : Array[Byte] = []
      for i = 0; i < 64; i = i + 1 {
        umid.push(if version >= 1 { payload[348 + i] } else { b'\x00' })
      }
      let coding : Array[Byte] = []
      if size > 602 {
        for i = 602; i < size; i = i + 1 {
          if payload[i] == b'\x00' {
            break
          }
          coding.push(payload[i])
        }
      }
      return Some({
        description: wav_bext_string(payload, 0, 256),
        originator: wav_bext_string(payload, 256, 32),
        originator_reference: wav_bext_string(payload, 288, 32),
        origination_date: wav_bext_string(payload, 320, 10),
        origination_time: wav_bext_string(payload, 330, 8),
        time_reference: wav_bext_u64(payload, 338),
        umid: Bytes::from_array(umid),
        coding_history: utf8_to_string(coding),
      })
    }
    pos = start + size + (size & 1)
  }
  None
}

///|
fn wav_bext_push_fixed(dst : Array[Byte], value : String, len : Int32) -> Unit {
  let bytes = utf8_from_string(value)
  for i = 0; i < len; i = i + 1 {
    dst.push(if i < bytes.length() { bytes[i] } else { b'\x00' })
  }
}

///|
fn wav_bext_push_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push((v & 0xFF).to_byte())
  dst.push(((v >> 8) & 0xFF).to_byte())
}

///|
/// Build the complete `bext` chunk (header, payload and pad byte) exactly as
/// `bwf_write_bext_chunk` does with version 1 and a zero/tagged UMID.
fn wav_bext_chunk(bext : WavBext) -> Array[Byte] {
  let payload : Array[Byte] = []
  wav_bext_push_fixed(payload, bext.description, 256)
  wav_bext_push_fixed(payload, bext.originator, 32)
  wav_bext_push_fixed(payload, bext.originator_reference, 32)
  wav_bext_push_fixed(payload, bext.origination_date, 10)
  wav_bext_push_fixed(payload, bext.origination_time, 8)
  for i = 0; i < 8; i = i + 1 {
    payload.push(((bext.time_reference >> (8 * i)) & 0xFFUL).to_int().to_byte())
  }
  wav_bext_push_u16(payload, 1) // version 1 (UMID present)
  for i = 0; i < 64; i = i + 1 {
    payload.push(if i < bext.umid.length() { bext.umid[i] } else { b'\x00' })
  }
  for _ in 0..<190 {
    payload.push(b'\x00')
  }
  if bext.coding_history != "" {
    let history = utf8_from_string(bext.coding_history)
    for b in history {
      payload.push(b)
    }
    payload.push(b'\x00')
  }
  let out : Array[Byte] = []
  for c in "bext" {
    out.push(c.to_int().to_byte())
  }
  for i = 0; i < 4; i = i + 1 {
    out.push(((payload.length() >> (8 * i)) & 0xFF).to_byte())
  }
  for b in payload {
    out.push(b)
  }
  if (payload.length() & 1) != 0 {
    out.push(b'\x00')
  }
  out
}
