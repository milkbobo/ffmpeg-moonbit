///|
test "CAF WAV ADPCM matches FFmpeg and trims the padded final block" {
  for
    (codec, channels, per_block, file_md5, pcm_md5) in [
      (
        "adpcm_ima_wav", 1, 2041, "a1864d82212a634b99fda7811581d54d", "b82e183577fb50405642f19d563a1bc7",
      ),
      (
        "adpcm_ms", 1, 2036, "baa8548e0c9d297c8b86223bab1e8952", "9f4cf5ac804cb25ef63c084dad711f7d",
      ),
      (
        "adpcm_ima_wav", 2, 1017, "938fa183e37a48f97152e730587507a8", "c010706da65b9af246b24f6e9b303705",
      ),
      (
        "adpcm_ms", 2, 1012, "a8b613430df5504dbf6dabe0cb9bb3f2", "3f6c4ba5fd6b9ac932141515029e0b6a",
      ),
    ] {
    let rate = if channels == 1 { 8000 } else { 32000 }
    let samples = Array::makei(5203 * channels, i => {
      let n = i / channels
      let value = if i % channels == 0 { 19 * n + 37 } else { 73 * n + 11 }
      (value % 256 - 128) * 256
    })
    let aligned = wav_muxer_new(rate, channels, 16).unwrap()
    aligned.write_samples(samples[:2 * per_block * channels])
    let exact = decode_audio_file(aligned.finish()).to_caf_wav_adpcm(codec)
    assert_eq(caf_md5(exact), file_md5)
    assert_true(
      av_caf_open(exact[:exact.length() - 1].to_owned())
      is Err("caf: incomplete WAV ADPCM block"),
    )
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(samples[:])
    let data = decode_audio_file(wav.finish()).to_caf_wav_adpcm(codec)
    let track = av_caf_open(data).unwrap()
    assert_eq(track.format.frames_per_packet, per_block)
    assert_eq(track.packets[1].pts, per_block.to_int64())
    assert_eq(track.sample_count, 5203L)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.codec_id(), codec)
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.samples()[0].length(), 5203)
    let pcm = decoded.to_wav_s16()
    let info = av_wav_open(pcm).unwrap()
    let start = info.data_offset.to_int()
    assert_eq(
      caf_md5(pcm[start:start + info.data_size.to_int()].to_owned()),
      pcm_md5,
    )
  }
}
