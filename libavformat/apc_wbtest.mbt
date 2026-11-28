///|
test "CRYO APC restores its predictors and matches FFmpeg across packets" {
  for
    (channels, hash) in [
      (1, "a4bd1454b4a2de3fa24e1e68db23f9fd"),
      (2, "289fc340910516fa1486f648f502c4bc"),
    ] {
    let file : Array[Byte] = []
    wav_mux_tag(file, "CRYO_APC1.20")
    wav_mux_u32(file, (8206 / channels).reinterpret_as_uint())
    wav_mux_u32(file, 22050U)
    wav_mux_u32(file, (-12345).reinterpret_as_uint())
    wav_mux_u32(file, 23456U)
    wav_mux_u32(file, (channels - 1).reinterpret_as_uint())
    for i in 0..<4103 {
      file.push(((i * 73) ^ (i >> 3)).to_byte())
    }
    let data = Bytes::from_array(file)
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), "apc")
    let first = media.next_packet().unwrap()
    let tail = media.next_packet().unwrap()
    assert_eq((first.pts, first.data.length()), (0L, 4096))
    assert_eq((tail.pts, tail.data.length()), (8192L / channels.to_int64(), 7))
    let decoded = decode_audio_file(data)
    assert_eq(decoded.codec_id, "adpcm_ima_apc")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), 22050)
    let pcm = decoded.to_wav_s16()
    let demux = av_wav_open(pcm).unwrap()
    assert_eq(demux.data_size, 16412L)
    assert_eq(telephony_md5(pcm[demux.data_offset.to_int():].to_owned()), hash)
    assert_true(apc_open(data[:31].to_owned()) is Err(_))
  }
}
