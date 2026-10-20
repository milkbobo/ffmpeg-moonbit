///|
/// Whitebox tests for the Matroska Tracks slice (`matroska_track.mbt`),
/// ported from FFmpeg 9.0.2 `libavformat/matroskadec.c`
/// (`matroska_tracks[]`/`matroska_track[]`/`matroska_track_video[]`/
/// `matroska_track_audio[]`/`matroska_track_encodings[]`/
/// `matroska_block_addition_mapping[]`).
///
/// Synthetic TrackEntry layouts are hand-derived from the table defaults;
/// the real-file tests pin the docker-generated webm (VP8+Opus) and mkv
/// (H.264+AAC) used by the previous slices.

// ---------------------------------------------------------------------------
// synthetic TrackEntry builders
// ---------------------------------------------------------------------------

///| `el` from ebml_wbtest is reused (same package); this file adds track
/// helpers only. */

///|
/// A minimal EBML header + segment open, as in mkv_segment_wbtest. */
fn track_movie(tracks_payload : Bytes) -> Bytes {
  let header = synth_ebml_header(b"matroska")
  let seg = bcat([seg_open_unknown(), tracks_payload, cluster_id()])
  bcat([header, seg])
}

///|
/// A complete Tracks level-1 element wrapping `entries`. */
fn tracks_box(entries : Bytes) -> Bytes {
  bcat([b"\x16\x54\xAE\x6B", vint1(entries.length()), entries])
}

