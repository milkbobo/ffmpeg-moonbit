///|
/// Real-data fMP4 tests for the HEVC/AV1/VP9 single-track writers: init and
/// media segments are concatenated, parsed back by `av_mov_open`, and the
/// reassembled samples are decoded against the same FFmpeg references as the
/// non-fragmented MP4 tests.

///|
fn fmp4_video_payload(bytes : Bytes, track : Mp4Track) -> Array[Byte] {
  let out : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in bytes[start:end] {
      out.push(b)
    }
  }
  out
}

///|
test "fmp4 muxer: real HEVC segments decode round-trip" {
  let stream = @libavutil.av_base64_decode(mkv_hevc_stream_b64, 1000000).unwrap()
  let hvcc = @libavutil.av_base64_decode(mkv_hevc_hvcc_b64, 1024).unwrap()
  let packets = mkv_hevc_au_packets(stream)
  assert_eq(packets.length(), 5)
  let init = fmp4_hevc_init_segment(64, 64, 90000, hvcc).unwrap()
  let samples : Array[Fmp4Sample] = []
  for i, packet in packets {
    samples.push(fmp4_sample(packet, 3000, i == 0))
  }
  let seg = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let bytes = fmp4_join([init, seg])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "hvc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 64)
  assert_eq(track.extradata.unwrap(), hvcc)
  assert_eq(track.samples.length(), 5)
  let payload = Bytes::from_array(fmp4_video_payload(bytes, track))
  // The fixture stores Annex B start codes; each packet re-prefixes its NALs
  // with four-byte lengths.
  let expected : Array[Byte] = []
  for packet in packets {
    for b in packet {
      expected.push(b)
    }
  }
  assert_eq(payload, Bytes::from_array(expected))
  let frames = @libavcodec.ff_hevc_decode_frames_ex(payload, true, 4, true).unwrap()
  let sorted = frames.copy()
  sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  assert_eq(sorted.length(), mkv_hevc_refs.length())
  for i = 0; i < mkv_hevc_refs.length(); i = i + 1 {
    assert_eq(mkv_hevc_md5(sorted[i].yuvp(8)), mkv_hevc_refs[i])
  }
}

///|
test "fmp4 muxer: real AV1 segments decode round-trip" {
  let av1c = @libavutil.av_base64_decode(mp4_av1_real_av1c_b64, 256).unwrap()
  let frames : Array[Bytes] = []
  for f in mp4_av1_real_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  let init = fmp4_av1_init_segment(64, 48, 90000, av1c).unwrap()
  let samples : Array[Fmp4Sample] = []
  for i, frame in frames {
    samples.push(fmp4_sample(frame, 9000, i == 0))
  }
  let seg = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let bytes = fmp4_join([init, seg])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 5)
  let payload = fmp4_video_payload(bytes, track)
  let mut off = 0
  for frame in frames {
    assert_eq(Bytes::from_array(payload[off:off + frame.length()]), frame)
    off = off + frame.length()
  }
  let dec = @libavcodec.Av1Decoder::new()
  for i, frame in frames {
    let shown = match dec.decode_packet(frame) {
      Ok(v) => v
      Err(e) => fail("av1 frame \{i}: \{e}")
    }
    let picture = match shown {
      Some(p) => p
      None => fail("av1 frame \{i} not shown")
    }
    assert_eq(mp4_av1_real_md5(picture.packed()), mp4_av1_real_refs[i])
  }
}

///|
test "fmp4 muxer: real VP9 segments decode round-trip" {
  let frames : Array[Bytes] = []
  for f in webm_av_vp9_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let init = fmp4_vp9_init_segment(64, 48, 90000, vpcc).unwrap()
  let samples : Array[Fmp4Sample] = []
  for i, frame in frames {
    samples.push(fmp4_sample(frame, 9000, i == 0))
  }
  let seg = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let bytes = fmp4_join([init, seg])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "vp09")
  assert_eq(track.samples.length(), 5)
  let payload = fmp4_video_payload(bytes, track)
  let mut off = 0
  for frame in frames {
    assert_eq(Bytes::from_array(payload[off:off + frame.length()]), frame)
    off = off + frame.length()
  }
  let dec = @libavcodec.vp9_decoder_new()
  for i, frame in frames {
    let decoded = match dec.decode_packet(frame) {
      Ok(v) => v
      Err(e) => fail("vp9 frame \{i}: \{e}")
    }
    assert_eq(decoded.length(), 1)
    let yuv = dec.frame_bytes()
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, yuv, yuv.length())
    let hex = "0123456789abcdef"
    let text = StringBuilder()
    for byte in digest {
      text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
      text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
    }
    assert_eq(text.to_string(), webm_av_vp9_refs[i], msg="vp9 frame \{i}")
  }
}
