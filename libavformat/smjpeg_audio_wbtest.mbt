///|
test "Loki SMJPEG APCM matches FFmpeg for interleaved video and audio tags" {
  for
    (channels, hash) in [
      (1, "c37be005e09a906f78da52ba01efb03c"),
      (2, "3fc74fc9eafe8385ba5901e0e60584cb"),
    ] {
    let file = smjpeg_magic.to_array()
    aiff_mux_u32be(file, 0U)
    aiff_mux_u32be(file, 75U)
    wav_mux_tag(file, "_SND")
    aiff_mux_u32be(file, 8U)
    aiff_mux_u16be(file, 22050)
    file.push(4)
    file.push(channels.to_byte())
    wav_mux_tag(file, "APCM_VID")
    aiff_mux_u32be(file, 12U)
    aiff_mux_u32be(file, 1U)
    aiff_mux_u16be(file, 16)
    aiff_mux_u16be(file, 16)
    wav_mux_tag(file, "JFIFHEND")
    for block in 0..<2 {
      wav_mux_tag(file, "sndD")
      aiff_mux_u32be(file, (31 * block).reinterpret_as_uint())
      aiff_mux_u32be(file, (4 * channels + 23).reinterpret_as_uint())
      for ch in 0..<channels {
        aiff_mux_u16be(file, 12000 - 6000 * block - 22000 * ch)
        file.push((8 + 27 * block + 13 * ch).to_byte())
        file.push(0)
      }
      for i in 0..<23 {
        file.push(((i * 73) ^ (41 * block) ^ (i >> 3)).to_byte())
      }
      if block == 0 {
        wav_mux_tag(file, "vidD")
        aiff_mux_u32be(file, 0U)
        aiff_mux_u32be(file, 4U)
        file.append(b"\xff\xd8\xff\xd9".to_array())
      }
    }
    wav_mux_tag(file, "DONE")
    let data = Bytes::from_array(file)
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), "smjpeg")
    assert_eq(media.duration_seconds(), Some(0.075))
    assert_eq(media.next_packet().unwrap().pts, 0L)
    assert_eq(media.next_packet().unwrap().pts, 31L)
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), 92 / channels)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
  }
}

///|
test "SMJPEG PCM export matches FFmpeg and recovers every input sample" {
  for
    (channels, hash) in [
      (1, "4b2a12ff4361ae8781822f2c986190ea"),
      (2, "4d823bfc069737e51c39eedc33764471"),
    ] {
    let wav = wav_muxer_new(22050, channels, 16).unwrap()
    let samples = Array::makei(8346 * channels, i => i * 12289 % 65536 - 32768)
    wav.write_samples(samples[:])
    let src = wav.finish()
    let data = decode_audio_file(src).to_smjpeg_pcm()
    assert_eq(telephony_md5(data), hash)
    let (track, duration) = smjpeg_audio_open(data).unwrap()
    assert_eq(track.frames[1].pts, 46L)
    assert_eq(track.frames[8].duration, 154)
    assert_eq(duration, 379L)
    assert_eq(decode_audio_file(data).to_wav_s16(), src)
  }
}
