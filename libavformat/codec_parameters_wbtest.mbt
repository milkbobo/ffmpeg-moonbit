///|
/// White-box tests for the codec-tag mapping and the container → codec
/// parameter bridge.
///
/// The extradata vectors are the same docker-generated `linuxserver/ffmpeg:9.0.2`
/// records used by the libavcodec parameter-set tests (44-byte avcC from
/// `h264.mp4`, 108/109-byte hvcC from `hevc.mp4`/`hevc10.mp4`, and the AAC
/// AudioSpecificConfig `12 08 56 e5 00` from `aac.mp4`). The Matroska case
/// uses the real x264 MKV prefix already embedded by the EBML/Tracks slices
/// (`real_mkv_1024_b64`): CodecPrivate `avcC` (profile Baseline, level 1.0)
/// and 128x96 SPS geometry are cross-checked against ffprobe.

///| 44-byte avcC from h264.mp4 (High, level 3.0, 64x48).
let cp_avcc_b64 : Bytes =
  b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///| 108-byte hvcC with the real Main VPS/SPS/PPS arrays.
let cp_hvcc8_b64 : Bytes =
  b"AQFgAAAAkAAAAAAAHvAA/P34+AAADwOgAAEAGEABDAH//wFgAAADAJAAAAMAAAMAHpKAkKEAAQAoQgEBAWAAAAMAkAAAAwAAAwAeoCCDFlkq5MrwFoCAAAADAIAAAAMChKIAAQAGRAHBc9CJ"

///| 109-byte hvcC with the real Main10 arrays.
let cp_hvcc10_b64 : Bytes =
  b"AQIgAAAAkAAAAAAAHvAA/P36+gAADwOgAAEAGEABDAH//wIgAAADAJAAAAMAAAMAHpKAkKEAAQApQgEBAiAAAAMAkAAAAwAAAwAeoCCDE2WSrkyvAWgIAAADAAgAAAMAKECiAAEABkQBwXPQiQ=="

test "codec_parameters: Matroska codec tag table" {
  assert_eq(ff_mkv_codec_id("V_MPEG4/ISO/AVC"), "h264")
  assert_eq(ff_mkv_codec_id("V_MPEGH/ISO/HEVC"), "hevc")
  assert_eq(ff_mkv_codec_id("A_AAC"), "aac")
  assert_eq(ff_mkv_codec_id("A_MPEG/L3"), "mp3")
  assert_eq(ff_mkv_codec_id("A_MPEG/L2"), "mp2")
  assert_eq(ff_mkv_codec_id("V_VP9"), "vp9")
  assert_eq(ff_mkv_codec_id("A_OPUS"), "opus")
  assert_eq(ff_mkv_codec_id("S_TEXT/UTF8"), "subrip")
  assert_eq(ff_mkv_codec_id("V_TOTALLY_UNKNOWN"), "")
}

test "codec_parameters: MP4 sample-entry mapping" {
  assert_eq(mov_codec_name("avc1", ""), "h264")
  assert_eq(mov_codec_name("avc3", ""), "h264")
  assert_eq(mov_codec_name("hvc1", ""), "hevc")
  assert_eq(mov_codec_name("hev1", ""), "hevc")
  assert_eq(mov_codec_name("mp4a", "aac"), "aac")
  assert_eq(mov_codec_name("mp4a", "mp3"), "mp3")
  assert_eq(mov_codec_name("mp4a", ""), "aac")
  assert_eq(mov_codec_name(".mp3", ""), "mp3")
  assert_eq(mov_codec_name("tx3g", ""), "mov_text")
  assert_eq(mov_codec_name("vp09", ""), "vp9")
}

