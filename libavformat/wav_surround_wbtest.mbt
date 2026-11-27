///|
test "WAV tags and Dolby GUID identify complete AC-3 and E-AC-3 frames" {
  let ac3 = ac3_decode(ac3_mono44_b64)
  let eac3 = eac3_decode(eac3_mono48_b64)
  let eac3_guid = b"\xaf\x87\xfb\xa7\x02\x2d\xfb\x42\xa4\xd4\x05\xcd\x93\x84\x3b\xdd"
  for
    (payload, guid, codec) in [
      (ac3, b"", "ac3"),
      (eac3, b"", "eac3"),
      (eac3, eac3_guid, "eac3"),
    ] {
    let track = av_ac3_open(payload).unwrap()
    let ext = !guid.is_empty()
    let fmt_size = if ext { 40 } else { 16 }
    let out = b"RIFF".to_array()
    wav_mux_u32(out, (20 + fmt_size + payload.length()).reinterpret_as_uint())
    out.append(b"WAVEfmt ".to_array())
    wav_mux_u32(out, fmt_size.reinterpret_as_uint())
    wav_mux_u16(out, if ext { 0xFFFE } else { 0x2000 })
    wav_mux_u16(out, track.channels)
    wav_mux_u32(out, track.sample_rate.reinterpret_as_uint())
    wav_mux_u32(out, 0U)
    wav_mux_u16(out, 1)
    wav_mux_u16(out, 16)
    if ext {
      out.append(b"\x16\x00\x10\x00\x00\x00\x00\x00".to_array())
      out.append(guid.to_array())
    }
    out.append(b"data".to_array())
    wav_mux_u32(out, payload.length().reinterpret_as_uint())
    out.append(payload.to_array())
    let file = Bytes::from_array(out)
    let wave = av_wav_open(file).unwrap()
    assert_eq(wave.format.codec, codec)
    assert_eq(wave.sample_count, track.total_samples)
    let media = MediaFile::open(file)
    for frame in track.frames {
      let packet = media.next_packet().unwrap()
      let start = frame.pos.to_int()
      assert_eq(packet.data, payload[start:start + frame.size].to_owned())
      assert_eq(packet.pts, frame.pts)
    }
    assert_true(media.next_packet() is None)
    assert_eq(
      decode_audio_file(file).samples,
      decode_audio_file(payload).samples,
    )
  }
}

///|
test "Wave64 DTS excludes trailing alignment bytes and keeps decoder state" {
  let raw = playback_audit_dts_fixture()
  // Two bytes of inter-frame alignment lead to six bytes of Wave64 padding.
  let payload = raw[:1008].to_owned() + b"\x00\x00" + raw[1008:].to_owned()
  let size = w64_align8(24L + payload.length().to_int64())
  let out = w64_guid_riff.to_array()
  w64_le64(out, 40L + 40L + size)
  out.append(w64_guid_wave.to_array())
  out.append(w64_guid_fmt.to_array())
  w64_le64(out, 40L)
  out.append(
    b"\x01\x20\x02\x00\x80\xbb\x00\x00\x00\x00\x00\x00\x01\x00\x10\x00".to_array(),
  )
  out.append(w64_guid_data.to_array())
  w64_le64(out, size)
  out.append(payload.to_array())
  while out.length() % 8 != 0 {
    out.push(0)
  }
  let data = Bytes::from_array(out)
  let wav = av_w64_open(data).unwrap()
  assert_eq(wav.format.codec, "dts")
  assert_eq(wav.data_size, payload.length().to_int64())
  assert_eq(wav.packets.map(p => p.size), [1008, 1008])
  assert_eq(wav.packets.map(p => p.pts), [0L, 512L])
  assert_eq(decode_audio_file(data).samples, decode_audio_file(raw).samples)
}

///|
fn wav_dts_cd_test_frame() -> Bytes {
  // 14-bit LE header of a 44.1 kHz 5.1 DTS core frame, with dummy payload.
  let header = b"\xff\x1f\x00\xe8\xf0\x07\x6f\xfc\x98\xfc\x00\xe6\xe0\x14\x09\x00\xde\xfb"
  Bytes::makei(2048, i => if i < header.length() { header[i] } else { 0 })
}

///|
test "DTS-CD in WAV and Wave64 uses core channels and frame timestamps" {
  let frame = wav_dts_cd_test_frame()
  let payload = frame + frame
  let riff = wav_muxer_new(44100, 2, 16, channel_mask=3U).unwrap()
  riff.data.append(payload.to_array())
  let wave64 = w64_muxer_new(44100, 2, 16).unwrap()
  wave64.data.append(payload.to_array())
  for
    (file, demux) in [
      (riff.finish(), av_wav_open),
      (wave64.finish(), av_w64_open),
    ] {
    let wave = demux(file).unwrap()
    assert_eq(wave.format.codec, "dts")
    assert_eq(wave.format.format_tag, 1)
    assert_eq(wave.format.sample_rate, 44100)
    assert_eq(wave.format.channels, 6)
    assert_eq(wave.format.channel_mask, 0U)
    assert_eq(wave.sample_count, 1024L)
    assert_eq(wave.packets.map(p => (p.pts, p.duration)), [
      (0L, 512),
      (512L, 512),
    ])
    let media = MediaFile::open(file)
    assert_eq(media.next_packet().unwrap().data, frame)
    assert_eq(media.next_packet().unwrap().data, frame)
    assert_true(media.next_packet() is None)
  }
}

///|
test "DTS-CD detection keeps PCM with incomplete or misplaced core frames" {
  let frame = wav_dts_cd_test_frame()
  for
    (rate, payload) in [
      (44100, b"\x00\x11\x00\x22"),
      (44100, frame),
      (44100, frame + frame[:20].to_owned()),
      (44100, frame + frame + b"\x01\x00\x00\x00"),
      (44100, b"\x00\x11\x00\x22" + frame + frame),
      (48000, frame + frame),
    ] {
    let mux = wav_muxer_new(rate, 2, 16).unwrap()
    mux.data.append(payload.to_array())
    let wave = av_wav_open(mux.finish()).unwrap()
    assert_eq(wave.format.codec, "pcm_s16le")
    assert_eq(wave.format.sample_rate, rate)
    assert_eq(wave.format.channels, 2)
    assert_eq(wave.sample_count, payload.length().to_int64() / 4L)
  }
}
