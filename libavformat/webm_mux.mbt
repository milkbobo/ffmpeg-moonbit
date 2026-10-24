///|
/// Minimal WebM/Opus writer: EBML header, Segment Info, one A_OPUS track and
/// a single Cluster of SimpleBlocks.  Sizes use the fixed 8-byte EBML VINT so
/// the document can be assembled in one pass.  The EBML DocType defaults to
/// "webm" and can be switched to "matroska" for standalone .mkv output (same
/// CodecID and OpusHead private data).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct WebmOpusMuxer {
  channels : Int32
  pre_skip : Int32
  input_sample_rate : Int32
  doctype : String
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn webm_opus_muxer_new(
  channels? : Int32 = 2,
  pre_skip? : Int32 = 0,
  input_sample_rate? : Int32 = 48000,
  doctype? : String = "webm",
) -> Result[WebmOpusMuxer, String] {
  if channels < 1 || channels > 2 || pre_skip < 0 || input_sample_rate <= 0 {
    return Err("EINVAL: invalid WebM/Opus stream parameters")
  }
  if doctype != "webm" && doctype != "matroska" {
    return Err("EINVAL: DocType must be webm or matroska")
  }
  Ok({
    channels,
    pre_skip,
    input_sample_rate,
    doctype,
    packets: [],
    durations: [],
  })
}

///|
pub fn WebmOpusMuxer::write_packet(
  self : WebmOpusMuxer,
  packet : Bytes,
) -> Result[Unit, String] {
  if packet.length() == 0 {
    return Err("EINVAL: empty Opus packet")
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
fn webm_id(dst : Array[Byte], id : UInt32, len : Int32) -> Unit {
  for i in 0..<len {
    dst.push(((id >> (8 * (len - 1 - i))) & 0xFFU).to_byte())
  }
}

///|
fn webm_size(dst : Array[Byte], size : Int32) -> Unit {
  let v = size.to_int64()
  let mut len = 1
  while len < 8 && v >= (1L << (7 * len)) - 1L {
    len = len + 1
  }
  let payload_bits = 8 - len
  let first = (1 << (8 - len)) |
    (((v >> (8 * (len - 1))) & ((1L << payload_bits) - 1L)).to_int())
  dst.push(first.to_byte())
  for i in 1..<len {
    dst.push(((v >> (8 * (len - 1 - i))) & 0xFFL).to_int().to_byte())
  }
}

///|
fn webm_elem(dst : Array[Byte], id : UInt32, id_len : Int32, body : Array[Byte]) -> Unit {
  webm_id(dst, id, id_len)
  webm_size(dst, body.length())
  dst.append(body)
}

///|
fn webm_uint_body(value : UInt64) -> Array[Byte] {
  let body : Array[Byte] = []
  let mut started = false
  for i in 0..<8 {
    let b = ((value >> (8 * (7 - i))) & 0xFFUL).to_int()
    if b != 0 || started || i == 7 {
      body.push(b.to_byte())
      started = true
    }
  }
  body
}

///|
fn webm_uint_elem(dst : Array[Byte], id : UInt32, id_len : Int32, value : UInt64) -> Unit {
  webm_elem(dst, id, id_len, webm_uint_body(value))
}

///|
fn webm_string_elem(dst : Array[Byte], id : UInt32, id_len : Int32, text : String) -> Unit {
  let body : Array[Byte] = []
  for c in text {
    body.push(c.to_int().to_byte())
  }
  webm_elem(dst, id, id_len, body)
}

///|
fn webm_float_elem(dst : Array[Byte], id : UInt32, id_len : Int32, value : Double) -> Unit {
  let bits = value.reinterpret_as_int64()
  let body : Array[Byte] = []
  for i in 0..<8 {
    body.push(((bits >> (8 * (7 - i))) & 0xFFL).to_int().to_byte())
  }
  webm_elem(dst, id, id_len, body)
}

///|
fn WebmOpusMuxer::opus_head(self : WebmOpusMuxer) -> Bytes {
  let head : Array[Byte] = []
  for b in b"OpusHead" {
    head.push(b)
  }
  head.push(b'\x01')
  head.push(self.channels.to_byte())
  head.push((self.pre_skip & 0xFF).to_byte())
  head.push(((self.pre_skip >> 8) & 0xFF).to_byte())
  for i in 0..<4 {
    head.push(((self.input_sample_rate >> (8 * i)) & 0xFF).to_byte())
  }
  head.push(b'\x00')
  head.push(b'\x00') // output gain
  head.push(b'\x00') // mapping family 0
  Bytes::from_array(head)
}

///|
fn WebmOpusMuxer::cluster(self : WebmOpusMuxer) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL) // Timecode 0
  // FFmpeg `matroskaenc.c` shifts block timestamps by `ts_offset` (the
  // pre-skip rescaled to the 1 ms track timebase, rounded half away from
  // zero) so that the demuxer's `- codec_delay` restores the original
  // timestamps.  With no pre-skip the offset is 0.
  let ts_offset = (self.pre_skip.to_int64() * 1000L + 24000L) / 48000L
  let mut samples = 0
  for i in 0..<self.packets.length() {
    let packet = self.packets[i]
    let ms = samples * 1000 / 48000 + ts_offset.to_int()
    let block : Array[Byte] = [
      b'\x81', ((ms >> 8) & 0xFF).to_byte(), (ms & 0xFF).to_byte(), b'\x80',
    ]
    for b in packet {
      block.push(b)
    }
    webm_elem(cluster, 0xA3, 1, block)
    samples = samples + self.durations[i]
  }
  cluster
}

