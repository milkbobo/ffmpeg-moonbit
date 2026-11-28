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
  out.push(1) // Vorbis comment framing bit.
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
  seq = ogg_mux_packet_pages(out, self.serial, seq, 0L, comment, false)
  seq = ogg_mux_packet_pages(
    out,
    self.serial,
    seq,
    0L,
    self.setup_header,
    false,
  )
  let mut granule = 0L
  for i in 0..<self.packets.length() {
    granule = granule + self.durations[i].to_int64()
    seq = ogg_mux_packet_pages(
      out,
      self.serial,
      seq,
      granule,
      self.packets[i],
      i + 1 == self.packets.length(),
    )
  }
  Bytes::from_array(out)
}

///|
/// Encode normalized stereo PCM as Ogg Vorbis at the given sample rate.
pub fn av_ogg_encode_vorbis(
  samples : Array[Array[Double]],
  rate : Int32,
) -> Result[Bytes, String] {
  guard samples.length() == 2 && rate > 0 else {
    return Err("vorbis: expected stereo PCM with a positive sample rate")
  }
  let count = samples[0].length()
  guard count > 0 && samples[1].length() == count else {
    return Err("vorbis: expected two equal, nonempty PCM channels")
  }
  let encoder = match @libavcodec.vorbis_encoder_new(rate, 2) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard encoder.extradata() is Some(headers) else {
    return Err("vorbis: missing encoder headers")
  }
  let (id, comment, setup) = @libavcodec.vorbis_e2e_split_extradata(headers)
  let mux = match ogg_vorbis_muxer_new(id, comment, setup) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let block_size = encoder.initial_padding
  let count64 = count.to_int64()
  let block = block_size.to_int64()
  let input_blocks = (count - 1) / block_size + 1
  // The first packet primes the overlap. One extra block drains the tail.
  for i in 0..<=input_blocks {
    let start = i.to_int64() * block
    let queue = Array::makei(block_size / encoder.frame_size, frame => {
      Array::makei(encoder.frame_size * 2, j => {
        let pos = start + (frame * encoder.frame_size + j / 2).to_int64()
        if pos < count64 {
          samples[j % 2][pos.to_int()]
        } else {
          0.0
        }
      })
    })
    let packet = match encoder.encode(queue, 0, queue.length(), false) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let duration = if i == 0 {
      0
    } else {
      (start.min(count64) - (start - block)).to_int()
    }
    mux.write_packet(packet, duration)
  }
  Ok(mux.finish())
}

///|
/// Encode the decoded stereo track as Ogg Vorbis.
pub fn DecodedAudio::to_ogg_vorbis(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  match av_ogg_encode_vorbis(self.samples, self.sample_rate) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
