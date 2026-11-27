///|
/// MPEG-TS adapter for the unified playback API: builds on the ported
/// `av_mpegts_open` demuxer (PES-level packets, 90 kHz timestamps). Video
/// payloads are Annex B NAL streams. ADTS, LATM, Dolby and MPEG audio
/// are indexed across PES boundaries.

///|
pub struct TsAudioPes {
  packets : Array[MediaPacket]
  mut end_pts : Int64
}

///|
/// Build the 2-byte AudioSpecificConfig from an ADTS header's raw fields:
/// 5-bit audio object type, 4-bit sampling frequency index, 4-bit channel
/// configuration, then the three zero GASpecificConfig bits.
pub fn ts_adts_to_asc(
  object_type : Int32,
  sampling_index : Int32,
  chan_config : Int32,
) -> Bytes {
  let v = ((object_type & 0x1F) << 11) |
    ((sampling_index & 0xF) << 7) |
    ((chan_config & 0xF) << 3)
  Bytes::from_array([(v >> 8).to_byte(), (v & 0xFF).to_byte()])
}

///|
/// True when an Annex B access unit holds an IDR slice (nal_unit_type 5) -
/// what the C's h264 parser turns into AV_PKT_FLAG_KEY, since the TS layer
/// itself does not mark keyframes. Every NAL is inspected: an IDR normally
/// follows an AUD, SPS, PPS or SEI inside the PES. (The parser also keys on
/// recovery-point SEIs, which open-GOP streams rely on; that case is not
/// covered here.)
fn ts_h264_is_idr(payload : Bytes) -> Bool {
  let n = payload.length()
  let mut i = 0
  while i + 3 < n {
    if payload[i].to_int() == 0 &&
      payload[i + 1].to_int() == 0 &&
      payload[i + 2].to_int() == 1 {
      if (payload[i + 3].to_int() & 0x1F) == 5 {
        return true
      }
      i = i + 3
    } else {
      i = i + 1
    }
  }
  false
}

///|
/// Open the TS demuxer and build the stream table and audio frame index.
fn playback_ts_build(data : Bytes) -> MediaFile raise MediaError {
  let demux = match av_mpegts_open(data) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let streams : Array[StreamInfo] = []
  let audio_frames : Map[Int32, TsAudioPes] = Map([])
  for i = 0; i < demux.streams.length(); i = i + 1 {
    let t = demux.streams[i]
    let mut mt = if t.codec_type == "video" {
      MediaType::Video
    } else if t.codec_type == "audio" {
      MediaType::Audio
    } else {
      MediaType::Subtitle
    }
    let mut rate = 0
    let mut ch = 0
    let mut extradata : Bytes? = None
    let mut codec = t.codec
    if mt == MediaType::Video && t.codec == "h264" {
      // TS carries no avcC: hand the first PES (an IDR with the SPS/PPS
      // NALs in front) to ff_h264_decode_extradata as Annex B data - the
      // same path the C uses when the extradata is not length-prefixed.
      for p in demux.packets {
        if p.stream_index == i {
          extradata = Some(p.payload)
          break
        }
      }
    }
    if t.codec == "pcm_bluray" || t.codec == "s302m" {
      for p in demux.packets {
        if p.stream_index == i &&
          ts_pcm_packet_params(t.codec, p.payload)
          is Some((sample_rate, channels, _)) {
          rate = sample_rate
          ch = channels
          break
        }
      }
    }
    if t.codec == "aac" {
      let (asc, sample_rate, channels) = playback_ts_index_adts(demux, i, audio_frames)
      rate = sample_rate
      ch = channels
      extradata = Some(asc)
    } else if t.codec == "aac_latm" {
      let (config, asc) = playback_ts_index_latm(demux, i, audio_frames)
      rate = config.sample_rate
      ch = config.channels
      extradata = Some(asc)
    } else if t.codec == "opus" &&
      t.opus_channel_config is Some(code) &&
      ts_opus_head(code) is Some(head) {
      playback_ts_index_opus(demux, i, head, audio_frames)
      rate = 48000
      ch = head[9].to_int()
      extradata = Some(head)
    } else if ts_uses_audio_index(t.codec) {
      let track = playback_ts_index_raw_audio(demux, i, audio_frames, t.codec)
      rate = track.sample_rate
      ch = track.channels
      codec = track.codec
    } else if t.codec == "truehd" &&
      playback_ts_index_truehd(demux, i, audio_frames)
      is Some((sample_rate, channels)) {
      rate = sample_rate
      ch = channels
    } else if (t.codec == "dts" || (t.codec == "" && t.stream_type == 0x82)) &&
      playback_ts_index_dts(demux, i, audio_frames) is Some(track) {
      // FFmpeg also writes type 0x82 in plain TS without HDMV registration.
      // Require actual core frames before interpreting the private type.
      mt = MediaType::Audio
      codec = "dts"
      rate = track.sample_rate
      ch = track.channels
    }
    streams.push({
      index: i,
      media_type: mt,
      codec_id: codec,
      sample_rate: rate,
      channels: ch,
      width: 0,
      height: 0,
      extradata,
    })
  }
  {
    format_name: "mpegts",
    streams,
    source: Ts(demux, audio_frames),
    cursor: [0],
  }
}

