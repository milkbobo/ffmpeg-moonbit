///|
/// DASH audio AdaptationSet: real AAC access units are written as a fMP4
/// init/media pair inside a two-AdaptationSet MPD, parsed back by
/// `av_dash_parse` and read through `DashSegmentReader`, then demuxed and
/// decoded against the same FFmpeg PCM reference as the ADTS test.

///|
test "dash: real AAC fMP4 audio AdaptationSet decodes round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let vsamples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    vsamples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let vinit = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let vmedia = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(vsamples[0], 9000, true),
    fmp4_sample(vsamples[1], 9000, false),
    fmp4_sample(vsamples[2], 9000, false),
    fmp4_sample(vsamples[3], 9000, false),
    fmp4_sample(vsamples[4], 9000, false),
  ]).unwrap()
  let source = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let packets : Array[Bytes] = []
  for packet in source.packets {
    if packet.stream_index == 1 && packets.length() < 5 {
      packets.push(packet.data)
    }
  }
  assert_eq(packets.length(), 5)
  let ainit = fmp4_aac_init_segment(44100, 1).unwrap()
  let asamples : Array[Fmp4Sample] = []
  for packet in packets {
    asamples.push(fmp4_sample(packet, 1024, true))
  }
  let amedia = fmp4_media_segment(1, 1, 0L, asamples).unwrap()
  let mpd_text = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42C01E",
        "v1",
        200000L,
        90000L,
        45000L,
        "video-init.mp4",
        "video-$Number$.m4s",
        width=64,
        height=48,
      ),
      DashAdaptation::new(
        "audio",
        "audio/mp4",
        "mp4a.40.2",
        "a1",
        64000L,
        44100L,
        5120L,
        "audio-init.mp4",
        "audio-$Number$.m4s",
        sample_rate=44100,
      ),
    ],
    media_duration_seconds=0.1,
  )
  let mpd = av_dash_parse(mpd_text).unwrap()
  assert_eq(mpd.periods[0].adaptation_sets.length(), 2)
  let audio = mpd.periods[0].adaptation_sets[1]
  assert_eq(audio.content_type, "audio")
  let rep = audio.representations[0]
  assert_eq(rep.codec, "aac")
  assert_eq(rep.audio_sampling_rate, 44100)
  assert_eq(rep.segments.length(), 1)
  assert_eq(rep.segments[0].uri, "audio-1.m4s")
  let fetch : MediaFetch = (uri, _, _) => {
    if uri == "audio-init.mp4" {
      Ok(ainit)
    } else if uri == "audio-1.m4s" {
      Ok(amedia)
    } else if uri == "video-init.mp4" {
      Ok(vinit)
    } else if uri == "video-1.m4s" {
      Ok(vmedia)
    } else {
      Err("unexpected uri \{uri}")
    }
  }
  let reader = dash_segment_reader_new(rep, fetch)
  let segment = match reader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no DASH segment")
    Err(e) => fail("dash fetch failed: \{e}")
  }
  let bytes = segment.bytes()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "mp4a")
  assert_eq(track.sample_rate, 44100U)
  assert_eq(track.channels, 1U)
  assert_eq(track.samples.length(), 5)
  let dec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  let pcm : Array[Double] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let out = match dec.decode_frame(bytes[start:end].to_owned()) {
      Ok(v) => v
      Err(e) => fail("AAC decode failed: \{e}")
    }
    for element in out {
      for v in element.samples {
        pcm.push(v)
      }
    }
  }
  assert_eq(pcm.length(), 5120)
  let reference = @libavutil.av_base64_decode(adts_ref_pcm_b64, 16384).unwrap()
  let mut max_diff = 0
  for i = 0; i < 5120; i = i + 1 {
    let v = pcm[i] * 32768.0
    let q = if v >= 32767.5 {
      32767
    } else if v <= -32768.5 {
      -32768
    } else {
      v.round().to_int()
    }
    let start = 2 * i
    let want = reference[start].to_int() | (reference[start + 1].to_int() << 8)
    let want = if want >= 32768 { want - 65536 } else { want }
    let diff = if q > want { q - want } else { want - q }
    if diff > max_diff {
      max_diff = diff
    }
  }
  assert_true(max_diff <= 1, msg="DASH AAC max diff \{max_diff}")
}