test "codec_parameters: H.264 avcC -> geometry/profile/VUI" {
  let avcc = @libavutil.av_base64_decode(cp_avcc_b64, 1024).unwrap()
  let p = codec_parameters_from_extradata("h264", Some(avcc), 0, 0, 0, 0)
  assert_eq(p.codec, "h264")
  assert_true(p.extradata_parsed)
  assert_eq(p.profile, 100) // High
  assert_eq(p.level, 30)
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  assert_eq(p.chroma_format, 1)
  assert_eq(p.bit_depth, 8)
  assert_eq(p.pix_fmt, "yuv420p")
  assert_eq(p.fps_num, 10) // time_scale 10 / (2 * num_units_in_tick 1)
  assert_eq(p.fps_den, 2)
  assert_eq(p.sar_num, 1)
  assert_eq(p.sar_den, 1)
}

test "codec_parameters: HEVC hvcC 8-bit and Main10" {
  let hvcc = @libavutil.av_base64_decode(cp_hvcc8_b64, 1024).unwrap()
  let p = codec_parameters_from_extradata("hevc", Some(hvcc), 0, 0, 0, 0)
  assert_true(p.extradata_parsed)
  assert_eq(p.profile, 1) // Main
  assert_eq(p.level, 30)
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  assert_eq(p.chroma_format, 1)
  assert_eq(p.bit_depth, 8)
  assert_eq(p.pix_fmt, "yuv420p")
  assert_eq(p.fps_num, 5)
  assert_eq(p.fps_den, 1)

  let hvcc10 = @libavutil.av_base64_decode(cp_hvcc10_b64, 1024).unwrap()
  let p10 = codec_parameters_from_extradata("hevc", Some(hvcc10), 0, 0, 0, 0)
  assert_true(p10.extradata_parsed)
  assert_eq(p10.profile, 2) // Main 10
  assert_eq(p10.bit_depth, 10)
  assert_eq(p10.pix_fmt, "yuv420p10le")
  assert_eq(p10.width, 64)
  assert_eq(p10.fps_num, 5)
}

test "codec_parameters: AAC AudioSpecificConfig" {
  let p = codec_parameters_from_extradata(
    "aac", Some(b"\x12\x08\x56\xE5\x00"), 0, 0, 0, 0,
  )
  assert_true(p.extradata_parsed)
  assert_eq(p.profile, 2) // AAC-LC
  assert_eq(p.sample_rate, 44100)
  assert_eq(p.channels, 1)
  assert_eq(p.frame_size, 1024)
}

test "codec_parameters: missing/unknown extradata falls back to the container" {
  let p = codec_parameters_from_extradata("mp3", None, 0, 0, 48000, 2)
  assert_true(!p.extradata_parsed)
  assert_eq(p.codec, "mp3")
  assert_eq(p.sample_rate, 48000)
  assert_eq(p.channels, 2)
  let q = codec_parameters_from_extradata(
    "h264", Some(b"\xFF\xFF\xFF"), 320, 240, 0, 0,
  )
  assert_true(!q.extradata_parsed)
  assert_eq(q.width, 320)
  assert_eq(q.height, 240)
}

test "codec_parameters: real MP4 AAC track (esds extradata)" {
  let bytes = @libavutil.av_base64_decode(real_aac_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "mp4a")
  assert_eq(track.codec_id, "aac")
  let p = mp4_track_codec_parameters(track)
  assert_eq(p.codec, "aac")
  assert_true(p.extradata_parsed)
  assert_eq(p.profile, 2) // AAC-LC
  assert_eq(p.sample_rate, 44100)
  assert_eq(p.channels, 1)
  assert_eq(p.frame_size, 1024)
}

test "codec_parameters: real Matroska H.264 track" {
  let bytes = @libavutil.av_base64_decode(real_mkv_1024_b64, 1200).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  let track = mh.tracks[0]
  assert_eq(track.codec_id, Some("V_MPEG4/ISO/AVC"))
  let p = mkv_track_codec_parameters(track)
  assert_eq(p.codec, "h264")
  assert_true(p.extradata_parsed)
  assert_eq(p.profile, 66) // Baseline (x264 with 8x8dct disabled)
  assert_eq(p.level, 10)
  assert_eq(p.width, 128)
  assert_eq(p.height, 96)
  assert_eq(p.chroma_format, 1)
  assert_eq(p.bit_depth, 8)
  assert_eq(p.pix_fmt, "yuv420p")
}
