///|
/// MoonBit port of the DASH MPD layer from FFmpeg 9.0.2
/// `libavformat/dashdec.c` (`parse_manifest`, `parse_manifest_adaptationset`,
/// `parse_manifest_representation`, `get_*_segment_list`, template expansion)
/// on top of the package's minimal XML parser.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: static/dynamic MPD metadata, Period/AdaptationSet/Representation
/// inheritance, BaseURL chains, SegmentTemplate with `$Number$`/`$Time$`/
/// `$RepresentationID$`/`$Bandwidth$` substitution, SegmentTimeline (including
/// `r="-1"`), and duration-driven segment enumeration. The C's HTTP layer and
/// lazy per-representation download contexts stay at the platform boundary.
///
/// SegmentList initialization/media ranges are consumed by segment_io.mbt.
/// Out of scope: SegmentBase index-range playback, xlink remote elements, UTCTiming clock
/// synchronisation, multi-period overlap checks, and DRM (`ContentProtection`).

///|
pub struct DashSegment {
  number : Int64
  /// Segment start in the representation's timescale.
  time : Int64
  duration : Int64
  uri : String
  /// SegmentList@mediaRange (inclusive start-end); empty for whole resources.
  media_range : String
}

///|
pub struct DashRepresentation {
  id : String
  bandwidth : Int64
  codecs : String
  /// FFmpeg codec name derived from `codecs` ("h264", "aac", ...).
  codec : String
  mime_type : String
  width : Int32
  height : Int32
  frame_rate : String
  audio_sampling_rate : Int32
  sar : String
  /// Effective base URL (MPD/Period/AdaptationSet/Representation BaseURLs).
  base_url : String
  timescale : Int64
  start_number : Int64
  initialization : String
  initialization_range : String
  media_template : String
  /// SegmentTemplate@media absent: a single-file Representation.
  index_range : String
  segments : Array[DashSegment]
}

///|
pub struct DashAdaptationSet {
  id : String
  content_type : String
  mime_type : String
  codecs : String
  lang : String
  width : Int32
  height : Int32
  frame_rate : String
  representations : Array[DashRepresentation]
}

///|
pub struct DashPeriod {
  id : String
  start : Double
  duration : Double
  adaptation_sets : Array[DashAdaptationSet]
}

///|
pub struct DashMpd {
  /// "static" or "dynamic".
  type_ : String
  profiles : String
  media_presentation_duration : Double
  min_buffer_time : Double
  base_url : String
  periods : Array[DashPeriod]
}

///|
/// ISO 8601 duration ("PT2.6S", "PT1H2M3.5S", "P1DT2H"). Years and months use
/// the 365/30-day approximation FFmpeg's `av_parse_time` does not need here.
pub fn dash_parse_duration(text : String) -> Double {
  let s = text.trim(chars=" \t\r\n")
  if s.length() == 0 || s[0].to_int() != 'P'.to_int() {
    return 0.0
  }
  let mut total = 0.0
  let mut number = StringBuilder()
  let mut is_time = false
  for c in s {
    let ch = c
    if ch == 'T' {
      is_time = true
    } else if (ch >= '0' && ch <= '9') || ch == '.' {
      number.write_char(ch)
    } else {
      let v = @string.parse_double(number.to_string()) catch { _ => 0.0 }
      number = StringBuilder()
      let scale = if ch == 'Y' {
        365.0 * 86400.0
      } else if ch == 'M' && !is_time {
        30.0 * 86400.0
      } else if ch == 'D' {
        86400.0
      } else if ch == 'H' {
        3600.0
      } else if ch == 'M' {
        60.0
      } else if ch == 'S' {
        1.0
      } else {
        0.0
      }
      total = total + v * scale
    }
  }
  total
}

///|
fn dash_time_scale(value : Double, timescale : Int64) -> Int64 {
  if value <= 0.0 || timescale <= 0L {
    0L
  } else {
    (value * timescale.to_double()).to_int64()
  }
}

