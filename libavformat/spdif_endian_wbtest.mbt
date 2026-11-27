///|
test "big-endian IEC 61937 preserves odd AAC payloads in raw captures and RIFX" {
  let raw = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let little = av_spdif_mux(raw, codec="aac").unwrap()
  let big = av_spdif_mux(raw, codec="aac", big_endian=true).unwrap()
  assert_eq(big[:4].to_owned(), b"\xf8\x72\x4e\x1f")
  assert_eq(big, Bytes::makei(little.length(), i => little[i ^ 1]))
  let prefixed = b"\x00\x00\x00" + big
  let track = av_spdif_open(prefixed).unwrap()
  assert_true(track.big_endian)
  let first = track.frames[0]
  assert_eq(first.pos, 11L)
  assert_eq(first.size, 185)
  let first_frame = raw[:185].to_owned()
  assert_eq(track.packet_data(prefixed, first).unwrap(), first_frame)
  assert_eq(spdif_packet_data(prefixed, first).unwrap(), first_frame)
  let rifx = wav_muxer_new(22050, 2, 16, big_endian=true).unwrap()
  rifx.data.append(big.to_array())
  let file = rifx.finish()
  assert_eq(file[:4].to_owned(), b"RIFX")
  let wave = av_wav_open(file).unwrap()
  assert_eq(wave.format.codec, "aac")
  assert_eq(wave.packet_data(file, wave.packets[0]).unwrap(), first_frame)
  let expected = decode_audio_file(raw)
  for input in [prefixed, file] {
    let audio = decode_audio_file(input)
    assert_eq(audio.channels, 2)
    assert_eq(audio.sample_rate, 44100)
    assert_eq(audio.samples, expected.samples)
  }
  let opposite = wav_muxer_new(22050, 2, 16, big_endian=true).unwrap()
  opposite.data.append(little.to_array())
  assert_eq(av_wav_open(opposite.finish()).unwrap().format.codec, "pcm_s16be")
  assert_true(av_spdif_open(big[:4096].to_owned() + little[4096:].to_owned()) is Err("spdif: changing stream format"))
}

///|
test "big-endian IEC 61937 normalizes little-endian DTS and reads inner E-AC-3 frames" {
  let dts = playback_audit_dts_fixture()
  let dts_le = Bytes::makei(dts.length(), i => dts[i ^ 1])
  let big = av_spdif_mux(dts, codec="dts", big_endian=true).unwrap()
  assert_eq(av_spdif_mux(dts_le, codec="dts", big_endian=true).unwrap(), big)
  assert_eq(decode_audio_file(big).samples, decode_audio_file(dts).samples)
  let fixture = eac3_decode(eac3_hi1blk_b64)
  let source = av_ac3_open(fixture).unwrap().frames[0]
  let first = fixture[:source.size].to_owned()
  let mut stream = b""
  for _ in 0..<(1536 / source.duration) {
    stream = stream + first
  }
  let packed = av_spdif_mux(stream, codec="eac3", big_endian=true).unwrap()
  let track = av_spdif_open(packed).unwrap()
  let packet = track.frames[1]
  assert_eq(packet.pos, (8 + source.size).to_int64())
  assert_eq(track.packet_data(packed, packet).unwrap(), first)
  assert_eq(spdif_packet_data(packed, packet).unwrap(), first)
}
