///|
/// MPEG-TS muxer tests: the emitted PAT/PMT/PES packets are parsed back by
/// the existing in-memory TS demuxer.

///|
test "ts muxer: PAT/PMT and PES round-trip through the demuxer" {
  let mux = ts_muxer_new()
  mux.write_video(90000L, b"hello")
  mux.write_audio(90090L, b"world")
  let bytes = mux.finish()
  assert_eq(bytes.length() % 188, 0)
  assert_eq(bytes[0], b'\x47')
  assert_eq(bytes[188], b'\x47')
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.packet_size, 188)
  assert_eq(demux.streams.length(), 2)
  assert_eq(demux.streams[0].pid, 0x100)
  assert_eq(demux.streams[0].codec, "h264")
  assert_eq(demux.streams[0].codec_type, "video")
  assert_eq(demux.streams[1].pid, 0x101)
  assert_eq(demux.streams[1].codec, "aac")
  assert_eq(demux.streams[1].codec_type, "audio")
  assert_eq(demux.packets.length(), 2)
  let mut video_ok = false
  let mut audio_ok = false
  for packet in demux.packets {
    if packet.pid == 0x100 {
      assert_eq(packet.payload, b"hello")
      assert_eq(packet.pts, 90000L)
      video_ok = true
    } else if packet.pid == 0x101 {
      assert_eq(packet.payload, b"world")
      assert_eq(packet.pts, 90090L)
      audio_ok = true
    }
  }
  assert_true(video_ok && audio_ok)
  assert_eq(demux.pcrs.length(), 1)
  assert_eq(demux.pcrs[0].pid, 0x100)
  assert_eq(demux.pcrs[0].base, 90000L)
  assert_eq(demux.pcrs[0].ext, 0)
}

///|
test "ts muxer: large payload spans multiple packets with continuity" {
  let mux = ts_muxer_new(video_pid=0x200, audio_pid=0x201)
  let payload : Array[Byte] = []
  for i in 0..<500 {
    payload.push(i.to_byte())
  }
  mux.write_video(0L, Bytes::from_array(payload))
  let bytes = mux.finish()
  assert_eq(bytes.length() % 188, 0)
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.streams[0].pid, 0x200)
  assert_eq(demux.packets.length(), 1)
  assert_eq(demux.packets[0].payload.length(), 500)
  assert_eq(demux.packets[0].payload[499], (499).to_byte())
}
