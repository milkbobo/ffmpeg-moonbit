///|
/// Container → codec-parameter bridge.
///
/// This is the MoonBit equivalent of what `mov_read_trak` / `matroska_parse_tracks`
/// hand to `avcodec_parameters_from_context`: it combines the container's
/// declared geometry/sample rate with the codec-specific extradata parser
/// (`avcC`/`hvcC`/AudioSpecificConfig) from libavcodec. MP4/MOV and Matroska
/// therefore expose the same `CodecParameters` shape used by this port.
///
/// `H264Sps`/`HevcSps` are parsed copies: the parameter-set store lives in
/// libavcodec and is not retained in `CodecParameters`.

///|
/// Codec parameters as far as the demuxing slices need them. */
pub struct CodecParameters {
  /// FFmpeg codec name ("h264", "hevc", "aac", "mp3", ...).
  codec : String
  /// Numeric profile (H.264/HEVC profile_idc, AAC object type); 0 unknown.
  mut profile : Int32
  /// Level (H.264 level_idc or HEVC general_level_idc); 0 unknown.
  mut level : Int32
  mut width : Int32
  mut height : Int32
  /// Chroma format (0 mono, 1 4:2:0, 2 4:2:2, 3 4:4:4).
  mut chroma_format : Int32
  mut bit_depth : Int32
  /// FFmpeg pixel-format name ("yuv420p", "yuv420p10le", ...).
  mut pix_fmt : String
  mut sample_rate : Int32
  mut channels : Int32
  /// PCM samples per frame (AAC 1024, MP3 1152/576); 0 for video.
  mut frame_size : Int32
  /// Frame rate from the H.264/HEVC VUI, as a rational; 0/0 when absent.
  mut fps_num : Int32
  mut fps_den : Int32
  /// Sample aspect ratio from the VUI; 0/1 when unspecified.
  mut sar_num : Int32
  mut sar_den : Int32
  /// True when the codec-specific extradata was successfully parsed.
  mut extradata_parsed : Bool
}

///|
/// Empty parameters with a codec name. */
fn new_codec_parameters(codec : String) -> CodecParameters {
  {
    codec,
    profile: 0,
    level: 0,
    width: 0,
    height: 0,
    chroma_format: 0,
    bit_depth: 0,
    pix_fmt: "",
    sample_rate: 0,
    channels: 0,
    frame_size: 0,
    fps_num: 0,
    fps_den: 0,
    sar_num: 0,
    sar_den: 1,
    extradata_parsed: false,
  }
}

///|
/// FFmpeg's native-endian pixel-format names for 4:2:0/4:2:2/4:4:4/gray. */
fn pix_fmt_name(chroma : Int32, depth : Int32) -> String {
  let base = match chroma {
    0 => "gray"
    1 => "yuv420p"
    2 => "yuv422p"
    3 => "yuv444p"
    _ => ""
  }
  if base == "" {
    return ""
  }
  if depth == 8 {
    base
  } else {
    let suffix = "le"
    base + depth.to_string() + suffix
  }
}

///|
/// Find the first SPS in the id-indexed store (C's `ps->sps_list` walk). */
fn first_h264_sps(ps : @libavcodec.H264ParamSets) -> @libavcodec.H264Sps? {
  for i = 0; i < @libavcodec.max_sps_count; i = i + 1 {
    match ps.sps_list[i] {
      Some(sps) => return Some(sps)
      None => ()
    }
  }
  None
}

///|
/// Find the first HEVC SPS. */
fn first_hevc_sps(ps : @libavcodec.HevcParamSets) -> @libavcodec.HevcSps? {
  for i = 0; i < @libavcodec.hevc_max_sps_count; i = i + 1 {
    match ps.sps_list[i] {
      Some(sps) => return Some(sps)
      None => ()
    }
  }
  None
}

