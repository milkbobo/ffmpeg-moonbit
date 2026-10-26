///|
/// Minimal DASH SegmentTemplate MPD writer: one Period, one video
/// AdaptationSet and one Representation.  The existing DASH parser expands the
/// `$Number...$` template exactly like the C demuxer.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub fn dash_write_segment_template_mpd(
  id~ : String,
  bandwidth~ : Int64,
  codecs~ : String,
  width~ : Int32,
  height~ : Int32,
  timescale~ : Int64,
  duration~ : Int64,
  start_number~ : Int64,
  initialization~ : String,
  media_template~ : String,
  segment_count~ : Int32,
  media_duration_seconds~ : Double,
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
  sb.write_string("  <Period id=\"p0\" start=\"PT0S\">\n")
  sb.write_string(
    "    <AdaptationSet contentType=\"video\" mimeType=\"video/mp4\" codecs=\"\{codecs}\">\n",
  )
  sb.write_string(
    "      <SegmentTemplate timescale=\"\{timescale}\" duration=\"\{duration}\" startNumber=\"\{start_number}\"\n",
  )
  sb.write_string(
    "        initialization=\"\{initialization}\" media=\"\{media_template}\" />\n",
  )
  sb.write_string(
    "      <Representation id=\"\{id}\" bandwidth=\"\{bandwidth}\" width=\"\{width}\" height=\"\{height}\" />\n",
  )
  sb.write_string("    </AdaptationSet>\n")
  sb.write_string("  </Period>\n")
  sb.write_string("</MPD>\n")
  ignore(segment_count)
  sb.to_string()
}
