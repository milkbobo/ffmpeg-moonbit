///|
fn subtitle_cue(start : Double, end : Double, text : String) -> Json? {
  let start = start.max(0.0)
  guard end > start && !end.is_inf() && text.trim().length() > 0 else {
    return None
  }
  Some({ "start": Json(start), "end": Json(end), "text": Json(text) })
}

///|
fn demo_subtitle_tracks(data : Bytes) -> Array[Json] raise {
  let tracks : Array[Json] = []
  let file = @avf.MediaFile::open(data)
  if file.format_name().has_prefix("mov,") {
    let movie = demo_result(@avf.av_mov_open(data))
    for index, track in movie.tracks {
      if track.codec != "tx3g" ||
        track.timescale == 0U ||
        track.cenc_scheme != 0U {
        continue
      }
      let scale = track.timescale.to_double()
      let cues : Array[Json] = []
      for sample in track.samples {
        if sample.discard || sample.duration == 0U {
          continue
        }
        let text = demo_result(
          @avf.mp4_tx3g_text(demo_video_sample(data, sample)),
        )
        let start = sample.pts.to_double() / scale
        if subtitle_cue(
            start,
            start + sample.duration.to_double() / scale,
            text,
          )
          is Some(cue) {
          cues.push(cue)
        }
      }
      tracks.push({
        "index": Json(index),
        "language": Json(track.language),
        "cues": Json(cues),
      })
    }
  } else if file.format_name().has_prefix("matroska,") {
    let mkv = demo_result(@avf.av_matroska_open(data))
    let by_track : Map[Int32, Array[Json]] = Map([])
    for index, track in mkv.tracks {
      if track.codec_id == Some("S_TEXT/UTF8") {
        by_track[index] = []
      }
    }
    for packet in mkv.packets {
      guard by_track.get(packet.stream_index) is Some(cues) else { continue }
      if packet.pts == -9223372036854775807L - 1L || packet.duration == 0UL {
        continue
      }
      let track = mkv.tracks[packet.stream_index]
      let step = mkv.time_scale.to_double() * track.time_scale / 1000000000.0
      let start = packet.pts.to_double() * step
      let text = @utf8.decode_lossy(packet.data[:])
      if subtitle_cue(start, start + packet.duration.to_double() * step, text)
        is Some(cue) {
        cues.push(cue)
      }
    }
    for index, track in mkv.tracks {
      if by_track.get(index) is Some(cues) {
        tracks.push({
          "index": Json(index),
          "language": Json(track.language),
          "cues": Json(cues),
        })
      }
    }
  }
  tracks
}

///|
#export_name("ff_subtitle_tracks")
pub fn ff_subtitle_tracks(data : String) -> String {
  let tracks = demo_subtitle_tracks(u0100_to_bytes(data)) catch {
    error => return env_err_code("SUBTITLE_FAILED", error.to_string())
  }
  env_ok("\"tracks\":" + Json(tracks).stringify())
}
