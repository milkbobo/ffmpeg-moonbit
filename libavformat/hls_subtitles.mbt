///|
/// WebVTT segment writer for HLS subtitle renditions (FFmpeg 9.0.2
/// `webvttenc.c` layout: `WEBVTT` marker plus absolute cue timestamps).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One WebVTT cue with absolute millisecond times.
pub struct HlsVttCue {
  start_ms : Int64
  end_ms : Int64
  text : String
}

///|
pub fn hls_vtt_cue_new(
  start_ms : Int64,
  end_ms : Int64,
  text : String,
) -> HlsVttCue {
  { start_ms, end_ms, text, }
}

///|
/// `HH:MM:SS.mmm` timestamp.
fn hls_vtt_timestamp(ms : Int64) -> String {
  let v = if ms < 0L { 0L } else { ms }
  let h = v / 3600000L
  let m = v / 60000L % 60L
  let s = v / 1000L % 60L
  let milli = v % 1000L
  let two = fn(x : Int64) -> String { if x < 10L { "0\{x}" } else { "\{x}" } }
  let three = fn(x : Int64) -> String {
    if x < 10L {
      "00\{x}"
    } else if x < 100L {
      "0\{x}"
    } else {
      "\{x}"
    }
  }
  "\{two(h)}:\{two(m)}:\{two(s)}.\{three(milli)}"
}

///|
/// One WebVTT segment with the cues' absolute times. Like FFmpeg's
/// `webvttenc.c`, no `X-TIMESTAMP-MAP` is written: cue times stay on the
/// playlist timeline, which is what FFmpeg's HLS demuxer expects.
pub fn hls_write_vtt_segment(cues : ArrayView[HlsVttCue]) -> String {
  let sb = StringBuilder()
  sb.write_string("WEBVTT\n")
  for cue in cues {
    sb.write_string("\n")
    sb.write_string(hls_vtt_timestamp(cue.start_ms))
    sb.write_string(" --> ")
    sb.write_string(hls_vtt_timestamp(cue.end_ms))
    sb.write_string("\n")
    sb.write_string(cue.text)
    sb.write_string("\n")
  }
  sb.to_string()
}
