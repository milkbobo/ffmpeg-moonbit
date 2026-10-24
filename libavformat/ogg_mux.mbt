///|
/// In-memory Ogg/Opus writer: emits OpusHead and OpusTags on the first data
/// page, then one Ogg page per Opus packet with granule positions in sample
/// units.  The output is the same framing consumed by `av_ogg_opus_open`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct OggOpusMuxer {
  serial : Int32
  channels : Int32
  pre_skip : Int32
  input_sample_rate : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn ogg_opus_muxer_new(
  channels? : Int32 = 2,
  pre_skip? : Int32 = 0,
  input_sample_rate? : Int32 = 48000,
  serial? : Int32 = 0x12345678,
) -> Result[OggOpusMuxer, String] {
  if channels < 1 || channels > 2 || pre_skip < 0 || input_sample_rate <= 0 {
    return Err("EINVAL: invalid Ogg/Opus stream parameters")
  }
  Ok({
    serial,
    channels,
    pre_skip,
    input_sample_rate,
    packets: [],
    durations: [],
  })
}

///|
fn ogg_mux_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push((v & 0xFF).to_byte())
  dst.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn ogg_mux_u32(dst : Array[Byte], v : UInt32) -> Unit {
  for i in 0..<4 {
    dst.push(((v >> (8 * i)) & 0xFFU).to_byte())
  }
}

///|
fn ogg_mux_u64(dst : Array[Byte], v : Int64) -> Unit {
  for i in 0..<8 {
    dst.push(((v >> (8 * i)) & 0xFFL).to_int().to_byte())
  }
}

///|
fn ogg_mux_crc(page : Array[Byte]) -> UInt32 {
  let mut crc = 0U
  for i, b in page {
    let v = if i >= 22 && i < 26 { 0 } else { b.to_int() }
    crc = crc ^ (v.reinterpret_as_uint() << 24)
    for _ in 0..<8 {
      crc = if (crc & 0x80000000U) != 0 {
        (crc << 1) ^ 0x04C11DB7U
      } else {
        crc << 1
      }
    }
  }
  crc
}

///|
fn ogg_mux_page(
  out : Array[Byte],
  serial : Int32,
  seq : Int32,
  header_type : Int32,
  granule : Int64,
  packet : Bytes,
) -> Unit {
  let lacing : Array[Int32] = []
  let mut rem = packet.length()
  while rem >= 255 {
    lacing.push(255)
    rem = rem - 255
  }
  lacing.push(rem)
  let page : Array[Byte] = []
  page.push(b'O')
  page.push(b'g')
  page.push(b'g')
  page.push(b'S')
  page.push(b'\x00')
  page.push(header_type.to_byte())
  ogg_mux_u64(page, granule)
  ogg_mux_u32(page, serial.reinterpret_as_uint())
  ogg_mux_u32(page, seq.reinterpret_as_uint())
  ogg_mux_u32(page, 0U) // CRC placeholder
  page.push(lacing.length().to_byte())
  for lace in lacing {
    page.push(lace.to_byte())
  }
  for b in packet {
    page.push(b)
  }
  let crc = ogg_mux_crc(page)
  page[22] = (crc & 0xFFU).to_byte()
  page[23] = ((crc >> 8) & 0xFFU).to_byte()
  page[24] = ((crc >> 16) & 0xFFU).to_byte()
  page[25] = ((crc >> 24) & 0xFFU).to_byte()
  out.append(page)
}

///|
fn OggOpusMuxer::opus_head(self : OggOpusMuxer) -> Bytes {
  let head : Array[Byte] = []
  for b in b"OpusHead" {
    head.push(b)
  }
  head.push(b'\x01')
  head.push(self.channels.to_byte())
  ogg_mux_u16(head, self.pre_skip)
  ogg_mux_u32(head, self.input_sample_rate.reinterpret_as_uint())
  ogg_mux_u16(head, 0) // output gain
  head.push(b'\x00') // mapping family 0
  Bytes::from_array(head)
}

///|
fn ogg_mux_opus_tags() -> Bytes {
  let tags : Array[Byte] = []
  for b in b"OpusTags" {
    tags.push(b)
  }
  ogg_mux_u32(tags, 7U) // vendor string length
  for b in b"moonbit" {
    tags.push(b)
  }
  ogg_mux_u32(tags, 0U) // user comment count
  Bytes::from_array(tags)
}

///|
/// Append one valid Opus packet. Its duration is parsed from the TOC so the
/// Ogg granule positions stay consistent.
pub fn OggOpusMuxer::write_packet(
  self : OggOpusMuxer,
  packet : Bytes,
) -> Result[Unit, String] {
  if packet.length() < 1 || packet.length() > 65024 {
    return Err("EINVAL: Opus packet size out of Ogg range")
  }
  let parsed = match @libavcodec.opus_parse_packet(packet) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  self.packets.push(packet)
  self.durations.push(parsed.total_samples())
  Ok(())
}

///|
/// Serialize the stream. Header pages are emitted first, then one page per
/// packet; the final data page carries the EOS flag.
pub fn OggOpusMuxer::finish(self : OggOpusMuxer) -> Bytes {
  let out : Array[Byte] = []
  let mut seq = 0
  let head = self.opus_head()
  ogg_mux_page(out, self.serial, seq, 2, 0L, head)
  seq = seq + 1
  let tags = ogg_mux_opus_tags()
  ogg_mux_page(out, self.serial, seq, 0, 0L, tags)
  seq = seq + 1
  let mut granule = 0L
  for i in 0..<self.packets.length() {
    granule = granule + self.durations[i].to_int64()
    let header_type = if i == self.packets.length() - 1 { 4 } else { 0 }
    ogg_mux_page(out, self.serial, seq, header_type, granule, self.packets[i])
    seq = seq + 1
  }
  Bytes::from_array(out)
}
