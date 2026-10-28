///|
/// DASH SegmentList with single-file representations: one fMP4 file per
/// track (`BaseURL` + `mediaRange`/`range`), parsed back by `av_dash_parse`
/// and read through `DashSegmentReader` with byte-range fetches.

///|
fn dash_list_range(start : Int32, len : Int32) -> String {
  "\{start}-\{start + len - 1}"
}

///|
test "dash: single-file SegmentList video and audio decode round-trip" {
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
  let vfile : Array[Byte] = []
  for b in vinit {
    vfile.push(b)
  }
  for b in vmedia {
    vfile.push(b)
  }
  let vbytes = Bytes::from_array(vfile)
  let source = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let packets : Array[Bytes] = []
  for packet in source.packets {
    if packet.stream_index == 1 && packets.length() < 5 {
      packets.push(packet.data)
    }
  }
  let ainit = fmp4_aac_init_segment(44100, 1).unwrap()
  let asamples : Array[Fmp4Sample] = []
  for packet in packets {
    asamples.push(fmp4_sample(packet, 1024, true))
  }
  let amedia = fmp4_media_segment(1, 1, 0L, asamples).unwrap()
  let afile : Array[Byte] = []
  for b in ainit {
    afile.push(b)
  }
  for b in amedia {
    afile.push(b)
  }
  let abytes = Bytes::from_array(afile)
  let vinit_range = dash_list_range(0, vinit.length())
  let vmedia_range = dash_list_range(vinit.length(), vmedia.length())
  let ainit_range = dash_list_range(0, ainit.length())
  let amedia_range = dash_list_range(ainit.length(), amedia.length())
  let mpd_text = dash_write_segment_list_mpd(
    [
      DashListAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42C01E",
        "v1",
        200000L,
        90000L,
        45000L,
        [DashListSegment::new(media_range=vmedia_range)],
        base_url="video.mp4",
        initialization_range=vinit_range,
        width=64,
        height=48,
      ),
      DashListAdaptation::new(
        "audio",
        "audio/mp4",
        "mp4a.40.2",
        "a1",
        64000L,
        44100L,
        5120L,
        [DashListSegment::new(media_range=amedia_range)],
        base_url="audio.mp4",
        initialization_range=ainit_range,
        sample_rate=44100,
      ),
    ],
    media_duration_seconds=0.5,
  )
  assert_true(
    !mpd_text.contains("startNumber"),
    msg="default startNumber must be omitted",
  )
  let mpd = av_dash_parse(mpd_text).unwrap()
  assert_eq(mpd.periods[0].adaptation_sets.length(), 2)
  let vrep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(vrep.initialization, "video.mp4")
  assert_eq(vrep.initialization_range, vinit_range)
  assert_eq(vrep.segments.length(), 1)
  assert_eq(vrep.segments[0].uri, "video.mp4")
  assert_eq(vrep.segments[0].media_range, vmedia_range)
  let arep = mpd.periods[0].adaptation_sets[1].representations[0]
  assert_eq(arep.initialization, "audio.mp4")
  assert_eq(arep.segments[0].uri, "audio.mp4")
  let fetch : MediaFetch = (uri, offset, length) => {
    let file = if uri == "video.mp4" {
      vbytes
    } else if uri == "audio.mp4" {
      abytes
    } else {
      return Err("unexpected uri \{uri}")
    }
    let start = offset.to_int()
    let end = if length < 0L { file.length() } else { start + length.to_int() }
    if start < 0 || end > file.length() || start > end {
      return Err("bad range for \{uri}")
    }
    Ok(file[start:end].to_owned())
  }
  let vreader = dash_segment_reader_new(vrep, fetch)
  let vseg = match vreader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no video segment")
    Err(e) => fail("video read failed: \{e}")
  }
  let decoded_v = vseg.bytes()
  let vmovie = av_mov_open(decoded_v).unwrap()
  assert_eq(vmovie.tracks.length(), 1)
  let vtrack = vmovie.tracks[0]
  assert_eq(vtrack.codec, "avc1")
  assert_eq(vtrack.samples.length(), 5)
  let payload : Array[Byte] = []
  for sample in vtrack.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in decoded_v[start:end] {
      payload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let vdec = @libavcodec.new_h264_decoder()
  let frames = match vdec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
  let areader = dash_segment_reader_new(arep, fetch)
  let aseg = match areader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no audio segment")
    Err(e) => fail("audio read failed: \{e}")
  }
  let decoded_a = aseg.bytes()
  let amovie = av_mov_open(decoded_a).unwrap()
  assert_eq(amovie.tracks.length(), 1)
  let atrack = amovie.tracks[0]
  assert_eq(atrack.codec, "mp4a")
  assert_eq(atrack.samples.length(), 5)
  let adec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  for sample in atrack.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    match adec.decode_frame(decoded_a[start:end].to_owned()) {
      Ok(_) => ()
      Err(e) => fail("AAC decode failed: \{e}")
    }
  }
}

///|
test "dash: SegmentList keeps non-default startNumber" {
  let mpd_text = dash_write_segment_list_mpd(
    [
      DashListAdaptation::new(
        "video",
        "video/mp4",
        "avc1.42C01E",
        "v1",
        200000L,
        90000L,
        45000L,
        [DashListSegment::new(media="v-5.m4s")],
        initialization="v-init.mp4",
        start_number=5L,
      ),
    ],
    media_duration_seconds=0.5,
  )
  assert_true(mpd_text.contains("startNumber=\"5\""))
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.segments[0].uri, "v-5.m4s")
}
