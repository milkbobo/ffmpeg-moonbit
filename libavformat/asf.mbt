///|
/// Minimal ASF (Advanced Systems Format) demuxer for audio-only files,
/// following FFmpeg 9.0.2 `libavformat/asfdec_f.c` / `asf.h`.
///
/// Scope: File Properties, audio Stream Properties (WAVEFORMATEX; WMA v1/v2
/// codec ids) and Data Object packets with standard error correction.
/// Payload fragments are assembled per stream into media objects; WMA
/// bit-reservoir multi-subpayload packets are supported.  Video, extended
/// stream properties, DRM and payload-extension systems are skipped/ignored.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// GUIDs
// ---------------------------------------------------------------------------

///|
let asf_guid_header : Bytes = b"\x30\x26\xB2\x75\x8E\x66\xCF\x11\xA6\xD9\x00\xAA\x00\x62\xCE\x6C"

///|
let asf_guid_file_header : Bytes = b"\xA1\xDC\xAB\x8C\x47\xA9\xCF\x11\x8E\xE4\x00\xC0\x0C\x20\x53\x65"

///|
let asf_guid_stream_header : Bytes = b"\x91\x07\xDC\xB7\xB7\xA9\xCF\x11\x8E\xE6\x00\xC0\x0C\x20\x53\x65"

///|
let asf_guid_data_header : Bytes = b"\x36\x26\xB2\x75\x8E\x66\xCF\x11\xA6\xD9\x00\xAA\x00\x62\xCE\x6C"

///|
let asf_guid_audio_stream : Bytes = b"\x40\x9E\x69\xF8\x4D\x5B\xCF\x11\xA8\xFD\x00\x80\x5F\x5C\x44\x2B"

// ---------------------------------------------------------------------------
// data model
// ---------------------------------------------------------------------------

///|
/// One audio stream from the ASF Stream Properties object.
pub struct AsfTrack {
  /// ASF stream number (low 7 bits of the flags field).
  stream_number : Int32
  /// "wmav1" or "wmav2" (other codecs are not stored).
  codec : String
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
  block_align : Int32
  bits_per_sample : Int32
  /// WAVEFORMATEX codec private bytes (includes cbSize).
  extradata : Bytes
}

///|
/// One assembled media object (one codec packet).
pub struct AsfPacket {
  stream_index : Int32
  data : Bytes
  /// Presentation time in milliseconds (packet timestamp - preroll).
  pts : Int64
  is_keyframe : Bool
}

///|
/// Parsed ASF file.
pub struct AsfDemux {
  packet_size : Int32
  preroll : Int32
  tracks : Array[AsfTrack]
  packets : Array[AsfPacket]
}

// ---------------------------------------------------------------------------
// little-endian helpers
// ---------------------------------------------------------------------------

///|
fn asf_u16(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() | (data[off + 1].to_int() << 8)
}

///|
fn asf_u32(data : Bytes, off : Int32) -> Int64 {
  asf_u16(data, off).to_int64() | (asf_u16(data, off + 2).to_int64() << 16)
}

///|
fn asf_u64(data : Bytes, off : Int32) -> Int64 {
  asf_u32(data, off) | (asf_u32(data, off + 4) << 32)
}

///|
fn asf_guid_at(data : Bytes, off : Int32) -> Bytes {
  data[off:off + 16].to_owned()
}

// ---------------------------------------------------------------------------
// stream properties
// ---------------------------------------------------------------------------

