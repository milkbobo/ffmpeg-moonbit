///|
/// Matroska/WebM slice 3: Tracks — the `TrackEntry` family of
/// `libavformat/matroskadec.c` (`matroska_tracks[]`, `matroska_track[]`,
/// `matroska_track_video[]`, `matroska_track_audio[]`,
/// `matroska_track_encodings[]`, `matroska_block_addition_mapping[]`).
///
/// Out of scope (later slices, per README): TrackOperation (3D plane
/// combining), VideoColour/VideoProjection masters and content encryption —
/// recognised and skipped. Content encodings are parsed into records but not
/// applied (header stripping happens at block demux).

// ---------------------------------------------------------------------------
// element ids (matroska.h)
// ---------------------------------------------------------------------------

pub let matroska_id_trackentry : UInt32 = 0xAE

///|
pub let matroska_id_tracknumber : UInt32 = 0xD7

///|
pub let matroska_id_trackuid : UInt32 = 0x73C5

///|
pub let matroska_id_tracktype : UInt32 = 0x83

///|
pub let matroska_id_trackvideo : UInt32 = 0xE0

///|
pub let matroska_id_trackaudio : UInt32 = 0xE1

///|
pub let matroska_id_trackoperation : UInt32 = 0xE2

///|
pub let matroska_id_codecid : UInt32 = 0x86

///|
pub let matroska_id_codecprivate : UInt32 = 0x63A2

///|
pub let matroska_id_codecdelay : UInt32 = 0x56AA

///|
pub let matroska_id_seekpreroll : UInt32 = 0x56BB

///|
pub let matroska_id_trackname : UInt32 = 0x536E

///|
pub let matroska_id_tracklanguage : UInt32 = 0x22B59C

///|
pub let matroska_id_trackflagdefault : UInt32 = 0x88

///|
pub let matroska_id_trackflagforced : UInt32 = 0x55AA

///|
pub let matroska_id_trackflaghearingimpaired : UInt32 = 0x55AB

///|
pub let matroska_id_trackflagvisualimpaired : UInt32 = 0x55AC

///|
pub let matroska_id_trackflagtextdescriptions : UInt32 = 0x55AD

///|
pub let matroska_id_trackflagoriginal : UInt32 = 0x55AE

///|
pub let matroska_id_trackflagcommentary : UInt32 = 0x55AF

///|
pub let matroska_id_trackdefaultduration : UInt32 = 0x23E383

///|
pub let matroska_id_trackcontentencodings : UInt32 = 0x6D80

///|
pub let matroska_id_trackcontentencoding : UInt32 = 0x6240

///|
pub let matroska_id_tracktimecodescale : UInt32 = 0x23314F

///|
pub let matroska_id_trackmaxblkaddid : UInt32 = 0x55EE

///|
pub let matroska_id_trackblkaddmapping : UInt32 = 0x41E4

///|
pub let matroska_id_videoframerate : UInt32 = 0x2383E3

///|
pub let matroska_id_videodisplaywidth : UInt32 = 0x54B0

///|
pub let matroska_id_videodisplayheight : UInt32 = 0x54BA

///|
pub let matroska_id_videopixelwidth : UInt32 = 0xB0

///|
pub let matroska_id_videopixelheight : UInt32 = 0xBA

///|
pub let matroska_id_videopixelcropb : UInt32 = 0x54AA

///|
pub let matroska_id_videopixelcropt : UInt32 = 0x54BB

///|
pub let matroska_id_videopixelcropl : UInt32 = 0x54CC

///|
pub let matroska_id_videopixelcropr : UInt32 = 0x54DD

///|
pub let matroska_id_videodisplayunit : UInt32 = 0x54B2

///|
pub let matroska_id_videoflaginterlaced : UInt32 = 0x9A

///|
pub let matroska_id_videofieldorder : UInt32 = 0x9D

///|
pub let matroska_id_videostereomode : UInt32 = 0x53B8

///|
pub let matroska_id_videoalphamode : UInt32 = 0x53C0

///|
pub let matroska_id_videocolorspace : UInt32 = 0x2EB524

///|
pub let matroska_id_audiosamplingfreq : UInt32 = 0xB5

///|
pub let matroska_id_audiooutsamplingfreq : UInt32 = 0x78B5

///|
pub let matroska_id_audiobitdepth : UInt32 = 0x6264

