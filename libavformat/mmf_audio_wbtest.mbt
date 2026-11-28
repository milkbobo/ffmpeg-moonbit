///|
test "SMAF Yamaha ADPCM matches FFmpeg across packets and padded final blocks" {
  // FFmpeg 9.0.2 references use -fflags +bitexact and -strict experimental.
  for
    (channels, rate, file_hash, pcm_hash) in [
      (
        1, 11025, "fc7bc9b4c516b6965ec1f0aa1a8c41c6", "ac5ee8bdf0220e639238a4b8866a6f4b",
      ),
      (
        2, 44100, "a7ff9c7f837d4601c1e4250331d082e1", "7d133b7ecc130e1efc67009b0873346d",
      ),
    ] {
    let samples = Array::makei(10006 * channels, i => {
      let frame = i / channels
      if i % channels == 0 {
        (317 * frame + 289) % 60013 - 30006
      } else {
        (733 * frame + 811) % 62731 - 31365
      }
    })
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(samples[:])
    let encoded = decode_audio_file(wav.finish()).to_mmf()
    assert_eq(telephony_md5(encoded), file_hash)
    let track = mmf_open(encoded).unwrap()
    assert_eq(track.total_samples, 10240L)
    assert_eq(track.frames[1].pts, (8192 / channels).to_int64())
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.format_name(), "mmf")
    assert_eq(decoded.codec_id(), "adpcm_yamaha")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), rate)
    let pcm = @swr.swr_flt_planar_to_s16(decoded.samples(), channels)
    let bytes : Array[Byte] = []
    for sample in pcm {
      wav_mux_u16(bytes, sample)
    }
    assert_eq(telephony_md5(Bytes::from_array(bytes)), pcm_hash)

    let damaged = encoded.to_array()
    let wave_size_offset = track.frames[0].pos.to_int() - 4
    damaged[wave_size_offset] = 0xff
    assert_true(
      mmf_open(Bytes::from_array(damaged))
      is Err("mmf: truncated audio subchunk"),
    )
  }
}
