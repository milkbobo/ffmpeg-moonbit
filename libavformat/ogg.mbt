///|
/// In-memory Ogg/Opus demuxer.  Parses Ogg pages, lacing values and granule
/// positions, validates the OpusHead/OpusTags headers and emits one packet per
/// Opus access unit with 48 kHz PTS (including pre-skip handling).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: a single Opus logical stream (the common `.opus`/`.ogg` audio case).
/// Chained/multiplexed streams and other codecs are rejected.

///|
pub struct OggOpusPacket {
  data : Bytes
  pts : Int64
  duration : Int32
  pos : Int64
  granule : Int64
}

///|
pub struct OggOpusDemux {
  serial : Int32
  channels : Int32
  pre_skip : Int32
  input_sample_rate : Int32
  extradata : Bytes
  packets : Array[OggOpusPacket]
}

///|
fn ogg_u32(data : BytesView, off : Int32) -> UInt32 {
  data[off].to_uint() |
  (data[off + 1].to_uint() << 8) |
  (data[off + 2].to_uint() << 16) |
  (data[off + 3].to_uint() << 24)
}

///|
fn ogg_u64(data : BytesView, off : Int32) -> Int64 {
  let lo = ogg_u32(data, off).to_int64()
  let hi = ogg_u32(data, off + 4).to_int64()
  (hi << 32) | (lo & 0xFFFFFFFFL)
}

///|
fn ogg_crc_ok(data : Bytes, start : Int32, end : Int32) -> Bool {
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
  crc == ogg_u32(data[:], start + 22)
}

///|
pub fn av_ogg_opus_open(data : Bytes) -> Result[OggOpusDemux, String] {
  if data.length() < 27 || data[0:4].to_owned() != b"OggS" {
    return Err("ogg: missing Ogg capture pattern")
  }
  let mut pos = 0
  let mut serial = 0
  let mut have_stream = false
  let mut pre_skip = 0
  let mut channels = 0
  let mut input_sample_rate = 0
  let mut extradata : Bytes? = None
  let mut got_head = false
  let mut got_tags = false
  let mut pending : Array[Byte] = []
  let mut cumulative = 0L
  let packets : Array[OggOpusPacket] = []
  while pos + 27 <= data.length() {
    if data[pos:pos + 4].to_owned() != b"OggS" {
      return Err("ogg: page lost sync")
    }
    if data[pos + 4].to_int() != 0 {
      return Err("ogg: unsupported version")
    }
    let header_type = data[pos + 5].to_int()
    let granule = ogg_u64(data[:], pos + 6)
    let page_serial = ogg_u32(data[:], pos + 14).reinterpret_as_int()
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
    if !ogg_crc_ok(data, pos, page_end) {
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
    let completed : Array[(Bytes, Int32)] = []
    for i in 0..<nseg {
      let lace = data[pos + 27 + i].to_int()
      for j in 0..<lace {
        pending.push(data[p + j])
      }
      p = p + lace
      if lace < 255 {
        let packet = Bytes::from_array(pending)
        pending = []
        if !got_head {
          match opus_head_parse(packet) {
            Some((ch, skip, rate)) => {
              channels = ch
              pre_skip = skip
              input_sample_rate = rate
              extradata = Some(packet)
              got_head = true
            }
            None => return Err("ogg: first packet is not OpusHead")
          }
        } else if !got_tags {
          if packet.length() < 8 || packet[0:8].to_owned() != b"OpusTags" {
            return Err("ogg: second packet is not OpusTags")
          }
          got_tags = true
        } else {
          let parsed = match @libavcodec.opus_parse_packet(packet) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          completed.push((packet, parsed.total_samples()))
        }
      }
    }
    if completed.length() > 0 {
      let end = if granule >= 0L { granule - pre_skip.to_int64() } else { -1L }
      for i in 0..<completed.length() {
        let (packet, nominal) = completed[i]
        let pts = cumulative - pre_skip.to_int64()
        let mut duration = nominal
        if i == completed.length() - 1 &&
          end >= 0L &&
          end > pts &&
          pts + duration.to_int64() > end {
          duration = (end - pts).to_int()
        }
        packets.push({ data: packet, pts, duration, pos: page_pos, granule, })
        cumulative = cumulative + nominal.to_int64()
      }
      // The Ogg granule is the authoritative sample position at page end.
      if granule >= 0L {
        cumulative = granule
      }
    } else if granule >= 0L {
      cumulative = granule
    }
    pos = page_end
  }
  if !got_head {
    return Err("ogg: no OpusHead packet")
  }
  Ok({
    serial,
    channels,
    pre_skip,
    input_sample_rate,
    extradata: extradata.unwrap(),
    packets,
  })
}
