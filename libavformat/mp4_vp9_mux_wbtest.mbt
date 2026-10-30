///|
/// VP9-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
test "mp4 muxer: VP9 samples and vpcC round-trip" {
  // vpcC FullBox: version 1, flags 0, profile 0, level 0, 8-bit 4:2:0,
  // unspecified colour fields, no codec initialization data.
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let mux = mp4_vp9_muxer_new(64, 48, vpcc, timescale=90000).unwrap()
  mux.write_packet(b"\x82\x00\x01", duration=3000, keyframe=true).unwrap()
  mux
  .write_packet(b"\x82\x00\x02", duration=3000, keyframe=false, cts=-1000)
  .unwrap()
  let bytes = mux.finish()
  let track = av_mov_open(bytes).unwrap().tracks[0]
  assert_eq(track.codec, "vp09")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.extradata.unwrap(), Bytes::from_array([1, 0, 0, 0x82]))
  let params = mp4_track_codec_parameters(track)
  assert_eq(params.profile, 0)
  assert_eq(params.pix_fmt, "yuv420p")
  assert_eq(track.samples.length(), 2)
  let expected_pts : Array[Int64] = [0L, 2000L]
  for i in 0..<2 {
    let sample = track.samples[i]
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.pts, expected_pts[i])
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i == 0)
  }
}

///|
test "mp4 muxer: real VP9 frames decode round-trip" {
  let frames : Array[Bytes] = []
  for f in webm_av_vp9_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let mux = mp4_vp9_muxer_new(64, 48, vpcc).unwrap()
  for i, frame in frames {
    mux.write_packet(frame, duration=9000, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "vp09")
  assert_eq(track.samples.length(), 5)
  let vdec = @libavcodec.vp9_decoder_new()
  for i, sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = bytes[start:end].to_owned()
    assert_eq(packet, frames[i])
    let decoded = match vdec.decode_packet(packet) {
      Ok(v) => v
      Err(e) => fail("vp9 frame \{i}: \{e}")
    }
    assert_eq(decoded.length(), 1)
    let yuv = vdec.frame_bytes()
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
