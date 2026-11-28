///|
test "raw and MPEG-TS AC-3 preserve syncframes and 5.1 speaker layout" {
  for
    (rate, channels, mask, count) in [
      (44100, 2, 0U, 5203),
      (48000, 6, 0x60fU, 4101),
    ] {
    let wav = @libavformat.wav_muxer_new(rate, channels, 16, channel_mask=mask).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let source = @libavformat.decode_audio_file(wav.finish())
    let raw = source.to_ac3()
    let track = @libavformat.av_ac3_open(raw).unwrap()
    let ts = source.to_ts_ac3()
    assert_true(ts == @libavformat.av_ts_mux_ac3(raw).unwrap())
    let transport = @libavformat.av_mpegts_open(ts).unwrap()
    assert_eq(transport.streams[0].codec, "ac3")
    assert_eq(transport.packets.length(), track.frames.length())
    assert_eq(track.sample_rate, rate)
    assert_eq(track.channels, channels)
    let rate64 = rate.to_int64()
    for i, frame in track.frames {
      let start = frame.pos.to_int()
      let packet = transport.packets[i]
      assert_eq(packet.payload, raw[start:start + frame.size].to_owned())
      assert_eq(packet.pts, (frame.pts * 90000L + rate64 / 2L) / rate64)
    }
    let audio = @libavformat.decode_audio_file(ts)
    let raw_audio = @libavformat.decode_audio_file(raw)
    assert_true(audio.samples() == raw_audio.samples())
    assert_eq(audio.samples()[0].length(), track.total_samples.to_int())
    let caf = @libavformat.decode_audio_file(source.to_caf_ac3())
    for ch in 0..<channels {
      assert_true(
        audio.samples()[ch][256:256 + count].to_owned() == caf.samples()[ch],
      )
    }
    for output in [audio, raw_audio] {
      assert_eq(
        @libavformat.av_wav_open(output.to_wav_s16()).unwrap().format.channel_mask,
        mask,
      )
    }
    assert_true(
      @libavformat.av_ts_mux_ac3(raw[:raw.length() - 1].to_owned())
      is Err("mpegts: incomplete AC-3 stream"),
    )
  }
}
