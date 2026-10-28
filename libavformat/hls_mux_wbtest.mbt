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

///|
test "hls muxer: master playlist round-trips" {
  let variants : Array[HlsMasterVariant] = [
    HlsMasterVariant::new(
      "720p.m3u8", 1500000, 1280, 720, "avc1.64001f,mp4a.40.2",
    ),
    HlsMasterVariant::new(
      "360p.m3u8", 600000, 640, 360, "avc1.64001e,mp4a.40.2",
    ),
  ]
  let text = hls_write_master_playlist(variants[:])
  let pl = av_hls_parse(text).unwrap()
  assert_true(pl.is_master)
  assert_eq(pl.version, 3)
  assert_eq(pl.streams.length(), 2)
  assert_eq(pl.streams[0].bandwidth, 1500000L)
  assert_eq(pl.streams[0].width, 1280)
  assert_eq(pl.streams[0].height, 720)
  assert_eq(pl.streams[0].codecs, "avc1.64001f,mp4a.40.2")
  assert_eq(pl.streams[0].uri, "720p.m3u8")
  assert_eq(pl.streams[1].uri, "360p.m3u8")
}

///|
test "hls muxer: EXT-X-MEDIA audio rendition is written and parsed" {
  let variant = HlsMasterVariant::new(
    "video.m3u8",
    800000,
    64,
    48,
    "avc1.42c00a,mp4a.40.2",
    audio_group="aud",
  )
  let rendition = HlsMasterRendition::new(
    "AUDIO",
    "aud",
    "English",
    "audio.m3u8",
    language="en",
    is_default=true,
    channels="1",
  )
  let text = hls_write_master_playlist([variant], renditions=[rendition])
  assert_true(
    text.contains(
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\",LANGUAGE=\"en\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"1\",URI=\"audio.m3u8\"\n",
    ),
  )
  assert_true(text.contains(",AUDIO=\"aud\"\n"))
  let pl = av_hls_parse(text).unwrap()
  assert_eq(pl.streams.length(), 1)
  assert_eq(pl.streams[0].uri, "video.m3u8")
  assert_eq(pl.renditions.length(), 1)
  assert_eq(pl.renditions[0].type_, "AUDIO")
  assert_eq(pl.renditions[0].group_id, "aud")
  assert_eq(pl.renditions[0].name, "English")
  assert_eq(pl.renditions[0].language, "en")
  assert_true(pl.renditions[0].is_default)
  assert_true(pl.renditions[0].autoselect)
  assert_eq(pl.renditions[0].channels, "1")
  assert_eq(pl.renditions[0].uri, "audio.m3u8")
}

///|
test "hls muxer: audio-only and video-only TS PMT list one stream" {
  let mux = ts_muxer_new(video=false, audio=true)
  mux.enable_adts(44100, 1).unwrap()
  mux.write_audio(0L, b"\x00\x01")
  let ts = av_mpegts_open(mux.finish()).unwrap()
  assert_eq(ts.streams.length(), 1)
  assert_eq(ts.streams[0].pid, 0x101)
  let video_only = ts_muxer_new(video=true, audio=false)
  video_only.write_video(0L, b"\x00\x00\x00\x01\x65")
  let ts2 = av_mpegts_open(video_only.finish()).unwrap()
  assert_eq(ts2.streams.length(), 1)
  assert_eq(ts2.streams[0].pid, 0x100)
}

///|
test "hls muxer: EXT-X-MAP for fMP4 is written and parsed" {
  let segments : Array[(String, Double)] = [
    ("seg0.m4s", 0.5),
    ("seg1.m4s", 0.5),
  ]
  let text = hls_write_media_playlist(
    segments[:],
    media_sequence=0L,
    version=7,
    map_uri=Some("init.mp4"),
  )
  let pl = av_hls_parse(text).unwrap()
  assert_eq(pl.version, 7)
  assert_eq(pl.maps.length(), 1)
  assert_eq(pl.maps[0].uri, "init.mp4")
  assert_eq(pl.segments.length(), 2)
  assert_eq(pl.segments[0].map_index, 0)
  assert_eq(pl.segments[1].map_index, 0)
}

///|
test "hls muxer: EXT-X-KEY carries the AES-128 URI and IV" {
  let iv : Array[Byte] = []
  for i in 0..<16 {
    iv.push(i.to_byte())
  }
  let text = hls_write_media_playlist(
    [("seg0.ts", 2.0)],
    key_uri=Some("key.bin"),
    key_iv=Some(Bytes::from_array(iv)),
  )
  assert_true(
    text.contains(
      "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x000102030405060708090A0B0C0D0E0F\n",
    ),
  )
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.keys.length(), 1)
  assert_eq(playlist.keys[0].method_, "AES-128")
  assert_eq(playlist.keys[0].uri, "key.bin")
  assert_eq(playlist.keys[0].iv, "0x000102030405060708090A0B0C0D0E0F")
}
