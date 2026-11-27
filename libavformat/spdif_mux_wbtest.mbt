///|
test "IEC 61937 mux writes AC-3 and DTS payloads with the correct word order" {
  let ac3 = ac3_decode(ac3_mono44_b64)
  let dts = playback_audit_dts_fixture()
  let dts_le = Bytes::makei(dts.length(), i => dts[i ^ 1])
  for (codec, raw, sizes, period) in [
    ("ac3", ac3, av_ac3_open(ac3).unwrap().frames.map(f => f.size), 6144),
    ("dts", dts, [1008, 1008], 2048),
  ] {
    let encoded = av_spdif_mux(raw, codec~).unwrap()
    assert_eq(encoded.length(), sizes.length() * period)
    let track = av_spdif_open(encoded).unwrap()
    assert_eq(track.frames.map(f => f.size), sizes)
    let mut start = 0
    for frame in track.frames {
      assert_eq(spdif_packet_data(encoded, frame).unwrap(), raw[start:start + frame.size].to_owned())
      start += frame.size
    }
    if codec == "dts" {
      assert_eq(av_spdif_mux(dts_le, codec~).unwrap(), encoded)
    } else {
      assert_eq(encoded[4].to_int(), 0x01)
      assert_eq(encoded[5].to_int(), raw[5].to_int() & 7)
    }
  }
  assert_true(av_spdif_mux(ac3 + b"\x00", codec="ac3") is Err("spdif: trailing coded data"))
  assert_true(av_spdif_mux(wav_dts_cd_test_frame(), codec="dts") is Err("spdif: payload exceeds burst capacity"))
}

///|
test "IEC 61937 mux groups E-AC-3 short frames into complete bursts" {
  let fixture = eac3_decode(eac3_hi1blk_b64)
  let frame = av_ac3_open(fixture).unwrap().frames[0]
  let coded = fixture[:frame.size].to_owned()
  let frames_per_burst = 1536 / frame.duration
  let mut stream = b""
  for _ in 0..<frames_per_burst {
    stream = stream + coded
  }
  let encoded = av_spdif_mux(stream, codec="eac3").unwrap()
  assert_eq(encoded.length(), 24576)
  assert_eq(wav_u16(encoded[:], 6, false), stream.length())
  let track = av_spdif_open(encoded).unwrap()
  assert_eq(track.total_samples, 1536L)
  assert_eq(track.frames.length(), frames_per_burst)
  for frame in track.frames {
    assert_eq(spdif_packet_data(encoded, frame).unwrap(), coded)
  }
  assert_true(av_spdif_mux(stream + coded, codec="eac3") is Err("spdif: incomplete E-AC-3 burst"))
}
