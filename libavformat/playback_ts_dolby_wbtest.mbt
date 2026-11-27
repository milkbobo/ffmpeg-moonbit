///|
test "MPEG-TS Dolby audio reassembles frames and preserves PES timestamps" {
  for
    (kind, data) in [
      (0x81, ac3_decode(ac3_mono44_b64)),
      (0x87, eac3_decode(eac3_mono48_b64)),
      (0x87, eac3_decode(eac3_hi1blk_b64)),
    ] {
    let expected = av_ac3_open(data).unwrap()
    let first_size = expected.frames[0].size
    let split = first_size + 2
    let ts = ts_muxer_new(video=false, audio_stream_type=kind)
    ts.write_audio(45000L, data[:2].to_owned())
    ts.write_audio(90000L, data[2:split].to_owned())
    ts.write_audio(120000L, data[split:].to_owned())
    let file = ts.finish()
    let media = MediaFile::open(file)
    let stream = media.streams()[0]
    assert_eq(stream.codec_id, expected.codec)
    assert_eq(stream.sample_rate, expected.sample_rate)
    assert_eq(stream.channels, expected.channels)
    let mut pts = 120000L
    for index, frame in expected.frames {
      let start = frame.pos.to_int()
      let packet = media.next_packet().unwrap()
      assert_eq(packet.data, data[start:start + frame.size].to_owned())
      assert_eq(
        packet.pts,
        if index == 0 {
          45000L
        } else if index == 1 {
          90000L
        } else {
          pts
        },
      )
      assert_true(packet.keyframe)
      if index >= 2 {
        pts += frame.duration.to_int64() *
          90000L /
          stream.sample_rate.to_int64()
      }
    }
    assert_true(media.next_packet() is None)
    if expected.frame_size == 1536 {
      let pcm = decode_audio_file(file)
      assert_eq(pcm.samples, decode_audio_file(data).samples)
      assert_eq(pcm.samples[0].length().to_int64(), expected.total_samples)
    }
  }
}
