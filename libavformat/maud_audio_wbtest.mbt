///|
test "Amiga MAUD exports PCM and G.711 with an aligned MDAT chunk" {
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  let samples = Array::makei(5203, i => ((19 * i + 37) % 256 - 128) * 256)
  wav.write_samples(samples[:])
  let input = decode_audio_file(wav.finish())
  for
    (codec, payload_md5, pcm_md5) in [
      (
        "pcm_s16be", "c1ea1d6dfbb21db9e39d3654dc359089", "5c420ffa689146a2265d50bf69272060",
      ),
      (
        "pcm_u8", "3d29d34fe04151b73ac610f5d8b4fde4", "5c420ffa689146a2265d50bf69272060",
      ),
      (
        "pcm_alaw", "e610571d87bfc0d80232eaa506bd5e04", "3ceee662e7b08169966a6c7e5db5523c",
      ),
      (
        "pcm_mulaw", "3a4e304b0af64397b7063665e1341d2a", "297cf23a66a7b25510658ca726df0ce5",
      ),
    ] {
    let data = input.to_maud(codec~)
    assert_eq(pb_be32(data, 4).to_int64(), (data.length() - 8).to_int64())
    let payload_size = pb_be32(data, 56).reinterpret_as_int()
    assert_eq(data.length() - 60 - payload_size, payload_size % 2)
    assert_eq(caf_md5(data[60:60 + payload_size].to_owned()), payload_md5)
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name(), "iff")
    assert_eq(audio.codec_id(), codec)
    assert_eq(audio.samples()[0].length(), 5203)
    let decoded = audio.to_wav_s16()
    let demux = av_wav_open(decoded).unwrap()
    let start = demux.data_offset.to_int()
    assert_eq(
      caf_md5(decoded[start:start + demux.data_size.to_int()].to_owned()),
      pcm_md5,
    )
  }
}

///|
test "Amiga MAUD supports a divided clock and skips padded annotation chunks" {
  let data = b"FORM\x00\x00\x00\x44MAUDMHDR\x00\x00\x00\x20\x00\x00\x00\x03\x00\x08\x00\x08\x00\x00\xbb\x80\x00\x06\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00ANNO\x00\x00\x00\x03ABC\x00MDAT\x00\x00\x00\x03\x00\x80\xff\x00"
  let audio = decode_audio_file(data)
  assert_eq(audio.sample_rate(), 8000)
  assert_eq(audio.samples(), [[-1.0, 0.0, 127.0 / 128.0]])
  let broken = data.to_array()
  broken[33] = 0
  assert_true(
    maud_open(Bytes::from_array(broken)) is Err("maud: zero clock divisor"),
  )
}
