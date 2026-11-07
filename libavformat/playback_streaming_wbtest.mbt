///|
/// White-box tests for the timeline normalization guards. These construct a
/// session directly so the saturation and index limits can be reached
/// without crafting a corrupt media file.

///|
test "streaming: sat add/sub clamp instead of wrapping at Int64 extremes" {
  let max = 9223372036854775807L
  let min = -9223372036854775808L
  assert_eq(streaming_sat_add(max, 1L), max)
  assert_eq(streaming_sat_add(min, -1L), min)
  assert_eq(streaming_sat_add(max, -1L), max - 1L)
  assert_eq(streaming_sat_add(min, 1L), min + 1L)
  assert_eq(streaming_sat_sub(min, 1L), min)
  assert_eq(streaming_sat_sub(max, -1L), max)
  assert_eq(streaming_sat_sub(max, 1L), max - 1L)
  assert_eq(streaming_sat_sub(min, -1L), min + 1L)
}

///|
test "streaming: a hostile stream index is refused, not allocated" {
  let playlist = av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
  let reader = hls_segment_reader_new(playlist, (_, _, _) => Err("unused")).unwrap()
  let media = streaming_from_reader(Hls, "hls", HlsReader(reader), None)
  try
    media.streaming_normalize({
      stream_index: 4096,
      data: b"",
      pts: 0L,
      keyframe: false,
    })
  catch {
    DemuxError(msg) => assert_true(msg.contains("out of range"))
    _ => fail("expected DemuxError")
  } noraise {
    _ => fail("expected DemuxError for hostile stream index")
  }
  assert_eq(media.last_pts.length(), 0)
}

///|
test "streaming: normalization places a restarted segment after the last pts" {
  let playlist = av_hls_parse("#EXTM3U\n#EXT-X-ENDLIST").unwrap()
  let reader = hls_segment_reader_new(playlist, (_, _, _) => Err("unused")).unwrap()
  let media = streaming_from_reader(Hls, "hls", HlsReader(reader), None)
  let mk = fn(pts : Int64) -> MediaPacket {
    { stream_index: 0, data: b"x", pts, keyframe: false, }
  }
  let a = media.streaming_normalize(mk(100L))
  let b = media.streaming_normalize(mk(200L))
  assert_eq(a.pts, 100L)
  assert_eq(b.pts, 200L)
  // New segment restarts at 0: with a 100-tick step it must land at 300.
  media.streaming_reset_segment()
  let c = media.streaming_normalize(mk(0L))
  assert_eq(c.pts, 300L)
  let d = media.streaming_normalize(mk(100L))
  assert_eq(d.pts, 400L)
}

///|
/// DASH segment times are in the Representation's timescale; subtitle cues are
/// in milliseconds. The conversion divides before multiplying so a corrupt
/// timeline cannot overflow, which makes the remainder path load-bearing.
test "streaming: dash segment time converts to milliseconds without overflow" {
  assert_eq(dash_time_to_ms(0L, 1000L), 0L)
  assert_eq(dash_time_to_ms(1000L, 1000L), 1000L)
  assert_eq(dash_time_to_ms(180000L, 90000L), 2000L)
  // 22050 at 44.1 kHz is exactly half a second, reached through the remainder.
  assert_eq(dash_time_to_ms(22050L, 44100L), 500L)
  // A missing timescale is treated as milliseconds (the DASH default is per
  // Representation, and every writer here emits 1000 when absent).
  assert_eq(dash_time_to_ms(1500L, 0L), 1500L)
  assert_eq(dash_time_to_ms(-1000L, 1000L), -1000L)
  // Multiplying first would wrap; the guard saturates instead.
  assert_eq(dash_time_to_ms(9223372036854775807L, 1L), 9223372036854775807L)
}

///|
/// A switch inside a live session must hand the new audio sub-session a
/// **full** refresh budget, not what the parent has left - otherwise the audio
/// track would run out of refreshes mid-stream while the video keeps going.
/// The parent's remaining budget is forced down first, so taking it by mistake
/// would show up here.
test "streaming: select_audio gives a live switch a full refresh budget" {
  let master_text = "#EXTM3U\n" +
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Francais\"," +
    "DEFAULT=NO,LANGUAGE=\"fr\",URI=\"afr.m3u8\"\n" +
    "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"English\"," +
    "DEFAULT=YES,LANGUAGE=\"en\",URI=\"aen.m3u8\"\n" +
    "#EXT-X-STREAM-INF:BANDWIDTH=200000,AUDIO=\"aud\"\nv/video.m3u8\n"
  let master = av_hls_parse(
    master_text,
    base_uri="https://cdn.test/hls/master.m3u8",
  ).unwrap()
  let media_playlist = av_hls_parse(
    "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:3.0,\nv0.ts\n",
    base_uri="https://cdn.test/hls/v/video.m3u8",
  ).unwrap()
  let fetch : MediaFetch = (uri, _, _) => {
    if uri == "https://cdn.test/hls/afr.m3u8" {
      let arr : Array[Byte] = []
      for c in "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:3.0,\nafr0.aac\n" {
        arr.push(c.to_int().to_byte())
      }
      return Ok(Bytes::from_array(arr))
    }
    Err("404: \{uri}")
  }
  let reader = hls_segment_reader_new(media_playlist, fetch).unwrap()
  let media = streaming_from_reader(Hls, "hls", HlsReader(reader), None)
  media.hls_renditions = master.renditions
  media.audio_group = "aud"
  media.audio_reload_budget = 3
  media.is_live = true
  media.reload_budget = 1
  media.select_audio(0)
  assert_eq(media.audio_selected(), 0)
  let track = media.audio_track.unwrap()
  assert_true(track.is_live)
  assert_eq(track.reload_budget, 3)
  assert_eq(track.playlist_uri, "https://cdn.test/hls/afr.m3u8")
}