///|
/// Substitute `$RepresentationID$`, `$Number[%0Nd]$`, `$Time$`, `$Bandwidth$`
/// and `$$` in a SegmentTemplate URL. */
pub fn dash_fill_template(
  template : String,
  representation_id : String,
  bandwidth : Int64,
  number : Int64,
  time : Int64,
) -> String {
  if !template.contains("$") {
    return template
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < template.length() {
    if template[i].to_int() == '$'.to_int() {
      // Find the closing '$' of this token.
      let mut j = i + 1
      while j < template.length() && template[j].to_int() != '$'.to_int() {
        j = j + 1
      }
      if j >= template.length() {
        sb.write_string(template[i:].to_owned())
        break
      }
      let token = template[i + 1:j].to_owned()
      if token == "" {
        sb.write_char('$')
      } else {
        let (name, fmt) = match token.find("%") {
          Some(k) => (token[0:k].to_owned(), token[k:].to_owned())
          None => (token, "")
        }
        let value = match name {
          "RepresentationID" => representation_id
          "Bandwidth" => bandwidth.to_string()
          "Number" => dash_format_number(number, fmt)
          "Time" => dash_format_number(time, fmt)
          _ => ""
        }
        sb.write_string(value)
      }
      i = j + 1
    } else {
      sb.write_char(template[i].to_int().unsafe_to_char())
      i = i + 1
    }
  }
  sb.to_string()
}

///|
fn dash_format_number(value : Int64, fmt : String) -> String {
  if fmt == "" {
    return value.to_string()
  }
  let mut width = 0
  for c in fmt {
    if c >= '0' && c <= '9' {
      width = width * 10 + (c.to_int() - '0'.to_int())
    }
  }
  let s = value.abs().to_string()
  let mut out = ""
  if width > s.length() {
    for _ in 0..<(width - s.length()) {
      out = out + "0"
    }
  }
  if value < 0L {
    "-" + out + s
  } else {
    out + s
  }
}

///|
fn dash_codec_name(codecs : String) -> String {
  let first = match codecs.find(",") {
    Some(i) => codecs[0:i].to_owned()
    None => codecs
  }
  let base = match first.find(".") {
    Some(i) => first[0:i].to_owned()
    None => first
  }
  match base {
    "avc1" | "avc3" | "avc2" | "avc4" => "h264"
    "hvc1" | "hev1" | "dvh1" | "dvhe" => "hevc"
    "av01" => "av1"
    "vp08" => "vp8"
    "vp09" => "vp9"
    "mp4a" => "aac"
    "mp3" => "mp3"
    "Opus" | "opus" => "opus"
    "ac-3" => "ac3"
    "ec-3" => "eac3"
    "flac" => "flac"
    "stpp" => "mov_text"
    "wvtt" => "webvtt"
    _ => ""
  }
}

///|
fn dash_trim_text(node : XmlNode) -> String {
  node.text.trim(chars=" \t\r\n").to_owned()
}

///|
fn dash_child_base_url(node : XmlNode) -> String {
  match node.child("BaseURL") {
    Some(b) => dash_trim_text(b)
    None => ""
  }
}

///|
fn dash_join_base(base : String, node : XmlNode) -> String {
  let sub = dash_child_base_url(node)
  if sub == "" {
    base
  } else {
    hls_resolve_uri(base, sub)
  }
}

///|
/// Resolve the nearest segment-addressing element through DASH inheritance.
fn dash_segment_node(
  period : XmlNode,
  adapt : XmlNode,
  rep : XmlNode,
  name : String,
) -> XmlNode? {
  for node in [rep, adapt, period] {
    if node.child(name) is Some(child) { return Some(child) }
  }
  None
}

///|
fn dash_segments_from_timeline(
  timeline : XmlNode,
  start_number : Int64,
  period_end : Int64,
  media : String,
  rep_id : String,
  bandwidth : Int64,
  base : String,
) -> Array[DashSegment] {
  let out : Array[DashSegment] = []
  let s_nodes = timeline.children_named("S")
  let mut current_time = 0L
  let mut number = start_number
  let mut i = 0
  while i < s_nodes.length() {
    let s = s_nodes[i]
    let t = match s.attr("t") {
      Some(v) => @string.parse_int64(v) catch { _ => current_time }
      None => current_time
    }
    let d = match s.attr("d") {
      Some(v) => @string.parse_int64(v) catch { _ => 0L }
      None => 0L
    }
    let r = match s.attr("r") {
      Some(v) => @string.parse_int64(v) catch { _ => 0L }
      None => 0L
    }
    if d <= 0L {
      i = i + 1
      continue
    }
    let mut repeats = r
    if r < 0L {
      // Repeat until the next S@t or the end of the period.
      let next_t = if i + 1 < s_nodes.length() {
        match s_nodes[i + 1].attr("t") {
          Some(v) => @string.parse_int64(v) catch { _ => 0L }
          None => 0L
        }
      } else {
        0L
      }
      let end = if next_t > t {
        next_t
      } else if period_end > t {
        period_end
      } else {
        t + d
      }
      repeats = (end - t + d - 1L) / d - 1L
      if repeats < 0L {
        repeats = 0L
      }
    }
    for k in 0..<=repeats.to_int() {
      let seg_time = t + d * k.to_int64()
      let uri = dash_fill_template(media, rep_id, bandwidth, number, seg_time)
      out.push({
        number,
        time: seg_time,
        duration: d,
        uri: hls_resolve_uri(base, uri),
        media_range: "",
      })
      number = number + 1L
    }
    current_time = t + d * (repeats + 1L)
    i = i + 1
  }
  out
}

///|
fn dash_parse_representation(
  rep : XmlNode,
  adapt : XmlNode,
  period : XmlNode,
  period_duration : Double,
  base : String,
) -> DashRepresentation {
  let id = rep.attr_or("id", "")
  let bandwidth = match rep.attr("bandwidth") {
    Some(v) => @string.parse_int64(v) catch { _ => 0L }
    None => 0L
  }
  let codecs = rep.attr_or("codecs", adapt.attr_or("codecs", ""))
  let mime_type = rep.attr_or("mimeType", adapt.attr_or("mimeType", ""))
  let width = match rep.attr("width") {
    Some(v) => @string.parse_int(v) catch { _ => 0 }
    None =>
      match adapt.attr("maxWidth") {
        Some(v) => @string.parse_int(v) catch { _ => 0 }
        None =>
          match adapt.attr("width") {
            Some(v) => @string.parse_int(v) catch { _ => 0 }
            None => 0
          }
      }
  }
  let height = match rep.attr("height") {
    Some(v) => @string.parse_int(v) catch { _ => 0 }
    None =>
      match adapt.attr("maxHeight") {
        Some(v) => @string.parse_int(v) catch { _ => 0 }
        None =>
          match adapt.attr("height") {
            Some(v) => @string.parse_int(v) catch { _ => 0 }
            None => 0
          }
      }
  }
  let frame_rate = rep.attr_or("frameRate", adapt.attr_or("frameRate", ""))
  let sampling_rate = match rep.attr("audioSamplingRate") {
    Some(v) => @string.parse_int(v) catch { _ => 0 }
    None => 0
  }
  let sar = rep.attr_or("sar", "")
  let rep_base = dash_join_base(base, rep)
  let mut timescale = 1L
  let mut start_number = 1L
  let mut initialization = ""
  let mut media_template = ""
  let mut index_range = ""
  let mut initialization_range = ""
  let mut segments : Array[DashSegment] = []
  match dash_segment_node(period, adapt, rep, "SegmentTemplate") {
    Some(tmpl) => {
      timescale = match tmpl.attr("timescale") {
        Some(v) => @string.parse_int64(v) catch { _ => 1L }
        None => 1L
      }
      start_number = match tmpl.attr("startNumber") {
        Some(v) => @string.parse_int64(v) catch { _ => 1L }
        None => 1L
      }
      initialization = tmpl.attr_or("initialization", "")
      media_template = tmpl.attr_or("media", "")
      index_range = tmpl.attr_or("indexRange", "")
      if initialization != "" {
        initialization = hls_resolve_uri(
          rep_base,
          dash_fill_template(initialization, id, bandwidth, start_number, 0L),
        )
      }
      if media_template != "" {
        let period_end = dash_time_scale(period_duration, timescale)
        match tmpl.child("SegmentTimeline") {
          Some(tl) =>
            segments = dash_segments_from_timeline(
              tl, start_number, period_end, media_template, id, bandwidth, rep_base,
            )
          None => {
            let seg_duration = match tmpl.attr("duration") {
              Some(v) => @string.parse_int64(v) catch { _ => 0L }
              None => 0L
            }
            if seg_duration > 0L && period_duration > 0.0 {
              let total = dash_time_scale(period_duration, timescale)
              let count = (total + seg_duration - 1L) / seg_duration
              for k in 0..<count.to_int() {
                let number = start_number + k.to_int64()
                let time = seg_duration * k.to_int64()
                let uri = dash_fill_template(
                  media_template, id, bandwidth, number, time,
                )
                segments.push({
                  number,
                  time,
                  duration: seg_duration,
                  uri: hls_resolve_uri(rep_base, uri),
                  media_range: "",
                })
              }
            }
          }
        }
      }
    }
    None => {
      // SegmentBase / SegmentList style: expose the BaseURL as a single URI.
      match dash_segment_node(period, adapt, rep, "SegmentBase") {
        Some(sb) => index_range = sb.attr_or("indexRange", "")
        None => ()
      }
      match dash_segment_node(period, adapt, rep, "SegmentList") {
        Some(sl) => {
          timescale = @string.parse_int64(sl.attr_or("timescale", "1")) catch { _ => 1L }
          if timescale < 1L { timescale = 1L }
          start_number = @string.parse_int64(sl.attr_or("startNumber", "1")) catch { _ => 1L }
          initialization_range = match sl.child("Initialization") {
            Some(init) => init.attr_or("range", "")
            None => ""
          }
          initialization = match sl.child("Initialization") {
            Some(init) =>
              hls_resolve_uri(rep_base, init.attr_or("sourceURL", ""))
            None => ""
          }
          let dur = match sl.attr("duration") {
            Some(v) => @string.parse_int64(v) catch { _ => 0L }
            None => 0L
          }
          let mut number = start_number
          let mut time = 0L
          for su in sl.children_named("SegmentURL") {
            segments.push({
              number,
              time,
              duration: dur,
              uri: hls_resolve_uri(rep_base, su.attr_or("media", "")),
              media_range: su.attr_or("mediaRange", ""),
            })
            number += 1L
            time += dur
          }
        }
        None => ()
      }
      if media_template == "" && segments.length() == 0 && index_range == "" {
        // A single-file Representation: BaseURL itself is the media URL.
        segments.push({
          number: 0L,
          time: 0L,
          duration: dash_time_scale(period_duration, 1L),
          uri: rep_base,
          media_range: "",
        })
      }
    }
  }
  {
    id,
    bandwidth,
    codecs,
    codec: dash_codec_name(codecs),
    mime_type,
    width,
    height,
    frame_rate,
    audio_sampling_rate: sampling_rate,
    sar,
    base_url: rep_base,
    timescale,
    start_number,
    initialization,
    initialization_range,
    media_template,
    index_range,
    segments,
  }
}

///|
/// Parse an MPD document. `base_uri` is the MPD's own URL (used to resolve
/// relative BaseURLs/templates; "" keeps them relative).
pub fn av_dash_parse(
  text : String,
  base_uri~ : String = "",
) -> Result[DashMpd, String] {
  let root = match xml_parse(text) {
    Ok(r) => r
    Err(e) => return Err(e)
  }
  if xml_local_name(root.name) != "MPD" {
    return Err("EINVAL: not an MPD document")
  }
  let mpd_base = dash_join_base(base_uri, root)
  let duration = dash_parse_duration(
    root.attr_or("mediaPresentationDuration", ""),
  )
  let min_buffer = dash_parse_duration(root.attr_or("minBufferTime", ""))
  let mpd : DashMpd = {
    type_: root.attr_or("type", "static"),
    profiles: root.attr_or("profiles", ""),
    media_presentation_duration: duration,
    min_buffer_time: min_buffer,
    base_url: mpd_base,
    periods: [],
  }
  for period_node in root.children_named("Period") {
    let period_start = dash_parse_duration(period_node.attr_or("start", ""))
    let period_dur = {
      let explicit = dash_parse_duration(period_node.attr_or("duration", ""))
      if explicit > 0.0 {
        explicit
      } else if duration > 0.0 {
        duration - period_start
      } else {
        0.0
      }
    }
    let period_base = dash_join_base(mpd_base, period_node)
    let period : DashPeriod = {
      id: period_node.attr_or("id", ""),
      start: period_start,
      duration: period_dur,
      adaptation_sets: [],
    }
    for adapt_node in period_node.children_named("AdaptationSet") {
      let adapt_base = dash_join_base(period_base, adapt_node)
      let adapt : DashAdaptationSet = {
        id: adapt_node.attr_or("id", ""),
        content_type: adapt_node.attr_or("contentType", ""),
        mime_type: adapt_node.attr_or("mimeType", ""),
        codecs: adapt_node.attr_or("codecs", ""),
        lang: adapt_node.attr_or("lang", ""),
        width: match adapt_node.attr("maxWidth") {
          Some(v) => @string.parse_int(v) catch { _ => 0 }
          None =>
            match adapt_node.attr("width") {
              Some(v) => @string.parse_int(v) catch { _ => 0 }
              None => 0
            }
        },
        height: match adapt_node.attr("maxHeight") {
          Some(v) => @string.parse_int(v) catch { _ => 0 }
          None =>
            match adapt_node.attr("height") {
              Some(v) => @string.parse_int(v) catch { _ => 0 }
              None => 0
            }
        },
        frame_rate: adapt_node.attr_or("frameRate", ""),
        representations: [],
      }
      for rep_node in adapt_node.children_named("Representation") {
        adapt.representations.push(
          dash_parse_representation(
            rep_node, adapt_node, period_node, period_dur, adapt_base,
          ),
        )
      }
      period.adaptation_sets.push(adapt)
    }
    mpd.periods.push(period)
  }
  Ok(mpd)
}
