///|
/// `AacEncoder::flush` (§346): the `AV_CODEC_CAP_DELAY` tail frame the C
/// encoder emits on `avcodec_send_frame(NULL)` - the last frame's samples
/// MDCT'd against 1024 zeros with no lookahead.
test "AAC encoder flush: gates and tail packet" {
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  // Nothing encoded yet: the C gate (no samples buffered) emits nothing.
  assert_true(enc.flush().unwrap() is None)
  let samples : Array[Double] = []
  for i = 0; i < 1024; i = i + 1 {
    samples.push(0.2 * (i % 64 - 32).to_double() / 32.0)
  }
  let _ = enc.encode_frame([samples]).unwrap()
  // One tail packet, a complete ADTS frame (sync word + protection_absent).
  let tail = enc.flush().unwrap()
  assert_true(tail is Some(_))
  let adts = tail.unwrap()
  assert_eq(adts.length() > 7, true)
  assert_eq(adts[0], b'\xff')
  assert_eq(adts[1] & b'\xf0', b'\xf0')
  // Repeated flush without a new frame: nothing more to emit.
  assert_true(enc.flush().unwrap() is None)
  // A new frame re-arms the tail, exactly like the C gate.
  let _ = enc.encode_frame([samples]).unwrap()
  assert_true(enc.flush().unwrap() is Some(_))
}
