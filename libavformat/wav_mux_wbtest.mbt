///|
/// WAV muxer tests: the emitted bytes are fed back through the existing
/// in-memory WAV demuxer so the RIFF layout, PCM packing and odd-size padding
/// are all checked end to end.

///|
test "wav muxer: 16-bit stereo round-trips through the demuxer" {
  let mux = wav_muxer_new(48000, 2, 16).unwrap()
  let samples : Array[Int32] = [
    0, -1, 32767, -32768, 1234, -4321, 255, -256,
  ]
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
  assert_eq(demux.format.codec, "pcm_f32le")
  assert_eq(demux.format.bits_per_sample, 32)
  assert_eq(demux.data_size, 8L)
  assert_eq(
    bytes[44:52].to_owned(),
    Bytes::from_array([0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0xBF]),
  )
  match wav_muxer_new(48000, 2, 16, float=true) {
    Ok(_) => fail("16-bit float WAV must fail")
    Err(_) => ()
  }
}
