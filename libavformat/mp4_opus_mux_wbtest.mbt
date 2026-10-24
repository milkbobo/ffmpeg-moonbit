///|
/// Opus-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
let mp4_opus_packet_b64 : Bytes = b"+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJQ=="

///|
test "mp4 muxer: Opus samples and dOps round-trip" {
  let packet = @libavutil.av_base64_decode(mp4_opus_packet_b64, 10000).unwrap()
  let mux = mp4_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "Opus")
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.channels, 1U)
  assert_eq(track.extradata.unwrap().length(), 19)
  assert_eq(track.samples.length(), 3)
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, 307U)
    assert_eq(sample.dts, (i * 960).to_int64())
    assert_eq(sample.duration, 960U)
    let start = sample.offset.to_int()
    assert_eq(bytes[start:start + 307].to_owned(), packet)
  }
}
