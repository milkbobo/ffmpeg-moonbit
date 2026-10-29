///|
/// Minimal audio-only Matroska writers: one `A_AAC` or one `A_FLAC` track and
/// a single Cluster of SimpleBlocks. Both share the EBML helpers used by the
/// H.264/HEVC writers; timestamps are non-negative milliseconds within one
/// cluster (remux callers shift codec-delay offsets to zero).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct MkvAudioEvent {
  pts_ms : Int64
  data : Bytes
  duration_ms : Int32
}

///|
fn mkv_audio_sorted(events : Array[MkvAudioEvent]) -> Array[MkvAudioEvent] {
  let out = events.copy()
  for i in 1..<out.length() {
    let item = out[i]
    let mut j = i
    while j > 0 && out[j - 1].pts_ms > item.pts_ms {
      out[j] = out[j - 1]
      j = j - 1
    }
    out[j] = item
  }
  out
}

///|
fn mkv_audio_cluster(events : Array[MkvAudioEvent]) -> Array[Byte] {
  let cluster : Array[Byte] = []
  webm_uint_elem(cluster, 0xE7, 1, 0UL)
  for e in mkv_audio_sorted(events) {
    let block : Array[Byte] = [
      b'\x81',
      ((e.pts_ms >> 8) & 0xFF).to_int().to_byte(),
      (e.pts_ms & 0xFF).to_int().to_byte(),
      b'\x80',
    ]
    for b in e.data {
      block.push(b)
    }
    webm_elem(cluster, 0xA3, 1, block)
  }
  cluster
}

///|
fn mkv_audio_document(
  codec_id : String,
  codec_private : Bytes,
  audio_body : Array[Byte],
  events : Array[MkvAudioEvent],
  codec_delay~ : UInt64 = 0UL,
) -> Bytes {
  let header_body : Array[Byte] = []
  webm_uint_elem(header_body, 0x4286, 2, 1UL)
  webm_uint_elem(header_body, 0x42F7, 2, 1UL)
  webm_uint_elem(header_body, 0x42F2, 2, 4UL)
  webm_uint_elem(header_body, 0x42F3, 2, 8UL)
  webm_string_elem(header_body, 0x4282, 2, "matroska")
  webm_uint_elem(header_body, 0x4287, 2, 4UL)
  webm_uint_elem(header_body, 0x4285, 2, 2UL)
  let ebml : Array[Byte] = []
  webm_elem(ebml, 0x1A45DFA3, 4, header_body)

  let info : Array[Byte] = []
  webm_uint_elem(info, 0x2AD7B1, 3, 1000000UL)
  webm_string_elem(info, 0x4D80, 2, "moonbit")
  webm_string_elem(info, 0x5741, 2, "moonbit")
  let mut duration = 0L
  for e in events {
    let end = e.pts_ms + e.duration_ms.to_int64()
    if end > duration {
      duration = end
    }
  }
  webm_float_elem(info, 0x4489, 2, duration.to_double())

  let track : Array[Byte] = []
  webm_uint_elem(track, 0xD7, 1, 1UL)
  webm_uint_elem(track, 0x73C5, 2, 1UL)
  webm_uint_elem(track, 0x83, 1, 2UL) // audio
  webm_string_elem(track, 0x86, 1, codec_id)
  if codec_private.length() > 0 {
    let private_body : Array[Byte] = []
    for b in codec_private {
      private_body.push(b)
    }
    webm_elem(track, 0x63A2, 2, private_body)
  }
  if codec_delay > 0UL {
    webm_uint_elem(track, 0x56AA, 2, codec_delay)
  }
  webm_elem(track, 0xE1, 1, audio_body)
  webm_elem(track, 0xEC, 1, [])

  let tracks : Array[Byte] = []
  webm_elem(tracks, 0xAE, 1, track)
  webm_elem(tracks, 0xEC, 1, [])

  let segment_body : Array[Byte] = []
  webm_elem(segment_body, 0x1549A966, 4, info)
  webm_elem(segment_body, 0x1654AE6B, 4, tracks)
  webm_elem(segment_body, 0x1F43B675, 4, mkv_audio_cluster(events))
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
/// One AAC-in-Matroska track. `asc` defaults to the AAC-LC
/// AudioSpecificConfig derived from the sample rate/channel count.
pub struct MkvAacMuxer {
  sample_rate : Int32
  channels : Int32
  asc : Bytes
  codec_delay : UInt64
  events : Array[MkvAudioEvent]
}

///|
pub fn mkv_aac_muxer_new(
  sample_rate : Int32,
  channels~ : Int32 = 2,
  asc~ : Bytes? = None,
  codec_delay_ns~ : UInt64 = 0UL,
) -> Result[MkvAacMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 7 {
    return Err("EINVAL: invalid MKV/AAC stream parameters")
  }
  let asc_bytes = match asc {
    Some(a) =>
      if a.length() < 2 {
        return Err("EINVAL: invalid AudioSpecificConfig")
      } else {
        a
      }
    None => Bytes::from_array(mp4_av_asc(sample_rate, channels))
  }
  Ok({
    sample_rate,
    channels,
    asc: asc_bytes,
    codec_delay: codec_delay_ns,
    events: [],
  })
}

///|
pub fn MkvAacMuxer::write_packet(
  self : MkvAacMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV/AAC packet")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
pub fn MkvAacMuxer::finish(self : MkvAacMuxer) -> Bytes {
  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, self.sample_rate.to_double())
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )
  mkv_audio_document(
    "A_AAC",
    self.asc,
    audio,
    self.events,
    codec_delay=self.codec_delay,
  )
}

