///|
test "Sierra SOL PCM and DPCM variants match FFmpeg across packets" {
  for
    (magic, flags, codec, channels, bits, hash) in [
      (0x0b8d, 1, "sol_dpcm", 1, 4, "b39081ec71495d6fc11b48e1feb11722"),
      (0x0c0d, 17, "sol_dpcm", 2, 4, "16d898a34bac38310eb987bf0017f0d4"),
      (0x0c8d, 21, "sol_dpcm", 2, 8, "584de01b7132e8d248f79b8e7b91cbbc"),
      (0x0b8d, 0, "pcm_u8", 1, 8, "b5a6a26c741877631a54c08e1b34c221"),
      (0x0c0d, 20, "pcm_s16le", 2, 16, "6486162b7dd317951816014874230c40"),
    ] {
    let file : Array[Byte] = []
    wav_mux_u16(file, magic)
    wav_mux_tag(file, "SOL")
    file.push(0)
    wav_mux_u16(file, 22050)
    file.push(flags.to_byte())
    wav_mux_u32(file, 4108U)
    if magic != 0x0b8d {
      file.push(0)
    }
    let start = file.length()
    for i in 0..<4108 {
      file.push(((i * 73) ^ (i >> 3)).to_byte())
    }
    let data = Bytes::from_array(file)
    let track = sol_open(data).unwrap()
    assert_eq(track.codec, codec)
    assert_eq(track.frames[0].pos, start.to_int64())
    assert_eq(track.frames[1].pts, 32768L / (bits * channels).to_int64())
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name, "sol")
    assert_eq(audio.channels(), channels)
    assert_eq(audio.sample_rate(), 22050)
    assert_eq(audio.samples()[0].length(), 32864 / (bits * channels))
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
    if bits == 16 {
      assert_true(
        sol_open(data[:data.length() - 1].to_owned())
        is Err("sol: incomplete channel frame"),
      )
    }
  }
}