///|
/// Parse `extradata` for `codec` and merge it with the container-declared
/// dimensions/sample rate. Failure to parse is not fatal: the container
/// fields are returned with `extradata_parsed = false`.
pub fn codec_parameters_from_extradata(
  codec : String,
  extradata : Bytes?,
  width : Int32,
  height : Int32,
  sample_rate : Int32,
  channels : Int32,
) -> CodecParameters {
  let p = new_codec_parameters(codec)
  p.width = width
  p.height = height
  p.sample_rate = sample_rate
  p.channels = channels
  let extra = match extradata {
    Some(b) => b
    None => return p
  }
  if extra.length() == 0 {
    return p
  }
  if codec == "h264" {
    let ps = @libavcodec.new_h264_param_sets()
    match @libavcodec.ff_h264_decode_extradata(extra, ps) {
      Err(_) => return p
      Ok(_) => ()
    }
    match first_h264_sps(ps) {
      None => return p
      Some(sps) => {
        p.profile = sps.profile_idc
        p.level = sps.level_idc
        p.chroma_format = sps.chroma_format_idc
        p.bit_depth = sps.bit_depth_luma
        p.pix_fmt = pix_fmt_name(sps.chroma_format_idc, sps.bit_depth_luma)
        let w = 16 * sps.mb_width - sps.crop_left - sps.crop_right
        let h = 16 * sps.mb_height - sps.crop_top - sps.crop_bottom
        if w > 0 {
          p.width = w
        }
        if h > 0 {
          p.height = h
        }
        if sps.timing_info_present_flag != 0 && sps.num_units_in_tick > 0 {
          p.fps_num = sps.time_scale
          p.fps_den = 2 * sps.num_units_in_tick
        }
        p.sar_num = sps.vui.sar_num
        p.sar_den = sps.vui.sar_den
        p.extradata_parsed = true
      }
    }
  } else if codec == "hevc" {
    let ps = @libavcodec.new_hevc_param_sets()
    match @libavcodec.ff_hevc_decode_extradata(extra, ps, true) {
      Err(_) => return p
      Ok(_) => ()
    }
    match first_hevc_sps(ps) {
      None => return p
      Some(sps) => {
        p.profile = sps.ptl.general_ptl.profile_idc
        p.level = sps.ptl.general_ptl.level_idc
        p.chroma_format = sps.chroma_format_idc
        p.bit_depth = sps.bit_depth
        p.pix_fmt = sps.pix_fmt
        let w = sps.width -
          sps.output_window.left_offset -
          sps.output_window.right_offset
        let h = sps.height -
          sps.output_window.top_offset -
          sps.output_window.bottom_offset
        if w > 0 {
          p.width = w
        }
        if h > 0 {
          p.height = h
        }
        if sps.vui.vui_timing_info_present_flag != 0 &&
          sps.vui.vui_num_units_in_tick > 0 {
          p.fps_num = sps.vui.vui_time_scale
          p.fps_den = sps.vui.vui_num_units_in_tick
        }
        p.sar_num = sps.vui.common.sar_num
        p.sar_den = sps.vui.common.sar_den
        p.extradata_parsed = true
      }
    }
  } else if codec == "aac" {
    let mut cfg = @libavcodec.new_mpeg4_audio_config()
    match @libavcodec.ff_mpeg4audio_get_config(cfg, extra, true) {
      Err(_) => return p
      Ok(_) => ()
    }
    if cfg.object_type == 2 && cfg.chan_config == 0 {
      match @libavcodec.aac_parse_audio_specific_config(extra) {
        Ok(parsed) => cfg = parsed.config
        Err(_) => return p
      }
    }
    p.profile = cfg.object_type
    if cfg.sample_rate > 0 {
      p.sample_rate = cfg.sample_rate
    }
    if cfg.channels > 0 {
      p.channels = cfg.channels
    }
    p.frame_size = cfg.frame_length
    p.extradata_parsed = true
  }
  p
}

///|
/// UInt64 → Int for container fields, clamping out-of-range values to 0. */
fn u64_to_int(v : UInt64) -> Int32 {
  if v <= 2147483647UL {
    v.to_int()
  } else {
    0
  }
}

///|
/// Matroska track → codec parameters. `<unset>` display dimensions (all ones)
/// fall back to the pixel dimensions, matching what ffprobe reports.
pub fn mkv_track_codec_parameters(track : MkvTrack) -> CodecParameters {
  let raw = match track.codec_id {
    Some(s) => s
    None => ""
  }
  let codec = ff_mkv_codec_id(raw)
  let mut width = 0
  let mut height = 0
  if track.track_type == mkv_track_type_video {
    width = if track.video.display_width == 0xFFFFFFFFFFFFFFFFUL {
      u64_to_int(track.video.pixel_width)
    } else {
      u64_to_int(track.video.display_width)
    }
    height = if track.video.display_height == 0xFFFFFFFFFFFFFFFFUL {
      u64_to_int(track.video.pixel_height)
    } else {
      u64_to_int(track.video.display_height)
    }
  }
  let sample_rate = if track.track_type == mkv_track_type_audio {
    track.audio.samplerate.to_int()
  } else {
    0
  }
  let channels = if track.track_type == mkv_track_type_audio {
    u64_to_int(track.audio.channels)
  } else {
    0
  }
  codec_parameters_from_extradata(
    codec,
    track.codec_priv,
    width,
    height,
    sample_rate,
    channels,
  )
}

///|
/// MP4/MOV track → codec parameters. */
pub fn mp4_track_codec_parameters(track : Mp4Track) -> CodecParameters {
  let codec = mov_codec_name(track.codec, track.codec_id)
  let sample_rate = if track.sample_rate <= 2147483647U {
    track.sample_rate.reinterpret_as_int()
  } else {
    0
  }
  let channels = if track.channels <= 2147483647U {
    track.channels.reinterpret_as_int()
  } else {
    0
  }
  codec_parameters_from_extradata(
    codec,
    track.extradata,
    track.width,
    track.height,
    sample_rate,
    channels,
  )
}
