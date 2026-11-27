///|
fn ts_truehd_test_pes(
  mux : TsMuxer,
  id : Byte,
  pts : Int64,
  payload : Bytes,
) -> Unit {
  let pes : Array[Byte] = b"\x00\x00\x01\xfd".to_array()
  ts_mux_u16(pes, 11 + payload.length())
  pes.append(b"\x84\x81\x08".to_array())
  ts_mux_pts(pes, pts)
  pes.append([b'\x01', b'\x81', id])
  pes.append(payload.to_array())
  mux.emit(mux.audio_pid, true, pes[:], pts)
}

///|
test "HDMV TrueHD restarts across PES and keeps AC-3 on its companion track" {
  let thd = @libavutil.av_base64_decode(
    b"4DT/2Phyb7qA8WACt1IAAAAAjZoQFAAAAAAAAAAA6sUgI/HqAAAAAAAAAOmtQAAAAEygheMhPpSEGGAPvWjaDKldk1yRAN8eFpxQMzmtvihHt7gQNyQABBTvWTttrqUSnbckrr6wywXgDQAAYAqRQIglIrylZylb/nLPe5Nt+tAXFw==",
    256,
  ).unwrap()
  let ac3 = ac3_decode(ac3_mono48_b64)
  let mux = ts_muxer_new(video=false, audio_stream_type=0x83)
  mux.pat()
  let pmt = b"\x02\xb0\x18\x00\x01\xc1\x00\x00\xe1\x01\xf0\x06\x05\x04HDMV\x83\xe1\x01\xf0\x00".to_array()
  let crc = ts_mux_crc(pmt)
  for i in 0..<4 {
    pmt.push((crc >> (24 - i * 8)).to_byte())
  }
  mux.section(mux.pmt_pid, pmt)
  mux.wrote_tables = true
  ts_truehd_test_pes(mux, b'\x72', 90000L, thd[:3].to_owned())
  ts_truehd_test_pes(mux, b'\x76', 90030L, ac3)
  ts_truehd_test_pes(mux, b'\x72', 91000L, thd[3:].to_owned())
  let file = mux.finish()
  let demux = av_mpegts_open(file).unwrap()
  assert_eq(demux.streams.map(s => s.codec), ["truehd", "ac3"])
  assert_eq(demux.programs[0].stream_indices, [0, 1])
  assert_eq(demux.packets.map(p => p.stream_index), [0, 1, 0])
  let media = MediaFile::open(file)
  assert_eq(media.streams()[0].sample_rate, 44100)
  assert_eq(media.streams()[0].channels, 1)
  assert_eq(media.streams()[1].sample_rate, 48000)
  let thd_packets : Array[MediaPacket] = []
  let ac3_decoder = media.audio_decoder(1)
  let mut ac3_count = 0
  while media.next_packet() is Some(packet) {
    if packet.stream_index == 0 {
      thd_packets.push(packet)
    } else {
      ac3_count += ac3_decoder.decode(packet).unwrap().nb_samples
    }
  }
  assert_eq(ac3_count.to_int64(), av_ac3_open(ac3).unwrap().total_samples)
  assert_eq(thd_packets.map(p => p.pts), [90000L, 91000L])
  assert_true(thd_packets[0].keyframe && !thd_packets[1].keyframe)
  assert_eq(thd_packets[0].data + thd_packets[1].data, thd)
  assert_eq(decode_audio_file(file).samples, decode_audio_file(thd).samples)
}
