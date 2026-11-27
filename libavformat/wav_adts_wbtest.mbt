///|
test "tagged WAV and Wave64 expose HE-AAC output metadata and ADTS duration" {
  let raw = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let source = av_adts_open(raw).unwrap()
  let wav = wav_muxer_new(22050, 1, 16).unwrap()
  wav.data.append(raw.to_array())
  let w64 = w64_muxer_new(22050, 1, 16).unwrap()
  w64.data.append(raw.to_array())
  let expected = decode_audio_file(raw)
  for
    (carrier, tag_offset, open, name) in [
      (wav.finish(), 20, av_wav_open, "wav"),
      (w64.finish(), 64, av_w64_open, "w64"),
    ] {
    let bytes = carrier.to_array()
    bytes[tag_offset] = 0x00
    bytes[tag_offset + 1] = 0x16
    let data = Bytes::from_array(bytes)
    let wave = open(data).unwrap()
    assert_eq(wave.format.codec, "aac")
    assert_eq(wave.sample_count, 2048L)
    assert_eq(wave.format.sample_rate, 22050)
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), name)
    assert_eq(media.streams()[0].sample_rate, 44100)
    assert_eq(media.streams()[0].channels, 2)
    assert_eq(media.duration_seconds(), Some(4096.0 / 44100.0))
    for f in source.frames {
      let packet = media.next_packet().unwrap()
      let start = f.pos.to_int()
      assert_eq(packet.data, raw[start:start + f.size].to_owned())
      assert_eq(packet.pts, ts_nopts)
    }
    assert_true(media.next_packet() is None)
    assert_eq(decode_audio_file(data).samples, expected.samples)
  }
}
