///|
/// WebM/Opus muxer tests: emitted files are parsed back by `av_matroska_open`.

///|
let webm_opus_packet_b64 : Bytes = b"+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJQ=="

///|
test "webm muxer: Opus track and SimpleBlocks round-trip" {
  let packet = @libavutil.av_base64_decode(webm_opus_packet_b64, 10000).unwrap()
  let mux = webm_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_true(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "A_OPUS")
  assert_eq(track.codec_priv.unwrap().length(), 19)
  assert_eq(track.audio.channels, 1UL)
  assert_eq(mkv.packets.length(), 3)
  let pts : Array[Int64] = [0L, 20L, 40L]
  for i in 0..<3 {
    assert_eq(mkv.packets[i].data, packet)
    assert_eq(mkv.packets[i].pts, pts[i])
    assert_true(mkv.packets[i].is_keyframe)
  }
}

///|
test "webm muxer: empty packets are rejected" {
  let mux = webm_opus_muxer_new(channels=1).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty Opus packet must fail")
    Err(_) => ()
  }
}
