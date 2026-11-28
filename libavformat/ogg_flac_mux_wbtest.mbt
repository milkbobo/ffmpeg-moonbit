///|
test "Ogg FLAC round-trips full-depth surround frames across continuation pages" {
  let channels = 8
  let count = 4101
  let wav = wav_muxer_new(48000, channels, 32, channel_mask=0x63fU).unwrap()
  let mut state = 0x12345678U
  let samples = Array::makei(count * channels, _ => {
    state = state ^ (state << 13)
    state = state ^ (state >> 17)
    state = state ^ (state << 5)
    state.reinterpret_as_int()
  })
  wav.write_samples(samples[:])
  let audio = decode_audio_file(wav.finish())
  let file = audio.to_ogg_flac(bits=32)
  let demux = av_ogg_flac_open(file).unwrap()
  assert_eq(demux.bits, 32)
  assert_eq(demux.total_samples, 4101L)
  assert_eq(demux.frames.length(), 2)
  assert_true(demux.frames[0].data.length() > 65025)
  assert_eq(demux.frames.map(frame => (frame.pts, frame.granule)), [
    (0L, 4096L),
    (4096L, 4101L),
  ])
  let media = MediaFile::open(file)
  assert_eq(media.next_packet().unwrap().pts, 0L)
  assert_eq(media.next_packet().unwrap().pts, 4096L)
  let decoded = decode_audio_file(file)
  assert_eq(decoded.channel_mask, 0x63fU)
  assert_eq(decoded.samples(), audio.samples())
  let truncated = file[:demux.frames[0].pos.to_int()].to_owned()
  assert_true(av_ogg_flac_open(truncated) is Err("ogg: incomplete FLAC packet"))
}
