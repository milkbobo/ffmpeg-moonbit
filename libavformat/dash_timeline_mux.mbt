///|
/// DASH `SegmentTemplate` + `SegmentTimeline` MPD writer: `$Time$` (or
/// `$Number$`) templates addressed by an explicit `<S>` timeline, matching
/// the parser's `dash_segments_from_timeline`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One `<S>` entry. `start < 0` omits `t` (continue after the previous entry);
/// `repeat == 0` omits `r`.
pub struct DashTimelineSegment {
  duration : Int64
  start : Int64
  repeat : Int64
}

///|
pub fn DashTimelineSegment::new(
  duration : Int64,
  start~ : Int64 = -1L,
  repeat~ : Int64 = 0L,
) -> DashTimelineSegment {
  { duration, start, repeat, }
}

///|
/// One AdaptationSet/Representation with a timed `SegmentTemplate`.
pub struct DashTimelineAdaptation {
  content_type : String
  mime_type : String
  codecs : String
  id : String
  bandwidth : Int64
  timescale : Int64
  start_number : Int64
  initialization : String
  media_template : String
  segments : Array[DashTimelineSegment]
  width : Int32
  height : Int32
  sample_rate : Int32
  lang : String
}

///|
pub fn DashTimelineAdaptation::new(
  content_type : String,
  mime_type : String,
  codecs : String,
  id : String,
  bandwidth : Int64,
  timescale : Int64,
  start_number : Int64,
  initialization : String,
  media_template : String,
  segments : Array[DashTimelineSegment],
  width~ : Int32 = 0,
  height~ : Int32 = 0,
  sample_rate~ : Int32 = 0,
  lang~ : String = "",
) -> DashTimelineAdaptation {
  {
    content_type,
    mime_type,
    codecs,
    id,
    bandwidth,
    timescale,
    start_number,
    initialization,
    media_template,
    segments,
    width,
    height,
    sample_rate,
    lang,
  }
}

///|
pub fn dash_write_timeline_mpd(
  adaptations : ArrayView[DashTimelineAdaptation],
  media_duration_seconds~ : Double,
  period_id~ : String = "p0",
) -> String {
  let sb = StringBuilder()
  sb.write_string("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
  sb.write_string(
    "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"static\"\n",
  )
  sb.write_string("     profiles=\"urn:mpeg:dash:profile:isoff-live:2011\"\n")
  sb.write_string(
    "     mediaPresentationDuration=\"PT\{media_duration_seconds}S\" minBufferTime=\"PT1.5S\">\n",
  )
  sb.write_string("  <Period id=\"\{period_id}\" start=\"PT0S\">\n")
  for a in adaptations {
    sb.write_string(
      "    <AdaptationSet contentType=\"\{a.content_type}\" mimeType=\"\{a.mime_type}\"",
    )
    // Text AdaptationSets (WebVTT) carry no codecs string.
    if a.codecs != "" {
      sb.write_string(" codecs=\"" + a.codecs + "\"")
    }
    if a.lang != "" {
      sb.write_string(" lang=\"" + a.lang + "\"")
    }
    sb.write_string(">\n")
    sb.write_string(
      "      <SegmentTemplate timescale=\"\{a.timescale}\" startNumber=\"\{a.start_number}\"\n",
    )
    sb.write_string("        ")
    // Self-contained WebVTT segments have no initialization.
    if a.initialization != "" {
      sb.write_string("initialization=\"" + a.initialization + "\" ")
    }
    sb.write_string("media=\"" + a.media_template + "\">\n")
    sb.write_string("        <SegmentTimeline>\n")
    for seg in a.segments {
      sb.write_string("          <S")
      if seg.start >= 0L {
        sb.write_string(" t=\"\{seg.start}\"")
      }
      sb.write_string(" d=\"\{seg.duration}\"")
      if seg.repeat != 0L {
        sb.write_string(" r=\"\{seg.repeat}\"")
      }
      sb.write_string(" />\n")
    }
    sb.write_string("        </SegmentTimeline>\n")
    sb.write_string("      </SegmentTemplate>\n")
    sb.write_string("      <Representation id=\"" + a.id + "\"")
    if a.bandwidth > 0L {
      sb.write_string(" bandwidth=\"\{a.bandwidth}\"")
    }
    if a.width > 0 && a.height > 0 {
      sb.write_string(" width=\"\{a.width}\" height=\"\{a.height}\"")
    }
    if a.sample_rate > 0 {
      sb.write_string(" audioSamplingRate=\"\{a.sample_rate}\"")
    }
    sb.write_string(" />\n")
    sb.write_string("    </AdaptationSet>\n")
  }
  sb.write_string("  </Period>\n")
  sb.write_string("</MPD>\n")
  sb.to_string()
}
