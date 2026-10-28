///|
/// Minimal DASH SegmentTemplate MPD writer: one Period with one or more
/// AdaptationSets (video and/or audio), each with a single Representation and
/// a `$Number...$` media template. The existing DASH parser expands the
/// template exactly like the C demuxer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One AdaptationSet/Representation pair. `width`/`height` are emitted for
/// video, `sample_rate` for audio; `content_type`/`mime_type` select the
/// AdaptationSet attributes.
pub struct DashAdaptation {
  content_type : String
  mime_type : String
  codecs : String
  id : String
  bandwidth : Int64
  timescale : Int64
  duration : Int64
  initialization : String
  media_template : String
  width : Int32
  height : Int32
  sample_rate : Int32
  start_number : Int64
  lang : String
}

///|
pub fn DashAdaptation::new(
  content_type : String,
  mime_type : String,
  codecs : String,
  id : String,
  bandwidth : Int64,
  timescale : Int64,
  duration : Int64,
  initialization : String,
  media_template : String,
  width~ : Int32 = 0,
  height~ : Int32 = 0,
  sample_rate~ : Int32 = 0,
  start_number~ : Int64 = 1L,
  lang~ : String = "",
) -> DashAdaptation {
  {
    content_type,
    mime_type,
    codecs,
    id,
    bandwidth,
    timescale,
    duration,
    initialization,
    media_template,
    width,
    height,
    sample_rate,
    start_number,
    lang,
  }
}

///|
pub fn dash_write_segment_template_mpd(
  adaptations : ArrayView[DashAdaptation],
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
      "    <AdaptationSet contentType=\"\{a.content_type}\" mimeType=\"\{a.mime_type}\" codecs=\"\{a.codecs}\"",
    )
    if a.lang != "" {
      sb.write_string(" lang=\"" + a.lang + "\"")
    }
    sb.write_string(">\n")
    sb.write_string(
      "      <SegmentTemplate timescale=\"\{a.timescale}\" duration=\"\{a.duration}\" startNumber=\"\{a.start_number}\"\n",
    )
    sb.write_string(
      "        initialization=\"\{a.initialization}\" media=\"\{a.media_template}\" />\n",
    )
    sb.write_string(
      "      <Representation id=\"\{a.id}\" bandwidth=\"\{a.bandwidth}\"",
    )
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