///|
/// `ff_get_wav_header` + the audio part of `asf_read_stream_properties`.
fn asf_parse_stream_properties(
  data : Bytes,
  body : Int32,
  size : Int32,
) -> AsfTrack? {
  if size < 16 + 16 + 8 + 8 + 2 + 4 {
    return None
  }
  if asf_guid_at(data, body) != asf_guid_audio_stream {
    return None
  }
  let type_specific_size = asf_u32(data, body + 16 + 16 + 8).to_int()
  let flags = asf_u16(data, body + 16 + 16 + 8 + 8)
  let stream_number = flags & 0x7F
  let wav = body + 16 + 16 + 8 + 8 + 2 + 4
  if type_specific_size < 16 || wav + type_specific_size > body + size {
    return None
  }
  let format_tag = asf_u16(data, wav)
  let codec = match format_tag {
    0x160 => "wmav1"
    0x161 => "wmav2"
    _ => return None
  }
  let channels = asf_u16(data, wav + 2)
  let sample_rate = asf_u32(data, wav + 4).to_int()
  let avg_bytes = asf_u32(data, wav + 8).to_int()
  let block_align = asf_u16(data, wav + 12)
  let bits_per_sample = asf_u16(data, wav + 14)
  let mut extra_start = wav + 16
  if type_specific_size > 16 {
    let cb_size = asf_u16(data, wav + 16)
    extra_start = wav + 18
    if cb_size + 18 > type_specific_size {
      extra_start = wav + 16
    }
  }
  let extra_end = if extra_start < wav + type_specific_size {
    wav + type_specific_size
  } else {
    extra_start
  }
  Some({
    stream_number,
    codec,
    sample_rate,
    channels,
    bit_rate: avg_bytes * 8,
    block_align,
    bits_per_sample,
    extradata: data[extra_start:extra_end].to_owned(),
  })
}

// ---------------------------------------------------------------------------
// packet parsing
// ---------------------------------------------------------------------------

///|
/// `DO_2BITS`: size code 0 keeps `value`, else 1/2/4 little-endian bytes.
fn asf_read_field(
  data : Bytes,
  pos : Ref[Int32],
  code : Int32,
  value : Int32,
) -> Int32 {
  let p = pos.val
  match code & 3 {
    1 => {
      pos.val = p + 1
      data[p].to_int()
    }
    2 => {
      pos.val = p + 2
      asf_u16(data, p)
    }
    3 => {
      pos.val = p + 4
      asf_u32(data, p).to_int()
    }
    _ => value
  }
}

