///|
test "Gremlin GDV skips video and matches FFmpeg's DPCM and PCM audio" {
  for
    (flags, size, depth, channels, codec, hash) in [
      (13, 1470, 0, 1, "gremlin_dpcm", "fe07df5ed1ed319645ed17ee05333f93"),
      (15, 2940, 1, 2, "gremlin_dpcm", "477f38ce47362cf2a25bc1427ccf3a3c"),
      (1, 1470, 0, 1, "pcm_u8", "49d8af2eebcb2be7edbea5dd8d9ff749"),
      (7, 5880, 0, 2, "pcm_s16le", "badfa6e9ca9713a74f6d766d5743ec48"),
    ] {
    let file : Array[Byte] = []
    wav_mux_u32(file, 0x29111994U)
    for word in [0, 3, 15, flags, 22050, depth, 0, 0, 320, 200] {
      wav_mux_u16(file, word)
    }
    for _ in 0..<(depth * 768) {
      file.push(0)
    }
    let start = file.length()
    for block in 0..<3 {
      for i in 0..<size {
        file.push(((i * 73) ^ (i >> 3) ^ (91 * block)).to_byte())
      }
      wav_mux_u16(file, 0x1305)
      wav_mux_u16(file, 5)
      for _ in 0..<9 {
        file.push(0)
      }
    }
    let data = Bytes::from_array(file)
    let track = gdv_audio_open(data).unwrap()
    assert_eq(track.codec, codec)
    assert_eq(track.frames.length(), 3)
    assert_eq(track.frames[0].pos, start.to_int64())
    assert_eq(track.frames[1].pos, (start + size + 13).to_int64())
    assert_eq(track.frames[1].pts, 1470L)
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), 4410)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
    assert_true(
      gdv_audio_open(data[:data.length() - 1].to_owned())
      is Err("gdv: truncated video packet"),
    )
  }
}
