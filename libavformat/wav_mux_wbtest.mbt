///|
/// WAV muxer tests: the emitted bytes are fed back through the existing
/// in-memory WAV demuxer so the RIFF layout, PCM packing and odd-size padding
/// are all checked end to end.

///|
test "wav muxer: 16-bit stereo round-trips through the demuxer" {
  let mux = wav_muxer_new(48000, 2, 16).unwrap()
  let samples : Array[Int32] = [0, -1, 32767, -32768, 1234, -4321, 255, -256]
  mux.write_samples(samples[:])
  let bytes = mux.finish()
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_s16le")
  assert_eq(demux.format.channels, 2)
  assert_eq(demux.format.sample_rate, 48000)
  assert_eq(demux.format.bits_per_sample, 16)
  assert_eq(demux.format.block_align, 4)
  assert_eq(demux.data_size, 16L)
  assert_eq(demux.sample_count, 4L)
  let payload = bytes[demux.data_offset.to_int():].to_owned()
  assert_eq(payload.length(), 16)
  let expect : Array[Byte] = [
    0, 0, 255, 255, 255, 127, 0, 128, 210, 4, 31, 239, 255, 0, 0, 255,
  ]
  assert_eq(payload, Bytes::from_array(expect))
}

///|
test "wav muxer: 24-bit mono pads the odd data chunk" {
  let mux = wav_muxer_new(44100, 1, 24).unwrap()
  mux.write_samples([0x123456, -1, -0x800000][:])
  let bytes = mux.finish()
  assert_eq(bytes.length(), 54)
  assert_eq(bytes[0:4], b"RIFF"[:])
  assert_eq(bytes[4:8], b"\x2e\x00\x00\x00"[:])
  assert_eq(bytes[36:40], b"data"[:])
  assert_eq(bytes[40:44], b"\x09\x00\x00\x00"[:])
  assert_eq(bytes[44:53].to_owned(), b"\x56\x34\x12\xff\xff\xff\x00\x00\x80")
  assert_eq(bytes[53], b'\x00')
}

///|
test "wav muxer: invalid PCM formats are rejected" {
  match wav_muxer_new(48000, 2, 12) {
    Ok(_) => fail("12-bit WAV muxing is not supported")
    Err(_) => ()
  }
  match wav_muxer_new(0, 2, 16) {
    Ok(_) => fail("zero sample rate must fail")
    Err(_) => ()
  }
}

///|
test "wav muxer: 8-bit unsigned PCM and extensible multichannel" {
  let mono = wav_muxer_new(8000, 1, 8).unwrap()
  mono.write_samples([0, 127, -128][:])
  let mono_bytes = mono.finish()
  let mono_demux = av_wav_open(mono_bytes).unwrap()
  assert_eq(mono_demux.format.codec, "pcm_u8")
  assert_eq(mono_demux.format.bits_per_sample, 8)
  assert_eq(mono_demux.data_size, 3L)
  assert_eq(mono_bytes[44:47].to_owned(), Bytes::from_array([0x80, 0xFF, 0x00]))

  let mux = wav_muxer_new(48000, 6, 16, channel_mask=0x3FU).unwrap()
  mux.write_samples([0, 0, 0, 0, 0, 0][:])
  let bytes = mux.finish()
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_s16le")
  assert_eq(demux.format.channels, 6)
  assert_eq(demux.format.bits_per_sample, 16)
  assert_eq(demux.format.channel_mask, 0x3FU)
  assert_eq(demux.data_size, 12L)
}

///|
test "wav muxer: IEEE float32 round-trips" {
  let mux = wav_muxer_new(48000, 2, 32, float=true).unwrap()
  let samples : Array[Float] = [0.5, -0.5]
  mux.write_float_samples(samples[:])
  let bytes = mux.finish()
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.format_tag, 3)
  assert_eq(demux.format.codec, "pcm_f32le")
  assert_eq(demux.format.bits_per_sample, 32)
  assert_eq(demux.data_size, 8L)
  // IEEE float is not PCM: a `fact` chunk with the frame count follows fmt.
  assert_eq(bytes[36:40], b"fact"[:])
  assert_eq(bytes[40:44], b"\x04\x00\x00\x00"[:])
  assert_eq(bytes[44:48], b"\x01\x00\x00\x00"[:])
  assert_eq(bytes[48:52], b"data"[:])
  assert_eq(
    bytes[56:64].to_owned(),
    Bytes::from_array([0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0xBF]),
  )
  let riff_size = bytes[4].to_int() |
    (bytes[5].to_int() << 8) |
    (bytes[6].to_int() << 16) |
    (bytes[7].to_int() << 24)
  assert_eq(riff_size, bytes.length() - 8)
  match wav_muxer_new(48000, 2, 16, float=true) {
    Ok(_) => fail("16-bit float WAV must fail")
    Err(_) => ()
  }
}

