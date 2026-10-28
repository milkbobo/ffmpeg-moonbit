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
  map_uri~ : String? = None,
  key_uri~ : String? = None,
  key_iv~ : Bytes? = None,
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
    Some(uri) => sb.write_string("#EXT-X-MAP:URI=\"" + uri + "\"\n")
    None => ()
  }
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
) -> HlsMasterVariant {
  { uri, bandwidth, width, height, codecs, audio_group, }
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
    sb.write_string("\n")
    sb.write_string(variant.uri)
    sb.write_string("\n")
  }
  sb.to_string()
}
