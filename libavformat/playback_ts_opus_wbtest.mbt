///|
fn ts_opus_test_wrap(
  payload : Bytes,
  start : Int32,
  end : Int32,
  extension : Bool,
) -> Bytes {
  let flags = 0xE0 |
    (if start > 0 { 0x10 } else { 0 }) |
    (if end > 0 { 0x08 } else { 0 }) |
    (if extension { 0x04 } else { 0 })
  let header : Array[Byte] = [b'\x7f', flags.to_byte()]
  for _ in 0..<(payload.length() / 255) {
    header.push(b'\xff')
  }
  header.push((payload.length() % 255).to_byte())
  if start > 0 {
    ts_mux_u16(header, start)
  }
  if end > 0 {
    ts_mux_u16(header, end)
  }
  if extension {
    header.append(b"\x01\x9d".to_array())
  }
  Bytes::from_array(header) + payload
}

///|
test "MPEG-TS Opus reconstructs 5.1 mapping and trims each access unit" {
  let webm = @libavutil.av_base64_decode(opus_51_webm_b64, 100000).unwrap()
  let mkv = av_matroska_open(webm).unwrap()
  let track = ts_muxer_new(video=false, audio_stream_type=0x06)
  track.pat()
  let pmt = b"\x02\xb0\x1c\x00\x01\xc1\x00\x00\xe1\x01\xf0\x00\x06\xe1\x01\xf0\x0a\x05\x04Opus\x7f\x02\x80\x06".to_array()
  let crc = ts_mux_crc(pmt)
  for i in 0..<4 {
    pmt.push((crc >> (24 - i * 8)).to_byte())
  }
  track.section(track.pmt_pid, pmt)
  track.wrote_tables = true
  let first = ts_opus_test_wrap(mkv.packets[0].data, 312, 0, true)
  let second = ts_opus_test_wrap(mkv.packets[1].data, 16, 32, false)
  let third = ts_opus_test_wrap(mkv.packets[2].data, 0, 120, false)
  track.write_audio(90000L, first[:2].to_owned())
  track.write_audio(91800L, first[2:].to_owned() + second + third)
  let file = track.finish()
  let media = MediaFile::open(file)
  assert_eq(media.streams()[0].codec_id, "opus")
  assert_eq(media.streams()[0].channels, 6)
  let extra = media.streams()[0].extradata.unwrap()
  let head = @libavcodec.opus_parse_head(extra).unwrap()
  assert_eq(head.channel_map, [0, 4, 1, 2, 3, 5])
  assert_eq(head.pre_skip, 0)
  let facade = media.audio_decoder(0)
  let reference = @libavcodec.OpusDecoder::new(head).unwrap()
  let trims = [(312, 0), (16, 32), (0, 120)]
  let mut total = 0
  for i in 0..<3 {
    let packet = media.next_packet().unwrap()
    assert_eq(packet.pts, 90000L + i.to_int64() * 1800L)
    let frame = facade.decode(packet).unwrap()
    let (pcm, n) = reference.decode_packet(Some(mkv.packets[i].data)).unwrap()
    let (start, end) = trims[i]
    assert_eq(frame.nb_samples, n - start - end)
    for ch in 0..<6 {
      for j in 0..<frame.nb_samples {
        assert_eq(frame.samples[ch][j], pcm[ch][start + j].to_double())
      }
    }
    total += frame.nb_samples
  }
  assert_true(media.next_packet() is None)
  let audio = decode_audio_file(file)
  assert_eq(audio.samples[0].length(), total)
  assert_eq(av_wav_open(audio.to_wav_s16()).unwrap().format.channel_mask, 0x3FU)
}

///|
test "MPEG-TS Opus export preserves presentation PCM and DVB trim flags" {
  for (rate, channels, count) in [(48000, 1, 1), (32000, 2, 5203)] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let source = decode_audio_file(wav.finish())
    let encoded = source.to_ts_opus()
    let media = MediaFile::open(encoded)
    let stream = media.streams()[0]
    assert_eq(stream.codec_id, "opus")
    assert_eq(stream.channels, channels)
    assert_eq(stream.sample_rate, 48000)
    let mut index = 0
    let mut valid = 0
    let expected = source.resample_to(48000).samples()[0].length()
    while media.next_packet() is Some(packet) {
      assert_eq(packet.pts, index.to_int64() * 1800L)
      let control = ts_opus_control(packet.data[:]).unwrap()
      assert_eq(control.trim_start, if index == 0 { 120 } else { 0 })
      valid += 960 - control.trim_start - control.trim_end
      if valid < expected {
        assert_eq(control.trim_end, 0)
      }
      index += 1
    }
    assert_eq(valid, expected)
    if count == 1 {
      assert_eq(index, 1)
    }
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.samples()[0].length(), expected)
    assert_true(
      decoded.samples() == decode_audio_file(source.to_ogg_opus()).samples(),
    )
  }
}
