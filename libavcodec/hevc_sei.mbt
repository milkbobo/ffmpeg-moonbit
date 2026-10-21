///|
/// MoonBit port of the HEVC SEI message layer from FFmpeg 9.0.2
/// `libavcodec/hevc/sei.c` plus the common payload syntax shared with
/// `libavcodec/h2645_sei.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: prefix/suffix SEI NAL (types 39/40), payload type/size 0xFF
/// continuation, mastering display colour volume (137), content light level
/// (144), user data unregistered (5), recovery point (6), alternative transfer
/// characteristics (147) and ambient viewing environment (148). Other messages
/// are retained as raw payloads so callers can add parsers without re-walking
/// the NAL.
///
/// Out of scope: buffering period / picture timing (needs the active SPS and
/// HRD state), film grain, scalable-nesting, and SEI-to-AVFrame side data.

///|
pub struct HevcSeiMasteringDisplay {
  /// `(x, y)` for G, B, R in the SEI's order.
  display_primaries : Array[(Int32, Int32)]
  white_point : (Int32, Int32)
  max_luminance : Int32
  min_luminance : Int32
}

///|
pub struct HevcSeiMessage {
  payload_type : Int32
  payload_size : Int32
  raw : Bytes
  /// 16-byte UUID for user_data_unregistered (5).
  mut unregistered_uuid : Bytes?
  mut unregistered_payload : Bytes?
  mut mastering_display : HevcSeiMasteringDisplay?
  mut max_content_light : Int32
  mut max_pic_average_light : Int32
  mut recovery_poc_cnt : Int32
  mut preferred_transfer : Int32
}

///|
pub struct HevcSei {
  messages : Array[HevcSeiMessage]
}

///|
fn sei_u16(b : BytesView, off : Int32) -> Int32 {
  (b[off].to_int() << 8) | b[off + 1].to_int()
}

///|
fn sei_u32(b : BytesView, off : Int32) -> Int32 {
  (b[off].to_int() << 24) |
  (b[off + 1].to_int() << 16) |
  (b[off + 2].to_int() << 8) |
  b[off + 3].to_int()
}

///|
fn hevc_sei_parse_message(
  payload_type : Int32,
  payload : Bytes,
) -> HevcSeiMessage {
  let msg : HevcSeiMessage = {
    payload_type,
    payload_size: payload.length(),
    raw: payload,
    unregistered_uuid: None,
    unregistered_payload: None,
    mastering_display: None,
    max_content_light: 0,
    max_pic_average_light: 0,
    recovery_poc_cnt: -1,
    preferred_transfer: -1,
  }
  if payload_type == 137 && payload.length() >= 24 {
    let primaries : Array[(Int32, Int32)] = []
    for i in 0..<3 {
      primaries.push((sei_u16(payload, i * 4), sei_u16(payload, i * 4 + 2)))
    }
    msg.mastering_display = Some({
      display_primaries: primaries,
      white_point: (sei_u16(payload, 12), sei_u16(payload, 14)),
      max_luminance: sei_u32(payload, 16),
      min_luminance: sei_u32(payload, 20),
    })
  } else if payload_type == 144 && payload.length() >= 4 {
    msg.max_content_light = sei_u16(payload, 0)
    msg.max_pic_average_light = sei_u16(payload, 2)
  } else if payload_type == 5 && payload.length() >= 16 {
    msg.unregistered_uuid = Some(payload[0:16].to_owned())
    msg.unregistered_payload = Some(payload[16:].to_owned())
  } else if payload_type == 6 && payload.length() >= 1 {
    // recovery_poc_cnt is ue(v); the remaining bits are the exact-match flag
    // and trailing bits.
    let br = BitReader::new(payload)
    msg.recovery_poc_cnt = br.read_ue()
  } else if payload_type == 147 && payload.length() >= 1 {
    msg.preferred_transfer = payload[0].to_int()
  }
  msg
}

///|
fn hevc_sei_parse_payload(data : Bytes) -> HevcSei {
  let messages : Array[HevcSeiMessage] = []
  let n = data.length()
  let mut pos = 0
  while pos < n {
    // rbsp_trailing_bits: a lone 0x80 ends the SEI RBSP.
    if data[pos] == b'\x80' && pos == n - 1 {
      break
    }
    let mut payload_type = 0
    while pos < n && data[pos] == b'\xff' {
      payload_type = payload_type + 255
      pos = pos + 1
    }
    if pos >= n {
      break
    }
    payload_type = payload_type + data[pos].to_int()
    pos = pos + 1
    let mut payload_size = 0
    while pos < n && data[pos] == b'\xff' {
      payload_size = payload_size + 255
      pos = pos + 1
    }
    if pos >= n {
      break
    }
    payload_size = payload_size + data[pos].to_int()
    pos = pos + 1
    if pos + payload_size > n {
      break
    }
    let payload = data[pos:pos + payload_size].to_owned()
    pos = pos + payload_size
    messages.push(hevc_sei_parse_message(payload_type, payload))
  }
  { messages, }
}

///|
/// Parse every prefix/suffix SEI NAL in an Annex B or length-prefixed stream.
pub fn ff_hevc_parse_sei(
  data : Bytes,
  is_nalff : Bool,
  nal_length_size : Int32,
) -> Result[HevcSei, String] {
  let pkt = match ff_h2645_packet_split(data, nal_length_size, Hevc, is_nalff) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let all : Array[HevcSeiMessage] = []
  for nal in pkt.nals {
    if nal.nal_type == 39 || nal.nal_type == 40 {
      if nal.data.length() < 2 {
        continue
      }
      let sei = hevc_sei_parse_payload(nal.data[2:].to_owned())
      for m in sei.messages {
        all.push(m)
      }
    }
  }
  Ok({ messages: all, })
}
