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
  if discontinuity_sequence != 0L {
    sb.write_string("#EXT-X-DISCONTINUITY-SEQUENCE:\{discontinuity_sequence}\n")
  }
  sb.write_string("#EXT-X-TARGETDURATION:\{target}\n")
  sb.write_string("#EXT-X-MEDIA-SEQUENCE:\{media_sequence}\n")
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
pub fn hls_write_media_playlist_specs(
  segments : ArrayView[HlsMediaSegmentSpec],
  target_duration~ : Int32 = 0,
  media_sequence~ : Int64 = 0L,
  discontinuity_sequence~ : Int64 = 0L,
  version~ : Int32 = 3,
  endlist~ : Bool = true,
  map_uri~ : String? = None,
  map_byterange~ : HlsByteRange? = None,
  key_uri~ : String? = None,
  key_iv~ : Bytes? = None,
) -> String {
  hls_write_media_playlist_impl(
    segments, target_duration, media_sequence, discontinuity_sequence, version, endlist,
    map_uri, map_byterange, key_uri, key_iv,
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
  width : Int32
  height : Int32
  codecs : String
  audio_group : String
  /// `SUBTITLES` attribute naming an `EXT-X-MEDIA` subtitle group.
  subtitle_group : String
}

///|
/// One `EXT-X-MEDIA` rendition (audio, subtitles, ...).
pub struct HlsMasterRendition {
  type_ : String
  group_id : String
  name : String
  language : String
  is_default : Bool
  autoselect : Bool
  channels : String
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
) -> HlsMasterVariant {
  { uri, bandwidth, width, height, codecs, audio_group, subtitle_group, }
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
) -> HlsMasterRendition {
  { type_, group_id, name, language, is_default, autoselect, channels, uri, }
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
    let default_attr = if r.is_default { "YES" } else { "NO" }
    let autoselect_attr = if r.autoselect { "YES" } else { "NO" }
    sb.write_string(",DEFAULT=" + default_attr)
    sb.write_string(",AUTOSELECT=" + autoselect_attr)
    if r.channels != "" {
      sb.write_string(",CHANNELS=\"" + r.channels + "\"")
    }
    sb.write_string(",URI=\"" + r.uri + "\"\n")
  }
  for variant in variants {
    sb.write_string(
      "#EXT-X-STREAM-INF:BANDWIDTH=\{variant.bandwidth},RESOLUTION=\{variant.width}x\{variant.height},CODECS=\"\{variant.codecs}\"",
    )
    if variant.audio_group != "" {
      sb.write_string(",AUDIO=\"" + variant.audio_group + "\"")
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
