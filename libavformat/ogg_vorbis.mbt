///|
/// In-memory Ogg/Vorbis demuxer.  Parses Ogg pages, lacing values and granule
/// positions, validates the three Vorbis headers and emits the audio packets
/// in order.  Sample positions follow the page granule (the number of PCM
/// samples up to the end of the page); the decoder's first-frame skip is
/// applied by `VorbisDecoder::decode_stream`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: a single Vorbis logical stream (the common `.ogg` audio case).
/// Chained/multiplexed streams and other codecs are rejected.

///|
pub struct OggVorbisPacket {
  data : Bytes
  /// Granule position of the page the packet ends on (-1 when unset).
  granule : Int64
  /// Byte offset of the page start.
  pos : Int64
}

///|
pub struct OggVorbisDemux {
  serial : Int32
  channels : Int32
  sample_rate : Int32
  id_header : Bytes
  comment_header : Bytes
  setup_header : Bytes
  /// User comments of the comment header (generic keys).
  tags : Array[(String, String)]
  packets : Array[OggVorbisPacket]
  /// Last granule of the stream (total PCM samples).
  total_samples : Int64
}

///|
fn ogg_vorbis_u32(data : BytesView, off : Int32) -> UInt32 {
  data[off].to_uint() |
  (data[off + 1].to_uint() << 8) |
  (data[off + 2].to_uint() << 16) |
  (data[off + 3].to_uint() << 24)
}

///|
fn ogg_vorbis_u64(data : BytesView, off : Int32) -> Int64 {
  let lo = ogg_vorbis_u32(data, off).to_int64()
  let hi = ogg_vorbis_u32(data, off + 4).to_int64()
  (hi << 32) | (lo & 0xFFFFFFFFL)
}

///|
fn ogg_vorbis_crc_ok(data : Bytes, start : Int32, end : Int32) -> Bool {
  if end - start < 27 {
    return false
  }
  let mut crc = 0U
  for i in start..<end {
    let rel = i - start
    let b = if rel >= 22 && rel < 26 { 0 } else { data[i].to_int() }
    crc = crc ^ (b.reinterpret_as_uint() << 24)
    for _ in 0..<8 {
      crc = if (crc & 0x80000000U) != 0 {
        (crc << 1) ^ 0x04C11DB7U
      } else {
        crc << 1
      }
    }
  }
  crc == ogg_vorbis_u32(data[:], start + 22)
}

///|
fn ogg_vorbis_header_packet(packet : Bytes, kind : Int32) -> Bool {
  if packet.length() < 7 || packet[0].to_int() != kind {
    return false
  }
  let signature : Bytes = b"vorbis"
  for i = 0; i < 6; i = i + 1 {
    if packet[1 + i] != signature[i] {
      return false
    }
  }
  true
}

///|
pub fn av_ogg_vorbis_open(data : Bytes) -> Result[OggVorbisDemux, String] {
  if data.length() < 27 || data[0:4].to_owned() != b"OggS" {
    return Err("ogg: missing Ogg capture pattern")
  }
  let mut pos = 0
  let mut serial = 0
  let mut have_stream = false
  let mut id_header : Bytes? = None
  let mut comment_header : Bytes? = None
  let mut setup_header : Bytes? = None
  let mut pending : Array[Byte] = []
  let packets : Array[OggVorbisPacket] = []
  let mut total_samples = 0L
  while pos + 27 <= data.length() {
    if data[pos:pos + 4].to_owned() != b"OggS" {
      return Err("ogg: page lost sync")
    }
    if data[pos + 4].to_int() != 0 {
      return Err("ogg: unsupported version")
    }
    let header_type = data[pos + 5].to_int()
    let granule = ogg_vorbis_u64(data[:], pos + 6)
    let page_serial = ogg_vorbis_u32(data[:], pos + 14).reinterpret_as_int()
    let nseg = data[pos + 26].to_int()
    if pos + 27 + nseg > data.length() {
      return Err("ogg: truncated segment table")
    }
    let mut payload_len = 0
    for i in 0..<nseg {
      payload_len = payload_len + data[pos + 27 + i].to_int()
    }
    let page_end = pos + 27 + nseg + payload_len
    if page_end > data.length() {
      return Err("ogg: truncated page payload")
    }
    if !ogg_vorbis_crc_ok(data, pos, page_end) {
      return Err("ogg: page CRC mismatch")
    }
    if !have_stream {
      serial = page_serial
      have_stream = true
    }
    if page_serial != serial {
      pos = page_end
      continue
    }
    if (header_type & 1) != 0 && pending.length() == 0 {
      return Err("ogg: continuation page without a partial packet")
    }
    let page_pos = pos.to_int64()
    let mut p = pos + 27 + nseg
    for i in 0..<nseg {
      let lace = data[pos + 27 + i].to_int()
      for j in 0..<lace {
        pending.push(data[p + j])
      }
      p = p + lace
      if lace < 255 {
        let packet = Bytes::from_array(pending)
        pending = []
        if id_header is None {
          if !ogg_vorbis_header_packet(packet, 1) {
            return Err("ogg: first packet is not a Vorbis id header")
          }
          id_header = Some(packet)
        } else if comment_header is None {
          if !ogg_vorbis_header_packet(packet, 3) {
            return Err("ogg: second packet is not a Vorbis comment header")
          }
          comment_header = Some(packet)
        } else if setup_header is None {
          if !ogg_vorbis_header_packet(packet, 5) {
            return Err("ogg: third packet is not a Vorbis setup header")
          }
          setup_header = Some(packet)
        } else {
          packets.push({ data: packet, granule, pos: page_pos, })
        }
      }
    }
    if granule >= 0L {
      total_samples = granule
    }
    pos = page_end
  }
  let id = match id_header {
    Some(h) => h
    None => return Err("ogg: no Vorbis identification header")
  }
  let comment = match comment_header {
    Some(h) => h
    None => return Err("ogg: no Vorbis comment header")
  }
  let setup = match setup_header {
    Some(h) => h
    None => return Err("ogg: no Vorbis setup header")
  }
  let (tags, _) = match vorbis_comment_read(comment, 7, comment.length()) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Bytes 11..15 of the id header: channels and sample rate.
  let channels = id[11].to_int()
  let sample_rate = (id[12].to_uint() |
  (id[13].to_uint() << 8) |
  (id[14].to_uint() << 16) |
  (id[15].to_uint() << 24)).reinterpret_as_int()
  Ok({
    serial,
    channels,
    sample_rate,
    id_header: id,
    comment_header: comment,
    setup_header: setup,
    tags,
    packets,
    total_samples,
  })
}
