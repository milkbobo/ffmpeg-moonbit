///|
/// Regression (§331): a pure tone must survive the default path's long
/// frames. Before the `coef2minsf` floor (`aac_encode_min_sf`) the tonal
/// peak quantised past 8191, was clamped by the escape codebook, and the
/// long frames decoded at ~1 dB SNR while the transient start (short
/// windows) still looked fine; the in-process FFmpeg oracle exposed it
/// (`ffref` AAC interop test: 3.4 dB vs the native encoder's 31.5 dB).
test "aac_lc_pure_tone_does_not_saturate" {
  let rate = 44100
  let frames = 6
  let row : Array[Double] = []
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    row.push(0.305 * @math.sin(2.0 * 3.14159265358979323846 * 440.0 * t))
  }
  let pcm = [row]
  let stream = aac_encode_test_stream(pcm, 1, frames, rate, 128000)
  // Spectral round trip per frame: every frame, long ones included, must
  // carry the tone at quantisation precision.
  for f = 0; f < frames; f = f + 1 {
    let payload = stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    assert_eq(gb.read(3).reinterpret_as_int(), 0) // ID_SCE
    let _ = gb.read(4)
    let (got, ics) = aac_encode_test_parse_channel(gb)
    let buf : Array[Double] = Array::make(2048, 0.0)
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = if f > 0 { row[(f - 1) * 1024 + i] } else { 0.0 }
      buf[1024 + i] = row[f * 1024 + i]
    }
    let want = aac_encode_test_analysis(buf, ics.info.window_sequence)
    let mut energy = 0.0
    let mut noise = 0.0
    for j = 0; j < 1024; j = j + 1 {
      let d = got[j] - want[j]
      energy = energy + want[j] * want[j]
      noise = noise + d * d
    }
    let snr = 10.0 * @math.log10(energy / noise)
    assert_true(
      snr > 50.0,
      msg="frame \{f} (seq \{ics.info.window_sequence}): spectral snr \{snr}",
    )
  }
  // Waveform round trip through the in-tree decoder (one priming frame).
  let decoded = aac_encode_test_decode(stream, 1)
  let mut energy = 0.0
  let mut noise = 0.0
  for i = 1024; i < (frames - 1) * 1024; i = i + 1 {
    let d = decoded[0][i + 1024] - row[i]
    energy = energy + row[i] * row[i]
    noise = noise + d * d
  }
  let snr = 10.0 * @math.log10(energy / noise)
  assert_true(snr > 40.0, msg="waveform snr \{snr}")
}