///|
test "wav muxer: 24/32-bit PCM payloads round-trip sample-exactly" {
  let mux24 = wav_muxer_new(44100, 2, 24).unwrap()
  mux24.write_samples([0x7FFFFF, -0x800000, 0x123456, -1][:])
  let b24 = mux24.finish()
  let d24 = av_wav_open(b24).unwrap()
  assert_eq(d24.format.codec, "pcm_s24le")
  assert_eq(d24.format.bits_per_sample, 24)
  assert_eq(d24.data_offset, 44L)
  assert_eq(
    b24[44:56].to_owned(),
    Bytes::from_array([
      0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x80, 0x56, 0x34, 0x12, 0xFF, 0xFF, 0xFF,
    ]),
  )

  let mux32 = wav_muxer_new(48000, 2, 32).unwrap()
  mux32.write_samples([0x7FFFFFFF, -2147483647 - 1, 0x01020304, -2][:])
  let b32 = mux32.finish()
  let d32 = av_wav_open(b32).unwrap()
  assert_eq(d32.format.codec, "pcm_s32le")
  assert_eq(d32.format.bits_per_sample, 32)
  assert_eq(d32.data_offset, 44L)
  assert_eq(
    b32[44:60].to_owned(),
    Bytes::from_array([
      0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x00, 0x00, 0x80, 0x04, 0x03, 0x02, 0x01, 0xFE,
      0xFF, 0xFF, 0xFF,
    ]),
  )
}

///|
test "wav muxer: 96 kHz plain WAVEFORMATEX is accepted by the demuxer" {
  let mux = wav_muxer_new(96000, 2, 16).unwrap()
  mux.write_samples([1, -1][:])
  let bytes = mux.finish()
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.format_tag, 1)
  assert_eq(demux.format.sample_rate, 96000)
  assert_eq(demux.format.byte_rate, 384000)
  assert_eq(demux.data_size, 4L)
}

///|
test "wav muxer: extensible float uses WAVE_FORMAT_EXTENSIBLE subformat" {
  let mux = wav_muxer_new(48000, 6, 32, channel_mask=0x3FU, float=true).unwrap()
  let samples : Array[Float] = []
  for i in 0..<12 {
    samples.push(Float::from_double(i.to_double() / 8.0))
  }
  mux.write_float_samples(samples[:])
  let bytes = mux.finish()
  assert_eq(bytes[20:22], b"\xfe\xff"[:]) // 0xFFFE, not IEEE float 0x0003
  assert_eq(bytes[36:38], b"\x16\x00"[:]) // cbSize = 22
  assert_eq(bytes[38:40], b"\x20\x00"[:]) // valid bits = 32
  assert_eq(bytes[40:44], b"\x3f\x00\x00\x00"[:]) // channel mask
  assert_eq(bytes[44:48], b"\x03\x00\x00\x00"[:]) // subformat IEEE_FLOAT
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.format_tag, 3)
  assert_eq(demux.format.codec, "pcm_f32le")
  assert_eq(demux.format.channels, 6)
  assert_eq(demux.format.bits_per_sample, 32)
  assert_eq(demux.format.channel_mask, 0x3FU)
  assert_eq(demux.data_size, 48L)
  assert_eq(demux.sample_count, 2L)
}

///|
test "wav muxer: RF64 header carries ds64 sizes" {
  let mux = wav_muxer_new(48000, 2, 16, rf64=true).unwrap()
  mux.write_samples([1, -1, 2, -2][:])
  let bytes = mux.finish()
  assert_eq(bytes[0:4], b"RF64"[:])
  assert_eq(bytes[4:8], b"\xff\xff\xff\xff"[:])
  assert_eq(bytes[8:12], b"WAVE"[:])
  assert_eq(bytes[12:16], b"ds64"[:])
  let riff_size = bytes[20].to_int() |
    (bytes[21].to_int() << 8) |
    (bytes[22].to_int() << 16) |
    (bytes[23].to_int() << 24)
  assert_eq(riff_size, bytes.length() - 8)
  let data_size = bytes[28].to_int() |
    (bytes[29].to_int() << 8) |
    (bytes[30].to_int() << 16) |
    (bytes[31].to_int() << 24)
  assert_eq(data_size, 8)
  assert_eq(bytes[36], b'\x02') // sample count, 2 frames
  assert_eq(bytes[72:76], b"data"[:])
  assert_eq(bytes[76:80], b"\xff\xff\xff\xff"[:])
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_s16le")
  assert_eq(demux.format.channels, 2)
  assert_eq(demux.data_offset, 80L)
  assert_eq(demux.data_size, 8L)
  assert_eq(demux.sample_count, 2L)
  assert_eq(
    bytes[80:88].to_owned(),
    Bytes::from_array([1, 0, 0xFF, 0xFF, 2, 0, 0xFE, 0xFF]),
  )
}

