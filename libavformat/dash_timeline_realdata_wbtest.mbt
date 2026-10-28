///|
/// DASH `SegmentTemplate`+`SegmentTimeline` writer: five single-frame fMP4
/// media segments are addressed by a `$Time$` template. The parsed timeline
/// drives `DashSegmentReader`, and the reassembled H.264 access units decode
/// to the FFmpeg frame references.

///|
test "dash: SegmentTimeline $Time$ video round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let media : Array[Bytes] = []
  let files : Map[String, Bytes] = Map([])
  files["video-init.mp4"] = init
  for i, sample in samples {
    let seg = fmp4_media_segment(1, i + 1, i.to_int64() * 9000L, [
      fmp4_sample(sample, 9000, i == 0),
    ]).unwrap()
    media.push(seg)
    files["video-\{i * 9000}.m4s"] = seg
  }
  let timeline : Array[DashTimelineSegment] = []
  for i in 0..<5 {
    timeline.push(
      DashTimelineSegment::new(9000L, start=if i == 0 { 0L } else { -1L }),
    )
  }
  let mpd_text = dash_write_timeline_mpd(
    [
      DashTimelineAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42c01e",
        "v1",
        200000L,
        90000L,
        1L,
        "video-init.mp4",
        "video-$Time$.m4s",
        timeline,
        width=64,
        height=48,
      ),
    ],
    media_duration_seconds=0.5,
  )
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments.length(), 5)
  assert_eq(rep.segments[0].time, 0L)
  assert_eq(rep.segments[4].time, 36000L)
  assert_eq(rep.segments[2].uri, "video-18000.m4s")
  let fetch : MediaFetch = (uri, _, _) => {
    match files.get(uri) {
      Some(bytes) => Ok(bytes)
      None => Err("unexpected uri \{uri}")
    }
  }
  let reader = dash_segment_reader_new(rep, fetch)
  let payload : Array[Byte] = []
  for i in 0..<5 {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => fail("missing segment \{i}")
      Err(e) => fail("segment read failed: \{e}")
    }
    let movie = match av_mov_open(segment.bytes()) {
      Ok(v) => v
      Err(e) => fail("fMP4 open failed: \{e}")
    }
    assert_eq(movie.tracks.length(), 1)
    assert_eq(movie.tracks[0].samples.length(), 1)
    let sample = movie.tracks[0].samples[0]
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let bytes = segment.bytes()
    for b in bytes[start:end] {
      payload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
}
