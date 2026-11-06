///|
/// MPEG-TS adapter for the unified playback API: builds on the ported
/// `av_mpegts_open` demuxer (PES-level packets, 90 kHz timestamps). Video
/// payloads are Annex B NAL streams; AAC payloads are continuous ADTS
/// frame runs, which the adapter splits into per-frame packets like the
/// C's AAC demuxer does, and whose first header also yields the
/// AudioSpecificConfig the AAC decoder needs as extradata.

///|
/// Build the 2-byte AudioSpecificConfig from an ADTS header's raw fields:
/// 5-bit audio object type, 4-bit sampling frequency index, 4-bit channel
/// configuration, then the three zero GASpecificConfig bits.
pub fn ts_adts_to_asc(object_type : Int32, sampling_index : Int32, chan_config : Int32) -> Bytes {
  let v = ((object_type & 0x1F) << 11) | ((sampling_index & 0xF) << 7) | ((chan_config & 0xF) << 3)
  Bytes::from_array([(v >> 8).to_byte(), (v & 0xFF).to_byte()])
}

///|
/// True when an Annex B payload starts with an IDR slice (nal_unit_type 5),
/// scanning past the first start code. H.264-in-TS keyframes surface here
/// because the TS layer itself does not mark them.
fn ts_h264_is_idr(payload : Bytes) -> Bool {
  let n = payload.length()
  let mut i = 0
  // Locate the first start code (3- or 4-byte).
  while i + 3 < n {
    if payload[i].to_int() == 0 &&
      payload[i + 1].to_int() == 0 &&
      payload[i + 2].to_int() == 1 {
      i = i + 3
      break
    }
    if i + 4 <= n &&
      payload[i].to_int() == 0 &&
      payload[i + 1].to_int() == 0 &&
      payload[i + 2].to_int() == 0 &&
      payload[i + 3].to_int() == 1 {
      i = i + 4
      break
    }
    i = i + 1
  }
  if i >= n {
    return false
  }
  (payload[i].to_int() & 0x1F) == 5
}

///|
/// Split a PES payload that carries a continuous ADTS frame run into the
/// individual frames (byte ranges of `payload`), using the ported ADTS
/// header parser for framing.
fn ts_split_adts(payload : Bytes) -> Array[(Int, Int)] raise MediaError {
  let frames : Array[(Int, Int)] = []
  let mut pos = 0
  let n = payload.length()
  let hdr_size = @libavcodec.av_aac_adts_header_size
  while pos + hdr_size <= n {
    let hdr = payload.clamped_view(start=pos, end=pos + hdr_size).to_owned()
    let header = match @libavcodec.ff_adts_header_parse_buf(hdr) {
      Ok(h) => h
      Err(_) => {
        // Resync one byte, like the C parser loop.
        pos = pos + 1
        continue
      }
    }
    let len = header.frame_length
    if len <= hdr_size || pos + len > n {
      break
    }
    frames.push((pos + hdr_size, len - hdr_size))
    pos = pos + len
  }
  if frames.length() == 0 {
    raise DemuxError("mpegts: no ADTS frames in the audio payload")
  }
  frames
}

///|
/// Open the TS demuxer and build the stream table. The audio stream's
/// sample rate, channel count and ASC extradata come from parsing the
/// first ADTS frames found in its packets.
fn playback_ts_build(data : Bytes) -> MediaFile raise MediaError {
  let demux = match av_mpegts_open(data) {
    Ok(v) => v
    Err(e) => raise DemuxError(e)
  }
  let streams : Array[StreamInfo] = []
  for i = 0; i < demux.streams.length(); i = i + 1 {
    let t = demux.streams[i]
    let mt = if t.codec_type == "video" {
      MediaType::Video
    } else if t.codec_type == "audio" {
      MediaType::Audio
    } else {
      MediaType::Subtitle
    }
    let mut rate = 0
    let mut ch = 0
    let mut extradata : Bytes? = None
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
    if mt == MediaType::Audio && t.codec == "aac" {
      // Parse the first ADTS frames of this stream for the format header.
      let mut payload : Bytes? = None
      for p in demux.packets {
        if p.stream_index == i {
          payload = Some(p.payload)
          break
        }
      }
      match payload {
        Some(pl) => {
          let track = match av_adts_open(pl) {
            Ok(v) => v
            Err(_) => raise UnsupportedCodec("mpegts: unreadable ADTS stream")
          }
          rate = track.sample_rate
          ch = track.channels
          // The raw indices come from re-parsing the first header.
          let hdr = pl
            .clamped_view(start=0, end=@libavcodec.av_aac_adts_header_size)
            .to_owned()
          match @libavcodec.ff_adts_header_parse_buf(hdr) {
            Ok(h) =>
              extradata = Some(
                ts_adts_to_asc(h.object_type, h.sampling_index, h.chan_config),
              )
            Err(_) => raise UnsupportedCodec("mpegts: bad ADTS header")
          }
        }
        None => raise UnsupportedCodec("mpegts: audio stream without packets")
      }
    }
    streams.push({
      index: i,
      media_type: mt,
      codec_id: t.codec,
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
    source: Ts(demux),
    cursor: [0],
  }
}

///|
/// TS packet walk: video payloads yield one packet per PES; AAC payloads
/// are split into their ADTS frames (the frame body, header stripped),
/// each carrying the PES's PTS.
fn MediaFile::playback_ts_next(self : MediaFile, demux : TsDemux) -> MediaPacket? raise MediaError {
  while self.cursor[0] < demux.packets.length() {
    let p = demux.packets[self.cursor[0]]
    self.cursor[0] = self.cursor[0] + 1
    let info = self.streams[p.stream_index]
    if info.media_type == MediaType::Audio && info.codec_id == "aac" {
      // Split the ADTS run; re-scan from the payload start each time by
      // tracking the per-PES offset in cursor[1].
      let frames = ts_split_adts(p.payload)
      let idx = if self.cursor.length() > 1 {
        self.cursor[1]
      } else {
        0
      }
      if idx < frames.length() {
        let (off, len) = frames[idx]
        if self.cursor.length() > 1 {
          self.cursor[1] = idx + 1
        } else {
          self.cursor.push(idx + 1)
        }
        // Do not consume the PES until all frames are out.
        self.cursor[0] = self.cursor[0] - 1
        let pts = if p.pts != ts_nopts {
          p.pts
        } else if p.dts != ts_nopts {
          p.dts
        } else {
          0
        }
        return Some({
          stream_index: p.stream_index,
          data: p.payload[off:off + len].to_owned(),
          pts,
          keyframe: false,
        })
      }
      // All frames of this PES emitted: drop the per-PES frame cursor and
      // move to the next packet.
      if self.cursor.length() > 1 {
        self.cursor[1] = 0
      }
      continue
    }
    let keyframe = if info.codec_id == "h264" {
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
    return Some({
      stream_index: p.stream_index,
      data: p.payload,
      pts,
      keyframe,
    })
  }
  None
}
