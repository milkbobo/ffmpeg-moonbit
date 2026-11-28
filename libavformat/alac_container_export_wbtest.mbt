///|
test "CAF and Matroska ALAC export keep 32-bit PCM and sub-millisecond tails" {
  let count = 4101
  let wav = wav_muxer_new(96000, 2, 32).unwrap()
  wav.write_samples(
    Array::makei(count * 2, i => (i.to_uint64() * 2654435761UL).to_int())[:],
  )
  let source = decode_audio_file(wav.finish())
  let caf = source.to_caf_alac(bits=32)
  let mkv = source.to_mkv_alac(bits=32)
  let caf_track = av_caf_open(caf).unwrap()
  assert_eq(caf_track.format.bits, 32)
  assert_eq(caf_track.packets.map(p => (p.pts, p.duration)), [
    (0L, 4096),
    (4096L, 5),
  ])
  let mkv_track = av_matroska_open(mkv).unwrap()
  let config = mkv_track_codec_parameters(mkv_track.tracks[0])
  assert_eq(config.bit_depth, 32)
  assert_eq(config.sample_rate, 96000)
  assert_true(config.extradata_parsed)
  assert_eq(mkv_track.packets.map(p => p.pts), [0L, 43L])
  for file in [caf, mkv] {
    let decoded = decode_audio_file(file)
    assert_eq(decoded.sample_rate(), 96000)
    assert_eq(decoded.samples()[0].length(), count)
    assert_true(decoded.samples() == source.samples())
  }
}

///|
test "CAF ALAC uses the cookie block length for packet timing" {
  let alac = @libavcodec.alac_encode(
    Array::makei(33, i => i * 257 - 8192),
    1,
    48000,
    16,
    frame_size=32,
  ).unwrap()
  let mux = caf_alac_muxer_new(alac.cookie).unwrap()
  mux.write_packet(alac.frames[0]).unwrap()
  mux.write_packet(alac.frames[1], duration=1).unwrap()
  let file = mux.finish()
  let track = av_caf_open(file).unwrap()
  assert_eq(track.format.frames_per_packet, 32)
  assert_eq(track.sample_count, 33L)
  assert_eq(track.packets.map(p => (p.pts, p.duration)), [(0L, 32), (32L, 1)])
  assert_eq(decode_audio_file(file).samples()[0].length(), 33)
}
