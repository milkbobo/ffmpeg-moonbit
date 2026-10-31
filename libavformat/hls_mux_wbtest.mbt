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

///|
test "hls muxer: header tags (playlist type, cache, iframe, independent)" {
  let text = hls_write_media_playlist(
    [("seg0.ts", 2.0)],
    allow_cache=0,
    playlist_type="VOD",
    i_frames_only=true,
    independent_segments=true,
  )
  assert_true(text.contains("#EXT-X-ALLOW-CACHE:NO\n"))
  assert_true(text.contains("#EXT-X-PLAYLIST-TYPE:VOD\n"))
  assert_true(text.contains("#EXT-X-I-FRAMES-ONLY\n"))
  assert_true(text.contains("#EXT-X-INDEPENDENT-SEGMENTS\n"))
  // hlsplaylist.c order: allow-cache before target duration; playlist type
  // after the media sequence, then I-FRAMES-ONLY. hlsenc emits
  // INDEPENDENT-SEGMENTS after the header, before any segment.
  let ver = text.find("#EXT-X-VERSION:").unwrap()
  let cache = text.find("#EXT-X-ALLOW-CACHE:").unwrap()
  let target = text.find("#EXT-X-TARGETDURATION:").unwrap()
  let seq = text.find("#EXT-X-MEDIA-SEQUENCE:").unwrap()
  let ptype = text.find("#EXT-X-PLAYLIST-TYPE:").unwrap()
  let iframe = text.find("#EXT-X-I-FRAMES-ONLY").unwrap()
  let indep = text.find("#EXT-X-INDEPENDENT-SEGMENTS").unwrap()
  assert_true(ver < cache && cache < target && target < seq)
  assert_true(seq < ptype && ptype < iframe && iframe < indep)
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.playlist_type, "VOD")
  assert_true(playlist.i_frames_only)
  assert_true(playlist.independent_segments)
  // Defaults omit every header tag; allow_cache=1 flips the value.
  let plain = hls_write_media_playlist([("seg0.ts", 2.0)])
  assert_false(plain.contains("#EXT-X-ALLOW-CACHE"))
  assert_false(plain.contains("#EXT-X-PLAYLIST-TYPE"))
  assert_false(plain.contains("#EXT-X-I-FRAMES-ONLY"))
  assert_false(plain.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
  let yes = hls_write_media_playlist([("seg0.ts", 2.0)], allow_cache=1)
  assert_true(yes.contains("#EXT-X-ALLOW-CACHE:YES\n"))
}

///|
test "hls muxer: discontinuity, gap and program date-time round-trip" {
  let segments : Array[HlsMediaSegmentSpec] = [
    HlsMediaSegmentSpec::new(
      "seg0.ts",
      2.0,
      program_date_time="2026-10-31T00:00:00.000Z",
    ),
    HlsMediaSegmentSpec::new("seg1.ts", 2.0, discontinuity=true),
    HlsMediaSegmentSpec::new("seg2.ts", 1.5, gap=true),
  ]
  let text = hls_write_media_playlist_specs(
    segments[:],
    discontinuity_sequence=2L,
  )
  assert_true(text.contains("#EXT-X-DISCONTINUITY-SEQUENCE:2\n"))
  assert_true(
    text.contains("#EXT-X-PROGRAM-DATE-TIME:2026-10-31T00:00:00.000Z\n"),
  )
  assert_true(text.contains("#EXT-X-DISCONTINUITY\n"))
  assert_true(text.contains("#EXT-X-GAP\n"))
  // Each tag precedes the segment entry it annotates; the date follows
  // EXTINF as in hlsplaylist.c.
  let pdt_pos = text.find("#EXT-X-PROGRAM-DATE-TIME:").unwrap()
  let first_inf = text.find("#EXTINF:").unwrap()
  let seg0_pos = text.find("seg0.ts").unwrap()
  let disc_pos = text.find("#EXT-X-DISCONTINUITY\n").unwrap()
  let seg1_pos = text.find("seg1.ts").unwrap()
  let gap_pos = text.find("#EXT-X-GAP\n").unwrap()
  let seg2_pos = text.find("seg2.ts").unwrap()
  assert_true(first_inf < pdt_pos && pdt_pos < seg0_pos)
  assert_true(seg0_pos < disc_pos && disc_pos < seg1_pos)
  assert_true(seg1_pos < gap_pos && gap_pos < seg2_pos)
  // The discontinuity sequence precedes the target duration, as in hlsenc.c.
  let seq_pos = text.find("#EXT-X-DISCONTINUITY-SEQUENCE:2")
  let target_pos = text.find("#EXT-X-TARGETDURATION:")
  assert_true(seq_pos.unwrap() < target_pos.unwrap())
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.discontinuity_sequence, 2L)
  assert_eq(playlist.segments.length(), 3)
  assert_eq(playlist.segments[0].program_date_time, "2026-10-31T00:00:00.000Z")
  assert_false(playlist.segments[0].discontinuity)
  assert_false(playlist.segments[0].gap)
  assert_true(playlist.segments[1].discontinuity)
  assert_false(playlist.segments[1].gap)
  assert_eq(playlist.segments[1].program_date_time, "")
  assert_false(playlist.segments[2].discontinuity)
  assert_true(playlist.segments[2].gap)
  // Segments without flags stay tag-free.
  let plain = hls_write_media_playlist_specs([
    HlsMediaSegmentSpec::new("seg0.ts", 2.0),
  ])
  assert_false(plain.contains("#EXT-X-DISCONTINUITY"))
  assert_false(plain.contains("#EXT-X-GAP"))
  assert_false(plain.contains("#EXT-X-PROGRAM-DATE-TIME"))
}