///|
pub fn WebmOpusMuxer::finish(self : WebmOpusMuxer) -> Bytes {
  let header_body : Array[Byte] = []
  webm_uint_elem(header_body, 0x4286, 2, 1UL) // EBMLVersion
  webm_uint_elem(header_body, 0x42F7, 2, 1UL) // EBMLReadVersion
  webm_uint_elem(header_body, 0x42F2, 2, 4UL) // EBMLMaxIDLength
  webm_uint_elem(header_body, 0x42F3, 2, 8UL) // EBMLMaxSizeLength
  webm_string_elem(header_body, 0x4282, 2, self.doctype)
  webm_uint_elem(header_body, 0x4287, 2, 4UL) // DocTypeVersion
  webm_uint_elem(header_body, 0x4285, 2, 2UL) // DocTypeReadVersion
  let ebml : Array[Byte] = []
  webm_elem(ebml, 0x1A45DFA3, 4, header_body)

  let info : Array[Byte] = []
  webm_uint_elem(info, 0x2AD7B1, 3, 1000000UL) // TimecodeScale
  webm_string_elem(info, 0x4D80, 2, "moonbit")
  webm_string_elem(info, 0x5741, 2, "moonbit")
  let mut total = 0
  for d in self.durations {
    total = total + d
  }
  let duration_ms = total.to_double() * 1000.0 / 48000.0
  webm_float_elem(info, 0x4489, 2, duration_ms)

  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, 48000.0)
  webm_uint_elem(audio, 0x9F, 1, self.channels.reinterpret_as_uint().to_uint64())

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL) // TrackNumber
  webm_uint_elem(track, 0x73C5, 2, 1UL) // TrackUID
  webm_uint_elem(track, 0x83, 1, 2UL) // TrackType audio
  webm_string_elem(track, 0x86, 1, "A_OPUS")
  let head_body : Array[Byte] = []
  for b in self.opus_head() {
    head_body.push(b)
  }
  webm_elem(track, 0x63A2, 2, head_body)
  if self.pre_skip > 0 {
    // CodecDelay in ns, as FFmpeg `matroskaenc.c` derives it from the Opus
    // pre-skip at the fixed 48 kHz rate; the demuxer turns it back into
    // initial_padding/skip_samples.
    let delay_ns = self.pre_skip.to_int64() * 1000000000L / 48000L
    webm_uint_elem(track, 0x56AA, 2, delay_ns.reinterpret_as_uint64())
  }
  webm_uint_elem(track, 0x56BB, 2, 80000000UL) // SeekPreRoll (80 ms)
  webm_elem(track, 0xE1, 1, audio)
  webm_elem(track, 0xEC, 1, []) // Void keeps nested levels from ending together

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
  webm_elem(tracks, 0xEC, 1, [])
  let cluster = self.cluster()
  let segment_body : Array[Byte] = []
  webm_elem(segment_body, 0x1549A966, 4, info)
  webm_elem(segment_body, 0x1654AE6B, 4, tracks)
  webm_elem(segment_body, 0x1F43B675, 4, cluster)
  let segment : Array[Byte] = []
  webm_elem(segment, 0x18538067, 4, segment_body)
  let out : Array[Byte] = []
  for b in ebml {
    out.push(b)
  }
  for b in segment {
    out.push(b)
  }
  Bytes::from_array(out)
}
