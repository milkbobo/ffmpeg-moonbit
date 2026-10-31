///|
/// FLAC encoder Rice escape partitions: a dense partition may use the
/// all-ones Rice parameter, which stores it as fixed-width signed samples.
/// RFC 9639 permits escape only for partition order > 0. The 24-bit noise
/// fixture would otherwise cost ~17 bits/sample with Rice2 (or 24 with
/// verbatim), while escaped partitions cost 16 bits/sample.

///|
/// Deterministic pseudo-random residuals in [-32768, 32767].
fn flac_escape_noise(count : Int32, seed : UInt32) -> Array[Int32] {
  let out : Array[Int32] = []
  let mut state = seed
  for _ in 0..<count {
    state = state * 1664525U + 1013904223U
    out.push(((state >> 16).reinterpret_as_int() & 0xFFFF) - 32768)
  }
  out
}

///|
test "flac encoder: rice escape partitions round-trip and shrink dense frames" {
  let samples = flac_escape_noise(4096, 777U)
  let enc = @libavcodec.flac_encode(samples, 1, 44100, 24, block_size=4096).unwrap()
  assert_eq(enc.frames.length(), 1)
  // 16 bits/sample escaped vs ~17 for Rice2 and 24 for verbatim.
  assert_true(
    enc.frames[0].length() < 8500,
    msg="frame length \{enc.frames[0].length()}",
  )
  let dec = match @libavcodec.ff_flac_decode(enc.file()) {
    Ok(v) => v
    Err(e) => fail("flac escape decode failed: \{e}")
  }
  assert_eq(dec.samples.length(), 4096)
  // ff_flac_decode left-aligns 24-bit samples in 32-bit words.
  for i in 0..<4096 {
    assert_eq(dec.samples[i], samples[i] << 8, msg="sample \{i}")
  }
}
