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
  /// Audio channel count for the AudioChannelConfiguration element (0 omits).
  channels : Int32
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
  channels~ : Int32 = 0,
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
    channels,
    start_number,
    lang,
  }
}

///|

///|
/// Emit the SegmentTemplate AdaptationSets of one Period (shared by the
/// single- and multi-period writers).
fn dash_write_template_adaptations(
  sb : StringBuilder,
  adaptations : ArrayView[DashAdaptation],
) -> Unit {
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
      "      <SegmentTemplate timescale=\"\{a.timescale}\" duration=\"\{a.duration}\" startNumber=\"\{a.start_number}\"\n",
    )
    // WebVTT segments are self-contained: no initialization segment.
    if a.initialization != "" {
      sb.write_string("        initialization=\"" + a.initialization + "\"\n")
    }
    sb.write_string("        media=\"" + a.media_template + "\" />\n")
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
    if a.content_type == "audio" && a.channels > 0 {
      sb.write_string(">\n")
      sb.write_string(
        "        <AudioChannelConfiguration schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"\{a.channels}\" />\n",
      )
      sb.write_string("      </Representation>\n")
    } else {
      sb.write_string(" />\n")
    }
    sb.write_string("    </AdaptationSet>\n")
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
  dash_write_template_adaptations(sb, adaptations)
  sb.write_string("  </Period>\n")
  sb.write_string("</MPD>\n")
  sb.to_string()
}

///|
/// One `<Period>` of a multi-period SegmentTemplate MPD.
pub struct DashPeriodSpec {
  id : String
  start_seconds : Double
  /// Explicit Period duration; 0 omits the attribute (the parser then uses
  /// the rest of the presentation for this Period).
  duration_seconds : Double
  adaptations : Array[DashAdaptation]
}

///|
pub fn DashPeriodSpec::new(
  id : String,
  start_seconds : Double,
  adaptations : Array[DashAdaptation],
  duration_seconds~ : Double = 0.0,
) -> DashPeriodSpec {
  { id, start_seconds, duration_seconds, adaptations, }
}

///|
/// Write a multi-period SegmentTemplate MPD. Each Period carries its own
/// AdaptationSets and, when non-zero, an explicit `duration` attribute that
/// the DASH parser uses to expand per-period segment counts.
pub fn dash_write_segment_template_mpd_periods(
  periods : ArrayView[DashPeriodSpec],
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
  for period in periods {
    sb.write_string(
      "  <Period id=\"" + period.id + "\" start=\"PT\{period.start_seconds}S\"",
    )
    if period.duration_seconds > 0.0 {
      sb.write_string(" duration=\"PT\{period.duration_seconds}S\"")
    }
    sb.write_string(">\n")
    dash_write_template_adaptations(sb, period.adaptations)
    sb.write_string("  </Period>\n")
  }
  sb.write_string("</MPD>\n")
  sb.to_string()
}

///|
/// One `SegmentURL` of a SegmentList representation. Empty `media` means the
/// segment lives in the Representation BaseURL (single-file layout).
pub struct DashListSegment {
  media : String
  media_range : String
}

///|
pub fn DashListSegment::new(
  media~ : String = "",
  media_range~ : String = "",
) -> DashListSegment {
  { media, media_range, }
}

///|
/// `SegmentList` AdaptationSet/Representation pair. `initialization` is the
/// `sourceURL` attribute; empty means the BaseURL (with
/// `initialization_range` when set).
pub struct DashListAdaptation {
  content_type : String
  mime_type : String
  codecs : String
  id : String
  bandwidth : Int64
  timescale : Int64
  duration : Int64
  start_number : Int64
  base_url : String
  initialization : String
  initialization_range : String
  segments : Array[DashListSegment]
  width : Int32
  height : Int32
  sample_rate : Int32
  /// Audio channel count for the AudioChannelConfiguration element (0 omits).
  channels : Int32
  lang : String
}

///|
pub fn DashListAdaptation::new(
  content_type : String,
  mime_type : String,
  codecs : String,
  id : String,
  bandwidth : Int64,
  timescale : Int64,
  duration : Int64,
  segments : Array[DashListSegment],
  base_url~ : String = "",
  initialization~ : String = "",
  initialization_range~ : String = "",
  start_number~ : Int64 = 1L,
  width~ : Int32 = 0,
  height~ : Int32 = 0,
  sample_rate~ : Int32 = 0,
  channels~ : Int32 = 0,
  lang~ : String = "",
) -> DashListAdaptation {
  {
    content_type,
    mime_type,
    codecs,
    id,
    bandwidth,
    timescale,
    duration,
    start_number,
    base_url,
    initialization,
    initialization_range,
    segments,
    width,
    height,
    sample_rate,
    channels,
    lang,
  }
}

