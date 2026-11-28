///|
test "IRCAM little-endian exports and decoded samples match FFmpeg 9.0.2" {
  let samples = Array::makei(5203 * 2, i => {
    let n = i / 2
    let value = if i % 2 == 0 { 19 * n + 37 } else { 73 * n + 11 }
    (value % 256 - 128) * 256
  })
  let wav = wav_muxer_new(32000, 2, 16).unwrap()
  wav.write_samples(samples[:])
  let audio = decode_audio_file(wav.finish())
  for
    (codec, file_hash) in [
      ("pcm_s8", "e524a60b279f3e480620760bd37b56fb"),
      ("pcm_s16le", "376d42903b3a32a9bccea732fcb046a3"),
      ("pcm_s24le", "1f628587203c49351eb5fb6cbfaec00b"),
      ("pcm_s32le", "21e202afb7873df39c693cc640d7f50d"),
      ("pcm_f32le", "371a6b85bca9384773b9af1c280ed726"),
      ("pcm_f64le", "5bfb7ef9ea4f652dbdc5e3013fc71028"),
      ("pcm_alaw", "12f3a46acad9a906cee3ece938fd7fc3"),
      ("pcm_mulaw", "946cfd234f82a8ab043faff82cc7f7c0"),
    ] {
    let encoded = audio.to_ircam(codec~)
    assert_eq(telephony_md5(encoded), file_hash)
    let track = ircam_open(encoded).unwrap()
    assert_eq(track.total_samples, 5203L)
    assert_eq(track.frames[1].pts, 2048L)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.format_name(), "ircam")
    assert_eq(decoded.codec_id(), codec)
    assert_eq(decoded.sample_rate(), 32000)
    match codec {
      "pcm_alaw" | "pcm_mulaw" => {
        let pcm = @swr.swr_flt_planar_to_s16(decoded.samples(), 2)
        let bytes : Array[Byte] = []
        for sample in pcm {
          wav_mux_u16(bytes, sample)
        }
        let hash = if codec == "pcm_alaw" {
          "6cb346bce3d35d536e7d11525e2791d1"
        } else {
          "c6390bc19d18b67a6fd81d4517e88cb9"
        }
        assert_eq(telephony_md5(Bytes::from_array(bytes)), hash)
      }
      _ => assert_eq(decoded.samples(), audio.samples())
    }
  }
}

///|
test "IRCAM big-endian signed 32-bit and float64 retain sample precision" {
  let samples : Array[Double] = [0.123456789123, -1.125]
  for (tag, codec) in [(0x40004U, "pcm_s32le"), (8U, "pcm_f64le")] {
    let data = b"\x64\xa3\x02\x00".to_array()
    wav_mux_w32(data, Float::from_int(32000).reinterpret_as_uint(), true)
    wav_mux_w32(data, 2U, true)
    wav_mux_w32(data, tag, true)
    for _ in 16..<1024 {
      data.push(0)
    }
    let expected = if tag == 8U {
      for sample in samples {
        caf_mux_u64be(data, sample.reinterpret_as_uint64())
      }
      [[samples[0]], [samples[1]]]
    } else {
      wav_mux_w32(data, 0x80000001U, true)
      wav_mux_w32(data, 0x7fffffffU, true)
      [[-2147483647.0 / 2147483648.0], [2147483647.0 / 2147483648.0]]
    }
    let encoded = Bytes::from_array(data)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.samples(), expected)
    assert_eq(decode_audio_file(decoded.to_ircam(codec~)).samples(), expected)
    assert_true(
      ircam_open(encoded[:encoded.length() - 1].to_owned())
      is Err("ircam: incomplete PCM frame"),
    )
  }
}
