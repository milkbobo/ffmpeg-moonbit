///|
// Header from the FFmpeg-generated dcaenc_stereo_48k fixture; only framing
// is under test here, so fill the unused coded payload with zeros.
fn dts_test_frame() -> Bytes {
  let header = b"\x7f\xfe\x80\x01\xfc\x3c\x3e\xf0\xb5\xe0\x01\x38\x00"
  Bytes::makei(1008, i => if i < header.length() { header[i] } else { 0 })
}

///|
test "raw DTS: preserve source positions, frame sizes, and sample timestamps" {
  let first = dts_test_frame()
  let second = Bytes::makei(1008, i => if i == 5 { 0x7c } else { first[i] })
  let swapped = Bytes::makei(1008, i => second[i ^ 1])
  let stream = b"prefix" + first + b"\x00\x00" + swapped
  let track = match @libavformat.av_dts_open(stream) {
    Ok(track) => track
    Err(e) => fail("DTS demux rejected packed stream with padding: \{e}")
  }
  assert_eq(track.sample_rate, 48000)
  assert_eq(track.channels, 2)
  assert_eq(track.frame_size, 512)
  assert_eq(track.total_samples, 1536L)
  assert_eq(track.frames.length(), 2)
  let a = track.frames[0]
  let b = track.frames[1]
  assert_eq((a.pos, a.size, a.pts, a.duration), (6L, 1008, 0L, 512))
  assert_eq((b.pos, b.size, b.pts, b.duration), (1016L, 1008, 512L, 1024))
  assert_true(a.is_keyframe && b.is_keyframe)
}

///|
test "raw DTS: reject incomplete frames and extension substreams" {
  let frame = dts_test_frame()
  assert_true(
    @libavformat.av_dts_open(frame[:1007].to_owned()) is
    Err("dts: truncated core frame"),
  )
  assert_true(
    @libavformat.av_dts_open(frame + frame[:20].to_owned()) is
    Err("dts: truncated core frame"),
  )
  assert_true(
    @libavformat.av_dts_open(frame + b"\x64\x58\x20\x25" + frame) is
    Err("dts: extension substream is not supported"),
  )
  assert_true(
    @libavformat.av_dts_open(b"\x64\x58\x20\x25" + frame) is
    Err("dts: extension substream is not supported"),
  )
  let changed_rate = Bytes::makei(1008, i => if i == 8 { 0xa1 } else { frame[i] })
  assert_true(
    @libavformat.av_dts_open(frame + changed_rate) is
    Err("dts: core stream parameters change between frames"),
  )
}

///|
test "raw DTS: probe requires complete frames and stronger evidence after junk" {
  let frame = dts_test_frame()
  let is_dts = fn(data) {
    let (id, _) = @libavformat.av_probe_input_format(@libavformat.ProbeData::new(data))
    id is Some(f) && f.name() == "dts"
  }
  assert_true(is_dts(frame))
  assert_false(is_dts(frame[:1007].to_owned()))
  assert_false(is_dts(b"junk" + frame))
  assert_true(is_dts(b"junk" + frame + frame))
  assert_false(is_dts(frame + b"\x64\x58\x20\x25"))
}
