///|
test "MPEG-TS DTS core validates the private type and joins frames across PES" {
  let raw = playback_audit_dts_fixture()
  let track = av_dts_open(raw).unwrap()
  let first_size = track.frames[0].size
  for stream_type in [0x82, 0x8A] {
    let mux = ts_muxer_new(video=false, audio_stream_type=stream_type)
    mux.write_audio(45000L, raw[:2].to_owned())
    mux.write_audio(90000L, raw[2:first_size + 2].to_owned())
    mux.write_audio(120000L, raw[first_size + 2:].to_owned())
    let file = mux.finish()
    let media = MediaFile::open(file)
    let stream = media.streams()[0]
    assert_eq(stream.codec_id, "dts")
    assert_true(stream.media_type == MediaType::Audio)
    assert_eq(stream.sample_rate, track.sample_rate)
    assert_eq(stream.channels, track.channels)
    for i, frame in track.frames {
      let start = frame.pos.to_int()
      let packet = media.next_packet().unwrap()
      assert_eq(packet.pts, if i == 0 { 45000L } else { 90000L })
      assert_eq(packet.data, raw[start:start + frame.size].to_owned())
      assert_true(packet.keyframe)
    }
    assert_true(media.next_packet() is None)
    assert_eq(decode_audio_file(file).samples, decode_audio_file(raw).samples)
  }
  let other = ts_muxer_new(video=false, audio_stream_type=0x82)
  other.write_audio(45000L, Bytes::make(512, 0))
  assert_eq(MediaFile::open(other.finish()).streams()[0].codec_id, "")
}
