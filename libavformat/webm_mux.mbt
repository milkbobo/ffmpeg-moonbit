///|
/// Audio-only WebM and Matroska writer for one A_OPUS track.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct WebmOpusMuxer {
  channels : Int32
  pre_skip : Int32
  input_sample_rate : Int32
  doctype : String
  language : String
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn webm_opus_muxer_new(
  channels~ : Int32 = 2,
  pre_skip~ : Int32 = 0,
  input_sample_rate~ : Int32 = 48000,
  doctype~ : String = "webm",
  language~ : String = "und",
) -> Result[WebmOpusMuxer, String] {
  if channels < 1 ||
    channels > 2 ||
    pre_skip < 0 ||
    pre_skip > 65535 ||
    input_sample_rate <= 0 {
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
    language: if language == "" {
      "und"
    } else {
      language
    },
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
    ((v >> (8 * (len - 1))) & ((1L << payload_bits) - 1L)).to_int()
  dst.push(first.to_byte())
  for i in 1..<len {
    dst.push(((v >> (8 * (len - 1 - i))) & 0xFFL).to_int().to_byte())
  }
}

///|
fn webm_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  body : Array[Byte],
) -> Unit {
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
fn webm_uint_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  value : UInt64,
) -> Unit {
  webm_elem(dst, id, id_len, webm_uint_body(value))
}

///|
fn webm_string_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  text : String,
) -> Unit {
  let body : Array[Byte] = []
  for c in text {
    body.push(c.to_int().to_byte())
  }
  webm_elem(dst, id, id_len, body)
}

///|
fn webm_float_elem(
  dst : Array[Byte],
  id : UInt32,
  id_len : Int32,
  value : Double,
) -> Unit {
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
pub fn WebmOpusMuxer::finish(self : WebmOpusMuxer) -> Bytes {
  self.serialize()
}

///|
fn WebmOpusMuxer::serialize(
  self : WebmOpusMuxer,
  valid_frames? : Int64,
) -> Bytes {
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
  let priming = self.pre_skip.to_int64()
  // The packet muxer accepts a timeline starting at presentation time zero.
  // PCM export starts at -pre_skip, so its first block is stored at zero.
  let offset_ms = if valid_frames is Some(_) {
    0L
  } else {
    @libavutil.av_rescale(priming, 1000L, 48000L)
  }
  let events : Array[MkvAudioEvent] = []
  let mut total = 0L
  for i, packet in self.packets {
    let start_ms = total / 48L
    total += self.durations[i].to_int64()
    events.push({
      pts_ms: start_ms + offset_ms,
      data: packet,
      duration_ms: (total / 48L - start_ms).to_int(),
    })
    if valid_frames is Some(frames) && total >= frames + priming {
      break
    }
  }
  let duration_ms = valid_frames.unwrap_or(total).to_double() / 48.0
  let discard_padding = match valid_frames {
    Some(frames) =>
      @libavutil.av_rescale(total - priming - frames, 1000000000L, 48000L)
    None => 0L
  }
  webm_float_elem(info, 0x4489, 2, duration_ms)

  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, 48000.0)
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL) // TrackNumber
  webm_uint_elem(track, 0x73C5, 2, 1UL) // TrackUID
  webm_uint_elem(track, 0x83, 1, 2UL) // TrackType audio
  webm_string_elem(track, 0x22B59C, 3, self.language)
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
    let delay_ns = @libavutil.av_rescale(priming, 1000000000L, 48000L)
    webm_uint_elem(track, 0x56AA, 2, delay_ns.reinterpret_as_uint64())
  }
  webm_uint_elem(track, 0x56BB, 2, 80000000UL) // SeekPreRoll (80 ms)
  webm_elem(track, 0xE1, 1, audio)
  webm_elem(track, 0xEC, 1, []) // Void keeps nested levels from ending together

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
  webm_elem(tracks, 0xEC, 1, [])
  let info_elem : Array[Byte] = []
  webm_elem(info_elem, 0x1549A966, 4, info)
  let tracks_elem : Array[Byte] = []
  webm_elem(tracks_elem, 0x1654AE6B, 4, tracks)
  let clusters : Array[Byte] = []
  mkv_audio_clusters(clusters, events, discard_padding)
  let empty_times : Array[Int64] = []
  let (seekhead, cues) = mkv_seekhead_cues(
    info_elem, tracks_elem, clusters, empty_times,
  )
  let segment_body : Array[Byte] = []
  for part in [seekhead, info_elem, tracks_elem, clusters, cues] {
    for b in part {
      segment_body.push(b)
    }
  }
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

///|
/// Encode mono or stereo PCM as 48 kHz Opus in WebM or Matroska.
/// Set `doctype="matroska"` for an audio-only Matroska file.
pub fn DecodedAudio::to_webm_opus(
  self : DecodedAudio,
  doctype~ : String = "webm",
) -> Bytes raise MediaError {
  let (packets, priming, count) = self.encode_opus(separate_trims=true)
  let mux = match
    webm_opus_muxer_new(
      channels=self.channels,
      pre_skip=priming,
      input_sample_rate=self.sample_rate,
      doctype~,
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  for packet in packets {
    if mux.write_packet(packet) is Err(error) {
      raise DecodeError(error)
    }
  }
  mux.serialize(valid_frames=count.to_int64())
}
