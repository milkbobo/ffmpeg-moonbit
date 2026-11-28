///|
fn ima_game_test_audio(
  frames : Int32,
  channels : Int32,
) -> DecodedAudio raise MediaError {
  let pcm = Array::makei(frames * channels, i => i * 12289 % 65536 - 32768)
  let wav = wav_muxer_new(22050, channels, 16).unwrap()
  wav.write_samples(pcm[:])
  decode_audio_file(wav.finish())
}

///|
test "KVAG and APM match FFmpeg and retain state between packets" {
  let count = 8346
  for
    (channels, apm, hash) in [
      (1, false, "88b12a67d5e87f2d0dd6d8797df3cc3b"),
      (1, true, "695eb06439bd2b3917e2f7d16fc493c1"),
      (2, false, "5f201fd30c8697be82bbb6fe123a6a29"),
      (2, true, "5f8916c89aec114569db31fbcaf37728"),
    ] {
    let data = ima_game_test_audio(count, channels).to_ima_game(apm~)
    assert_eq(telephony_md5(data), hash)
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), if apm { "apm" } else { "kvag" })
    let first = media.next_packet().unwrap()
    let second = media.next_packet().unwrap()
    assert_eq(
      (first.pts, first.data.length(), first.keyframe),
      (0L, 4096, true),
    )
    assert_eq(second.pts, 8192L / channels.to_int64())
    assert_false(second.keyframe)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.sample_rate(), 22050)
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.samples()[0].length(), count)
  }
}

///|
test "APM reads both initial predictors from the header" {
  let original = ima_game_test_audio(8346, 2).to_ima_game(apm=true)
  let words : Array[Byte] = []
  for word in [-12345, 17, 0, 23456, 39] {
    wav_mux_u32(words, word.reinterpret_as_uint())
  }
  let state = Bytes::makei(original.length(), i => {
    if i >= 44 && i < 64 {
      words[i - 44]
    } else {
      original[i]
    }
  })
  let pcm = decode_audio_file(state).to_wav_s16()
  let wav = av_wav_open(pcm).unwrap()
  assert_eq(
    telephony_md5(pcm[wav.data_offset.to_int():].to_owned()),
    "921a6d0fe902aa01130f055dba31aa46",
  )
  let saved = Bytes::makei(state.length(), i => {
    if i == 40 {
      1
    } else {
      state[i]
    }
  })
  assert_true(
    ima_game_open(saved, apm=true) is Err("apm: saved samples are unsupported"),
  )
}

///|
test "KVAG and APM preserve the final unpaired sample in the high nibble" {
  let mono = ima_game_test_audio(1, 1)
  let kvag = mono.to_ima_game()
  assert_eq(kvag[14:].to_owned(), b"\xf0")
  assert_eq(decode_audio_file(kvag).samples()[0].length(), 2)
  let stereo = ima_game_test_audio(1, 2).to_ima_game(apm=true)
  assert_eq(stereo[100:].to_owned(), b"\xf0\xf0")
  let decoded = decode_audio_file(stereo)
  assert_eq(decoded.samples()[0].length(), 2)
  assert_eq(decoded.samples()[1].length(), 2)
  assert_true(ima_game_open(stereo[:101].to_owned(), apm=true) is Err(_))
}
