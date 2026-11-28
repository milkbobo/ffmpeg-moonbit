///|
test "native SoX matches FFmpeg for both byte orders with full 32-bit precision" {
  let wav = wav_muxer_new(32000, 2, 32).unwrap()
  let pcm = Array::makei(5203 * 2, i => {
    (i.to_int64() * 985493619L % 4294967296L - 2147483648L).to_int()
  })
  wav.write_samples(pcm[:])
  let audio = decode_audio_file(wav.finish())
  for
    (big_endian, hash) in [
      (false, "a811f53117ca48d9f4165b9e844788e6"),
      (true, "88d7d99f350fafb1d6088afe134d3aaa"),
    ] {
    let data = audio.to_sox(big_endian~)
    assert_eq(telephony_md5(data), hash)
    let track = sox_open(data).unwrap()
    assert_eq(track.total_samples, 5203L)
    assert_eq(track.frames[1].pts, 2048L)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.samples(), audio.samples())
    assert_eq(decoded.to_sox(big_endian~), data)
    assert_true(
      sox_open(data[:data.length() - 1].to_owned())
      is Err("sox: incomplete PCM frame"),
    )
  }
}
