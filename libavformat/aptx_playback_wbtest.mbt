///|
test "aptX and aptX HD preserve decoder state across raw packets" {
  for
    (filename, codec, block_size, parity_bit) in [
      ("sample.aptx", "aptx", 4, 0x20),
      ("sample.aptxhd", "aptx_hd", 6, 0x08),
    ] {
    // Zero codewords, with packed stereo parity alternating every eighth block.
    let raw = Bytes::makei(259 * block_size, i => {
      if i % block_size == 0 && i / block_size % 8 == 7 {
        parity_bit.to_byte()
      } else {
        b'\x00'
      }
    })
    let media = MediaFile::open(raw, filename~)
    assert_eq(media.format_name(), codec)
    let first = media.next_packet().unwrap()
    let last = media.next_packet().unwrap()
    assert_eq((first.pts, first.data.length()), (0L, 256 * block_size))
    assert_eq((last.pts, last.data.length()), (1024L, 3 * block_size))
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(raw, filename~)
    assert_eq(audio.sample_rate(), 48000)
    assert_eq(audio.channels(), 2)
    assert_eq(audio.read_error(), "")
    let expected = @libavcodec.ff_aptx_decode(raw, hd=block_size == 6).unwrap().samples
    let planar = audio.samples()
    for ch in 0..<2 {
      assert_eq(planar[ch].length(), 1036)
      for i in 0..<1036 {
        assert_eq(
          planar[ch][i],
          expected[i * 2 + ch].to_double() / 2147483648.0,
        )
      }
    }
  }
}

///|
test "raw aptX rejects an incomplete final block" {
  let result = Ok(
    MediaFile::open(Bytes::make(7, b'\x00'), filename="broken.aptxhd"),
  ) catch {
    err => Err(err)
  }
  assert_true(
    result is Err(DemuxError("aptx: empty stream or incomplete block")),
  )
}

///|
test "aptX and aptX HD encode FFmpeg's stereo reference and play it at 44.1 kHz" {
  let sample_count = 1031
  let pcm = Array::makei(sample_count * 2, i => {
    let frame = i / 2
    let value = if i % 2 == 0 {
      frame * 633451
    } else {
      frame * 1172131 + 219773
    }
    (value % 16777216 - 8388608) << 8
  })
  let wav = wav_muxer_new(44100, 2, 32).unwrap()
  wav.write_samples(pcm[:])
  let input = decode_audio_file(wav.finish())
  for
    (filename, hd, size, hash) in [
      ("sample.aptx", false, 1032, "11218ac331d385e2abdee09f03f918d5"),
      ("sample.aptxhd", true, 1548, "b977b54b352823d557681f0ab478a6e8"),
    ] {
    let encoded = input.to_aptx(hd~)
    assert_eq(encoded.length(), size)
    assert_eq(telephony_md5(encoded), hash)
    let audio = decode_audio_file(encoded, filename~, aptx_rate=44100)
    assert_eq(audio.sample_rate(), 44100)
    assert_eq(audio.channels(), 2)
    assert_eq(audio.duration_seconds(), Some(1032.0 / 44100.0))
    assert_eq(audio.samples()[0].length(), 1032)
    assert_eq(audio.samples()[1].length(), 1032)
    assert_eq(audio.read_error(), "")
  }
}
