///|
/// Tests for the HLS playlist parser.
///
/// The real master/media playlists were produced by
/// `linuxserver/ffmpeg:9.0.2` with `-f hls -hls_time 1
/// -hls_playlist_type vod -master_pl_name master.m3u8` (TS segments) and
/// `-hls_segment_type fmp4` (init.mp4 + m4s segments).

///|
let hls_master_text : String =
  #|#EXTM3U
  #|#EXT-X-VERSION:3
  #|#EXT-X-STREAM-INF:BANDWIDTH=80213,AVERAGE-BANDWIDTH=73464,RESOLUTION=64x48,CODECS="avc1.42c00a,mp4a.40.2"
  #|media.m3u8
  #|

///|
let hls_media_text : String =
  #|#EXTM3U
  #|#EXT-X-VERSION:3
  #|#EXT-X-TARGETDURATION:1
  #|#EXT-X-MEDIA-SEQUENCE:0
  #|#EXT-X-PLAYLIST-TYPE:VOD
  #|#EXTINF:1.000000,
  #|seg0.ts
  #|#EXTINF:1.000000,
  #|seg1.ts
  #|#EXTINF:0.600000,
  #|seg2.ts
  #|#EXT-X-ENDLIST
  #|

///|
let hls_fmp4_text : String =
  #|#EXTM3U
  #|#EXT-X-VERSION:7
  #|#EXT-X-TARGETDURATION:1
  #|#EXT-X-MEDIA-SEQUENCE:0
  #|#EXT-X-PLAYLIST-TYPE:VOD
  #|#EXT-X-MAP:URI="init.mp4"
  #|#EXTINF:1.200000,
  #|fseg0.m4s
  #|#EXT-X-ENDLIST
  #|

///|
test "hls: ffmpeg master playlist" {
  let pl = av_hls_parse(hls_master_text).unwrap()
  assert_true(pl.is_master)
  assert_eq(pl.version, 3)
  assert_eq(pl.streams.length(), 1)
  let s = pl.streams[0]
  assert_eq(s.bandwidth, 80213L)
  assert_eq(s.average_bandwidth, 73464L)
  assert_eq(s.width, 64)
  assert_eq(s.height, 48)
  assert_eq(s.codecs, "avc1.42c00a,mp4a.40.2")
  assert_eq(s.uri, "media.m3u8")
  assert_false(s.is_i_frame)
}

///|
test "hls: ffmpeg TS media playlist" {
  let pl = av_hls_parse(hls_media_text).unwrap()
  assert_false(pl.is_master)
  assert_eq(pl.target_duration, 1)
  assert_eq(pl.media_sequence, 0L)
  assert_eq(pl.playlist_type, "VOD")
  assert_true(pl.endlist)
  assert_eq(pl.segments.length(), 3)
  assert_eq(pl.segments[0].uri, "seg0.ts")
  assert_true(pl.segments[0].duration == 1.0)
  assert_eq(pl.segments[2].uri, "seg2.ts")
  assert_true(pl.segments[2].duration == 0.6)
  assert_eq(pl.segments[2].media_sequence, 2L)
  assert_eq(pl.segments[0].key_index, -1)
  assert_eq(pl.segments[0].map_index, -1)
}

///|
test "hls: ffmpeg fMP4 playlist with EXT-X-MAP" {
  let pl = av_hls_parse(hls_fmp4_text).unwrap()
  assert_eq(pl.version, 7)
  assert_eq(pl.maps.length(), 1)
  assert_eq(pl.maps[0].uri, "init.mp4")
  assert_eq(pl.segments.length(), 1)
  assert_eq(pl.segments[0].map_index, 0)
  assert_eq(pl.segments[0].uri, "fseg0.m4s")
  assert_true(pl.segments[0].duration == 1.2)
}