///|
/// `asf_parse_packet` for one fixed-size ASF packet.  Appends complete media
/// objects to `packets` and returns the number of bytes consumed.
fn asf_parse_one_packet(
  data : Bytes,
  start : Int32,
  packet_size : Int32,
  preroll : Int32,
  tracks : Array[AsfTrack],
  packets : Array[AsfPacket],
) -> Result[Unit, String] {
  let limit = if start + packet_size > data.length() {
    data.length()
  } else {
    start + packet_size
  }
  let pos : Ref[Int32] = { val: start, }
  if pos.val + 8 > limit {
    return Err("asf: truncated packet")
  }
  // Error correction data.
  let c = data[pos.val].to_int()
  pos.val = pos.val + 1
  let mut packet_flags = 0
  let mut packet_property = 0
  if (c & 0x80) != 0 {
    if c == 0x82 {
      // Standard ECC: two zero bytes.
      if pos.val + 2 > limit {
        return Err("asf: truncated ECC")
      }
      if data[pos.val].to_int() != 0 || data[pos.val + 1].to_int() != 0 {
        return Err("asf: unsupported ECC")
      }
      pos.val = pos.val + 2
    } else {
      return Err("asf: unsupported ECC")
    }
    packet_flags = data[pos.val].to_int()
    packet_property = data[pos.val + 1].to_int()
    pos.val = pos.val + 2
  } else {
    packet_flags = c
    packet_property = data[pos.val].to_int()
    pos.val = pos.val + 1
  }
  let length_type = (packet_flags >> 5) & 3
  let seq_type = (packet_flags >> 1) & 3
  let pad_type = (packet_flags >> 3) & 3
  let packet_length = asf_read_field(data, pos, length_type, packet_size)
  let _ = asf_read_field(data, pos, seq_type, 0)
  let padding = asf_read_field(data, pos, pad_type, 0)
  if packet_length <= 0 ||
    packet_length > packet_size ||
    padding >= packet_length {
    return Err("asf: invalid packet length")
  }
  if pos.val + 6 > limit {
    return Err("asf: truncated packet header")
  }
  let packet_timestamp = asf_u32(data, pos.val).to_int()
  pos.val = pos.val + 6 // timestamp + duration
  let mut segments = 1
  let mut segsizetype = 0x80
  if (packet_flags & 0x01) != 0 {
    if pos.val >= limit {
      return Err("asf: truncated segment header")
    }
    segsizetype = data[pos.val].to_int()
    pos.val = pos.val + 1
    segments = segsizetype & 0x3F
  }
  let header_end = pos.val
  let packet_end = start + packet_length - padding
  let mut left = packet_end - header_end
  if left < 0 {
    return Err("asf: invalid packet header size")
  }
  // Per-stream fragment assembly.
  let pending : Array[Array[Byte]?] = []
  let pending_size : Array[Int32] = []
  let pending_off : Array[Int32] = []
  let pending_pts : Array[Int64] = []
  let pending_key : Array[Bool] = []
  for _t = 0; _t < tracks.length(); _t = _t + 1 {
    pending.push(None)
    pending_size.push(0)
    pending_off.push(0)
    pending_pts.push(0L)
    pending_key.push(false)
  }
  let multi_size : Ref[Int32] = { val: 0, }
  let multi_time_start : Ref[Int32] = { val: 0, }
  let multi_time_delta : Ref[Int32] = { val: 0, }
  let multi_active : Ref[Bool] = { val: false, }
  while segments > 0 && left >= 3 {
    segments = segments - 1
    if pos.val + 2 > packet_end {
      break
    }
    let stream_byte = data[pos.val].to_int()
    pos.val = pos.val + 1
    let stream_number = stream_byte & 0x7F
    let key_frame = (stream_byte & 0x80) != 0
    let _ = asf_read_field(data, pos, (packet_property >> 4) & 3, 0)
    let frag_offset = asf_read_field(data, pos, (packet_property >> 2) & 3, 0)
    let replic_size = asf_read_field(data, pos, packet_property & 3, 0)
    let mut obj_size = 0
    let mut obj_ts = packet_timestamp
    if replic_size >= 8 {
      if pos.val + 8 > packet_end {
        return Err("asf: truncated replicated data")
      }
      obj_size = asf_u32(data, pos.val).to_int()
      obj_ts = asf_u32(data, pos.val + 4).to_int()
      pos.val = pos.val + replic_size
    } else if replic_size == 1 {
      multi_time_start.val = frag_offset
      multi_time_delta.val = data[pos.val].to_int()
      pos.val = pos.val + 1
      multi_active.val = true
    } else if replic_size != 0 {
      return Err("asf: unsupported replicated data size")
    }
    if pos.val > packet_end {
      return Err("asf: payload header overflow")
    }
    let mut frag_size = left - (pos.val - header_end)
    if (packet_flags & 0x01) != 0 {
      frag_size = asf_read_field(data, pos, segsizetype >> 6, 0)
    }
    if replic_size == 1 {
      multi_size.val = frag_size
      if pos.val >= packet_end {
        break
      }
      // Multi-subpayload: each subpayload starts with its length byte.
      let mut multi_left = multi_size.val
      while multi_left > 0 && pos.val < packet_end {
        let sub_len = data[pos.val].to_int()
        pos.val = pos.val + 1
        multi_left = multi_left - 1
        if sub_len > multi_left || pos.val + sub_len > packet_end {
          pos.val = pos.val + multi_left
          break
        }
        let sub = data[pos.val:pos.val + sub_len].to_owned()
        pos.val = pos.val + sub_len
        multi_left = multi_left - sub_len
        let mut stream_index = -1
        for t = 0; t < tracks.length(); t = t + 1 {
          if tracks[t].stream_number == stream_number {
            stream_index = t
          }
        }
        if stream_index >= 0 {
          packets.push({
            stream_index,
            data: sub,
            pts: (multi_time_start.val - preroll).to_int64(),
            is_keyframe: key_frame,
          })
        }
        multi_time_start.val = multi_time_start.val + multi_time_delta.val
      }
      left = packet_end - pos.val
      continue
    }
    if obj_size <= 0 || obj_size > 1 << 24 {
      return Err("asf: invalid media object size")
    }
    if frag_offset < 0 || frag_size < 0 || frag_offset + frag_size > obj_size {
      return Err("asf: invalid fragment position")
    }
    if pos.val + frag_size > packet_end {
      return Err("asf: fragment exceeds packet")
    }
    let mut stream_index = -1
    for t = 0; t < tracks.length(); t = t + 1 {
      if tracks[t].stream_number == stream_number {
        stream_index = t
      }
    }
    if stream_index >= 0 && !multi_active.val {
      let current = pending[stream_index]
      let need_new = match current {
        None => true
        Some(buf) =>
          buf.length() != obj_size || frag_offset != pending_off[stream_index]
      }
      let target = if need_new {
        let buf : Array[Byte] = Array::make(obj_size, b'\x00')
        pending[stream_index] = Some(buf)
        pending_size[stream_index] = obj_size
        pending_off[stream_index] = 0
        pending_pts[stream_index] = (obj_ts - preroll).to_int64()
        pending_key[stream_index] = key_frame
        buf
      } else {
        match pending[stream_index] {
          Some(buf) => buf
          None => return Err("asf: missing fragment buffer")
        }
      }
      for i = 0; i < frag_size; i = i + 1 {
        target[frag_offset + i] = data[pos.val + i]
      }
      pos.val = pos.val + frag_size
      pending_off[stream_index] = frag_offset + frag_size
      if pending_off[stream_index] == obj_size {
        packets.push({
          stream_index,
          data: Bytes::from_array(target),
          pts: pending_pts[stream_index],
          is_keyframe: pending_key[stream_index],
        })
        pending[stream_index] = None
        pending_off[stream_index] = 0
      }
    } else {
      pos.val = pos.val + frag_size
    }
    left = packet_end - pos.val
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// file parse
// ---------------------------------------------------------------------------

///|
/// Parse an ASF/WMA file: header objects (File/Stream Properties) and the
/// Data Object packets.
pub fn av_asf_open(data : Bytes) -> Result[AsfDemux, String] {
  if data.length() < 30 || asf_guid_at(data, 0) != asf_guid_header {
    return Err("asf: not an ASF file")
  }
  let header_size = asf_u64(data, 16)
  if header_size < 30 || header_size > data.length().to_int64() {
    return Err("asf: invalid header size")
  }
  let num_objects = asf_u32(data, 24).to_int()
  let mut packet_size = 0
  let mut preroll = 0
  let tracks : Array[AsfTrack] = []
  let packets : Array[AsfPacket] = []
  let mut data_start = -1
  let mut data_size : Int64 = 0
  let mut pos = 30
  for _i = 0; _i < num_objects; _i = _i + 1 {
    if pos.to_int64() + 24L > header_size {
      break
    }
    let guid = asf_guid_at(data, pos)
    let size = asf_u64(data, pos + 16)
    if size < 24 || pos.to_int64() + size > data.length().to_int64() {
      break
    }
    let body = pos + 24
    let body_size = size.to_int() - 24
    if guid == asf_guid_file_header {
      if body_size >= 64 {
        preroll = asf_u32(data, body + 56).to_int()
        let min_pkt = asf_u32(data, body + 68).to_int()
        let max_pkt = asf_u32(data, body + 72).to_int()
        packet_size = if max_pkt > 0 { max_pkt } else { min_pkt }
      }
    } else if guid == asf_guid_stream_header {
      match asf_parse_stream_properties(data, body, body_size) {
        Some(track) => tracks.push(track)
        None => ()
      }
    }
    pos = pos + size.to_int()
  }
  // The Data Object is a sibling of the Header Object, not a child.
  let mut obj = header_size.to_int()
  while obj + 24 <= data.length() {
    let guid = asf_guid_at(data, obj)
    let size = asf_u64(data, obj + 16)
    if size < 24 || obj.to_int64() + size > data.length().to_int64() {
      break
    }
    if guid == asf_guid_data_header {
      data_start = obj
      data_size = size
      break
    }
    obj = obj + size.to_int()
  }
  if data_start < 0 || packet_size <= 0 {
    return Err("asf: missing data object or packet size")
  }
  if tracks.length() == 0 {
    return Err("asf: no supported audio stream")
  }
  let packets_start = data_start + 50
  let packets_end = if data_start.to_int64() + data_size >
    data.length().to_int64() {
    data.length()
  } else {
    (data_start.to_int64() + data_size).to_int()
  }
  let mut pos = packets_start
  while pos + packet_size <= packets_end {
    match
      asf_parse_one_packet(data, pos, packet_size, preroll, tracks, packets) {
      Ok(_) => ()
      Err(e) => println("DBG asf packet err at \{pos}: \{e}")
    }
    pos = pos + packet_size
  }
  Ok({ packet_size, preroll, tracks, packets, })
}
