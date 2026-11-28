///|
test "DERF and WADY DPCM match FFmpeg for mono and stereo across packets" {
  for
    (channels, wady, hash) in [
      (1, false, "cab3a702e86410e43c19b9fde1723869"),
      (2, false, "4ae3c60f529cbc327b8fab011baa1346"),
      (1, true, "196268cd07354c0e916d9265db155e9f"),
      (2, true, "f52c5a89aa1482359b2d2ee72ed0b1d8"),
    ] {
    let file : Array[Byte] = []
    if wady {
      wav_mux_tag(file, "WADY")
      file.push(0)
      file.push(83)
      wav_mux_u16(file, channels)
      wav_mux_u32(file, 22050U)
      wav_mux_u32(file, 0U)
      wav_mux_u32(file, (4108 / channels).reinterpret_as_uint())
      for _ in 0..<28 {
        file.push(0)
      }
    } else {
      wav_mux_tag(file, "DERF")
      wav_mux_u32(file, channels.reinterpret_as_uint())
      wav_mux_u32(file, 4108U)
    }
    for i in 0..<4108 {
      file.push(
        if i < 8 {
          63
        } else if i < 14 {
          127
        } else {
          ((i * 73) ^ (i >> 3)).to_byte()
        },
      )
    }
    let data = Bytes::from_array(file)
    let track = derf_wady_open(data, wady~).unwrap()
    assert_eq(track.frames[0].size, 2048 * channels)
    assert_eq(track.frames[1].pts, 2048L)
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name, if wady { "wady" } else { "derf" })
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), 22050)
    assert_eq(audio.samples()[0].length(), 4108 / channels)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
    if channels == 2 {
      assert_true(
        derf_wady_open(data[:data.length() - 1].to_owned(), wady~) is Err(_),
      )
    }
  }
}