///|
/// One FLAC-in-Matroska track. CodecPrivate is the native `fLaC` marker plus
/// STREAMINFO (and any extra metadata blocks); packets are FLAC frames.
pub struct MkvFlacMuxer {
  streaminfo : Bytes
  headers : Array[Bytes]
  sample_rate : Int32
  channels : Int32
  bits : Int32
  events : Array[MkvAudioEvent]
}

///|
pub fn mkv_flac_muxer_new(
  streaminfo : Bytes,
  headers~ : Array[Bytes] = [],
) -> Result[MkvFlacMuxer, String] {
  if streaminfo.length() != 34 {
    return Err("EINVAL: invalid FLAC STREAMINFO")
  }
  let sample_rate = ogg_flac_bits(streaminfo, 80, 20).to_int()
  let channels = ogg_flac_bits(streaminfo, 100, 3).to_int() + 1
  let bits = ogg_flac_bits(streaminfo, 103, 5).to_int() + 1
  if sample_rate <= 0 {
    return Err("EINVAL: invalid FLAC sample rate")
  }
  for block in headers {
    if block.length() < 4 {
      return Err("EINVAL: invalid FLAC metadata block")
    }
  }
  Ok({ streaminfo, headers, sample_rate, channels, bits, events: [], })
}

///|
pub fn MkvFlacMuxer::write_packet(
  self : MkvFlacMuxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() < 6 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV/FLAC frame")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
fn MkvFlacMuxer::codec_private(self : MkvFlacMuxer) -> Bytes {
  let out : Array[Byte] = []
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
  for block in self.headers {
    for b in block {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
pub fn MkvFlacMuxer::finish(self : MkvFlacMuxer) -> Bytes {
  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, self.sample_rate.to_double())
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )
  webm_uint_elem(audio, 0x6264, 2, self.bits.reinterpret_as_uint().to_uint64())
  mkv_audio_document("A_FLAC", self.codec_private(), audio, self.events)
}

///|
/// One AC-3 or E-AC-3 track in Matroska (`A_AC3` / `A_EAC3`).  The codec
/// state is fully in-band, so no CodecPrivate is written.
pub struct MkvAc3Muxer {
  codec_id : String
  sample_rate : Int32
  channels : Int32
  events : Array[MkvAudioEvent]
}

///|
pub fn mkv_ac3_muxer_new(
  sample_rate : Int32,
  channels : Int32,
) -> Result[MkvAc3Muxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 6 {
    return Err("EINVAL: invalid MKV/AC-3 stream parameters")
  }
  Ok({ codec_id: "A_AC3", sample_rate, channels, events: [], })
}

///|
pub fn mkv_eac3_muxer_new(
  sample_rate : Int32,
  channels : Int32,
) -> Result[MkvAc3Muxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 6 {
    return Err("EINVAL: invalid MKV/E-AC-3 stream parameters")
  }
  Ok({ codec_id: "A_EAC3", sample_rate, channels, events: [], })
}

///|
/// One MP3 track in Matroska (`A_MPEG/L3`).  MP3 frames are self-describing,
/// so no CodecPrivate is written.
pub fn mkv_mp3_muxer_new(
  sample_rate : Int32,
  channels : Int32,
) -> Result[MkvAc3Muxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 2 {
    return Err("EINVAL: invalid MKV/MP3 stream parameters")
  }
  Ok({ codec_id: "A_MPEG/L3", sample_rate, channels, events: [], })
}

///|
pub fn MkvAc3Muxer::write_packet(
  self : MkvAc3Muxer,
  packet : Bytes,
  pts_ms : Int64,
  duration_ms : Int32,
) -> Result[Unit, String] {
  if packet.length() < 2 || duration_ms <= 0 || pts_ms < 0L {
    return Err("EINVAL: invalid MKV/AC-3 packet")
  }
  self.events.push({ pts_ms, data: packet, duration_ms, })
  Ok(())
}

///|
pub fn MkvAc3Muxer::finish(self : MkvAc3Muxer) -> Bytes {
  let audio : Array[Byte] = []
  webm_float_elem(audio, 0xB5, 1, self.sample_rate.to_double())
  webm_uint_elem(
    audio,
    0x9F,
    1,
    self.channels.reinterpret_as_uint().to_uint64(),
  )
  mkv_audio_document(self.codec_id, b"", audio, self.events)
}
