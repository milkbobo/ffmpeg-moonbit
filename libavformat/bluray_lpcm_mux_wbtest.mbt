///|
test "Blu-ray LPCM HDMV export preserves PCM, speaker mapping, and the final short packet" {
  for
    (bits, channels, rate, mask, layout, first_hash) in [
      (16, 1, 48000, 0U, 1, "a81d6f0df30a3d24a65f52eb83b2798e"),
      (16, 4, 96000, 0x603U, 7, "c6870c1bc9d1c57144331a82ba787c2d"),
      (24, 6, 96000, 0x60fU, 9, "c710303516968f6c2cb10894f1c8db20"),
      (24, 7, 192000, 0x637U, 10, "73cd4b028854a39678e0f040c99e6f22"),
      (24, 8, 192000, 0x63fU, 11, "b6afaf4a8635a2acedc07f39971aab11"),
    ] {
    let block = if bits == 16 { 240 } else { 360 }
    let frames = 2 * block + 17
    let full = 1 << bits
    let samples = Array::makei(frames * channels, i => {
      let value = (317391 * (i / channels) + 11717 * (i % channels) + 289) %
        full
      (value - full / 2) << (32 - bits)
    })
    let wav = wav_muxer_new(rate, channels, 32, channel_mask=mask).unwrap()
    wav.write_samples(samples[:])
    let input = decode_audio_file(wav.finish())
    let data = input.to_ts_bluray_lpcm(bits~)
    let media = MediaFile::open(data)
    assert_eq(media.streams()[0].codec_id, "pcm_bluray")
    let first = media.next_packet().unwrap()
    // FFmpeg 9.0.2 drops the top eight bits when encoding 24-bit 7.1.
    // That fixture is verified by comparing FFmpeg-decoded PCM with the source.
    assert_eq(caf_md5(first.data), first_hash)
    assert_eq(
      @libavcodec.parse_bluray_lpcm_header(first.data).unwrap().layout,
      layout,
    )
    ignore(media.next_packet().unwrap())
    let tail = media.next_packet().unwrap()
    assert_eq(
      tail.pts,
      (2L * block.to_int64() * 90000L + rate.to_int64() / 2L) / rate.to_int64(),
    )
    assert_eq(
      @libavcodec.parse_bluray_lpcm_header(tail.data).unwrap().samples,
      17,
    )
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(data)
    assert_eq(audio.sample_rate(), rate)
    assert_eq(audio.samples(), input.samples())
    assert_eq(
      av_wav_open(audio.to_wav_s16()).unwrap().format.channel_mask,
      mask,
    )
    assert_eq(audio.to_ts_bluray_lpcm(bits~), data)
  }
}