///|
pub let matroska_id_audiochannels : UInt32 = 0x9F

///|
pub let matroska_id_encodingscope : UInt32 = 0x5032

///|
pub let matroska_id_encodingtype : UInt32 = 0x5033

///|
pub let matroska_id_encodingcompression : UInt32 = 0x5034

///|
pub let matroska_id_encodingcompalgo : UInt32 = 0x4254

///|
pub let matroska_id_encodingcompsettings : UInt32 = 0x4255

///|
pub let matroska_id_blkaddidvalue : UInt32 = 0x41E7

///|
pub let matroska_id_blkaddidname : UInt32 = 0x41E6

///|
pub let matroska_id_blkaddidtype : UInt32 = 0x41E5

///|
pub let matroska_id_blkaddidextradata : UInt32 = 0x41E8

///|
/// `MatroskaTrackType`: 1 video, 2 audio, 3 complex, 16 logo, 17 subtitle,
/// 18 buttons, 32 control. */
pub let mkv_track_type_video : UInt64 = 1

///|
pub let mkv_track_type_audio : UInt64 = 2

///|
pub let mkv_track_type_subtitle : UInt64 = 17

///|
/// `MATROSKA_TRACK_ENCODING_COMP_*`: 0 zlib, 1 bzlib, 2 lzo1x, 3 header
/// strip. */
pub let mkv_comp_header_strip : UInt64 = 3

// ---------------------------------------------------------------------------
// data model
// ---------------------------------------------------------------------------

///|
/// `MatroskaTrackVideo` (the fields this slice consumes; colour/projection
/// masters are skipped). */
pub struct MkvTrackVideo {
  mut frame_rate : Double
  /// Display dimensions default to -1 ("unset") as in the C.
  mut display_width : UInt64
  mut display_height : UInt64
  mut pixel_width : UInt64
  mut pixel_height : UInt64
  mut pixel_crop_bottom : UInt64
  mut pixel_crop_top : UInt64
  mut pixel_crop_left : UInt64
  mut pixel_crop_right : UInt64
  mut display_unit : UInt64
  mut interlaced : UInt64
  mut field_order : UInt64
  mut stereo_mode : UInt64
  mut alpha_mode : UInt64
  mut color_space : Bytes?
}

///|
/// `MatroskaTrackAudio`. */
pub struct MkvTrackAudio {
  /// SamplingFrequency, default 8000.0.
  mut samplerate : Double
  /// OutputSamplingFrequency.
  mut out_samplerate : Double
  mut bitdepth : UInt64
  /// Channels, default 1.
  mut channels : UInt64
}

///|
/// `MatroskaTrackEncoding` (compression only; encryption is skipped). */
pub struct MkvTrackEncoding {
  /// ContentEncodingScope, default 1.
  mut scope : UInt64
  /// ContentEncodingType, default 0 (compression).
  mut encoding_type : UInt64
  /// ContentCompAlgo, default 0 (zlib).
  mut comp_algo : UInt64
  /// ContentCompSettings raw bytes.
  mut comp_settings : Bytes?
}

///|
/// `MatroskaBlockAdditionMapping`. */
pub struct MkvBlockAddition {
  mut value : UInt64
  mut name : String?
  /// ContentElemType, default 0.
  mut elem_type : UInt64
  mut extradata : Bytes?
}

///|
/// `MatroskaTrack` (the fields this slice consumes). */
pub struct MkvTrack {
  /// TrackNumber.
  mut num : UInt64
  mut name : String?
  /// TrackUID.
  mut uid : UInt64
  /// TrackType (see `mkv_track_type_*`).
  mut track_type : UInt64
  /// CodecID string ("V_VP9", "A_OPUS", ...).
  mut codec_id : String?
  /// CodecPrivate payload (extradata).
  mut codec_priv : Bytes?
  /// CodecDelay, in time_scale units.
  mut codec_delay : UInt64
  /// TrackLanguage, default "eng".
  mut language : String
  /// DefaultDuration (ns).
  mut default_duration : UInt64
  /// TrackTimecodeScale, default 1.0.
  mut time_scale : Double
  mut flag_commentary : UInt64
  /// TrackFlagDefault, default 1.
  mut flag_default : UInt64
  mut flag_forced : UInt64
  mut flag_hearingimpaired : UInt64
  mut flag_visualimpaired : UInt64
  mut flag_textdescriptions : UInt64
  mut flag_original : UInt64
  /// MaxBlockAdditionID.
  mut max_block_additional_id : UInt64
  /// SeekPreRoll.
  mut seek_preroll : UInt64
  video : MkvTrackVideo
  audio : MkvTrackAudio
  encodings : Array[MkvTrackEncoding]
  block_additions : Array[MkvBlockAddition]
}

