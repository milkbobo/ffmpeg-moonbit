///|
test "DAUD matches FFmpeg packet layout and keeps all six PCM channels" {
  let samples = Array::makei(5203 * 6, i => {
    (317 * (i / 6) + 11717 * (i % 6) + 289) % 65536 - 32768
  })
  let wav = wav_muxer_new(96000, 6, 16, channel_mask=0x60fU).unwrap()
  wav.write_samples(samples[:])
  let input = decode_audio_file(wav.finish())
  let daud = input.to_daud()
  assert_eq(caf_md5(daud), "55b87c00b0aa45600a2753ec779ec3d1")
  let track = daud_open(daud).unwrap()
  assert_eq(track.frames.map(p => (p.pts, p.duration)), [
    (0L, 2000),
    (2000L, 2000),
    (4000L, 1203),
  ])
  let with_flags = daud.to_array()
  with_flags[4] = (with_flags[4].to_int() | 0xa0).to_byte()
  with_flags[6] = (with_flags[6].to_int() | 0x0f).to_byte()
  let decoded = decode_audio_file(
    Bytes::from_array(with_flags),
    filename="audio.daud",
  )
  assert_eq(decoded.codec_id(), "pcm_s24daud")
  assert_eq(decoded.sample_rate(), 96000)
  assert_eq(decoded.channels(), 6)
  assert_eq(decoded.samples(), input.samples())
  let output = av_wav_open(decoded.to_wav_s16()).unwrap()
  assert_eq(output.format.channel_mask, 0x60fU)
  assert_true(
    daud_open(daud[:daud.length() - 1].to_owned())
    is Err("daud: truncated packet"),
  )
}