///|
/// Write a SegmentList MPD (one Representation per AdaptationSet). Supports
/// separate media files and single-file representations typed by
/// `BaseURL` + `mediaRange`.
pub fn dash_write_segment_list_mpd(
  adaptations : ArrayView[DashListAdaptation],
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
    sb.write_string(">\n")
    if a.content_type == "audio" && a.channels > 0 {
      sb.write_string(
        "        <AudioChannelConfiguration schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"\{a.channels}\" />\n",
      )
    }
    if a.base_url != "" {
      sb.write_string("        <BaseURL>\{a.base_url}</BaseURL>\n")
    }
    sb.write_string(
      "        <SegmentList timescale=\"\{a.timescale}\" duration=\"\{a.duration}\"",
    )
    // DASH default startNumber is 1; FFmpeg's dashdec mis-indexes explicit
    // SegmentURL lists when the attribute shifts cur_seq_no, so omit the default.
    if a.start_number != 1L {
      sb.write_string(" startNumber=\"\{a.start_number}\"")
    }
    sb.write_string(">\n")
    // WebVTT segments are self-contained: no initialization section.
    if a.initialization != "" || a.initialization_range != "" {
      sb.write_string("          <Initialization")
      if a.initialization != "" {
        sb.write_string(" sourceURL=\"" + a.initialization + "\"")
      }
      if a.initialization_range != "" {
        sb.write_string(" range=\"" + a.initialization_range + "\"")
      }
      sb.write_string(" />\n")
    }
    for seg in a.segments {
      sb.write_string("          <SegmentURL")
      if seg.media != "" {
        sb.write_string(" media=\"" + seg.media + "\"")
      }
      if seg.media_range != "" {
        sb.write_string(" mediaRange=\"" + seg.media_range + "\"")
      }
      sb.write_string(" />\n")
    }
    sb.write_string("        </SegmentList>\n")
    sb.write_string("      </Representation>\n")
    sb.write_string("    </AdaptationSet>\n")
  }
  sb.write_string("  </Period>\n")
  sb.write_string("</MPD>\n")
  sb.to_string()
}

///|
/// `SegmentBase` AdaptationSet/Representation pair: a single-file track
/// addressed by `BaseURL` plus an `indexRange`/`Initialization` byte range.
pub struct DashBaseAdaptation {
  content_type : String
  mime_type : String
  codecs : String
  id : String
  bandwidth : Int64
  base_url : String
  initialization_range : String
  index_range : String
  width : Int32
  height : Int32
  sample_rate : Int32
  /// Audio channel count for the AudioChannelConfiguration element (0 omits).
  channels : Int32
  lang : String
}

///|
pub fn DashBaseAdaptation::new(
  content_type : String,
  mime_type : String,
  codecs : String,
  id : String,
  bandwidth : Int64,
  base_url : String,
  initialization_range : String,
  index_range : String,
  width~ : Int32 = 0,
  height~ : Int32 = 0,
  sample_rate~ : Int32 = 0,
  channels~ : Int32 = 0,
  lang~ : String = "",
) -> DashBaseAdaptation {
  {
    content_type,
    mime_type,
    codecs,
    id,
    bandwidth,
    base_url,
    initialization_range,
    index_range,
    width,
    height,
    sample_rate,
    channels,
    lang,
  }
}

///|
/// Write a `SegmentBase` MPD (one single-file Representation per
/// AdaptationSet). `index_range` must cover the file's global `sidx`, and
/// `initialization_range` the `ftyp`+`moov` prefix.
pub fn dash_write_segment_base_mpd(
  adaptations : ArrayView[DashBaseAdaptation],
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
    if a.codecs != "" {
      sb.write_string(" codecs=\"" + a.codecs + "\"")
    }
    if a.lang != "" {
      sb.write_string(" lang=\"" + a.lang + "\"")
    }
    sb.write_string(">\n")
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
    sb.write_string(">\n")
    if a.content_type == "audio" && a.channels > 0 {
      sb.write_string(
        "        <AudioChannelConfiguration schemeIdUri=\"urn:mpeg:dash:23003:3:audio_channel_configuration:2011\" value=\"\{a.channels}\" />\n",
      )
    }
    sb.write_string("        <BaseURL>\{a.base_url}</BaseURL>\n")
    sb.write_string("        <SegmentBase")
    if a.index_range != "" {
      sb.write_string(" indexRange=\"" + a.index_range + "\"")
    }
    if a.initialization_range != "" {
      sb.write_string(">\n")
      sb.write_string(
        "          <Initialization range=\"" +
        a.initialization_range +
        "\" />\n",
      )
      sb.write_string("        </SegmentBase>\n")
    } else {
      sb.write_string(" />\n")
    }
    sb.write_string("      </Representation>\n")
    sb.write_string("    </AdaptationSet>\n")
  }
  sb.write_string("  </Period>\n")
  sb.write_string("</MPD>\n")
  sb.to_string()
}