///|
/// A track with the table defaults applied (the C's zero-init plus the
/// `ebml_parse_nest` pre-pass).
fn new_mkv_track() -> MkvTrack {
  {
    num: 0,
    name: None,
    uid: 0,
    track_type: 0,
    codec_id: None,
    codec_priv: None,
    codec_delay: 0,
    language: "eng",
    default_duration: 0,
    time_scale: 1.0,
    flag_commentary: 0,
    flag_default: 1,
    flag_forced: 0,
    flag_hearingimpaired: 0,
    flag_visualimpaired: 0,
    flag_textdescriptions: 0,
    flag_original: 0,
    max_block_additional_id: 0,
    seek_preroll: 0,
    video: {
      frame_rate: 0.0,
      display_width: 0xFFFFFFFFFFFFFFFFUL, // -1: unset
      display_height: 0xFFFFFFFFFFFFFFFFUL,
      pixel_width: 0,
      pixel_height: 0,
      pixel_crop_bottom: 0,
      pixel_crop_top: 0,
      pixel_crop_left: 0,
      pixel_crop_right: 0,
      display_unit: 0,
      interlaced: 0,
      field_order: 0,
      stereo_mode: 0,
      alpha_mode: 0,
      color_space: None,
    },
    audio: {
      samplerate: 8000.0,
      out_samplerate: 0.0,
      bitdepth: 0,
      channels: 1,
    },
    encodings: [],
    block_additions: [],
  }
}

// ---------------------------------------------------------------------------
// table factories
// ---------------------------------------------------------------------------

///|
/// A scalar sink helper: match and assign, or `EINVAL` on a kind mismatch. */
fn sink_u64(
  dst : (UInt64) -> Unit,
) -> (EbmlValue, Int64) -> Result[Unit, String] {
  (v, _) => {
    match v {
      U(u) => {
        dst(u)
        Ok(())
      }
      _ => Err("EINVAL")
    }
  }
}

///|
/// Float sink. */
fn sink_f64(
  dst : (Double) -> Unit,
) -> (EbmlValue, Int64) -> Result[Unit, String] {
  (v, _) => {
    match v {
      F(f) => {
        dst(f)
        Ok(())
      }
      _ => Err("EINVAL")
    }
  }
}

///|
/// String sink. */
fn sink_str(
  dst : (String) -> Unit,
) -> (EbmlValue, Int64) -> Result[Unit, String] {
  (v, _) => {
    match v {
      S(s) => {
        dst(s)
        Ok(())
      }
      _ => Err("EINVAL")
    }
  }
}

///|
/// Bytes sink. */
fn sink_bin(
  dst : (Bytes) -> Unit,
) -> (EbmlValue, Int64) -> Result[Unit, String] {
  (v, _) => {
    match v {
      B(b) => {
        dst(b)
        Ok(())
      }
      _ => Err("EINVAL")
    }
  }
}

///|
/// `matroska_track_video[]` (colour/projection masters skipped). */
fn matroska_track_video_table(t : MkvTrack) -> Array[EbmlSyntax] {
  // sinks write through `t.video.<f>`: MkvTrackVideo is a value struct, so a
  // captured local copy would lose every assignment
  [
    {
      id: matroska_id_videoframerate,
      kind: Float(0.0),
      sink: Some(sink_f64(f => t.video.frame_rate = f)),
    },
    {
      id: matroska_id_videodisplaywidth,
      kind: Uint(0xFFFFFFFFFFFFFFFFUL),
      sink: Some(sink_u64(u => t.video.display_width = u)),
    },
    {
      id: matroska_id_videodisplayheight,
      kind: Uint(0xFFFFFFFFFFFFFFFFUL),
      sink: Some(sink_u64(u => t.video.display_height = u)),
    },
    {
      id: matroska_id_videopixelwidth,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_width = u)),
    },
    {
      id: matroska_id_videopixelheight,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_height = u)),
    },
    {
      id: matroska_id_videopixelcropb,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_crop_bottom = u)),
    },
    {
      id: matroska_id_videopixelcropt,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_crop_top = u)),
    },
    {
      id: matroska_id_videopixelcropl,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_crop_left = u)),
    },
    {
      id: matroska_id_videopixelcropr,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.pixel_crop_right = u)),
    },
    {
      id: matroska_id_videodisplayunit,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.display_unit = u)),
    },
    {
      id: matroska_id_videoflaginterlaced,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.interlaced = u)),
    },
    {
      id: matroska_id_videofieldorder,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.field_order = u)),
    },
    {
      id: matroska_id_videostereomode,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.stereo_mode = u)),
    },
    {
      id: matroska_id_videoalphamode,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.video.alpha_mode = u)),
    },
    {
      id: matroska_id_videocolorspace,
      kind: Bin,
      sink: Some(sink_bin(b => t.video.color_space = Some(b))),
    },
  ]
}

