///|
/// Fragmented-MP4 writer tests: each init/media segment pair is concatenated
/// and parsed back by the existing MOV demuxer.

///|
fn fmp4_join(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
test "fmp4 muxer: H.264 init and media segments round-trip" {
  let avcc = @libavutil.av_base64_decode(mp4_h264_avcc_b64, 1024).unwrap()
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let seg0 = fmp4_media_segment(1, 1, 0L, [
    { data: b"\x00\x00\x00\x02\x65\x88", duration: 3000, keyframe: true },
    { data: b"\x00\x00\x00\x02\x41\x9A", duration: 3000, keyframe: false },
  ]).unwrap()
  let seg1 = fmp4_media_segment(1, 2, 6000L, [
    { data: b"\x00\x00\x00\x03\x41\x9B\x9C", duration: 3000, keyframe: true },
  ]).unwrap()
  let movie = av_mov_open(fmp4_join([init, seg0, seg1])).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.timescale, 90000U)
  assert_eq(track.extradata.unwrap(), avcc)
  assert_eq(track.samples.length(), 3)
  let sizes : Array[UInt32] = [6U, 6U, 7U]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, sizes[i])
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i != 1)
  }
}

///|
test "fmp4 muxer: AAC init and media segments round-trip" {
  let init = fmp4_aac_init_segment(48000, 2).unwrap()
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: b"\x11\x22\x33", duration: 1024, keyframe: true },
    { data: b"\x44\x55", duration: 1024, keyframe: true },
  ]).unwrap()
  let movie = av_mov_open(fmp4_join([init, seg])).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "mp4a")
  assert_eq(track.codec_id, "aac")
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.channels, 2U)
  assert_eq(track.timescale, 48000U)
  assert_eq(track.samples.length(), 2)
  assert_eq(track.samples[0].dts, 0L)
  assert_eq(track.samples[1].dts, 1024L)
  assert_eq(track.samples[1].duration, 1024U)
}

///|
test "fmp4 muxer: media payload sits at the sample offsets" {
  let avcc = @libavutil.av_base64_decode(mp4_h264_avcc_b64, 1024).unwrap()
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let payload = b"\x00\x00\x00\x02\x65\x88"
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: payload, duration: 3000, keyframe: true },
  ]).unwrap()
  let file = fmp4_join([init, seg])
  let track = av_mov_open(file).unwrap().tracks[0]
  let sample = track.samples[0]
  assert_eq(
    file[sample.offset.to_int():sample.offset.to_int() +
      sample.size.reinterpret_as_int()],
    payload,
  )
}

///|
test "fmp4 muxer: invalid parameters are rejected" {
  let avcc = @libavutil.av_base64_decode(mp4_h264_avcc_b64, 1024).unwrap()
  match fmp4_h264_init_segment(0, 48, 90000, avcc) {
    Ok(_) => fail("zero width must fail")
    Err(_) => ()
  }
  match fmp4_h264_init_segment(64, 48, 90000, b"") {
    Ok(_) => fail("short avcC must fail")
    Err(_) => ()
  }
  match fmp4_aac_init_segment(44100, 0) {
    Ok(_) => fail("zero channels must fail")
    Err(_) => ()
  }
  match fmp4_media_segment(1, 1, 0L, []) {
    Ok(_) => fail("empty segment must fail")
    Err(_) => ()
  }
  match
    fmp4_media_segment(1, 1, 0L, [
      { data: b"\x00", duration: 0, keyframe: true },
    ]) {
    Ok(_) => fail("zero duration must fail")
    Err(_) => ()
  }
}

///|
test "fmp4 muxer: HEVC init and media segments round-trip" {
  let hvcc = @libavutil.av_base64_decode(mp4_hevc_hvcc_b64, 1024).unwrap()
  let init = fmp4_hevc_init_segment(64, 48, 90000, hvcc).unwrap()
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: b"\x00\x00\x01\x02", duration: 3000, keyframe: true },
    { data: b"\x00\x00\x01\x03", duration: 3000, keyframe: false },
  ]).unwrap()
  let track = av_mov_open(fmp4_join([init, seg])).unwrap().tracks[0]
  assert_eq(track.codec, "hvc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.extradata.unwrap(), hvcc)
  assert_eq(track.samples.length(), 2)
  assert_eq(track.samples[0].keyframe, true)
  assert_eq(track.samples[1].keyframe, false)
}

///|
test "fmp4 muxer: AV1 init and media segments round-trip" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let init = fmp4_av1_init_segment(64, 48, 90000, av1c).unwrap()
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: b"\x0A\x0B\x0C", duration: 3000, keyframe: true },
  ]).unwrap()
  let track = av_mov_open(fmp4_join([init, seg])).unwrap().tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 1)
  assert_eq(track.samples[0].size, 3U)
}

///|
test "fmp4 muxer: VP9 init and media segments round-trip" {
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let init = fmp4_vp9_init_segment(64, 48, 90000, vpcc).unwrap()
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: b"\x82\x00\x01", duration: 3000, keyframe: true },
    { data: b"\x82\x00\x02", duration: 3000, keyframe: false },
  ]).unwrap()
  let track = av_mov_open(fmp4_join([init, seg])).unwrap().tracks[0]
  assert_eq(track.codec, "vp09")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_true(track.extradata.unwrap().length() > 0)
  assert_eq(track.samples.length(), 2)
}

///|
test "fmp4 muxer: Opus init and media segments round-trip" {
  let init = fmp4_opus_init_segment(1, 312, 48000, 48000).unwrap()
  let seg = fmp4_media_segment(1, 1, 0L, [
    { data: b"\xF8\x00", duration: 960, keyframe: true },
    { data: b"\xF8\x01", duration: 960, keyframe: true },
  ]).unwrap()
  let track = av_mov_open(fmp4_join([init, seg])).unwrap().tracks[0]
  assert_eq(track.codec, "Opus")
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.channels, 1U)
  assert_eq(track.extradata.unwrap().length(), 19)
  assert_eq(track.samples.length(), 2)
  assert_eq(track.samples[1].dts, 960L)
  assert_eq(track.samples[1].duration, 960U)
}

///|
test "fmp4 muxer: invalid HEVC/AV1/VP9/Opus parameters are rejected" {
  match fmp4_hevc_init_segment(64, 48, 90000, b"") {
    Ok(_) => fail("short hvcC must fail")
    Err(_) => ()
  }
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  match fmp4_av1_init_segment(-1, 48, 90000, av1c) {
    Ok(_) => fail("negative width must fail")
    Err(_) => ()
  }
  let vpcc : Bytes = b"\x01\x00\x00\x00"
  match fmp4_vp9_init_segment(64, 48, 0, vpcc) {
    Ok(_) => fail("zero timescale must fail")
    Err(_) => ()
  }
  match fmp4_opus_init_segment(3, 312, 48000, 48000) {
    Ok(_) => fail("more than two channels must fail")
    Err(_) => ()
  }
}
