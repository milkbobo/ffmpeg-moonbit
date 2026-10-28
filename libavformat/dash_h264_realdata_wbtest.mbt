///|
/// Real-data DASH end-to-end test: the x264 fMP4 fixture is described by this
/// port's SegmentTemplate MPD writer, fetched through the DASH segment reader
/// and decoded. Frame MD5s match FFmpeg 9.0.2 single-thread decode.

///|
fn dash_h264_fetch(init : Bytes, media : Bytes) -> MediaFetch {
  (uri, offset, length) => {
    let data = if uri == "init.mp4" {
      init
    } else if uri == "seg-1.m4s" {
      media
    } else {
      return Err("unexpected DASH resource: " + uri)
    }
    if offset < 0L || offset > data.length().to_int64() {
      return Err("bad range")
    }
    let end = if length < 0L {
      data.length().to_int64()
    } else {
      if offset + length > data.length().to_int64() {
        return Err("range past end")
      }
      offset + length
    }
    Ok(data[offset.to_int():end.to_int()].to_owned())
  }
}

///|
test "dash: real H.264 fMP4 segment template decodes round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let media = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(samples[0], 9000, true),
    fmp4_sample(samples[1], 9000, false),
    fmp4_sample(samples[2], 9000, false),
    fmp4_sample(samples[3], 9000, false),
    fmp4_sample(samples[4], 9000, false),
  ]).unwrap()
  let mpd_text = dash_write_segment_template_mpd(
    id="v1",
    bandwidth=200000L,
    codecs="avc1.42C01E",
    width=64,
    height=48,
    timescale=90000L,
    duration=45000L,
    start_number=1L,
    initialization="init.mp4",
    media_template="seg-$Number$.m4s",
    segment_count=1,
    media_duration_seconds=0.5,
  )
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.initialization, "init.mp4")
  assert_eq(rep.segments.length(), 1)
  assert_eq(rep.segments[0].uri, "seg-1.m4s")
  let reader = dash_segment_reader_new(rep, dash_h264_fetch(init, media))
  let segment = match reader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no DASH segment")
    Err(e) => fail("dash fetch failed: \{e}")
  }
  match reader.next() {
    Ok(None) => ()
    _ => fail("unexpected second DASH segment")
  }
  let bytes = segment.bytes()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.samples.length(), 5)
  let payload : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
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
