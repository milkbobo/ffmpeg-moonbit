///|
fn spdif_dtshd_test_burst(packet : Bytes, subtype : Int32) -> Bytes {
  let coded = b"\x01\x00\x00\x00\x00\x00\x00\x00\xfe\xfe".to_array()
  wav_mux_w16(coded, packet.length(), true)
  coded.append(packet.to_array())
  let length = ((coded.length() + 23) & -16) - 8
  while coded.length() < length {
    coded.push(0)
  }
  let burst = b"\x72\xf8\x1f\x4e".to_array()
  wav_mux_u16(burst, 0x11 | (subtype << 8))
  wav_mux_u16(burst, length)
  for i in 0..<length {
    burst.push(coded[i ^ 1])
  }
  while burst.length() < 2048 << subtype {
    burst.push(0)
  }
  Bytes::from_array(burst)
}

///|
test "IEC 61937 DTS type IV exposes complete core packets across burst subtypes" {
  let raw = playback_audit_dts_fixture()
  let first = raw[:1008].to_owned()
  let second = raw[1008:].to_owned()
  let exss = b"\x00\x00\x64\x58\x20\x25\x01"
  let wrapped = spdif_dtshd_test_burst(first + exss, 1) +
    spdif_dtshd_test_burst(second, 5)
  let big = Bytes::makei(wrapped.length(), i => wrapped[i ^ 1])
  let expected = decode_audio_file(raw).samples
  for data in [wrapped, big] {
    let track = av_spdif_open(data).unwrap()
    assert_eq(track.codec, "dts")
    assert_eq(track.frames.map(p => (p.pos, p.size, p.pts)), [
      (20L, 1008, 0L),
      (4116L, 1008, 512L),
    ])
    assert_eq(track.packet_data(data, track.frames[0]).unwrap(), first)
    assert_eq(track.packet_data(data, track.frames[1]).unwrap(), second)
    assert_eq(decode_audio_file(data).samples, expected)
  }
  let wav = wav_muxer_new(96000, 2, 16).unwrap()
  wav.data.append(wrapped.to_array())
  let rifx = wav_muxer_new(96000, 2, 16, big_endian=true).unwrap()
  rifx.data.append(big.to_array())
  let wave64 = w64_muxer_new(96000, 2, 16).unwrap()
  wave64.data.append(wrapped.to_array())
  for
    (file, name) in [
      (wav.finish(), "wav"),
      (rifx.finish(), "wav"),
      (wave64.finish(), "w64"),
    ] {
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, name)
    assert_eq(audio.sample_rate, 48000)
    assert_eq(audio.samples, expected)
  }
}

///|
test "IEC 61937 DTS type IV rejects invalid subtype, length and missing core" {
  let raw = playback_audit_dts_fixture()[:1008].to_owned()
  let wrapped = spdif_dtshd_test_burst(raw, 0)
  let bad_subtype = wrapped.to_array()
  bad_subtype[5] = 6
  let bad_packet_length = wrapped.to_array()
  bad_packet_length[18] = 0xff
  bad_packet_length[19] = 0xff
  let exss_only = spdif_dtshd_test_burst(b"\x64\x58\x20\x25\x00\x01", 0)
  let core_truncated = spdif_dtshd_test_burst(raw[:900].to_owned(), 0)
  for
    invalid in [
      Bytes::from_array(bad_subtype),
      Bytes::from_array(bad_packet_length),
      exss_only,
      core_truncated,
    ] {
    assert_true(av_spdif_open(invalid) is Err(_))
  }
}

///|
test "DTS type IV mux preserves EXSS when it fits and falls back per burst" {
  let core = playback_audit_dts_fixture()
  let first = core[:1008].to_owned()
  let second = core[1008:].to_owned()
  let header = b"\x64\x58\x20\x25\x00\x01\xe0\x89\x60"
  let exss = Bytes::makei(1100, i => {
    if i < header.length() {
      header[i]
    } else {
      0
    }
  })
  let stream = first + exss + second
  let small = av_spdif_mux(stream, codec="dts", dtshd_rate=48000).unwrap()
  assert_eq(
    small,
    spdif_dtshd_test_burst(first, 0) + spdif_dtshd_test_burst(second, 0),
  )
  let large = av_spdif_mux(stream, codec="dts", dtshd_rate=96000).unwrap()
  let reference = spdif_dtshd_test_burst(first + exss, 1) +
    spdif_dtshd_test_burst(second, 1)
  assert_eq(large, reference)
  let big = av_spdif_mux(stream, codec="dts", dtshd_rate=96000, big_endian=true).unwrap()
  assert_eq(big, Bytes::makei(reference.length(), i => reference[i ^ 1]))
  assert_eq(decode_audio_file(big).samples, decode_audio_file(core).samples)
  assert_true(
    av_spdif_mux(first + exss[:16].to_owned(), codec="dts", dtshd_rate=96000)
    is Err("spdif: invalid or truncated DTS-HD extension"),
  )
  assert_true(
    av_spdif_mux(core, codec="dts", dtshd_rate=48001)
    is Err("spdif: DTS carrier rate does not yield a supported burst period"),
  )
}
