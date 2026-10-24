///|
/// HLS media-playlist writer round-trips through `av_hls_parse`.

///|
test "hls muxer: media playlist round-trips" {
  let segments : Array[(String, Double)] = [
    ("seg0.ts", 2.0),
    ("seg1.ts", 1.5),
    ("seg2.ts", 2.25),
  ]
  let text = hls_write_media_playlist(segments[:], media_sequence=7L)
  let playlist = av_hls_parse(text).unwrap()
  assert_false(playlist.is_master)
  assert_eq(playlist.version, 3)
  assert_eq(playlist.target_duration, 3)
  assert_eq(playlist.media_sequence, 7L)
  assert_true(playlist.endlist)
  assert_eq(playlist.segments.length(), 3)
  assert_eq(playlist.segments[0].uri, "seg0.ts")
  assert_eq(playlist.segments[0].duration, 2.0)
  assert_eq(playlist.segments[2].uri, "seg2.ts")
  assert_eq(playlist.segments[2].duration, 2.25)
}

///|
test "hls muxer: empty playlist and explicit target duration" {
  let text = hls_write_media_playlist([], target_duration=6, endlist=false)
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.target_duration, 6)
  assert_false(playlist.endlist)
  assert_eq(playlist.segments.length(), 0)
}
