///|
/// In-memory Ogg/Vorbis writer: emits the identification, comment and setup
/// header pages (BOS on the first), then one Ogg page per audio packet with
/// granule positions in absolute PCM samples, EOS on the final page.  The
/// output is the same framing consumed by `av_ogg_vorbis_open`, so an
/// encode -> mux -> demux -> decode round trip stays inside the repository.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
pub struct OggVorbisMuxer {
  serial : Int32
  id_header : Bytes
  comment_header : Bytes
  setup_header : Bytes
  packets : Array[Bytes]
  /// Samples produced by each packet (blocksize/2 per long block here).
  durations : Array[Int32]
  tags : Array[(String, String)]
}

///|
/// Build a Vorbis muxer from the encoder's three headers.  `tags` feed the
/// comment header (a fresh vendor string is written).
pub fn ogg_vorbis_muxer_new(
  id_header : Bytes,
  comment_header : Bytes,
  setup_header : Bytes,
  serial~ : Int32 = 0x5147212,
  tags~ : Array[(String, String)] = [],
) -> Result[OggVorbisMuxer, String] {
  if id_header.length() < 28 || id_header[0].to_int() != 1 {
    return Err("EINVAL: not a Vorbis identification header")
  }
  if comment_header.length() < 16 || comment_header[0].to_int() != 3 {
    return Err("EINVAL: not a Vorbis comment header")
  }
  if setup_header.length() < 8 || setup_header[0].to_int() != 5 {
    return Err("EINVAL: not a Vorbis setup header")
  }
  Ok({
    serial,
    id_header,
    comment_header,
    setup_header,
    packets: [],
    durations: [],
    tags,
  })
}

///|
fn ogg_vorbis_mux_comment(comments : Array[(String, String)]) -> Bytes {
  let out : Array[Byte] = []
  for b in b"\x03vorbis" {
    out.push(b)
  }
  for b in vorbis_comment_body("moonbit", comments) {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Append one audio packet; `samples` is the number of PCM samples the
/// packet decodes to (blocksize/2 for the long-block encoder here).
pub fn OggVorbisMuxer::write_packet(
  self : OggVorbisMuxer,
  packet : Bytes,
  samples : Int32,
) -> Unit {
  self.packets.push(packet)
  self.durations.push(samples)
}

///|
/// Serialize the stream: three header pages (BOS flag on the first), then
/// one page per audio packet with a running granule; the last data page
/// carries EOS.
pub fn OggVorbisMuxer::finish(self : OggVorbisMuxer) -> Bytes {
  let out : Array[Byte] = []
  let mut seq = 0
  ogg_mux_page(out, self.serial, seq, 2, 0L, self.id_header)
  seq = seq + 1
  let comment = ogg_vorbis_mux_comment(self.tags)
  ogg_mux_page(out, self.serial, seq, 0, 0L, comment)
  seq = seq + 1
  ogg_mux_page(out, self.serial, seq, 0, 0L, self.setup_header)
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
