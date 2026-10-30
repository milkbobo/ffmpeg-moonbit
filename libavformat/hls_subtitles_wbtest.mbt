///|
/// WebVTT segment and master-playlist subtitle-rendition writers.

///|
test "hls subtitles: WebVTT segment layout" {
  let cues : Array[HlsVttCue] = [
    hls_vtt_cue_new(1050L, 2150L, "First cue"),
    hls_vtt_cue_new(3000L, 4500L, "Second\nline"),
  ]
  let vtt = hls_write_vtt_segment(cues)
  assert_eq(
    vtt,
    "WEBVTT\n\n" +
    "00:00:01.050 --> 00:00:02.150\nFirst cue\n\n" +
    "00:00:03.000 --> 00:00:04.500\nSecond\nline\n",
  )
}

///|
test "hls subtitles: master playlist names the subtitle group" {
  let variants : Array[HlsMasterVariant] = [
    HlsMasterVariant::new(
      "video.m3u8",
      800000,
      64,
      48,
      "avc1.42c00d",
      subtitle_group="subs",
    ),
  ]
  let renditions : Array[HlsMasterRendition] = [
    HlsMasterRendition::new(
      "SUBTITLES",
      "subs",
      "English",
      "subs.m3u8",
      language="en",
      is_default=true,
    ),
  ]
  let master = hls_write_master_playlist(variants, renditions~)
  assert_true(master.contains("TYPE=SUBTITLES"))
  assert_true(master.contains("GROUP-ID=\"subs\""))
  assert_true(master.contains("URI=\"subs.m3u8\""))
  assert_true(master.contains("SUBTITLES=\"subs\""))
  assert_true(master.contains("LANGUAGE=\"en\""))
}
