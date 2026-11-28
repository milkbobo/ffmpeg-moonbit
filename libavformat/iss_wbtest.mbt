///|
test "Funcom ISS resets packet predictors and matches FFmpeg for both nibble orders" {
  for
    (channels, hash) in [
      (1, "310abc54882720d44017e5a6cb3ee70b"),
      (2, "68391394f559b599729a924e9b6427c0"),
    ] {
    let file : Array[Byte] = []
    let size = 24 + 8 * channels
    let duration = (size - channels * 4) * 2 / channels
    wav_mux_tag(file, "IMA_ADPCM_Sound \{size} clip")
    file.push(0)
    wav_mux_tag(file, " 0 \{channels - 1} 1 2 0 1.000 \{3 * size} ")
    let start = file.length()
    let payload = Array::makei(3 * size, i => ((i * 73) ^ (i >> 3)).to_byte())
    for block in 0..<3 {
      for ch in 0..<channels {
        let pos = block * size + ch * 4
        let predictor = 12000 - 6000 * block - 22000 * ch
        payload[pos] = predictor.to_byte()
        payload[pos + 1] = (predictor >> 8).to_byte()
        payload[pos + 2] = (8 + 27 * block + 13 * ch).to_byte()
        payload[pos + 3] = 0
      }
    }
    file.append(payload)
    let data = Bytes::from_array(file)
    let track = iss_open(data).unwrap()
    assert_eq(track.frames.length(), 3)
    assert_eq(track.frames[0].pos, start.to_int64())
    assert_eq(track.frames[1].pts, duration.to_int64())
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), 22050)
    assert_eq(audio.samples()[0].length(), duration * 3)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
    assert_true(iss_open(data[:data.length() - 1].to_owned()) is Err(_))
  }
}
