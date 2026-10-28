///|
/// Ogg FLAC (RFC 5334 mapping) demuxer and minimal writer.
///
/// The demuxer validates the mapping header, separates metadata blocks from
/// audio packets and assembles a native `fLaC` stream that the FLAC decoder
/// consumes directly. The writer emits the mapping headers and puts every
/// audio frame on one page whose granule is the STREAMINFO sample count.
///
/// Scope: a single FLAC logical stream; chained/multiplexed streams are
/// rejected.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct OggFlacFrame {
  data : Bytes
  granule : Int64
  pos : Int64
}

///|
pub struct OggFlacDemux {
  serial : Int32
  sample_rate : Int32
  channels : Int32
  bits : Int32
  total_samples : Int64
  /// 34-byte STREAMINFO payload.
  streaminfo : Bytes
  /// Metadata block packets following STREAMINFO (raw block bytes).
  headers : Array[Bytes]
  frames : Array[OggFlacFrame]
  /// Assembled native FLAC file (`fLaC` + metadata + frames).
  stream : Bytes
}

///|
/// Read `n` bits (MSB first) from the STREAMINFO payload.
fn ogg_flac_bits(info : Bytes, off : Int32, n : Int32) -> Int64 {
  let mut v : Int64 = 0L
  for k = 0; k < n; k = k + 1 {
    let bit = off + k
    let byte = info[bit >> 3].to_int()
    v = (v << 1) | ((byte >> (7 - (bit & 7))) & 1).to_int64()
  }
  v
}

///|
pub fn av_ogg_flac_open(data : Bytes) -> Result[OggFlacDemux, String] {
  if data.length() < 27 || data[0:4].to_owned() != b"OggS" {
    return Err("ogg: missing Ogg capture pattern")
  }
  let mut pos = 0
  let mut serial = 0
  let mut have_stream = false
  let mut got_first = false
  let mut num_headers = 0
  let mut headers_seen = 0
  let mut streaminfo = b""
  let mut sample_rate = 0
  let mut channels = 0
  let mut bits = 0
  let mut total_samples = 0L
  let mut first_stream : Bytes = b""
  let mut pending : Array[Byte] = []
  let headers : Array[Bytes] = []
  let frames : Array[OggFlacFrame] = []
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
    for i in 0..<nseg {
      let lace = data[pos + 27 + i].to_int()
      for j in 0..<lace {
        pending.push(data[p + j])
      }
      p = p + lace
      if lace < 255 {
        let packet = Bytes::from_array(pending)
        pending = []
        if !got_first {
          if packet.length() < 51 ||
            packet[0].to_int() != 0x7F ||
            packet[1:5].to_owned() != b"FLAC" ||
            packet[5].to_int() != 1 ||
            packet[6].to_int() != 0 ||
            packet[9:13].to_owned() != b"fLaC" ||
            (packet[13].to_int() & 0x7F) != 0 ||
            (
              (packet[14].to_int() << 16) |
              (packet[15].to_int() << 8) |
              packet[16].to_int()
            ) !=
            34 {
            return Err("ogg: first packet is not an Ogg FLAC mapping header")
          }
          num_headers = (packet[7].to_int() << 8) | packet[8].to_int()
          streaminfo = packet[17:51].to_owned()
          sample_rate = ogg_flac_bits(streaminfo, 80, 20).to_int()
          channels = ogg_flac_bits(streaminfo, 100, 3).to_int() + 1
          bits = ogg_flac_bits(streaminfo, 103, 5).to_int() + 1
          total_samples = ogg_flac_bits(streaminfo, 108, 36)
          // `fLaC` + STREAMINFO block as stored in the first packet.
          first_stream = packet[9:51].to_owned()
          got_first = true
        } else if headers_seen < num_headers {
          headers.push(packet)
          headers_seen = headers_seen + 1
        } else {
          frames.push({ data: packet, granule, pos: page_pos, })
        }
      }
    }
    pos = page_end
  }
  if !got_first {
    return Err("ogg: no Ogg FLAC mapping header")
  }
  if headers_seen != num_headers {
    return Err("ogg: missing Ogg FLAC header packets")
  }
  // STREAMINFO may carry 0 ("unknown") for streamed encodes; the last page
  // granule is the authoritative sample count then.
  if total_samples == 0L && frames.length() > 0 {
    total_samples = frames[frames.length() - 1].granule
  }
  let joined : Array[Byte] = []
  for b in first_stream {
    joined.push(b)
  }
  for block in headers {
    for b in block {
      joined.push(b)
    }
  }
  for frame in frames {
    for b in frame.data {
      joined.push(b)
    }
  }
  Ok({
    serial,
    sample_rate,
    channels,
    bits,
    total_samples,
    streaminfo,
    headers,
    frames,
    stream: Bytes::from_array(joined),
  })
}

