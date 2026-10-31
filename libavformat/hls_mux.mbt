///|
/// Minimal HLS media-playlist writer.  Emits an M3U8 that the existing
/// `av_hls_parse` accepts: version, target duration, media sequence, EXTINF
/// entries and (optionally) EXT-X-ENDLIST.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// One media-playlist entry for `hls_write_media_playlist_byterange`: a URI,
/// duration and optional `EXT-X-BYTERANGE`. `offset < 0` omits the offset
/// (the range continues after the previous sub-range of the resource).
pub struct HlsMediaSegmentSpec {
  uri : String
  duration : Double
  byterange : HlsByteRange?
  /// `EXT-X-DISCONTINUITY` before this segment.
  discontinuity : Bool
  /// `EXT-X-GAP`: the segment is advertised but its resource is absent.
  gap : Bool
  /// Raw `EXT-X-PROGRAM-DATE-TIME` value; empty omits the tag.
  program_date_time : String
}

///|
pub fn HlsMediaSegmentSpec::new(
  uri : String,
  duration : Double,
  byterange~ : HlsByteRange? = None,
  discontinuity~ : Bool = false,
  gap~ : Bool = false,
  program_date_time~ : String = "",
) -> HlsMediaSegmentSpec {
  { uri, duration, byterange, discontinuity, gap, program_date_time, }
}

///|
/// `<length>[@<offset>]` used by both `EXT-X-BYTERANGE` and the `BYTERANGE`
/// attribute of `EXT-X-MAP`.
fn hls_mux_byterange_value(range : HlsByteRange) -> String {
  if range.offset >= 0L {
    "\{range.length}@\{range.offset}"
  } else {
    "\{range.length}"
  }
}

///|
/// `EXT-X-BYTERANGE:<length>[@<offset>]`.
fn hls_mux_byterange_tag(range : HlsByteRange) -> String {
  "#EXT-X-BYTERANGE:" + hls_mux_byterange_value(range)
}

