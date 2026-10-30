///|
/// DASH `SegmentBase` writer: the global `sidx` matches FFmpeg's `movenc`
/// layout byte-for-byte, and a self-written single-file representation is
/// addressed back through `DashSegmentReader` to the H.264 frame references.

///|
test "dash: sidx matches ffmpeg movenc layout" {
  let file = @libavutil.av_base64_decode(dash_sb_mp4_b64, 100000).unwrap()
  let expected = file[817:881].to_owned()
  let sidx = fmp4_sidx(1, 10240, 0L, [
    Fmp4SidxRef::new(1923, 5120L),
    Fmp4SidxRef::new(1335, 5120L),
  ]).unwrap()
  assert_eq(sidx, expected)
}

///|
test "dash: SegmentBase writer round-trips a single-file representation" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let media1 = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(samples[0], 9000, true),
    fmp4_sample(samples[1], 9000, false),
    fmp4_sample(samples[2], 9000, false),
  ]).unwrap()
  let media2 = fmp4_media_segment(1, 2, 27000L, [
    fmp4_sample(samples[3], 9000, false),
    fmp4_sample(samples[4], 9000, false),
  ]).unwrap()
  let sidx = fmp4_sidx(1, 90000, 0L, [
    Fmp4SidxRef::new(media1.length(), 27000L),
    Fmp4SidxRef::new(media2.length(), 18000L),
  ]).unwrap()
  let file : Array[Byte] = []
  for part in [init, sidx, media1, media2] {
    for b in part {
      file.push(b)
    }
  }
  let file_bytes = Bytes::from_array(file)
  let init_range = "0-\{init.length() - 1}"
  let index_start = init.length()
  let index_range = "\{index_start}-\{index_start + sidx.length() - 1}"
  let mpd_text = dash_write_segment_base_mpd(
    [
      DashBaseAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42c01e",
        "v1",
        200000L,
        "video.mp4",
        init_range,
        index_range,
        width=64,
        height=48,
      ),
    ],
    media_duration_seconds=0.5,
  )
  assert_true(mpd_text.contains("<BaseURL>video.mp4</BaseURL>"))
  assert_true(mpd_text.contains("indexRange=\"\{index_range}\""))
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.initialization, "video.mp4")
  assert_eq(rep.initialization_range, init_range)
  assert_eq(rep.index_range, index_range)
  assert_eq(rep.segments.length(), 0)
  let fetch : MediaFetch = (uri, offset, length) => {
    if uri != "video.mp4" {
      return Err("unexpected uri \{uri}")
    }
    let start = offset.to_int()
    let end = if length < 0L {
      file_bytes.length()
    } else {
      start + length.to_int()
    }
    if start < 0 || end > file_bytes.length() || start > end {
      return Err("bad range")
    }
    Ok(file_bytes[start:end].to_owned())
  }
  let reader = dash_segment_reader_new(rep, fetch)
  let payload : Array[Byte] = []
  let mut segments = 0
  while true {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => break
      Err(e) => fail("segment read failed: \{e}")
    }
    segments = segments + 1
    let movie = match av_mov_open(segment.bytes()) {
      Ok(v) => v
      Err(e) => fail("fMP4 open failed: \{e}")
    }
    let track = movie.tracks[0]
    let bytes = segment.bytes()
    for sample in track.samples {
      let start = sample.offset.to_int()
      let end = start + sample.size.reinterpret_as_int()
      for b in bytes[start:end] {
        payload.push(b)
      }
    }
  }
  assert_eq(segments, 2)
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
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i], msg=i.to_string())
  }
}
