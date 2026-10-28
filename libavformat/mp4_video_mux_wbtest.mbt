///|
/// H.264-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
/// 44-byte avcC record from a real 64x48 High-profile MP4 fixture. */
let mp4_h264_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mp4 muxer: H.264 samples and avcC round-trip" {
  let avcc = @libavutil.av_base64_decode(mp4_h264_avcc_b64, 1024).unwrap()
  let mux = mp4_h264_muxer_new(64, 48, avcc, timescale=90000).unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x02\x65\x88", duration=3000, keyframe=true)
  .unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x02\x41\x9A", duration=3000, keyframe=false)
  .unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x02\x65\x88", duration=3000, keyframe=true)
  .unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.timescale, 90000U)
  assert_eq(track.extradata.unwrap(), avcc)
  assert_eq(track.samples.length(), 3)
  let sizes : Array[Int32] = [6, 6, 6]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, sizes[i].reinterpret_as_uint())
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i != 1)
  }
}

///|
test "mp4 muxer: invalid H.264 parameters are rejected" {
  let avcc = @libavutil.av_base64_decode(mp4_h264_avcc_b64, 1024).unwrap()
  match mp4_h264_muxer_new(0, 48, avcc) {
    Ok(_) => fail("zero width must fail")
    Err(_) => ()
  }
  let mux = mp4_h264_muxer_new(64, 48, avcc).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty packet must fail")
    Err(_) => ()
  }
}

///|
test "mp4 muxer: real H.264 samples decode round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  assert_eq(off, joined.length())
  let mux = mp4_h264_muxer_new(64, 48, avcc).unwrap()
  for i, sample in samples {
    mux.write_packet(sample, duration=3000, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.extradata.unwrap(), avcc)
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
