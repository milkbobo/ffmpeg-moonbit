///|
/// Codec identifier mapping for the two containers ported so far.
///
/// * Matroska: `ff_mkv_codec_tags[]` from `libavformat/matroska.c` (WebM
///   restrictions are implicit in the IDs the muxer writes).
/// * MP4/MOV: the subset of `ff_codec_movvideo_tags[]` /
///   `ff_codec_movaudio_tags[]` (`libavformat/isom_tags.c`) covering the
///   codecs of this project plus the common neighbours.
///
/// The identifiers are FFmpeg's `AVCodecID` names (lower case: "h264",
/// "hevc", "aac", "mp3", ...). An unknown tag returns "".

///|
/// `ff_mkv_codec_tags`: Matroska CodecID → codec name.
pub fn ff_mkv_codec_id(codec_id : String) -> String {
  match codec_id {
    "A_AAC" => "aac"
    "A_AC3" => "ac3"
    "A_EAC3" => "eac3"
    "A_ALAC" => "alac"
    "A_DTS" => "dts"
    "A_FLAC" => "flac"
    "A_MLP" => "mlp"
    "A_MPEG/L1" => "mp1"
    "A_MPEG/L2" => "mp2"
    "A_MPEG/L3" => "mp3"
    "A_OPUS" => "opus"
    "A_OPUS/EXPERIMENTAL" => "opus"
    "A_TRUEHD" => "truehd"
    "A_TTA1" => "tta"
    "A_VORBIS" => "vorbis"
    "A_WAVPACK4" => "wavpack"
    "A_PCM/INT/LIT" => "pcm_s16le"
    "A_PCM/INT/BIG" => "pcm_s16be"
    "A_PCM/FLOAT/IEEE" => "pcm_f32le"
    "D_WEBVTT/SUBTITLES"
    | "D_WEBVTT/CAPTIONS"
    | "D_WEBVTT/DESCRIPTIONS"
    | "D_WEBVTT/METADATA" => "webvtt"
    "S_TEXT/UTF8" | "S_TEXT/ASCII" => "subrip"
    "S_TEXT/ASS" | "S_ASS" => "ass"
    "S_TEXT/SSA" | "S_SSA" => "ass"
    "S_VOBSUB" => "dvd_subtitle"
    "S_DVBSUB" => "dvb_subtitle"
    "S_HDMV/PGS" => "hdmv_pgs_subtitle"
    "V_AV1" => "av1"
    "V_AVS2" => "avs2"
    "V_AVS3" => "avs3"
    "V_DIRAC" => "dirac"
    "V_FFV1" => "ffv1"
    "V_JPEG2000" => "jpeg2000"
    "V_MJPEG" => "mjpeg"
    "V_MPEG1" => "mpeg1video"
    "V_MPEG2" => "mpeg2video"
    "V_MPEG4/ISO/ASP" | "V_MPEG4/ISO/AP" | "V_MPEG4/ISO/SP" => "mpeg4"
    "V_MPEG4/ISO/AVC" => "h264"
    "V_MPEGH/ISO/HEVC" => "hevc"
    "V_MPEGI/ISO/VVC" => "vvc"
    "V_MPEG4/MS/V3" => "msmpeg4v3"
    "V_PRORES" => "prores"
    "V_REAL/RV10" => "rv10"
    "V_REAL/RV20" => "rv20"
    "V_REAL/RV30" => "rv30"
    "V_REAL/RV40" => "rv40"
    "V_SNOW" => "snow"
    "V_THEORA" => "theora"
    "V_UNCOMPRESSED" => "rawvideo"
    "V_VP8" => "vp8"
    "V_VP9" => "vp9"
    _ => ""
  }
}

///|
/// MP4/MOV sample-entry fourcc → codec name. `codec_id` is the codec name
/// resolved from `esds` (the C's `mov_read_esds` sets it for `mp4a`), used to
/// distinguish MP3-in-MP4 from AAC.
pub fn mov_codec_name(codec : String, codec_id : String) -> String {
  match codec {
    "avc1" | "avc2" | "avc3" | "avc4" | "aivx" | "dvav" | "dva1" => "h264"
    "hev1" | "hvc1" | "dvhe" | "dvh1" => "hevc"
    "av01" => "av1"
    "vp08" => "vp8"
    "vp09" => "vp9"
    "mp4v" => "mpeg4"
    "jpeg" | "mjpa" | "mjpg" => "mjpeg"
    "mjpb" => "mjpegb"
    "png " => "png"
    "mp4a" => if codec_id != "" { codec_id } else { "aac" }
    ".mp3" | "mp3 " | "0x6D730055" => "mp3"
    "ac-3" => "ac3"
    "ec-3" => "eac3"
    "Opus" => "opus"
    "fLaC" => "flac"
    "alac" => "alac"
    "ima4" => "adpcm_ima_qt"
    "twos" => "pcm_s16be"
    "sowt" => "pcm_s16le"
    "raw " => "pcm_u8"
    "in24" => "pcm_s24le"
    "in32" => "pcm_s32le"
    "fl32" => "pcm_f32le"
    "fl64" => "pcm_f64le"
    "tx3g" => "mov_text"
    "wvtt" => "webvtt"
    _ => codec
  }
}