///|
pub struct OggFlacMuxer {
  serial : Int32
  streaminfo : Bytes
  headers : Array[Bytes]
  total_samples : Int64
  frames : Array[Bytes]
}

///|
fn ogg_flac_laces(packets : Array[Bytes]) -> Int32 {
  let mut n = 0
  for packet in packets {
    n = n + packet.length() / 255 + 1
  }
  n
}

///|
pub fn ogg_flac_muxer_new(
  streaminfo : Bytes,
  headers : Array[Bytes],
  total_samples : Int64,
  serial~ : Int32 = 0x464C4143,
) -> Result[OggFlacMuxer, String] {
  if streaminfo.length() != 34 || total_samples < 0L {
    return Err("EINVAL: invalid Ogg/FLAC stream parameters")
  }
  for block in headers {
    if block.length() < 4 {
      return Err("EINVAL: invalid Ogg/FLAC metadata block")
    }
  }
  if ogg_flac_laces(headers) > 255 {
    return Err("EINVAL: Ogg/FLAC metadata page needs too many segments")
  }
  Ok({ serial, streaminfo, headers, total_samples, frames: [], })
}

///|
pub fn OggFlacMuxer::write_packet(
  self : OggFlacMuxer,
  packet : Bytes,
) -> Result[Unit, String] {
  if packet.length() < 6 || packet.length() > 65024 {
    return Err("EINVAL: FLAC frame size out of Ogg range")
  }
  self.frames.push(packet)
  if ogg_flac_laces(self.frames) > 255 {
    let _ = self.frames.pop()
    return Err("EINVAL: Ogg/FLAC audio page needs too many segments")
  }
  Ok(())
}

///|
fn OggFlacMuxer::mapping_header(self : OggFlacMuxer) -> Bytes {
  let out : Array[Byte] = [b'\x7F']
  for b in b"FLAC" {
    out.push(b)
  }
  out.push(b'\x01') // mapping version major
  out.push(b'\x00') // mapping version minor
  // The mapping header count is big-endian (unlike the Ogg page fields).
  out.push(((self.headers.length() >> 8) & 0xFF).to_byte())
  out.push((self.headers.length() & 0xFF).to_byte())
  for b in b"fLaC" {
    out.push(b)
  }
  out.push(if self.headers.length() == 0 { b'\x80' } else { b'\x00' })
  out.push(b'\x00')
  out.push(b'\x00')
  out.push(b'\x22')
  for b in self.streaminfo {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
pub fn OggFlacMuxer::finish(self : OggFlacMuxer) -> Bytes {
  let out : Array[Byte] = []
  let mut seq = 0
  ogg_mux_page_multi(out, self.serial, seq, 2, 0L, [self.mapping_header()])
  seq = seq + 1
  if self.headers.length() > 0 {
    let eos = if self.frames.length() == 0 { 4 } else { 0 }
    ogg_mux_page_multi(out, self.serial, seq, eos, 0L, self.headers)
    seq = seq + 1
  }
  if self.frames.length() > 0 {
    ogg_mux_page_multi(
      out,
      self.serial,
      seq,
      4,
      self.total_samples,
      self.frames,
    )
  }
  Bytes::from_array(out)
}
