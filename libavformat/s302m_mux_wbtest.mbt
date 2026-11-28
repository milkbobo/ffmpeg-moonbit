///|
test "SMPTE 302M export matches FFmpeg payloads and preserves full PCM precision" {
  for
    (bits, channels, wav_mask, first_hash, tail_hash) in [
      (
        16, 2, 0U, "4b21c5b55dc72f705d3d8f26ebc2509c", "30fc3a0502c28291757535675a326fb7",
      ),
      (
        20, 4, 0x33U, "0afe0e05a60208cbf024a84d08b9b047", "69c6a0a9d36f750895f584c5fed0728a",
      ),
      (
        24, 6, 0x3fU, "6da53c93bc9f9fd66303e7e5e169cc14", "65c8f844c8c03e3071a663866630e941",
      ),
      (
        24, 8, 0x6000003fU, "7fccc353e18e6b87b32a6a1a068c9281", "63aae3bffe92f0a20e2a38845d3b1322",
      ),
    ] {
    let full = 1 << bits
    let samples = Array::makei(4201 * channels, i => {
      let value = (317391 * (i / channels) + 11717 * (i % channels) + 289) %
        full
      (value - full / 2) << (32 - bits)
    })
    let wav = wav_muxer_new(48000, channels, 32).unwrap()
    wav.write_samples(samples[:])
    let source = decode_audio_file(wav.finish())
    let ts = source.to_ts_s302m(bits~)
    let media = MediaFile::open(ts)
    let stream = media.streams()[0]
    assert_eq(stream.codec_id, "s302m")
    assert_eq(stream.channels, channels)
    let first = media.next_packet().unwrap()
    assert_eq(caf_md5(first.data), first_hash)
    for _ in 0..<3 {
      ignore(media.next_packet().unwrap())
    }
    let last = media.next_packet().unwrap()
    assert_eq(last.pts, 7680L)
    assert_eq(caf_md5(last.data), tail_hash)
    assert_eq(@libavcodec.parse_s302m_header(last.data).unwrap().samples, 105)
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(ts)
    assert_eq(audio.samples(), source.samples())
    let decoded_wav = av_wav_open(audio.to_wav_s16()).unwrap()
    assert_eq(decoded_wav.format.channel_mask, wav_mask)
  }
}
