///|
test "MOV GSM exports fixed packets with exact presentation duration" {
  for count in [17, 160, 161, 641] {
    let wav = wav_muxer_new(8000, 1, 16).unwrap()
    wav.write_samples(Array::makei(count, i => i * 7919 % 65536 - 32768)[:])
    let audio = decode_audio_file(wav.finish())
    let encoded = audio.to_mov_gsm()
    let track = av_mov_open(encoded).unwrap().tracks[0]
    assert_eq(track.codec, "agsm")
    assert_eq(track.duration, count.to_uint64())
    assert_eq(track.samples_per_frame, 160U)
    assert_eq(track.bytes_per_frame, 33U)
    let raw = audio.to_gsm()
    assert_eq(track.samples.length(), raw.length() / 33)
    for i, packet in track.samples {
      let pos = packet.offset.to_int()
      assert_eq(packet.size, 33U)
      assert_eq(encoded[pos:pos + 33], raw[i * 33:i * 33 + 33])
    }
    let full = decode_audio_file(raw, filename="track.gsm").samples()[0]
    assert_eq(decode_audio_file(encoded).samples()[0], full[:count].to_owned())
    assert_true(av_mov_mux_gsm(raw, valid_samples=0) is Err(_))
    assert_true(av_mov_mux_gsm(raw[:raw.length() - 1].to_owned()) is Err(_))
  }
}

///|
test "MOV GSM trims a lone packet with a short sample table duration" {
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  wav.write_samples(Array::make(17, 16384)[:])
  let file = decode_audio_file(wav.finish()).to_mov_gsm()
  let updated = file.to_array()
  let duration = for i in 0..<(file.length() - 19) {
    if pb_match(file, i, "stts") {
      break i + 16
    }
  } nobreak {
    fail("missing stts atom")
  }
  updated[duration + 3] = 17
  let shortened = Bytes::from_array(updated)
  assert_eq(av_mov_open(shortened).unwrap().tracks[0].samples[0].duration, 17U)
  assert_eq(decode_audio_file(shortened).samples()[0].length(), 17)
}
