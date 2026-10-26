///|
/// Minimal HLS media-playlist writer.  Emits an M3U8 that the existing
/// `av_hls_parse` accepts: version, target duration, media sequence, EXTINF
/// entries and (optionally) EXT-X-ENDLIST.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// Write a VOD-style media playlist. `target_duration` 0 means "use the
/// ceiling of the largest segment duration".
pub fn hls_write_media_playlist(
  segments : ArrayView[(String, Double)],
  target_duration~ : Int32 = 0,
  media_sequence~ : Int64 = 0L,
  version~ : Int32 = 3,
  endlist~ : Bool = true,
) -> String {
  let mut max_duration = 0.0
  for entry in segments {
    if entry.1 > max_duration {
      max_duration = entry.1
    }
  }
  let target = if target_duration > 0 {
    target_duration
  } else {
    let v = max_duration.to_int()
    if max_duration > v.to_double() {
      v + 1
    } else {
      v
    }
  }
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n")
  sb.write_string("#EXT-X-VERSION:\{version}\n")
  sb.write_string("#EXT-X-TARGETDURATION:\{target}\n")
  sb.write_string("#EXT-X-MEDIA-SEQUENCE:\{media_sequence}\n")
  for entry in segments {
    sb.write_string("#EXTINF:\{entry.1},\n")
    sb.write_string(entry.0)
    sb.write_string("\n")
  }
  if endlist {
    sb.write_string("#EXT-X-ENDLIST\n")
  }
  sb.to_string()
}

///|
/// Write a master playlist. Each entry is
/// `(uri, bandwidth, width, height, codecs)`.
pub fn hls_write_master_playlist(
  variants : ArrayView[(String, Int32, Int32, Int32, String)],
  version~ : Int32 = 3,
) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n")
  sb.write_string("#EXT-X-VERSION:\{version}\n")
  for variant in variants {
    let (uri, bandwidth, width, height, codecs) = variant
    sb.write_string(
      "#EXT-X-STREAM-INF:BANDWIDTH=\{bandwidth},RESOLUTION=\{width}x\{height},CODECS=\"\{codecs}\"\n",
    )
    sb.write_string(uri)
    sb.write_string("\n")
  }
  sb.to_string()
}