///|
/// `matroska_track_audio[]`. */
fn matroska_track_audio_table(t : MkvTrack) -> Array[EbmlSyntax] {
  // through `t.audio.<f>`: same value-struct reasoning as video
  [
    {
      id: matroska_id_audiosamplingfreq,
      kind: Float(8000.0),
      sink: Some(sink_f64(f => t.audio.samplerate = f)),
    },
    {
      id: matroska_id_audiooutsamplingfreq,
      kind: Float(0.0),
      sink: Some(sink_f64(f => t.audio.out_samplerate = f)),
    },
    {
      id: matroska_id_audiobitdepth,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.audio.bitdepth = u)),
    },
    {
      id: matroska_id_audiochannels,
      kind: Uint(1),
      sink: Some(sink_u64(u => t.audio.channels = u)),
    },
  ]
}

///|
/// `matroska_track_encoding_compression[]`. */
fn matroska_track_encoding_compression_table(
  e : MkvTrackEncoding,
) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_encodingcompalgo,
      kind: Uint(0),
      sink: Some(sink_u64(u => e.comp_algo = u)),
    },
    {
      id: matroska_id_encodingcompsettings,
      kind: Bin,
      sink: Some(sink_bin(b => e.comp_settings = Some(b))),
    },
  ]
}

///|
/// `matroska_track_encoding[]` (encryption skipped). */
fn matroska_track_encoding_table(e : MkvTrackEncoding) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_encodingscope,
      kind: Uint(1),
      sink: Some(sink_u64(u => e.scope = u)),
    },
    {
      id: matroska_id_encodingtype,
      kind: Uint(0),
      sink: Some(sink_u64(u => e.encoding_type = u)),
    },
    {
      id: matroska_id_encodingcompression,
      kind: Nest(() => matroska_track_encoding_compression_table(e)),
      sink: None,
    },
  ]
}

///|
/// `matroska_track_encodings[]`: one ContentEncoding per entry. */
fn matroska_track_encodings_table(t : MkvTrack) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_trackcontentencoding,
      kind: Nest(() => {
        let e : MkvTrackEncoding = {
          scope: 1,
          encoding_type: 0,
          comp_algo: 0,
          comp_settings: None,
        }
        t.encodings.push(e)
        matroska_track_encoding_table(t.encodings[t.encodings.length() - 1])
      }),
      sink: None,
    },
  ]
}

///|
/// `matroska_block_addition_mapping[]`. */
fn matroska_block_addition_table(t : MkvTrack) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_trackblkaddmapping,
      kind: Nest(() => {
        let b : MkvBlockAddition = {
          value: 0,
          name: None,
          elem_type: 0,
          extradata: None,
        }
        t.block_additions.push(b)
        let idx = t.block_additions.length() - 1
        let ba = t.block_additions[idx]
        [
          {
            id: matroska_id_blkaddidvalue,
            kind: Uint(0),
            sink: Some(sink_u64(u => ba.value = u)),
          },
          {
            id: matroska_id_blkaddidname,
            kind: Str(None),
            sink: Some(sink_str(s => ba.name = Some(s))),
          },
          {
            id: matroska_id_blkaddidtype,
            kind: Uint(0),
            sink: Some(sink_u64(u => ba.elem_type = u)),
          },
          {
            id: matroska_id_blkaddidextradata,
            kind: Bin,
            sink: Some(sink_bin(x => ba.extradata = Some(x))),
          },
        ]
      }),
      sink: None,
    },
  ]
}

