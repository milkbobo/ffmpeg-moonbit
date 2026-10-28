///|
/// Real-data dual-track fMP4 test: one H.264 video track and one AAC audio
/// track share the `moov` and one media segment (`mfhd` + two `traf` boxes).
/// The concatenated init+media bytes are parsed back by `av_mov_open` and
/// both tracks are decoded against the same references as the MP4/MKV A/V
/// tests (FFmpeg 9.0.2 video frame MD5s, ADTS-equivalent AAC packets).

///|
test "fmp4 muxer: real H.264 + AAC dual-track segments round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let video_packets : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    video_packets.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let src = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let asc = src.tracks[1].codec_priv.unwrap()
  let audio_packets : Array[Bytes] = []
  for p in src.packets {
    if p.stream_index == 1 {
      audio_packets.push(p.data)
    }
  }
  assert_eq(audio_packets.length(), 45)

  let init = fmp4_av_init_segment(64, 48, 90000, avcc, 44100, 1).unwrap()
  let video_samples : Array[Fmp4Sample] = []
  for i, packet in video_packets {
    video_samples.push(fmp4_sample(packet, 9000, i == 0))
  }
  let audio_samples : Array[Fmp4Sample] = []
  for packet in audio_packets {
    audio_samples.push(fmp4_sample(packet, 1024, true))
  }
  let seg0 = fmp4_av_media_segment(
    1,
    video_samples[0:3].to_owned(),
    audio_samples[0:23].to_owned(),
  ).unwrap()
  let seg1 = fmp4_av_media_segment(
    2,
    video_samples[3:5].to_owned(),
    audio_samples[23:45].to_owned(),
    video_base_decode_time=27000L,
    audio_base_decode_time=23552L,
  ).unwrap()
  let bytes = fmp4_join([init, seg0, seg1])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)

  let video = movie.tracks[0]
  assert_eq(video.codec, "avc1")
  assert_eq(video.width, 64)
  assert_eq(video.height, 48)
  assert_eq(video.timescale, 90000U)
  assert_eq(video.extradata.unwrap(), avcc)
  assert_eq(video.samples.length(), 5)
  for i = 0; i < 5; i = i + 1 {
    let sample = video.samples[i]
    assert_eq(sample.dts, (i * 9000).to_int64())
    assert_eq(sample.duration, 9000U)
    assert_eq(sample.keyframe, i == 0)
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytes[start:end].to_owned(), video_packets[i])
  }

  let audio = movie.tracks[1]
  assert_eq(audio.codec, "mp4a")
  assert_eq(audio.codec_id, "aac")
  assert_eq(audio.sample_rate, 44100U)
  assert_eq(audio.channels, 1U)
  assert_eq(audio.timescale, 44100U)
  assert_eq(audio.samples.length(), 45)
  for i = 0; i < 45; i = i + 1 {
    let sample = audio.samples[i]
    assert_eq(sample.dts, (i * 1024).to_int64())
    assert_eq(sample.duration, 1024U)
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytes[start:end].to_owned(), audio_packets[i])
  }

  let vpayload : Array[Byte] = []
  for sample in video.samples {
    let start = sample.offset.to_int()
    for b in bytes[start:start + sample.size.reinterpret_as_int()] {
      vpayload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(vpayload),
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

  let adec = @libavcodec.new_aac_decoder_from_asc(asc).unwrap()
  let mut pcm_samples = 0
  for i, packet in audio_packets {
    match adec.decode_frame(packet) {
      Ok(out) =>
        for element in out {
          pcm_samples = pcm_samples + element.samples.length()
        }
      Err(e) => fail("aac frame \{i}: \{e}")
    }
  }
  assert_eq(pcm_samples, 45 * 1024)
}

///|
test "fmp4 muxer: A/V custom track ids round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let init = fmp4_av_init_segment(
    64,
    48,
    90000,
    avcc,
    48000,
    2,
    video_track_id=3,
    audio_track_id=7,
  ).unwrap()
  let media = fmp4_av_media_segment(
    1,
    [fmp4_sample(b"\x00\x00\x00\x01\x65\x88", 3000, true)],
    [fmp4_sample(b"\xAA\xBB", 1024, true)],
    video_track_id=3,
    audio_track_id=7,
  ).unwrap()
  let bytes = fmp4_join([init, media])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  let video = movie.tracks[0]
  assert_eq(video.track_id, 3U)
  assert_eq(video.codec, "avc1")
  assert_eq(video.samples.length(), 1)
  assert_eq(video.samples[0].size, 6U)
  let audio = movie.tracks[1]
  assert_eq(audio.track_id, 7U)
  assert_eq(audio.codec, "mp4a")
  assert_eq(audio.sample_rate, 48000U)
  assert_eq(audio.channels, 2U)
  assert_eq(audio.samples.length(), 1)
  assert_eq(audio.samples[0].size, 2U)
}

///|
test "fmp4 muxer: invalid A/V parameters are rejected" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  match fmp4_av_init_segment(64, 48, 90000, b"", 44100, 1) {
    Ok(_) => fail("short avcC must fail")
    Err(_) => ()
  }
  match fmp4_av_init_segment(64, 48, 90000, avcc, 12345, 1) {
    Ok(_) => fail("unsupported sample rate must fail")
    Err(_) => ()
  }
  match
    fmp4_av_init_segment(
      64,
      48,
      90000,
      avcc,
      44100,
      1,
      video_track_id=2,
      audio_track_id=2,
    ) {
    Ok(_) => fail("duplicate track ids must fail")
    Err(_) => ()
  }
  match
    fmp4_av_init_segment(
      64,
      48,
      90000,
      avcc,
      44100,
      1,
      video_track_id=0,
      audio_track_id=2,
    ) {
    Ok(_) => fail("zero track id must fail")
    Err(_) => ()
  }
  match
    fmp4_av_media_segment(
      1,
      [fmp4_sample(b"\x00\x00\x00\x01\x65\x88", 3000, true)],
      [],
    ) {
    Ok(_) => fail("empty audio run must fail")
    Err(_) => ()
  }
  match
    fmp4_av_media_segment(
      1,
      [fmp4_sample(b"\x00\x00\x00\x01\x65\x88", 0, true)],
      [fmp4_sample(b"\xAA", 1024, true)],
    ) {
    Ok(_) => fail("zero video duration must fail")
    Err(_) => ()
  }
}
