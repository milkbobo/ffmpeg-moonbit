///|
/// `AacEncoder::flush` (§346/§349): FFmpeg's `AV_CODEC_CAP_DELAY` drain.
/// The perceptual path emits each window one frame late, so the flush
/// always returns two packets once a frame is buffered - the pending
/// window (its type decided with `la == NULL`) and the zero-padded tail.
test "AAC encoder flush: gates and drain packets" {
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config_perceptual(48000, 1, 64000),
  ).unwrap()
  // Nothing encoded yet: the C gate (no samples buffered) drains nothing.
  assert_true(enc.flush().unwrap() is [])
  let samples : Array[Double] = []
  for i = 0; i < 1024; i = i + 1 {
    samples.push(0.2 * (i % 64 - 32).to_double() / 32.0)
  }
  // The perceptual path emits one frame late: the first call stashes.
  assert_true(enc.encode_frame([samples]).unwrap() is None)
  // The drain: two complete ADTS frames (sync word + protection_absent).
  let tail = enc.flush().unwrap()
  assert_eq(tail.length(), 2)
  for adts in tail {
    assert_eq(adts.length() > 7, true)
    assert_eq(adts[0], b'\xff')
    assert_eq(adts[1] & b'\xf0', b'\xf0')
  }
  // Repeated flush without a new frame: nothing more to drain.
  assert_true(enc.flush().unwrap() is [])
  // A new frame re-arms the drain, exactly like the C gate.
  let _ = enc.encode_frame([samples]).unwrap()
  assert_eq(enc.flush().unwrap().length(), 2)
}
