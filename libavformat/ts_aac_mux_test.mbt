///|
test "AAC-LC export preserves ADTS and LATM access units inside MPEG-TS" {
  for (rate, channels, count) in [(44100, 1, 1), (32000, 2, 20501)] {
    let wav = @libavformat.wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let source = @libavformat.decode_audio_file(wav.finish())
    let adts = source.to_adts()
    let loas = source.to_loas()
    let reference = @libavformat.decode_audio_file(adts)
    let coded_frames = (count + 1023) / 1024 + 1
    assert_eq(reference.samples()[0].length(), coded_frames * 1024)
    for (latm, codec, es) in [(false, "aac", adts), (true, "aac_latm", loas)] {
      let file = source.to_ts_aac(latm~)
      assert_true(file.length() >= 2040)
      let demux = @libavformat.av_mpegts_open(file).unwrap()
      assert_eq(demux.streams[0].codec, codec)
      assert_eq(demux.packets.length(), coded_frames)
      let rate64 = rate.to_int64()
      let mut pos = 0
      for i, packet in demux.packets {
        assert_eq(
          packet.pts,
          (i.to_int64() * 1024L * 90000L + rate64 / 2L) / rate64,
        )
        let end = pos + packet.payload.length()
        assert_eq(packet.payload, es[pos:end].to_owned())
        pos = end
      }
      assert_eq(pos, es.length())
      let audio = @libavformat.decode_audio_file(file)
      assert_eq(audio.codec_id(), codec)
      assert_eq(audio.sample_rate(), rate)
      assert_eq(audio.channels(), channels)
      assert_true(audio.samples() == reference.samples())
    }
  }
}