///|
/// Shared media-playlist writer over pre-resolved segment specs.
fn hls_write_media_playlist_impl(
  segments : ArrayView[HlsMediaSegmentSpec],
  target_duration : Int32,
  media_sequence : Int64,
  discontinuity_sequence : Int64,
  version : Int32,
  allow_cache : Int32,
  playlist_type : String,
  i_frames_only : Bool,
  independent_segments : Bool,
  endlist : Bool,
  map_uri : String?,
  map_byterange : HlsByteRange?,
  key_uri : String?,
  key_iv : Bytes?,
) -> String {
  let mut max_duration = 0.0
  for entry in segments {
    if entry.duration > max_duration {
      max_duration = entry.duration
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
  if allow_cache == 0 {
    sb.write_string("#EXT-X-ALLOW-CACHE:NO\n")
  } else if allow_cache == 1 {
    sb.write_string("#EXT-X-ALLOW-CACHE:YES\n")
  }
  if discontinuity_sequence != 0L {
    sb.write_string("#EXT-X-DISCONTINUITY-SEQUENCE:\{discontinuity_sequence}\n")
  }
  sb.write_string("#EXT-X-TARGETDURATION:\{target}\n")
  sb.write_string("#EXT-X-MEDIA-SEQUENCE:\{media_sequence}\n")
  if playlist_type != "" {
    sb.write_string("#EXT-X-PLAYLIST-TYPE:" + playlist_type + "\n")
  }
  if i_frames_only {
    sb.write_string("#EXT-X-I-FRAMES-ONLY\n")
  }
  if independent_segments {
    sb.write_string("#EXT-X-INDEPENDENT-SEGMENTS\n")
  }
  match key_uri {
    Some(uri) => {
      sb.write_string("#EXT-X-KEY:METHOD=AES-128,URI=\"" + uri + "\"")
      match key_iv {
        Some(iv) =>
          if iv.length() == 16 {
            sb.write_string(",IV=0x" + hls_mux_hex(iv))
          }
        None => ()
      }
      sb.write_string("\n")
    }
    None => ()
  }
  match map_uri {
    Some(uri) => {
      sb.write_string("#EXT-X-MAP:URI=\"" + uri + "\"")
      match map_byterange {
        Some(range) => {
          sb.write_string(",BYTERANGE=\"")
          sb.write_string(hls_mux_byterange_value(range))
          sb.write_string("\"")
        }
        None => ()
      }
      sb.write_string("\n")
    }
    None => ()
  }
  for entry in segments {
    if entry.discontinuity {
      sb.write_string("#EXT-X-DISCONTINUITY\n")
    }
    if entry.gap {
      sb.write_string("#EXT-X-GAP\n")
    }
    sb.write_string("#EXTINF:\{entry.duration},\n")
    match entry.byterange {
      Some(range) => {
        sb.write_string(hls_mux_byterange_tag(range))
        sb.write_string("\n")
      }
      None => ()
    }
    // hlsplaylist.c writes the date after EXTINF/BYTERANGE.
    if entry.program_date_time != "" {
      sb.write_string("#EXT-X-PROGRAM-DATE-TIME:")
      sb.write_string(entry.program_date_time)
      sb.write_string("\n")
    }
    sb.write_string(entry.uri)
    sb.write_string("\n")
  }
  if endlist {
    sb.write_string("#EXT-X-ENDLIST\n")
  }
  sb.to_string()
}

///|
/// Write a VOD-style media playlist. `target_duration` 0 means "use the
/// ceiling of the largest segment duration".
pub fn hls_write_media_playlist(
  segments : ArrayView[(String, Double)],
  target_duration~ : Int32 = 0,
  media_sequence~ : Int64 = 0L,
  version~ : Int32 = 3,
  allow_cache~ : Int32 = -1,
  playlist_type~ : String = "",
  i_frames_only~ : Bool = false,
  independent_segments~ : Bool = false,
  endlist~ : Bool = true,
  map_uri~ : String? = None,
  key_uri~ : String? = None,
  key_iv~ : Bytes? = None,
) -> String {
  let entries : Array[HlsMediaSegmentSpec] = []
  for entry in segments {
    entries.push(HlsMediaSegmentSpec::new(entry.0, entry.1))
  }
  hls_write_media_playlist_impl(
    entries,
    target_duration,
    media_sequence,
    0L,
    version,
    allow_cache,
    playlist_type,
    i_frames_only,
    independent_segments,
    endlist,
    map_uri,
    None,
    key_uri,
    key_iv,
  )
}

///|
/// Write a VOD media playlist from full segment specs. `EXT-X-BYTERANGE` is
/// emitted for entries that carry a range, and each entry may add
/// `EXT-X-DISCONTINUITY`, `EXT-X-GAP` and `EXT-X-PROGRAM-DATE-TIME`.
/// `allow_cache` 0/1 write `EXT-X-ALLOW-CACHE:NO/YES`, other values omit it;
/// `playlist_type` is written verbatim ("VOD"/"EVENT") when non-empty.
pub fn hls_write_media_playlist_specs(
  segments : ArrayView[HlsMediaSegmentSpec],
  target_duration~ : Int32 = 0,
  media_sequence~ : Int64 = 0L,
  discontinuity_sequence~ : Int64 = 0L,
  version~ : Int32 = 3,
  allow_cache~ : Int32 = -1,
  playlist_type~ : String = "",
  i_frames_only~ : Bool = false,
  independent_segments~ : Bool = false,
  endlist~ : Bool = true,
  map_uri~ : String? = None,
  map_byterange~ : HlsByteRange? = None,
  key_uri~ : String? = None,
  key_iv~ : Bytes? = None,
) -> String {
  hls_write_media_playlist_impl(
    segments, target_duration, media_sequence, discontinuity_sequence, version, allow_cache,
    playlist_type, i_frames_only, independent_segments, endlist, map_uri, map_byterange,
    key_uri, key_iv,
  )
}

///|
/// Write a VOD media playlist whose segments are byte ranges, optionally all
/// inside one resource. `EXT-X-BYTERANGE` requires version 4, so a lower
/// requested version is raised to 4.
pub fn hls_write_media_playlist_byterange(
  segments : ArrayView[HlsMediaSegmentSpec],
  target_duration~ : Int32 = 0,
  media_sequence~ : Int64 = 0L,
  discontinuity_sequence~ : Int64 = 0L,
  version~ : Int32 = 4,
  allow_cache~ : Int32 = -1,
  playlist_type~ : String = "",
  i_frames_only~ : Bool = false,
  independent_segments~ : Bool = false,
  endlist~ : Bool = true,
  map_uri~ : String? = None,
  map_byterange~ : HlsByteRange? = None,
  key_uri~ : String? = None,
  key_iv~ : Bytes? = None,
) -> String {
  hls_write_media_playlist_specs(
    segments,
    target_duration~,
    media_sequence~,
    discontinuity_sequence~,
    version=if version < 4 { 4 } else { version },
    allow_cache~,
    playlist_type~,
    i_frames_only~,
    independent_segments~,
    endlist~,
    map_uri~,
    map_byterange~,
    key_uri~,
    key_iv~,
  )
}

///|
/// Uppercase hex used by `EXT-X-KEY` IV attributes.
fn hls_mux_hex(data : Bytes) -> String {
  let hex = "0123456789ABCDEF"
  let sb = StringBuilder()
  for b in data {
    sb.write_char(hex.get_char((b.to_int() >> 4) & 15).unwrap())
    sb.write_char(hex.get_char(b.to_int() & 15).unwrap())
  }
  sb.to_string()
}

///|
/// One `EXT-X-STREAM-INF` entry. `audio_group` empty omits the AUDIO
/// attribute; otherwise it names an `EXT-X-MEDIA` audio group.
pub struct HlsMasterVariant {
  uri : String
  bandwidth : Int32
  /// `AVERAGE-BANDWIDTH`; 0 omits the attribute.
  average_bandwidth : Int32
  width : Int32
  height : Int32
  codecs : String
  audio_group : String
  /// `CLOSED-CAPTIONS` attribute naming an `EXT-X-MEDIA` captions group.
  closed_captions_group : String
  /// `SUBTITLES` attribute naming an `EXT-X-MEDIA` subtitle group.
  subtitle_group : String
}

///|
/// One `EXT-X-MEDIA` rendition (audio, subtitles, closed captions, ...).
pub struct HlsMasterRendition {
  type_ : String
  group_id : String
  name : String
  language : String
  is_default : Bool
  autoselect : Bool
  /// `FORCED=YES` on subtitle renditions; false omits the attribute.
  forced : Bool
  channels : String
  /// `INSTREAM-ID` for `TYPE=CLOSED-CAPTIONS` (in-band stream, no URI).
  instream_id : String
  uri : String
}

///|
pub fn HlsMasterVariant::new(
  uri : String,
  bandwidth : Int32,
  width : Int32,
  height : Int32,
  codecs : String,
  audio_group~ : String = "",
  subtitle_group~ : String = "",
  average_bandwidth~ : Int32 = 0,
  closed_captions_group~ : String = "",
) -> HlsMasterVariant {
  {
    uri,
    bandwidth,
    average_bandwidth,
    width,
    height,
    codecs,
    audio_group,
    closed_captions_group,
    subtitle_group,
  }
}

///|
pub fn HlsMasterRendition::new(
  type_ : String,
  group_id : String,
  name : String,
  uri : String,
  language~ : String = "",
  is_default~ : Bool = false,
  autoselect~ : Bool = true,
  channels~ : String = "",
  forced~ : Bool = false,
  instream_id~ : String = "",
) -> HlsMasterRendition {
  {
    type_,
    group_id,
    name,
    language,
    is_default,
    autoselect,
    forced,
    channels,
    instream_id,
    uri,
  }
}

///|
/// Write a master playlist with optional `EXT-X-MEDIA` renditions.
pub fn hls_write_master_playlist(
  variants : ArrayView[HlsMasterVariant],
  renditions~ : ArrayView[HlsMasterRendition] = [],
  version~ : Int32 = 3,
) -> String {
  let sb = StringBuilder()
  sb.write_string("#EXTM3U\n")
  sb.write_string("#EXT-X-VERSION:\{version}\n")
  for r in renditions {
    sb.write_string(
      "#EXT-X-MEDIA:TYPE=\{r.type_},GROUP-ID=\"\{r.group_id}\",NAME=\"\{r.name}\"",
    )
    if r.language != "" {
      sb.write_string(",LANGUAGE=\"" + r.language + "\"")
    }
    if r.type_ == "CLOSED-CAPTIONS" {
      // In-band captions carry INSTREAM-ID and no URI, as hlsenc writes them.
      if r.instream_id != "" {
        sb.write_string(",INSTREAM-ID=\"" + r.instream_id + "\"")
      }
      sb.write_string("\n")
      continue
    }
    let default_attr = if r.is_default { "YES" } else { "NO" }
    let autoselect_attr = if r.autoselect { "YES" } else { "NO" }
    sb.write_string(",DEFAULT=" + default_attr)
    sb.write_string(",AUTOSELECT=" + autoselect_attr)
    if r.forced {
      sb.write_string(",FORCED=YES")
    }
    if r.channels != "" {
      sb.write_string(",CHANNELS=\"" + r.channels + "\"")
    }
    sb.write_string(",URI=\"" + r.uri + "\"\n")
  }
  for variant in variants {
    sb.write_string("#EXT-X-STREAM-INF:BANDWIDTH=\{variant.bandwidth}")
    if variant.average_bandwidth > 0 {
      sb.write_string(",AVERAGE-BANDWIDTH=\{variant.average_bandwidth}")
    }
    if variant.width > 0 && variant.height > 0 {
      sb.write_string(",RESOLUTION=\{variant.width}x\{variant.height}")
    }
    if variant.codecs != "" {
      sb.write_string(",CODECS=\"\{variant.codecs}\"")
    }
    if variant.audio_group != "" {
      sb.write_string(",AUDIO=\"" + variant.audio_group + "\"")
    }
    if variant.closed_captions_group != "" {
      sb.write_string(
        ",CLOSED-CAPTIONS=\"" + variant.closed_captions_group + "\"",
      )
    }
    if variant.subtitle_group != "" {
      sb.write_string(",SUBTITLES=\"" + variant.subtitle_group + "\"")
    }
    sb.write_string("\n")
    sb.write_string(variant.uri)
    sb.write_string("\n")
  }
  sb.to_string()
}