///|
/// The EBML_NONE rows of `matroska_track[]` (skipped in the C). */
fn track_skip_ids() -> Array[UInt32] {
  [
    0xB9, // TrackFlagEnabled
     0x9C, // TrackFlagLacing
     0x258688, // CodecName
     0xAA, // CodecDecodeAll
     0x3B4040, // CodecInfoURL
     0x26B240, // CodecDownloadURL
     0x2D80, // TrackMinCache
     0x2DE84F, // TrackMaxCache
     0x54B3, // VideoAspectRatio
     0x5031, // EncodingOrder
  ]
}

///|
/// `matroska_track[]` for one TrackEntry. */
fn matroska_track_table(t : MkvTrack) -> Array[EbmlSyntax] {
  let rows : Array[EbmlSyntax] = [
    {
      id: matroska_id_tracknumber,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.num = u)),
    },
    {
      id: matroska_id_trackname,
      kind: Str(None),
      sink: Some(sink_str(s => t.name = Some(s))),
    },
    {
      id: matroska_id_trackuid,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.uid = u)),
    },
    {
      id: matroska_id_tracktype,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.track_type = u)),
    },
    {
      id: matroska_id_codecid,
      kind: Str(None),
      sink: Some(sink_str(s => t.codec_id = Some(s))),
    },
    {
      id: matroska_id_codecprivate,
      kind: Bin,
      sink: Some(sink_bin(b => t.codec_priv = Some(b))),
    },
    {
      id: matroska_id_codecdelay,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.codec_delay = u)),
    },
    {
      id: matroska_id_tracklanguage,
      kind: Str(Some("eng")),
      sink: Some(sink_str(s => t.language = s)),
    },
    {
      id: matroska_id_trackdefaultduration,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.default_duration = u)),
    },
    {
      id: matroska_id_tracktimecodescale,
      kind: Float(1.0),
      sink: Some(sink_f64(f => t.time_scale = f)),
    },
    {
      id: matroska_id_trackflagcommentary,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_commentary = u)),
    },
    {
      id: matroska_id_trackflagdefault,
      kind: Uint(1),
      sink: Some(sink_u64(u => t.flag_default = u)),
    },
    {
      id: matroska_id_trackflagforced,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_forced = u)),
    },
    {
      id: matroska_id_trackflaghearingimpaired,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_hearingimpaired = u)),
    },
    {
      id: matroska_id_trackflagvisualimpaired,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_visualimpaired = u)),
    },
    {
      id: matroska_id_trackflagtextdescriptions,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_textdescriptions = u)),
    },
    {
      id: matroska_id_trackflagoriginal,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.flag_original = u)),
    },
    {
      id: matroska_id_trackvideo,
      kind: Nest(() => matroska_track_video_table(t)),
      sink: None,
    },
    {
      id: matroska_id_trackaudio,
      kind: Nest(() => matroska_track_audio_table(t)),
      sink: None,
    },
    // TrackOperation (3D) and colour/projection are later slices; skip.
    { id: matroska_id_trackoperation, kind: Skip, sink: None, },
    {
      id: matroska_id_trackcontentencodings,
      kind: Nest(() => matroska_track_encodings_table(t)),
      sink: None,
    },
    {
      id: matroska_id_trackmaxblkaddid,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.max_block_additional_id = u)),
    },
    {
      id: matroska_id_seekpreroll,
      kind: Uint(0),
      sink: Some(sink_u64(u => t.seek_preroll = u)),
    },
  ]
  rows.push({
    id: matroska_id_trackblkaddmapping,
    kind: Nest(() => matroska_block_addition_table(t)),
    sink: None,
  })
  let ids = track_skip_ids()
  for i = 0; i < ids.length(); i = i + 1 {
    rows.push({ id: ids[i], kind: Skip, sink: None, })
  }
  rows
}

///|
/// `matroska_tracks[]`: one TrackEntry per TrackElement append. */
fn matroska_tracks_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_trackentry,
      kind: Nest(() => {
        let t = new_mkv_track()
        mh.tracks.push(t)
        matroska_track_table(mh.tracks[mh.tracks.length() - 1])
      }),
      sink: None,
    },
  ]
}
