///|
test "IEC 61937 ADTS playback reports HE-AAC stereo and keeps core packet timestamps" {
  let source = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let encoded = av_spdif_mux(source, codec="aac").unwrap()
  assert_eq(encoded[4], 0x07)
  let indexed = av_spdif_open(encoded).unwrap()
  let original = av_adts_open(source).unwrap()
  assert_eq(indexed.sample_rate, 22050)
  assert_eq(indexed.channels, 1)
  for i, frame in indexed.frames {
    assert_eq(frame.pos, (i * 4096 + 8).to_int64())
    assert_eq(frame.pts, (i * 1024).to_int64())
    let packet = original.frames[i]
    let pos = packet.pos.to_int()
    assert_eq(
      spdif_packet_data(encoded, frame).unwrap(),
      source[pos:pos + packet.size].to_owned(),
    )
  }
  let wav = wav_muxer_new(22050, 2, 16).unwrap()
  wav.data.append(encoded.to_array())
  let wave64 = w64_muxer_new(22050, 2, 16).unwrap()
  wave64.data.append(encoded.to_array())
  let expected = decode_audio_file(source)
  for
    (file, name) in [
      (encoded, "spdif"),
      (wav.finish(), "wav"),
      (wave64.finish(), "w64"),
    ] {
    let media = MediaFile::open(file)
    assert_eq(media.format_name(), name)
    assert_eq(media.streams()[0].codec_id, "aac")
    assert_eq(media.streams()[0].sample_rate, 44100)
    assert_eq(media.streams()[0].channels, 2)
    assert_eq(media.stream_timebase(0), Some((22050.0, 0.0)))
    assert_eq(media.duration_seconds(), Some(4096.0 / 44100.0))
    assert_eq(media.next_packet().unwrap().pts, 0L)
    assert_eq(media.next_packet().unwrap().pts, 1024L)
    assert_eq(decode_audio_file(file).samples, expected.samples)
  }
}

///|
fn spdif_aac_test_frame(blocks : Int32, size : Int32) -> Bytes {
  let header = @libavcodec.aac_adts_header_write(48000, 2, 2, size)
    .unwrap()
    .to_array()
  header[6] = (0xfc | (blocks - 1)).to_byte()
  Bytes::makei(size, i => if i < header.length() { header[i] } else { 0 })
}

///|
test "IEC 61937 ADTS remux preserves multiple raw blocks and validates burst length" {
  for (blocks, kind, period) in [(2, 0x13, 8192), (4, 0x33, 16384)] {
    let frame = spdif_aac_test_frame(blocks, 31)
    let out = av_spdif_mux(frame + frame, codec="aac").unwrap()
    assert_eq(out[4].to_int(), kind)
    assert_eq(out.length(), 2 * period)
    let track = av_spdif_open(out).unwrap()
    let samples = (blocks * 1024).to_int64()
    assert_eq(track.frames.map(f => f.pts), [0L, samples])
    assert_eq(track.total_samples, 2L * samples)
    assert_eq(spdif_packet_data(out, track.frames[1]).unwrap(), frame)
    let kind_mismatch = out.to_array()
    kind_mismatch[4] = 0x07
    assert_true(
      spdif_read_burst(Bytes::from_array(kind_mismatch)[:], 0) is None,
    )
  }
  assert_true(
    av_spdif_mux(spdif_aac_test_frame(3, 31), codec="aac")
    is Err("spdif: unsupported ADTS header"),
  )
  assert_true(
    av_spdif_mux(spdif_aac_test_frame(4, 8191), codec="aac")
    is Err("spdif: payload exceeds length field"),
  )
}
