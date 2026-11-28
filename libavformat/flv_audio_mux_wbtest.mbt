///|
test "FLV AAC-LC carries raw coded frames and the source sample rate" {
  for (rate, channels, count) in [(44100, 1, 1), (32000, 2, 5203)] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let audio = decode_audio_file(wav.finish())
    let encoded = audio.to_flv_aac()
    let track = av_flv_audio_open(encoded).unwrap()
    assert_eq(track.sample_rate, rate)
    assert_eq(track.channels, channels)
    assert_eq(track.codec, "aac")
    let packets = (count + 1023) / 1024 + 1
    assert_eq(track.packets.length(), packets)
    for i, packet in track.packets {
      assert_eq(
        packet.pts,
        @libavutil.av_rescale(i.to_int64() * 1024L, 1000L, rate.to_int64()),
      )
    }
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.samples()[0].length(), packets * 1024)
    assert_true(
      decoded.samples() == decode_audio_file(audio.to_loas()).samples(),
    )
  }
}

///|
test "Enhanced FLV FLAC preserves coded frames, PCM and the 5.1 layout" {
  let count = 4101
  let wav = wav_muxer_new(96000, 6, 32, channel_mask=0x60fU).unwrap()
  let mut state = 0xa9b83c2dU
  wav.write_samples(
    Array::makei(count * 6, _ => {
      state = state ^ (state << 13)
      state = state ^ (state >> 17)
      state = state ^ (state << 5)
      state.reinterpret_as_int()
    })[:],
  )
  let source = decode_audio_file(wav.finish())
  let raw = source.encode_flac_pcm(32).file()
  let flac = av_flac_open(raw).unwrap()
  let encoded = av_flv_mux_flac(raw).unwrap()
  assert_true(source.to_flv_flac(bits=32) == encoded)
  let track = av_flv_audio_open(encoded).unwrap()
  assert_eq(track.extradata.unwrap(), flac.streaminfo)
  assert_eq(track.packets.map(packet => packet.pts), [0L, 43L])
  for i, packet in track.packets {
    let original = flac.frames[i]
    let start = original.pos.to_int()
    assert_eq(
      encoded[packet.pos:packet.pos + packet.size].to_owned(),
      raw[start:start + original.size].to_owned(),
    )
  }
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.sample_rate(), 96000)
  assert_eq(decoded.channels(), 6)
  assert_eq(decoded.channel_mask, 0x60fU)
  assert_eq(decoded.samples()[0].length(), count)
  assert_true(decoded.samples() == source.samples())
}
