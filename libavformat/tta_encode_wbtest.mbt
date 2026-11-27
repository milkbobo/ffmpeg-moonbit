///|
test "TTA 24-bit export matches FFmpeg and preserves stereo PCM across frames" {
  let pcm = Array::makei(8371 * 2, i => {
    let frame = i / 2
    let value = if i % 2 == 0 {
      frame * 633451
    } else {
      frame * 1172131 + 219773
    }
    (value % 16777216 - 8388608) << 8
  })
  let wav = wav_muxer_new(8000, 2, 32).unwrap()
  wav.write_samples(pcm[:])
  let encoded = decode_audio_file(wav.finish()).to_tta(bits=24)
  assert_eq(telephony_md5(encoded), "af0e943d5369e3903993d90506bab004")
  let track = av_tta_open(encoded, verify_crc=true).unwrap()
  assert_eq(track.header.bits, 24)
  assert_eq(track.frames.length(), 2)
  assert_eq(track.frames[1].pts, 8359L)
  assert_eq(track.frames[1].duration, 12)
  let decoded = decode_audio_file(encoded, tta_verify_crc=true)
  assert_eq(decoded.sample_rate(), 8000)
  assert_eq(decoded.channels(), 2)
  let planes = decoded.samples()
  assert_eq(planes[0].length(), 8371)
  assert_eq(planes[1].length(), 8371)
  for i in 0..<pcm.length() {
    assert_eq(planes[i % 2][i / 2], pcm[i].to_double() / 2147483648.0)
  }
}

///|
test "strict TTA decode identifies header, seek table, and frame CRC failures" {
  let pcm = [0, -32768, 32767, -1, 1]
  let encoded = @libavcodec.encode_tta(pcm[:], 8000, 1, 16).unwrap()
  assert_eq(
    @libavcodec.ff_tta_decode(encoded, verify_crc=true).unwrap().samples,
    pcm,
  )
  for
    (offset, expected) in [
      (18, "tta: header CRC mismatch"),
      (26, "tta: seek table CRC mismatch"),
      (encoded.length() - 1, "tta: frame CRC mismatch at 0"),
    ] {
    let bad = Bytes::makei(encoded.length(), i => {
      if i == offset {
        (encoded[i].to_int() ^ 1).to_byte()
      } else {
        encoded[i]
      }
    })
    let result = Ok(decode_audio_file(bad, tta_verify_crc=true)) catch {
      error => Err(error)
    }
    guard result is Err(DemuxError(message)) else {
      fail("expected a TTA CRC error")
    }
    assert_eq(message, expected)
    assert_eq(@libavcodec.ff_tta_decode(bad).unwrap().samples, pcm)
    assert_true(@libavcodec.ff_tta_decode(bad, verify_crc=true) is Err(_))
  }
}
