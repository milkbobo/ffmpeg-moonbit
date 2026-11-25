///|
test "AIFF playback: signed PCM at 8, 16, 24 and 32 bits" {
  for bits in [8, 16, 24, 32] {
    let full_scale = 1L << (bits - 1)
    let mux = @libavformat.aiff_muxer_new(8000, 2, bits~).unwrap()
    mux.write_samples([
      (-full_scale).to_int(),
      (full_scale - 1L).to_int(),
      -1,
      0,
    ])
    let decoded = @libavformat.decode_audio_file(mux.finish())
    let step = 1.0 / full_scale.to_double()
    assert_eq(decoded.format_name, "aiff")
    assert_eq(decoded.sample_rate, 8000)
    assert_eq(decoded.channels, 2)
    assert_eq(decoded.duration_seconds, Some(2.0 / 8000.0))
    assert_eq(decoded.samples, [[-1.0, -step], [1.0 - step, 0.0]])
  }
}

///|
test "AIFF-C playback: sowt little-endian stereo" {
  // Two 16-bit stereo PCM frames at 8 kHz, with an AIFC FVER chunk.
  let file = b"FORM\x00\x00\x00\x48AIFCFVER\x00\x00\x00\x04\xa2\x80\x51\x40COMM\x00\x00\x00\x18\x00\x02\x00\x00\x00\x02\x00\x10\x40\x0b\xfa\x00\x00\x00\x00\x00\x00\x00sowt\x00\x00SSND\x00\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\xff\x7f\xff\xff\x00\x00"
  let decoded = @libavformat.decode_audio_file(file)
  assert_eq(decoded.codec_id, "pcm_s16le")
  assert_eq(decoded.samples, [[-1.0, -1.0 / 32768.0], [32767.0 / 32768.0, 0.0]])
}

///|
test "AIFF-C playback: Apple IMA4 uses 64-sample timestamps" {
  // Two stereo packets. Zero nibbles at step index 0 leave the predictor
  // unchanged; different second-packet predictors catch skipped blocks.
  let header = b"FORM\x00\x00\x00\xc8AIFCFVER\x00\x00\x00\x04\xa2\x80\x51\x40COMM\x00\x00\x00\x18\x00\x02\x00\x00\x00\x02\x00\x10\x40\x0b\xfa\x00\x00\x00\x00\x00\x00\x00ima4\x00\x00SSND\x00\x00\x00\x90\x00\x00\x00\x00\x00\x00\x00\x00"
  let buf = Bytes::from_array(
    [
      for i in 0..<(header.length() + 136) => {
        if i < header.length() {
          header[i]
        } else {
          match i - header.length() {
            0 => b'\x01'
            34 => b'\xff'
            68 => b'\x02'
            102 => b'\xfe'
            _ => b'\x00'
          }
        }
      }
    ],
  )
  let media = @libavformat.MediaFile::open(buf)
  guard media.next_packet() is Some(first) &&
    media.next_packet() is Some(second) else {
    fail("expected two Apple IMA4 packets")
  }
  assert_eq((first.data.length(), first.pts), (68, 0L))
  assert_eq((second.data.length(), second.pts), (68, 64L))
  assert_true(media.next_packet() is None)
  let decoded = @libavformat.decode_audio_file(buf)
  assert_eq(decoded.codec_id, "adpcm_ima_qt")
  assert_eq(decoded.duration_seconds, Some(128.0 / 8000.0))
  for i in 0..<128 {
    let expected = if i < 64 { 1.0 / 128.0 } else { 2.0 / 128.0 }
    assert_eq(decoded.samples[0][i], expected)
    assert_eq(decoded.samples[1][i], -expected)
  }
  assert_eq(decoded.samples[0].length(), 128)
  assert_eq(decoded.samples[1].length(), 128)
}