///|
/// Parameters carried in a PCM PES rather than in its PMT descriptor.
fn ts_pcm_packet_params(
  codec : String,
  payload : Bytes,
) -> (Int32, Int32, Int32)? {
  match codec {
    "pcm_bluray" =>
      match @libavcodec.parse_bluray_lpcm_header(payload) {
        Ok(h) if h.payload_bytes == payload.length() - 4 =>
          Some((h.sample_rate, h.channels, h.samples))
        _ => None
      }
    "s302m" =>
      match @libavcodec.parse_s302m_header(payload) {
        Ok(h) => Some((h.sample_rate, h.channels, h.samples))
        Err(_) => None
      }
    _ => None
  }
}

///|
/// TS packet walk: emit indexed audio frames and PES-level video packets.
fn MediaFile::playback_ts_next(
  self : MediaFile,
  demux : TsDemux,
  audio_frames : Map[Int32, TsAudioPes],
) -> MediaPacket? raise MediaError {
  // cursor[1]: the next indexed audio frame completed by the current PES.
  // cursor[2]: the video PES currently held back. The C's h264 parser only
  // completes an access unit when the next one's start code is seen, so
  // PES i surfaces when PES i+1 arrives (and the last at end of stream).
  if self.cursor.length() < 2 {
    self.cursor.push(0)
  }
  if self.cursor.length() < 3 {
    self.cursor.push(-1)
  }
  let held = self.cursor[2]
  if self.cursor[0] >= demux.packets.length() && held >= 0 {
    let out = ts_video_packet(self, demux, held)
    self.cursor[2] = -1
    return out
  }
  while self.cursor[0] < demux.packets.length() {
    let p = demux.packets[self.cursor[0]]
    let current = self.cursor[0]
    self.cursor[0] = self.cursor[0] + 1
    let info = self.streams[p.stream_index]
    if ts_stream_uses_audio_index(info) {
      let idx = self.cursor[1]
      if audio_frames.get(current) is Some(pes) && idx < pes.packets.length() {
        self.cursor[0] = current
        self.cursor[1] = idx + 1
        return Some(pes.packets[idx])
      }
      self.cursor[1] = 0
      continue
    }
    if info.media_type == MediaType::Video {
      // Hold this PES; emit the one it completes. Read the slot afresh:
      // several video PES can pass within one call.
      let prev = self.cursor[2]
      self.cursor[2] = current
      if prev >= 0 {
        return ts_video_packet(self, demux, prev)
      }
      continue
    }
    let pts = if p.pts != ts_nopts {
      p.pts
    } else if p.dts != ts_nopts {
      p.dts
    } else {
      0
    }
    return Some({
      stream_index: p.stream_index,
      data: p.payload,
      pts,
      keyframe: info.codec_id == "pcm_bluray" || info.codec_id == "s302m",
    })
  }
  let last = self.cursor[2]
  if last >= 0 {
    self.cursor[2] = -1
    return ts_video_packet(self, demux, last)
  }
  None
}

///|
/// Build the video packet for a held PES: Annex B IDR detection for the
/// keyframe flag, PES PTS (or DTS).
fn ts_video_packet(
  media : MediaFile,
  demux : TsDemux,
  index : Int32,
) -> MediaPacket? raise MediaError {
  // `av_read_frame` never hands back a stale index; a held PES that no
  // longer exists means the caller's cursor and the packet table have
  // drifted apart, which is a demuxer bug rather than an empty result.
  guard index >= 0 && index < demux.packets.length() else {
    raise DemuxError(
      "ts: held packet index \{index} outside 0..\{demux.packets.length()}",
    )
  }
  let p = demux.packets[index]
  let keyframe = if media.streams[p.stream_index].codec_id == "h264" {
    ts_h264_is_idr(p.payload)
  } else {
    false
  }
  let pts = if p.pts != ts_nopts {
    p.pts
  } else if p.dts != ts_nopts {
    p.dts
  } else {
    0
  }
  Some({ stream_index: p.stream_index, data: p.payload, pts, keyframe, })
}
