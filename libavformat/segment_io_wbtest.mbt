///|
fn segment_test_fetch(files : Array[(String, Bytes)]) -> MediaFetch {
  (uri, offset, length) => {
    for (name, b64) in files {
      if uri == name {
        let data = match @libavutil.av_base64_decode(b64, 1048576) {
          Ok(value) => value
          Err(e) => return Err(e)
        }
        if offset < 0L || offset > data.length().to_int64() {
          return Err("bad fixture range")
        }
        let end = if length < 0L {
          data.length().to_int64()
        } else {
          offset + length
        }
        if end > data.length().to_int64() {
          return Err("bad fixture range")
        }
        return Ok(data[offset.to_int():end.to_int()].to_owned())
      }
    }
    Err("missing resource: " + uri)
  }
}

///|
fn segment_test_decode_mp4(bytes : Bytes) -> Array[@libavcodec.H264Frame] raise {
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  let samples : Array[Bytes] = []
  for sample in track.samples {
    let offset = sample.offset.to_int()
    samples.push(
      bytes[offset:offset + sample.size.reinterpret_as_int()].to_owned(),
    )
  }
  @libavcodec.h264_decode_avc_frames(track.extradata.unwrap(), samples, false).unwrap()
}

///|
test "HLS callback -> TS demux -> H264: four real frames match FFmpeg MD5" {
  let playlist = av_hls_parse(
    segments_ts_manifest,
    base_uri="https://example.test/segments_ts/list.m3u8",
  ).unwrap()
  let reader = hls_segment_reader_new(
    playlist,
    segment_test_fetch(segments_ts_files),
  ).unwrap()
  let mut frame_index = 0
  for _ in 0..<2 {
    let bytes = reader.next().unwrap().unwrap().bytes()
    let ts = av_mpegts_open(bytes).unwrap()
    let elementary : Array[Byte] = []
    for packet in ts.packets {
      if ts.streams[packet.stream_index].codec == "h264" {
        for byte in packet.payload {
          elementary.push(byte)
        }
      }
    }
    let frames = @libavcodec.h264_decode_annexb_frames(
      Bytes::from_array(elementary[:]),
      false,
    ).unwrap()
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_ts_md5[frame_index],
        msg="TS frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}

///|
test "HLS callback -> fMP4 init+fragment -> H264: four real frames match FFmpeg MD5" {
  let playlist = av_hls_parse(
    segments_mp4_manifest,
    base_uri="https://example.test/segments_mp4/list.m3u8",
  ).unwrap()
  let reader = hls_segment_reader_new(
    playlist,
    segment_test_fetch(segments_mp4_files),
  ).unwrap()
  let mut frame_index = 0
  for _ in 0..<2 {
    let frames = segment_test_decode_mp4(
      reader.next().unwrap().unwrap().bytes(),
    )
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_mp4_md5[frame_index],
        msg="MP4 frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}

///|
test "DASH callback -> fMP4 init+fragment -> H264: four real frames match FFmpeg MD5" {
  let mpd = av_dash_parse(
    segments_dash_manifest,
    base_uri="https://example.test/segments_dash/list.mpd",
  ).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  let reader = dash_segment_reader_new(
    rep,
    segment_test_fetch(segments_dash_files),
  )
  let mut frame_index = 0
  for _ in 0..<2 {
    let frames = segment_test_decode_mp4(
      reader.next().unwrap().unwrap().bytes(),
    )
    assert_eq(frames.length(), 2)
    for frame in frames {
      assert_eq(
        h264_frame_md5(frame),
        segments_dash_md5[frame_index],
        msg="DASH frame \{frame_index}",
      )
      frame_index += 1
    }
  }
  assert_eq(frame_index, 4)
  assert_true(reader.next().unwrap() is None)
}