///|
test "wav muxer: RF64 combines with float and extensible" {
  let mux = wav_muxer_new(
    48000,
    6,
    32,
    channel_mask=0x3FU,
    float=true,
    rf64=true,
  ).unwrap()
  let samples : Array[Float] = [0.5, -0.5, 0.25, -0.25, 0.125, -0.125]
  mux.write_float_samples(samples[:])
  let bytes = mux.finish()
  assert_eq(bytes[0:4], b"RF64"[:])
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_f32le")
  assert_eq(demux.format.channels, 6)
  assert_eq(demux.format.channel_mask, 0x3FU)
  assert_eq(demux.data_size, 24L)
  assert_eq(demux.sample_count, 1L)
  assert_eq(demux.data_offset, 116L) // 48 ds64 header + 48 fmt + 12 fact + 8 data
}

///|
test "wav muxer: RIFX writes big-endian header and samples" {
  let mux = wav_muxer_new(44100, 2, 16, big_endian=true).unwrap()
  mux.write_samples([1, -1, 0x1234, -0x1234][:])
  let bytes = mux.finish()
  assert_eq(bytes[0:4], b"RIFX"[:])
  assert_eq(bytes[4:8], b"\x00\x00\x00\x2c"[:]) // RIFF size, big endian
  assert_eq(bytes[8:12], b"WAVE"[:])
  assert_eq(bytes[16:20], b"\x00\x00\x00\x10"[:]) // fmt size
  assert_eq(bytes[20:22], b"\x00\x01"[:]) // PCM tag
  assert_eq(bytes[22:24], b"\x00\x02"[:]) // channels
  assert_eq(bytes[24:28], b"\x00\x00\xac\x44"[:]) // 44100
  assert_eq(bytes[32:34], b"\x00\x04"[:]) // block align
  assert_eq(bytes[34:36], b"\x00\x10"[:]) // bits
  assert_eq(bytes[36:40], b"data"[:])
  assert_eq(bytes[40:44], b"\x00\x00\x00\x08"[:])
  assert_eq(
    bytes[44:52].to_owned(),
    Bytes::from_array([0x00, 0x01, 0xFF, 0xFF, 0x12, 0x34, 0xED, 0xCC]),
  )
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_s16be")
  assert_eq(demux.format.channels, 2)
  assert_eq(demux.format.sample_rate, 44100)
  assert_eq(demux.data_offset, 44L)
  assert_eq(demux.data_size, 8L)
  assert_eq(demux.sample_count, 2L)
}

///|
test "wav muxer: RIFX float uses big-endian fact and payload" {
  let mux = wav_muxer_new(48000, 1, 32, float=true, big_endian=true).unwrap()
  let samples : Array[Float] = [0.5, -0.5]
  mux.write_float_samples(samples[:])
  let bytes = mux.finish()
  assert_eq(bytes[0:4], b"RIFX"[:])
  assert_eq(bytes[36:40], b"fact"[:])
  assert_eq(bytes[40:44], b"\x00\x00\x00\x04"[:])
  assert_eq(bytes[44:48], b"\x00\x00\x00\x02"[:]) // 2 frames
  assert_eq(
    bytes[56:64].to_owned(),
    Bytes::from_array([0x3F, 0x00, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x00]),
  )
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_f32be")
  assert_eq(demux.data_size, 8L)
  assert_eq(demux.sample_count, 2L)
}

///|
test "wav muxer: RIFX rejects extensible and RF64 combinations" {
  match wav_muxer_new(48000, 6, 16, big_endian=true) {
    Ok(_) => fail("RIFX multichannel must fail")
    Err(_) => ()
  }
  match wav_muxer_new(48000, 2, 16, channel_mask=3U, big_endian=true) {
    Ok(_) => fail("RIFX channel mask must fail")
    Err(_) => ()
  }
  match wav_muxer_new(48000, 2, 16, rf64=true, big_endian=true) {
    Ok(_) => fail("RIFX RF64 must fail")
    Err(_) => ()
  }
}

///|
test "wav muxer: RIFX 8-bit payload stays endian-neutral" {
  let mux = wav_muxer_new(8000, 1, 8, big_endian=true).unwrap()
  mux.write_samples([0, 127, -128][:])
  let bytes = mux.finish()
  assert_eq(bytes[0:4], b"RIFX"[:])
  assert_eq(bytes[44:47].to_owned(), Bytes::from_array([0x80, 0xFF, 0x00]))
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_u8")
  assert_eq(demux.data_size, 3L)
}
