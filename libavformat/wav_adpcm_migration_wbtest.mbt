///|
test "Creative ADPCM WAV PCM matches FFmpeg across packets" {
  let wav : Array[Byte] = []
  wav_mux_tag(wav, "RIFF")
  wav_mux_u32(wav, 6194U)
  wav_mux_tag(wav, "WAVE")
  wav_mux_tag(wav, "fmt ")
  wav_mux_u32(wav, 18U)
  wav_mux_u16(wav, 0x0200)
  wav_mux_u16(wav, 2)
  wav_mux_u32(wav, 22050U)
  wav_mux_u32(wav, 16000U)
  wav_mux_u16(wav, 1024)
  wav_mux_u16(wav, 4)
  wav_mux_u16(wav, 0)
  wav_mux_tag(wav, "fact")
  wav_mux_u32(wav, 4U)
  wav_mux_u32(wav, 5123U)
  wav_mux_tag(wav, "data")
  wav_mux_u32(wav, 6144U)
  for i in 0..<6144 {
    wav.push(((i * 73) ^ (i >> 3)).to_byte())
  }
  let data = Bytes::from_array(wav)
  let track = av_wav_open(data).unwrap()
  assert_eq(track.format.codec, "adpcm_ct")
  assert_true(track.packets.length() > 1)
  assert_eq(track.packets[1].pts, track.packets[0].duration.to_int64())
  let decoded = decode_audio_file(data)
  assert_eq(decoded.samples()[0].length(), 6144)
  let pcm = decoded.to_wav_s16()
  let demux = av_wav_open(pcm).unwrap()
  let start = demux.data_offset.to_int()
  assert_eq(
    telephony_md5(pcm[start:].to_owned()),
    "5df4fc26112da43eed323fbd9984a92f",
  )
}

///|
test "mono and stereo ADPCM WAV exports preserve block timing and source length" {
  for channels in [1, 2] {
    let samples = Array::makei(117 * channels, i => i * 12289 % 65536 - 32768)
    let source = wav_muxer_new(22050, channels, 16).unwrap()
    source.write_samples(samples[:])
    let decoded = decode_audio_file(source.finish())
    for
      (codec, mono, stereo) in [
        (
          "adpcm_ima_wav",
          (57, "009ed584326bdda1609e94113d46ad9e"),
          (25, "22faf12358daf596b9a6c0e358d1becc"),
        ),
        (
          "adpcm_ms",
          (52, "721b637bd3cb1148620b6cd6e53945ff"),
          (20, "496cd9a346fbd8604fe5465b75ba8f2f"),
        ),
        (
          "adpcm_yamaha",
          (64, "66b5cf749d8f499099976804c89e6f7c"),
          (32, "a3ea0e973faf6729dc546cff3f05e0b3"),
        ),
      ] {
      let (block_frames, ffmpeg_md5) = if channels == 1 { mono } else { stereo }
      let blocks = (117 + block_frames - 1) / block_frames
      let wav = decoded.to_wav_adpcm(codec, block_size=32)
      assert_eq(telephony_md5(wav), ffmpeg_md5)
      let track = av_wav_open(wav).unwrap()
      assert_eq(track.format.codec, codec)
      assert_eq(track.format.block_align, 32)
      assert_eq(track.sample_count, 117L)
      assert_eq(track.data_size, (32 * blocks).to_int64())
      assert_eq(track.packets[0].duration, blocks * block_frames)
      let output = decode_audio_file(wav)
      assert_eq(output.channels(), channels)
      assert_eq(output.sample_rate(), 22050)
      assert_eq(output.samples()[0].length(), blocks * block_frames)
    }
  }
}

///|
test "ADPCM WAV export rejects invalid layouts and block sizes" {
  assert_true(av_wav_mux_adpcm([0][:], 22050, 2, "adpcm_ms") is Err(_))
  assert_true(av_wav_mux_adpcm([0][:], 22050, 3, "adpcm_ms") is Err(_))
  assert_true(
    av_wav_mux_adpcm([0][:], 22050, 1, "adpcm_ima_wav", block_size=33) is Err(_),
  )
  assert_true(av_wav_mux_adpcm([0][:], 0, 1, "adpcm_yamaha") is Err(_))
}
