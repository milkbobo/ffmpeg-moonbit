///|
test "IEC 61937 plays MPEG audio using the layer from the frame header" {
  let mp1 = Bytes::makei(288, i => {
    if i < 4 {
      b"\xff\xff\x68\xc4"[i]
    } else {
      0
    }
  })
  let mp2 = @libavutil.av_base64_decode(raw_mp2_linear_b64, 512).unwrap()
  let mp3 = @libavutil.av_base64_decode(raw_mp3_b64, 8192).unwrap()[417:].to_owned()
  for
    (codec, raw, data_type, period) in [
      ("mp1", mp1 + mp1, 0x04, 1536),
      ("mp2", mp2 + mp2, 0x05, 4608),
      ("mp3", mp3, 0x05, 4608),
    ] {
    let original = mpa_open(raw, for_transport=true).unwrap()
    let last = original.frames[original.frames.length() - 1]
    let source = raw[:last.pos.to_int() + last.size].to_owned()
    let encoded = av_spdif_mux(source, codec~).unwrap()
    assert_eq(encoded[4].to_int(), data_type)
    assert_eq(encoded.length(), original.frames.length() * period)
    let stream = av_spdif_open(encoded).unwrap()
    assert_eq(stream.codec, codec)
    assert_eq(stream.total_samples, original.total_samples)
    assert_eq(
      stream.frames.map(f => (f.pts, f.duration, f.size)),
      original.frames.map(f => (f.pts, f.duration, f.size)),
    )
    for i, packet in stream.frames {
      let pos = original.frames[i].pos.to_int()
      let coded = spdif_packet_data(encoded, packet).unwrap()
      assert_eq(coded, source[pos:pos + packet.size].to_owned())
      assert_eq(packet.pos, (i * period + 8).to_int64())
    }
    let decoded = decode_audio_file(encoded)
    let expected = decode_audio_file(source, filename="stream.mp3")
    assert_eq(decoded.format_name, "spdif")
    assert_eq(decoded.samples, expected.samples)
    if codec == "mp2" {
      let wave = w64_muxer_new(stream.sample_rate, 2, 16).unwrap()
      wave.data.append(encoded.to_array())
      let audio = decode_audio_file(wave.finish())
      assert_eq(audio.format_name, "w64")
      assert_eq(audio.codec_id, "mp2")
      assert_eq(audio.samples, expected.samples)
    }
  }
}

///|
test "IEC 61937 MPEG-2 low-rate and extended bursts keep decoded sample durations" {
  for
    (word, kind, codec, period) in [
      (b"\xff\xf7\x48\xc4", 0x08, "mp1", 3072),
      (b"\xff\xf5\x48\xc4", 0x09, "mp2", 9216),
      (b"\xff\xf3\x84\xc4", 0x0a, "mp3", 4608),
      (b"\xff\xf3\x85\xc4", 0x06, "mp3", 4608),
    ] {
    let h = @libavcodec.avpriv_mpegaudio_decode_header(rb32(word, 0)).unwrap()
    let frame = Bytes::makei(h.frame_size, i => if i < 4 { word[i] } else { 0 })
    let out = av_spdif_mux(frame + frame, codec~).unwrap()
    assert_eq(out[4].to_int(), kind)
    assert_eq(out.length(), 2 * period)
    let track = av_spdif_open(out).unwrap()
    assert_eq(track.codec, codec)
    assert_eq(track.sample_rate, h.sample_rate)
    let duration = match codec {
      "mp1" => 384
      "mp2" => 1152
      _ => 576
    }
    assert_eq(track.frames.map(f => f.pts), [0L, duration.to_int64()])
    assert_eq(track.total_samples, 2L * duration.to_int64())
  }
}
