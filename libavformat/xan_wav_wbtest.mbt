///|
test "Xan DPCM in WAV matches FFmpeg with independent packet predictors" {
  for
    (channels, hash) in [
      (1, "4888de29968a062f481ceaf22c53cdfd"),
      (2, "3529c8936e70a90d4afe912f86075b88"),
    ] {
    let file : Array[Byte] = []
    let size = 4112 * channels
    wav_mux_tag(file, "RIFF")
    wav_mux_u32(file, (38 + size).reinterpret_as_uint())
    wav_mux_tag(file, "WAVE")
    wav_mux_tag(file, "fmt ")
    wav_mux_u32(file, 18U)
    wav_mux_u16(file, 0x594a)
    wav_mux_u16(file, channels)
    wav_mux_u32(file, 22050U)
    wav_mux_u32(file, (22050 * channels).reinterpret_as_uint())
    wav_mux_u16(file, channels)
    wav_mux_u16(file, 8)
    wav_mux_u16(file, 0)
    wav_mux_tag(file, "data")
    wav_mux_u32(file, size.reinterpret_as_uint())
    for i in 0..<size {
      file.push(((i * 73) ^ (i >> 3)).to_byte())
    }
    let data = Bytes::from_array(file)
    let track = av_wav_open(data).unwrap()
    assert_eq(track.format.codec, "xan_dpcm")
    assert_eq(track.packets.length(), 3)
    assert_eq(track.packets[0].size, 2048 * channels)
    assert_eq(track.packets[1].pts, 2046L)
    assert_eq(track.packets[2].duration, 14)
    assert_eq(track.sample_count, 4106L)
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), 4106)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
  }
}