///|
/// One TrackEntry element. */
fn track_entry(children : Bytes) -> Bytes {
  el(b"\xAE", children)
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

///|
test "matroska: defaults of an empty TrackEntry" {
  let entry = track_entry(
    bcat([
      el(b"\xD7", b"\x01"), // TrackNumber 1
      el(b"\x83", b"\x02"), // TrackType audio
    ]),
  )
  let mh = av_matroska_open(track_movie(tracks_box(entry))).unwrap()
  assert_eq(mh.tracks.length(), 1)
  let t = mh.tracks[0]
  assert_eq(t.num, 1UL)
  assert_eq(t.track_type, mkv_track_type_audio)
  assert_eq(t.language, "eng")
  assert_eq(t.flag_default, 1UL)
  assert_eq(t.flag_forced, 0UL)
  assert_eq(t.time_scale, 1.0)
  assert_eq(t.audio.samplerate, 8000.0)
  assert_eq(t.audio.channels, 1UL)
  assert_eq(t.codec_id, None)
  // video dimension defaults are -1 (unset)
  assert_eq(t.video.display_width, 0xFFFFFFFFFFFFFFFFUL)
  assert_eq(t.codec_priv, None)
  assert_eq(t.encodings.length(), 0)
}

///|
test "matroska: video track full field set" {
  let video = bcat([
    el(b"\xB0", be_u64(128UL, 1)), // PixelWidth
    el(b"\xBA", be_u64(96UL, 1)), // PixelHeight
    el(b"\x54\xB0", be_u64(256UL, 2)), // DisplayWidth
    el(b"\x54\xBA", be_u64(192UL, 2)), // DisplayHeight
    el(b"\x54\xAA", be_u64(2UL, 1)), // PixelCropBottom
    el(b"\x9A", be_u64(0UL, 1)), // FlagInterlaced
    el(b"\x53\xC0", be_u64(1UL, 1)), // AlphaMode
    el(b"\x2E\xB5\x24", b"\x01\x02\x03\x04"), // ColourSpace
  ])
  let children = bcat([
    el(b"\xD7", b"\x01"),
    el(b"\x83", b"\x01"), // video
    el(b"\x86", b"V_VP9"),
    el(b"\x23\xE3\x83", be_u64(41666666UL, 4)), // DefaultDuration ns
    el(b"\xE0", video),
    // trailing VOID: the TrackEntry ends one element after the video master,
    // so the walk pops TrackEntry/Tracks on a level end and reaches the
    // Cluster from the segment level (real files terminate like this)
    b"\xEC",
    vint1(2),
    b"\x00\x00",
  ])
  let mh = av_matroska_open(track_movie(tracks_box(track_entry(children)))).unwrap()
  assert_eq(mh.tracks.length(), 1)
  let t = mh.tracks[0]
  assert_eq(t.track_type, mkv_track_type_video)
  assert_eq(t.codec_id, Some("V_VP9"))
  assert_eq(t.default_duration, 41666666UL)
  assert_eq(t.video.pixel_width, 128UL)
  assert_eq(t.video.pixel_height, 96UL)
  assert_eq(t.video.display_width, 256UL)
  assert_eq(t.video.display_height, 192UL)
  assert_eq(t.video.pixel_crop_bottom, 2UL)
  assert_eq(t.video.alpha_mode, 1UL)
  assert_eq(t.video.color_space, Some(b"\x01\x02\x03\x04"))
}

///|
test "matroska: audio track and track-level extras" {
  let audio = bcat([
    el(b"\xB5", b"\x40\xE7\x70\x00\x00\x00\x00\x00"), // 48000.0
    el(b"\x9F", be_u64(2UL, 1)), // Channels 2
    el(b"\x62\x64", be_u64(16UL, 1)), // BitDepth
  ])
  let children = bcat([
    el(b"\xD7", b"\x02"),
    el(b"\x83", b"\x02"),
    el(b"\x86", b"A_OPUS"),
    el(b"\x22\xB5\x9C", b"ger"), // Language ger
    el(b"\x56\xAA", be_u64(6500000UL, 4)), // CodecDelay
    el(b"\x56\xBB", be_u64(80000000UL, 4)), // SeekPreRoll
    el(b"\x23\x31\x4F", b"\x3F\x80\x00\x00"), // TimecodeScale 1.0
    el(b"\xE1", audio),
    b"\xEC",
    vint1(2),
    b"\x00\x00", // trailing VOID, see the video test
  ])
  let mh = av_matroska_open(track_movie(tracks_box(track_entry(children)))).unwrap()
  let t = mh.tracks[0]
  assert_eq(t.num, 2UL)
  assert_eq(t.language, "ger")
  assert_eq(t.codec_delay, 6500000UL)
  assert_eq(t.seek_preroll, 80000000UL)
  assert_eq(t.time_scale, 1.0)
  assert_eq(t.audio.samplerate, 48000.0)
  assert_eq(t.audio.channels, 2UL)
  assert_eq(t.audio.bitdepth, 16UL)
}

///|
test "matroska: content encodings (header-strip compression)" {
  let compression = bcat([
    el(b"\x42\x54", be_u64(mkv_comp_header_strip, 1)), // CompAlgo 3
    el(b"\x42\x55", b"\x1A\x45\xDF\xA3"), // CompSettings: 4 stripped bytes
  ])
  // ContentEncodings → ContentEncoding (0x6240, where the per-encoding
  // record is created) → ContentCompression
  let encoding_body = bcat([
    b"\x50\x34", // ContentCompression
    vint1(compression.length()),
    compression,
  ])
  let encoding = bcat([
    b"\x62\x40", // ContentEncoding
    vint1(encoding_body.length()),
    encoding_body,
  ])
  let encodings = bcat([b"\x6D\x80", vint1(encoding.length()), encoding])
  let children = bcat([
    el(b"\xD7", b"\x01"),
    el(b"\x83", b"\x01"),
    el(b"\x86", b"V_MPEG4/ISO/AVC"),
    encodings,
    b"\xEC",
    vint1(2),
    b"\x00\x00",
  ])
  let mh = av_matroska_open(track_movie(tracks_box(track_entry(children)))).unwrap()
  let t = mh.tracks[0]
  assert_eq(t.encodings.length(), 1)
  let e = t.encodings[0]
  assert_eq(e.scope, 1UL) // default scope
  assert_eq(e.comp_algo, mkv_comp_header_strip)
  assert_eq(e.comp_settings, Some(b"\x1A\x45\xDF\xA3"))
}

///|
test "matroska: two tracks keep separate field sets" {
  let v_entry = track_entry(
    bcat([
      el(b"\xD7", b"\x01"),
      el(b"\x83", b"\x01"),
      el(b"\x86", b"V_VP8"),
      el(b"\xE0", el(b"\xB0", be_u64(64UL, 1))),
      b"\xEC",
      vint1(2),
      b"\x00\x00",
    ]),
  )
  let a_entry = track_entry(
    bcat([
      el(b"\xD7", b"\x02"),
      el(b"\x83", b"\x02"),
      el(b"\x86", b"A_OPUS"),
      el(b"\xE1", el(b"\x9F", be_u64(1UL, 1))),
      b"\xEC",
      vint1(2),
      b"\x00\x00",
    ]),
  )
  let mh = av_matroska_open(track_movie(tracks_box(bcat([v_entry, a_entry])))).unwrap()
  assert_eq(mh.tracks.length(), 2)
  assert_eq(mh.tracks[0].codec_id, Some("V_VP8"))
  assert_eq(mh.tracks[0].video.pixel_width, 64UL)
  assert_eq(mh.tracks[1].codec_id, Some("A_OPUS"))
  assert_eq(mh.tracks[1].audio.channels, 1UL)
  // defaults untouched on the audio track's video struct
  assert_eq(mh.tracks[1].video.display_width, 0xFFFFFFFFFFFFFFFFUL)
}

// ---------------------------------------------------------------------------
// real files (1024-byte prefixes; same base64 as mkv_segment_wbtest)
// ---------------------------------------------------------------------------

///|
test "matroska: real webm tracks (VP8 + Opus, docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_webm_1024_b64, 1200).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  // ffprobe: Stream 0 vp8 128x96 10 fps; Stream 1 opus 48000 Hz mono
  assert_eq(mh.tracks.length(), 2)
  let v = mh.tracks[0]
  assert_eq(v.track_type, mkv_track_type_video)
  assert_eq(v.codec_id, Some("V_VP8"))
  assert_eq(v.video.pixel_width, 128UL)
  assert_eq(v.video.pixel_height, 96UL)
  // the file carries no DisplayWidth/Height (unset → -1): ffprobe derives
  // 128x96 from the pixel dimensions
  assert_eq(v.video.display_width, 0xFFFFFFFFFFFFFFFFUL)
  assert_eq(v.video.display_height, 0xFFFFFFFFFFFFFFFFUL)
  assert_eq(v.video.interlaced, 2UL) // undetermined, as written by the muxer
  // the file carries DefaultDuration 1e8 ns (= 10 fps), not FrameRate
  assert_eq(v.video.frame_rate, 0.0)
  assert_eq(v.default_duration, 100000000UL)
  assert_eq(v.default_duration, 100000000UL) // 10 fps → 1e8 ns
  let a = mh.tracks[1]
  assert_eq(a.track_type, mkv_track_type_audio)
  assert_eq(a.codec_id, Some("A_OPUS"))
  assert_eq(a.audio.samplerate, 48000.0)
  assert_eq(a.audio.channels, 1UL)
  assert_eq(a.codec_priv != None, true) // OpusHead
  assert_eq(a.codec_delay, 6500000UL) // ffmpeg's webm opus default
  assert_eq(a.seek_preroll, 80000000UL)
}

///|
test "matroska: real mkv tracks (H.264 only, docker ffmpeg)" {
  let bytes = @libavutil.av_base64_decode(real_mkv_1024_b64, 1200).unwrap()
  let mh = av_matroska_open(bytes).unwrap()
  // ffprobe: Stream 0 h264 128x96 (the file has no audio track)
  assert_eq(mh.tracks.length(), 1)
  let v = mh.tracks[0]
  assert_eq(v.codec_id, Some("V_MPEG4/ISO/AVC"))
  assert_eq(v.video.pixel_width, 128UL)
  assert_eq(v.video.pixel_height, 96UL)
  // avcC extradata present
  match v.codec_priv {
    Some(cp) => {
      assert_eq(cp[0], 1) // configurationVersion
      assert_eq(cp.length() > 8, true)
    }
    None => assert_true(false)
  }
  match v.codec_priv {
    Some(cp) => {
      // avcC: configurationVersion 1, plausible length
      assert_eq(cp[0], 1)
      assert_eq(cp.length() > 8, true)
    }
    None => assert_true(false)
  }
}
