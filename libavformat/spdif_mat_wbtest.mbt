///|
fn spdif_mat_test_stream(units : Int32, major~ : Bool = true) -> Bytes {
  let data : Array[Byte] = []
  for i in 0..<units {
    wav_mux_w16(data, 7, true)
    wav_mux_w16(data, (65500 + 40 * i) & 0xffff, true)
    if i == 0 && major {
      data.append(b"\xf8\x72\x6f\xba\x00\x00\x00\x00\x00\x00".to_array())
    } else {
      data.append(b"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_array())
    }
  }
  Bytes::from_array(data)
}

///|
test "TrueHD MAT writes complete bursts and handles a timing-counter wrap" {
  let data = spdif_mat_test_stream(25)
  let big = av_spdif_mux(data, codec="truehd", big_endian=true).unwrap()
  let little = av_spdif_mux(data, codec="truehd").unwrap()
  assert_eq(big.length(), 61440)
  assert_eq(big[:8].to_owned(), b"\xf8\x72\x4e\x1f\x00\x16\xef\xf0")
  assert_eq(big[8:12].to_owned(), b"\x07\x9e\x00\x03")
  assert_eq(big[28:42].to_owned(), data[:14].to_owned())
  assert_eq(big[2568:2582].to_owned(), data[14:28].to_owned())
  assert_eq(big[30716:30720].to_owned(), b"\xc3\xc1\x42\x49")
  assert_eq(big[61416:61420].to_owned(), b"\xc3\xc2\xc0\xc4")
  assert_eq(big[61430:].to_owned(), b"\x97\x11\x00\x00\x00\x00\x00\x00\x00\x00")
  assert_eq(little, Bytes::makei(big.length(), i => big[i ^ 1]))
}

///|
test "TrueHD MAT mux rejects incomplete and unsynchronized sources" {
  assert_true(
    av_spdif_mux(spdif_mat_test_stream(24), codec="truehd")
    is Err("spdif: no complete TrueHD MAT burst"),
  )
  assert_true(
    av_spdif_mux(spdif_mat_test_stream(25, major=false), codec="truehd")
    is Err("spdif: TrueHD must begin at a major sync"),
  )
  assert_true(
    av_spdif_mux(spdif_mat_test_stream(25) + b"\x00\x07", codec="truehd")
    is Err("spdif: invalid or truncated TrueHD access unit"),
  )
}

///|
test "TrueHD MAT recovers access units split across markers and bursts" {
  let raw = @libavutil.av_base64_decode(
    b"4DT/2Phyb7qA8WACt1IAAAAAjZoQFAAAAAAAAAAA6sUgI/HqAAAAAAAAAOmtQAAAAEygheMhPpSEGGAPvWjaDKldk1yRAN8eFpxQMzmtvihHt7gQNyQABBTvWTttrqUSnbckrr6wywXgDQAAYAqRQIglIrylZylb/nLPe5Nt+tAXFw==",
    256,
  ).unwrap()
  let expected = decode_audio_file(raw)
  for (start, continuation) in [(30710, 30728), (61410, 61468)] {
    let body = Array::make(61424, b'\x00')
    for (offset, marker) in spdif_mat_markers {
      for i, byte in marker {
        body[offset + i] = byte
      }
    }
    let payload = Bytes::from_array(body)
    let carrier : Array[Byte] = []
    for _ in 0..<2 {
      spdif_write_burst(carrier, payload[:], 0x16, big_endian=true).unwrap()
    }
    for i in 0..<6 {
      carrier[start + i] = raw[i]
    }
    for i in 6..<raw.length() {
      carrier[continuation + i - 6] = raw[i]
    }
    // Only the first word of the next access unit reached the last burst.
    carrier[122854] = raw[0]
    carrier[122855] = raw[1]
    let big = Bytes::from_array(carrier)
    let little = Bytes::makei(big.length(), i => big[i ^ 1])
    let without_final_padding = big[:big.length() - 8].to_owned()
    assert_eq(av_spdif_open(without_final_padding).unwrap().frames.length(), 2)
    assert_true(
      av_spdif_open(big[:big.length() - 9].to_owned())
      is Err("spdif: invalid or truncated TrueHD MAT burst"),
    )
    for packed in [big, little] {
      let track = av_spdif_open(packed).unwrap()
      assert_eq(track.frames.length(), 2)
      assert_eq(track.frames[0].pos, start.to_int64())
      assert_eq(track.frames[1].pts, 40L)
      let frame = track.frames[0]
      assert_eq(
        track.packet_data(packed, frame).unwrap(),
        raw[:frame.size].to_owned(),
      )
      assert_eq(
        spdif_packet_data(packed, frame).unwrap(),
        raw[:frame.size].to_owned(),
      )
      assert_eq(decode_audio_file(packed).samples, expected.samples)
    }
    let wav = wav_muxer_new(705600, 2, 16).unwrap()
    wav.data.append(little.to_array())
    let rifx = wav_muxer_new(705600, 2, 16, big_endian=true).unwrap()
    rifx.data.append(big.to_array())
    let wave64 = w64_muxer_new(705600, 2, 16).unwrap()
    wave64.data.append(little.to_array())
    for input in [wav.finish(), rifx.finish(), wave64.finish()] {
      let decoded = decode_audio_file(input)
      assert_eq(decoded.codec_id, "truehd")
      assert_eq(decoded.sample_rate, 44100)
      assert_eq(decoded.samples, expected.samples)
    }
  }
}
