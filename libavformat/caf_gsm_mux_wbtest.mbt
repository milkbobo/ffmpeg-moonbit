///|
test "CAF GSM packs the libgsm reference bits and trims the final block" {
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  wav.write_samples(Array::makei(641, i => i * 7919 % 65536 - 32768)[:])
  let input = decode_audio_file(wav.finish())
  let mut native_pcm : Array[Array[Double]] = []
  for
    (wav49, block, size, hash) in [
      (false, 160, 33, "233902c349c826be6527b7a0a08b5122"),
      (true, 320, 65, "155770eaaaebf39654bd20ac7c7ba1de"),
    ] {
    let encoded = input.to_caf_gsm(wav49~)
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.format.frames_per_packet, block)
    assert_eq(track.format.block_align, size)
    assert_eq(track.sample_count, 641L)
    assert_eq(track.packets[track.packets.length() - 1].duration, 1)
    let start = track.data_offset.to_int()
    let end = start + track.data_size.to_int()
    assert_eq(caf_md5(encoded[start:end].to_owned()), hash)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.sample_rate(), 8000)
    assert_eq(decoded.samples()[0].length(), 641)
    if wav49 {
      assert_eq(decoded.samples(), native_pcm)
    } else {
      native_pcm = decoded.samples()
      let broken = encoded.to_array()
      broken[start] = 0
      assert_true(
        av_caf_open(Bytes::from_array(broken))
        is Err("caf: missing GSM frame magic"),
      )
    }
    assert_true(
      av_caf_open(encoded[:end - 1].to_owned())
      is Err("caf: incomplete GSM block"),
    )
  }
}

///|
test "CAF GSM export resamples mono PCM to 8 kHz" {
  let wav = wav_muxer_new(16000, 1, 16).unwrap()
  wav.write_samples(Array::make(642, 0)[:])
  let encoded = decode_audio_file(wav.finish()).to_caf_gsm()
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.sample_rate(), 8000)
  assert_eq(decoded.samples()[0].length(), 321)
}
