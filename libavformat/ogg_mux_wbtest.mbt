///|
/// Ogg/Opus muxer tests: the emitted pages are parsed back by the Ogg demuxer.

///|
/// One 20 ms Opus packet extracted from the libopus fixture. */
let ogg_mux_packet_b64 : Bytes = b"+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJQ=="

///|
test "ogg muxer: Opus stream round-trips through the demuxer" {
  let packet = @libavutil.av_base64_decode(ogg_mux_packet_b64, 10000).unwrap()
  let mux = ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let bytes = mux.finish()
  let demux = av_ogg_opus_open(bytes).unwrap()
  assert_eq(demux.serial.reinterpret_as_uint(), 0x12345678U)
  assert_eq(demux.channels, 1)
  assert_eq(demux.pre_skip, 312)
  assert_eq(demux.input_sample_rate, 48000)
  assert_eq(demux.extradata.length(), 19)
  assert_eq(demux.packets.length(), 3)
  let pts : Array[Int64] = [-312L, 648L, 1608L]
  for i in 0..<3 {
    assert_eq(demux.packets[i].data, packet)
    assert_eq(demux.packets[i].pts, pts[i])
    assert_eq(demux.packets[i].duration, 960)
  }
}

///|
test "ogg muxer: empty packets are rejected" {
  let mux = ogg_opus_muxer_new(channels=1).unwrap()
  match mux.write_packet(Bytes::make(0, b'\x00')) {
    Ok(_) => fail("empty Opus packet must fail")
    Err(_) => ()
  }
}

///|
test "Ogg Opus export records the original rate and exact 48 kHz length" {
  for
    (channels, rate, count) in [
      (1, 48000, 1),
      (2, 48000, 960),
      (2, 32000, 5203),
    ] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let audio = decode_audio_file(wav.finish())
    let file = audio.to_ogg_opus()
    let track = av_ogg_opus_open(file).unwrap()
    let expected = audio.resample_to(48000).samples()[0].length()
    let last = track.packets[track.packets.length() - 1]
    assert_eq(track.input_sample_rate, rate)
    assert_eq(track.pre_skip, 120)
    assert_eq(last.granule, expected.to_int64() + 120L)
    assert_eq(last.pts + last.duration.to_int64(), expected.to_int64())
    let decoded = decode_audio_file(file)
    assert_eq(decoded.sample_rate(), 48000)
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.samples()[0].length(), expected)
    assert_eq(
      decoded.samples(),
      decode_audio_file(audio.to_caf_opus()).samples(),
    )
  }
}

///|
test "Ogg Opus trim removes surplus packets and rejects backward EOS timing" {
  let mux = ogg_opus_muxer_new(channels=1, pre_skip=120).unwrap()
  for _ in 0..<3 {
    mux.write_packet(b"\xf8").unwrap()
  }
  let file = mux.finish_trimmed(1000L).unwrap()
  let track = av_ogg_opus_open(file).unwrap()
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[1].granule, 1120L)
  assert_eq(track.packets[1].duration, 160)
  assert_eq(track.end_trim, 800)
  assert_true(mux.finish_trimmed(2761L) is Err(_))
  assert_true(mux.finish_trimmed(0L) is Err(_))
  assert_true(ogg_opus_muxer_new(pre_skip=65536) is Err(_))
  let bad = mux.serialize(2, Some(959L))
  assert_true(av_ogg_opus_open(bad) is Err("ogg: invalid final Opus granule"))
}