///|
test "hls muxer: average bandwidth, closed captions and forced subtitles" {
  let variant = HlsMasterVariant::new(
    "v.m3u8",
    800000,
    640,
    360,
    "avc1.42c01e,mp4a.40.2",
    audio_group="aud",
    subtitle_group="subs",
    average_bandwidth=750000,
    closed_captions_group="cc",
  )
  let cc = HlsMasterRendition::new(
    "CLOSED-CAPTIONS",
    "cc",
    "CC1",
    "",
    language="en",
    instream_id="CC1",
  )
  let subs = HlsMasterRendition::new(
    "SUBTITLES",
    "subs",
    "English",
    "subs.m3u8",
    forced=true,
  )
  let text = hls_write_master_playlist([variant], renditions=[cc, subs])
  assert_true(
    text.contains(
      "#EXT-X-STREAM-INF:BANDWIDTH=800000,AVERAGE-BANDWIDTH=750000,RESOLUTION=640x360,CODECS=\"avc1.42c01e,mp4a.40.2\",AUDIO=\"aud\",CLOSED-CAPTIONS=\"cc\",SUBTITLES=\"subs\"\n",
    ),
  )
  assert_true(
    text.contains(
      "#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID=\"cc\",NAME=\"CC1\",LANGUAGE=\"en\",INSTREAM-ID=\"CC1\"\n",
    ),
  )
  assert_true(
    text.contains(",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI=\"subs.m3u8\"\n"),
  )
  let pl = av_hls_parse(text).unwrap()
  assert_eq(pl.streams.length(), 1)
  assert_eq(pl.streams[0].average_bandwidth, 750000L)
  assert_eq(pl.streams[0].closed_captions, "cc")
  assert_eq(pl.renditions.length(), 2)
  assert_eq(pl.renditions[0].type_, "CLOSED-CAPTIONS")
  assert_eq(pl.renditions[0].instream_id, "CC1")
  assert_eq(pl.renditions[0].uri, "")
  assert_true(pl.renditions[1].forced)
  // Zero dimensions omit RESOLUTION, as ff_hls_write_stream_info does.
  let no_res = hls_write_master_playlist([
    HlsMasterVariant::new("a.m3u8", 64000, 0, 0, "mp4a.40.2"),
  ])
  assert_false(no_res.contains("RESOLUTION="))
  // Empty CODECS is omitted too.
  let bare = hls_write_master_playlist([
    HlsMasterVariant::new("b.m3u8", 1000, 0, 0, ""),
  ])
  assert_false(bare.contains("CODECS="))
}
