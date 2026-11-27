///|
test "MPEG-TS detects the MPEG audio layer and decodes frames split across PES" {
  let layer1 = Bytes::makei(288, i => {
    if i < 4 {
      b"\xff\xff\x68\xc4"[i]
    } else {
      b'\x00'
    }
  })
  let layer2 = @libavutil.av_base64_decode(raw_mp2_linear_b64, 512).unwrap()
  let layer3 = @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()[417:].to_owned()
  for
    (kind, codec, data) in [
      (0x03, "mp1", layer1 + layer1 + layer1),
      (0x04, "mp2", layer2 + layer2 + layer2),
      (0x03, "mp3", layer3),
    ] {
    let expected = av_mp3_open(data).unwrap()
    let split = expected.frames[0].size + 2
    let mux = ts_muxer_new(video=false, audio_stream_type=kind)
    mux.write_audio(45000L, data[:2].to_owned())
    mux.write_audio(90000L, data[2:split].to_owned())
    mux.write_audio(120000L, data[split:].to_owned())
    let file = mux.finish()
    let media = MediaFile::open(file)
    let stream = media.streams()[0]
    assert_eq(stream.codec_id, codec)
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
      if index >= 2 {
        pts += frame.duration.to_int64() *
          90000L /
          stream.sample_rate.to_int64()
      }
    }
    assert_true(media.next_packet() is None)
    let pcm = decode_audio_file(file)
    assert_eq(
      pcm.samples,
      decode_audio_file(data, filename="audio.mp3").samples,
    )
    assert_eq(pcm.samples[0].length().to_int64(), expected.total_samples)
  }
}
