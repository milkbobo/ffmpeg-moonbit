///|
test "native FLAC keeps complete frames and full-width PCM with unknown STREAMINFO total" {
  for bits in [16, 24, 32] {
    let amplitude = 1 << (bits - 2)
    let interleaved = Array::makei(268, i => {
      let sample = amplitude + i / 2 * 313 % 307 - 153
      if i % 2 == 0 {
        sample
      } else {
        -sample - 7
      }
    })
    let encoded = @libavcodec.flac_encode(
      interleaved,
      2,
      48000,
      bits,
      block_size=64,
    ).unwrap()
    let bytes = encoded.file().to_array()
    // Clear the 36-bit sample count while retaining the sample depth.
    bytes[21] = (bytes[21].to_int() & 0xF0).to_byte()
    for i in 22..<26 {
      bytes[i] = b'\x00'
    }
    let tag = id3v2_write_tag([("title", "Native FLAC")]).unwrap()
    let data = tag + Bytes::from_array(bytes)
    let track = av_flac_open(data).unwrap()
    assert_eq(track.bits, bits)
    assert_eq(track.total_samples, 134L)
    assert_eq(track.frames.length(), 3)
    assert_eq(track.frames[0].pos, tag.length().to_int64() + 42L)
    assert_eq(track.frames[2].duration, 6)
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), "flac")
    for i in 0..<3 {
      let packet = media.next_packet().unwrap()
      assert_eq(packet.pts, (i * 64).to_int64())
      assert_eq(packet.data, encoded.frames[i])
    }
    assert_true(media.next_packet() is None)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.sample_rate, 48000)
    assert_eq(decoded.channels, 2)
    assert_eq(decoded.duration_seconds, Some(134.0 / 48000.0))
    let scale = (1L << (bits - 1)).to_double()
    for ch in 0..<2 {
      assert_eq(decoded.samples[ch].length(), 134)
      for i in 0..<134 {
        assert_eq(
          (decoded.samples[ch][i] * scale).to_int(),
          interleaved[i * 2 + ch],
        )
      }
    }
  }
}

///|
test "native FLAC rejects truncated metadata, truncated frames and bad frame CRC" {
  let file = @libavcodec.flac_encode(
      Array::make(64, 123),
      1,
      8000,
      16,
      block_size=64,
    )
    .unwrap()
    .file()
  assert_true(
    av_flac_open(file[:35].to_owned())
    is Err("flac: missing or invalid STREAMINFO"),
  )
  assert_true(av_flac_open(file[:file.length() - 1].to_owned()) is Err(_))
  let bytes = file.to_array()
  let last = bytes.length() - 1
  bytes[last] = (bytes[last].to_int() ^ 1).to_byte()
  assert_true(
    av_flac_open(Bytes::from_array(bytes)) is Err("flac: frame CRC mismatch"),
  )
}
