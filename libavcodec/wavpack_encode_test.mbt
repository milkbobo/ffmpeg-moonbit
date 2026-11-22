///|
test "wavpack encode: integer PCM across blocks and sample rates" {
  for
    (bits, channels, rate) in [
      (16, 1, 44100),
      (16, 2, 48000),
      (24, 2, 12345),
      (32, 1, 96000),
      (32, 2, 192000),
    ] {
    let pcm = Array::makei(801 * channels, i => {
      let raw = (i * 135792467) ^ ((i + 3) * 1103515245)
      match i % 211 {
        0 => -2147483648 >> (32 - bits)
        1 => 2147483647 >> (32 - bits)
        2..<=48 => 0
        _ => raw >> (32 - bits)
      }
    })
    let coded = @libavcodec.ff_wavpack_encode(
      pcm[:],
      rate,
      channels,
      bits,
      block_samples=173,
    ).unwrap()
    let decoded = @libavcodec.ff_wavpack_decode(coded).unwrap()
    assert_eq(decoded.channels, channels)
    assert_eq(decoded.sample_rate, rate)
    assert_eq(decoded.bits, bits)
    assert_eq(
      decoded.samples,
      if bits == 24 {
        pcm.map(s => s << 8)
      } else {
        pcm
      },
    )
  }
}

///|
test "wavpack encode: zero runs and one-sample final block" {
  let pcm = Array::make(8194, 0)
  let coded = @libavcodec.ff_wavpack_encode(pcm[:], 48000, 2, 16).unwrap()
  assert_true(coded.length() < 120)
  let decoded = @libavcodec.ff_wavpack_decode(coded).unwrap()
  assert_eq(decoded.samples, pcm)
}

///|
test "wavpack encode: 32-bit PCM with zero low bytes stays compact" {
  let pcm = Array::makei(5000, i => (i % 511 - 255) << 8)
  let coded = @libavcodec.ff_wavpack_encode(pcm[:], 48000, 1, 32).unwrap()
  let decoded = @libavcodec.ff_wavpack_decode(coded).unwrap()
  assert_eq(decoded.bits, 32)
  assert_eq(decoded.samples, pcm)
  assert_true(coded.length() < pcm.length())
}

///|
test "wavpack encode: reject invalid PCM and settings" {
  assert_true(@libavcodec.ff_wavpack_encode([], 44100, 1, 16) is Err(_))
  assert_true(@libavcodec.ff_wavpack_encode([0], 44100, 2, 16) is Err(_))
  assert_true(@libavcodec.ff_wavpack_encode([32768], 44100, 1, 16) is Err(_))
  assert_true(@libavcodec.ff_wavpack_encode([0], 0, 1, 16) is Err(_))
  assert_true(@libavcodec.ff_wavpack_encode([0], 44100, 1, 8) is Err(_))
  assert_true(
    @libavcodec.ff_wavpack_encode([0], 44100, 1, 16, block_samples=0) is Err(_),
  )
}
