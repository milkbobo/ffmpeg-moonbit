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
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty Opus packet must fail")
    Err(_) => ()
  }
}