///|
test "hls: byte ranges, keys, discontinuities, gap, date-time" {
  let text =
    #|#EXTM3U
    #|#EXT-X-VERSION:4
    #|#EXT-X-MEDIA-SEQUENCE:10
    #|#EXT-X-DISCONTINUITY-SEQUENCE:2
    #|#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0123456789abcdef0123456789abcdef
    #|#EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
    #|#EXTINF:2.5,first title
    #|#EXT-X-BYTERANGE:1000@0
    #|seg0.ts
    #|#EXT-X-BYTERANGE:500
    #|seg1.ts
    #|#EXT-X-DISCONTINUITY
    #|#EXT-X-GAP
    #|#EXT-X-PROGRAM-DATE-TIME:2026-10-21T12:00:00Z
    #|#EXTINF:2.0,
    #|seg2.ts
    #|#EXT-X-KEY:METHOD=NONE
    #|#EXTINF:1.0,
    #|seg3.ts
    #|#EXT-X-UNKNOWN-TAG:whatever
    #|
  let pl = av_hls_parse(text).unwrap()
  assert_eq(pl.media_sequence, 10L)
  assert_eq(pl.discontinuity_sequence, 2L)
  assert_eq(pl.keys.length(), 1)
  assert_eq(pl.keys[0].method_, "AES-128")
  assert_eq(pl.keys[0].uri, "key.bin")
  assert_eq(pl.maps[0].byterange.unwrap().length, 720L)
  assert_eq(pl.segments.length(), 4)
  let s0 = pl.segments[0]
  assert_eq(s0.media_sequence, 10L)
  assert_eq(s0.title, "first title")
  assert_eq(s0.key_index, 0)
  assert_eq(s0.map_index, 0)
  assert_eq(s0.byterange.unwrap().length, 1000L)
  assert_eq(s0.byterange.unwrap().offset, 0L)
  let s1 = pl.segments[1]
  // Offset omitted: continues after the previous range.
  assert_eq(s1.byterange.unwrap().offset, 1000L)
  assert_eq(s1.key_index, 0)
  let s2 = pl.segments[2]
  assert_true(s2.discontinuity)
  assert_true(s2.gap)
  assert_eq(s2.program_date_time, "2026-10-21T12:00:00Z")
  assert_eq(s2.media_sequence, 12L)
  // METHOD=NONE clears the key for subsequent segments.
  assert_eq(pl.segments[3].key_index, -1)
}

///|
test "hls: master with renditions and I-frame stream" {
  let text =
    #|#EXTM3U
    #|#EXT-X-VERSION:6
    #|#EXT-X-INDEPENDENT-SEGMENTS
    #|#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio/en.m3u8"
    #|#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",LANGUAGE="en",FORCED=NO,URI="subs/en.m3u8"
    #|#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720,FRAME-RATE=29.97,CODECS="avc1.64001f,mp4a.40.2",AUDIO="aud",SUBTITLES="sub"
    #|720p.m3u8
    #|#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
    #|1080p.m3u8
    #|#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=95000,RESOLUTION=640x360,CODECS="avc1.64001e",URI="iframe.m3u8"
    #|
  let pl = av_hls_parse(
    text,
    base_uri="https://cdn.example.com/vod/master.m3u8",
  ).unwrap()
  assert_eq(pl.version, 6)
  assert_true(pl.independent_segments)
  assert_eq(pl.renditions.length(), 2)
  assert_eq(pl.renditions[0].type_, "AUDIO")
  assert_eq(pl.renditions[0].group_id, "aud")
  assert_true(pl.renditions[0].is_default)
  assert_true(pl.renditions[0].autoselect)
  assert_eq(pl.renditions[0].channels, "2")
  assert_eq(pl.renditions[0].uri, "https://cdn.example.com/vod/audio/en.m3u8")
  assert_eq(pl.renditions[1].type_, "SUBTITLES")
  assert_eq(pl.streams.length(), 3)
  assert_eq(pl.streams[0].width, 1280)
  assert_eq(pl.streams[0].height, 720)
  assert_eq(pl.streams[0].frame_rate, "29.97")
  assert_eq(pl.streams[0].audio, "aud")
  assert_eq(pl.streams[0].uri, "https://cdn.example.com/vod/720p.m3u8")
  assert_eq(pl.streams[1].uri, "https://cdn.example.com/vod/1080p.m3u8")
  assert_true(pl.streams[2].is_i_frame)
  assert_eq(pl.streams[2].uri, "https://cdn.example.com/vod/iframe.m3u8")
}

///|
test "hls: URI resolution" {
  let base = "https://cdn.example.com/a/b/media.m3u8"
  assert_eq(
    hls_resolve_uri(base, "seg.ts"),
    "https://cdn.example.com/a/b/seg.ts",
  )
  assert_eq(
    hls_resolve_uri(base, "../c/seg.ts"),
    "https://cdn.example.com/a/c/seg.ts",
  )
  assert_eq(
    hls_resolve_uri(base, "/root/seg.ts"),
    "https://cdn.example.com/root/seg.ts",
  )
  assert_eq(
    hls_resolve_uri(base, "//other.example.com/x.ts"),
    "https://other.example.com/x.ts",
  )
  assert_eq(hls_resolve_uri(base, "https://other/x.ts"), "https://other/x.ts")
  assert_eq(hls_resolve_uri(base, "data:text/plain,hi"), "data:text/plain,hi")
}

///|
test "hls: rejects a missing #EXTM3U and parses CRLF/BOM" {
  match av_hls_parse("#EXTINF:1,\nseg.ts\n") {
    Ok(_) => fail("expected header error")
    Err(e) => assert_true(e.contains("EXTM3U"))
  }
  let body = "\u{FEFF}#EXTM3U\r\n#EXTINF:1.5,\r\nseg.ts\r\n#EXT-X-ENDLIST\r\n"
  let pl = av_hls_parse(body).unwrap()
  assert_eq(pl.segments.length(), 1)
  assert_true(pl.segments[0].duration == 1.5)
  assert_true(pl.endlist)
}
