///|
test "FWSE v2 and v3 match FFmpeg across packet boundaries" {
  for
    (channels, pcm_md5) in [
      (1, "b72dffb2084c8b46728fd9cc53d484f1"),
      (2, "228389ee9639f68a4cafe4421c122793"),
    ] {
    let file : Array[Byte] = []
    wav_mux_tag(file, "FWSE")
    wav_mux_u32(file, (channels + 1).reinterpret_as_uint())
    wav_mux_u32(file, 0U)
    wav_mux_u32(file, 40U)
    wav_mux_u32(file, channels.reinterpret_as_uint())
    wav_mux_u32(file, (8212 / channels).reinterpret_as_uint())
    wav_mux_u32(file, 22050U)
    for _ in 0..<12 {
      file.push(0)
    }
    for i in 0..<4106 {
      file.push(((i * 73) ^ (i >> 3)).to_byte())
    }
    let data = Bytes::from_array(file)
    let track = fwse_open(data).unwrap()
    assert_eq(track.frames[0].pos, 40L)
    assert_eq(track.frames[0].size, 4096)
    assert_eq(track.frames[1].pts, 8192L / channels.to_int64())
    assert_eq(track.frames[1].size, 10)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.format_name, "fwse")
    assert_eq(decoded.codec_id, "adpcm_ima_mtf")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), 22050)
    let pcm = decoded.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(wav.data_size, 16424L)
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), pcm_md5)
    if channels == 2 {
      assert_true(
        fwse_open(data[:data.length() - 1].to_owned())
        is Err("fwse: incomplete channel pair"),
      )
    }
  }
}
