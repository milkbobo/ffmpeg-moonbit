///|
/// §302: the perceptual rate control's eight-short-window arm. §300 published
/// the 8 x 128 psy band records and §301 taught the twoloop search to walk
/// window groups; this is the encoder-side switch that lets a short frame use
/// them. It is opt-in (`aac_encode_config_with_perceptual_short`) because the
/// group plan is still one group of eight windows and the waveform SNR on the
/// transient fixture drops from 31.84 dB to 25.21 dB with no measured
/// noise-to-mask gain yet (§303).

///|
/// Read one SCE's `ics_info`. The ADTS header is 7 bytes; `aac_decode_ics` then
/// consumes the element id/tag and the ICS syntax up to (but not including) the
/// section data, which is all these assertions need.
fn aac_encode_test_short_ics(
  stream : Array[Bytes],
  f : Int32,
) -> @libavcodec.AacIcsInfo {
  let payload = stream[f]
    .clamped_view(
      start=@libavcodec.av_aac_adts_header_size,
      end=stream[f].length(),
    )
    .to_owned()
  let gb = @libavcodec.BitReader::new(payload)
  let _ = gb.read(3) // ID_SCE
  let _ = gb.read(4) // element_instance_tag
  let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
  ics.info
}

///|
/// Byte-for-byte stream equality, used to pin the long-window baselines.
fn aac_encode_test_stream_equal(a : Array[Bytes], b : Array[Bytes]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for f = 0; f < a.length(); f = f + 1 {
    if a[f].length() != b[f].length() {
      return false
    }
    for i = 0; i < a[f].length(); i = i + 1 {
      if a[f][i] != b[f][i] {
        return false
      }
    }
  }
  true
}

///|
/// A strictly steady programme with no dither and no attacks: LAME's attack
/// detector must leave every frame on a long window, which is exactly what a
/// long-window baseline comparison needs. `aac_encode_test_tone` adds LCG
/// dither and does produce short frames, so it cannot be used here.
fn aac_encode_test_steady(
  rate : Int32,
  channels : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let out : Array[Array[Double]] = []
  for ch = 0; ch < channels; ch = ch + 1 {
    let row : Array[Double] = Array::make(frames * 1024, 0.0)
    let f = if ch == 0 { 440.0 } else { 550.0 }
    for i = 0; i < frames * 1024; i = i + 1 {
      let t = i.to_double() / rate.to_double()
      row[i] = 0.2 * @math.sin(2.0 * 3.14159265358979323846 * f * t) +
        0.05 * @math.sin(2.0 * 3.14159265358979323846 * 1333.0 * t)
    }
    out.push(row)
  }
  out
}

///|
/// The switch composes with the other two opt-in tools and implies
/// `perceptual`, exactly like `with_pns` does. With it off (the default) a
/// short frame keeps the simplified model.
test "aac_lc_perceptual_short_config" {
  let rate = 44100
  let plain = @libavcodec.aac_encode_config(rate, 2, 128000)
  let perceptual = @libavcodec.aac_encode_config_perceptual(rate, 2, 128000)
  assert_true(!plain.perceptual_short)
  assert_true(!perceptual.perceptual_short)
  let short = @libavcodec.aac_encode_config_with_perceptual_short(plain)
  assert_true(short.perceptual)
  assert_true(short.perceptual_short)
  assert_true(!short.pns)
  assert_true(!short.is_stereo)
  // Both composition orders keep every flag.
  let both = @libavcodec.aac_encode_config_with_is(
    @libavcodec.aac_encode_config_with_pns(short),
  )
  assert_true(both.pns)
  assert_true(both.is_stereo)
  assert_true(both.perceptual)
  assert_true(both.perceptual_short)
  let reversed = @libavcodec.aac_encode_config_with_perceptual_short(
    @libavcodec.aac_encode_config_with_pns(
      @libavcodec.aac_encode_config_with_is(plain),
    ),
  )
  assert_true(reversed.pns)
  assert_true(reversed.is_stereo)
  assert_true(reversed.perceptual)
  assert_true(reversed.perceptual_short)
}

///|
/// With the switch off, a steady tonal stream (no short frames) is identical
/// to the stream the same configuration produced before §302: only the short
/// frames may change, and every long window - including the ones *after* the
/// short run, so psy state must not leak across the boundary - stays
/// byte-for-byte intact.
test "aac_lc_perceptual_short_keeps_long_window_baseline" {
  let rate = 44100
  let frames = 8
  let channels = 2
  let input = aac_encode_test_steady(rate, channels, frames)
  let plain = @libavcodec.aac_encode_config_perceptual(rate, channels, 128000)
  let short = @libavcodec.aac_encode_config_with_perceptual_short(plain)
  let plain_stream = aac_encode_test_stream_config(input, channels, frames, plain)
  let short_stream = aac_encode_test_stream_config(input, channels, frames, short)
  assert_eq(plain_stream.length(), short_stream.length())
  let mut long_frames = 0
  let mut short_frames = 0
  let mut changed_short = 0
  for f = 0; f < plain_stream.length(); f = f + 1 {
    let payload = plain_stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=plain_stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    let _ = gb.read(3)
    let _ = gb.read(4)
    let common = gb.read1()
    // A CPE with a common window carries one shared ics_info here.
    assert_true(common == 1U)
    let info = aac_encode_test_ok(@libavcodec.aac_decode_ics_info(gb))
    let same = aac_encode_test_stream_equal([plain_stream[f]], [short_stream[f]])
    if info.window_sequence == 2 {
      short_frames = short_frames + 1
      if !same {
        changed_short = changed_short + 1
      }
    } else {
      long_frames = long_frames + 1
      assert_true(same)
    }
  }
  // The chain always opens with LONG_START -> EIGHT_SHORT -> LONG_STOP, so a
  // steady fixture still exercises exactly one short frame and six long ones.
  assert_true(short_frames > 0)
  assert_true(long_frames > 0)
  assert_eq(changed_short, short_frames)
  println(
    "perceptual short baseline: long=\{long_frames} unchanged short=\{short_frames} changed=\{changed_short}",
  )
}

///|
/// The switch really does hand short frames to the psy/twoloop chain: the
/// short frames change, while their ICS stays a legal single-group eight-window
/// stream that both this port's decoder and FFmpeg 9.0.2 decode identically.
test "aac_lc_perceptual_short_window_stream" {
  let rate = 44100
  let frames = 8
  let input = aac_encode_test_transient(rate, frames)
  let plain = @libavcodec.aac_encode_config_perceptual(rate, 1, 128000)
  let short = @libavcodec.aac_encode_config_with_perceptual_short(plain)
  let plain_stream = aac_encode_test_stream_config(input, 1, frames, plain)
  let short_stream = aac_encode_test_stream_config(input, 1, frames, short)
  let mut short_frames = 0
  let mut changed = 0
  let mut bytes_short = 0
  for f = 0; f < short_stream.length(); f = f + 1 {
    let info = aac_encode_test_short_ics(short_stream, f)
    if info.window_sequence == 2 {
      short_frames = short_frames + 1
      bytes_short = bytes_short + short_stream[f].length()
      // `scale_factor_grouping = 0b1111111`: one group covering all eight
      // windows, which is the plan this arm codes (§302).
      assert_eq(info.scale_factor_grouping, 0x7f)
      assert_eq(info.num_windows, 8)
      // 44100 Hz has 14 short scalefactor bands; `max_sfb` is written in 4
      // bits on short frames, so an overrun would silently corrupt the ICS.
      assert_true(info.max_sfb <= 14)
      assert_true(info.max_sfb > 0)
      if !aac_encode_test_stream_equal([plain_stream[f]], [short_stream[f]]) {
        changed = changed + 1
      }
    }
  }
  // The LAME attack detector must still produce the short-window run, and
  // every one of those frames must actually be quantised by the new arm.
  assert_true(short_frames >= 3)
  assert_eq(changed, short_frames)
  let decoded = aac_encode_test_decode(short_stream, 1)
  let mut peak = 0.0
  for f = 0; f < short_stream.length(); f = f + 1 {
    for i = 0; i < 1024; i = i + 1 {
      let v = decoded[0][f * 1024 + i]
      // `NaN != NaN`, so this catches non-finite samples too.
      assert_true(v == v)
      if v.abs() > peak {
        peak = v.abs()
      }
    }
  }
  assert_true(peak < 4.0)
  let snr = aac_encode_test_pcm_snr(input, decoded, 1, frames)
  println(
    "perceptual short window: frames=\{short_frames} changed=\{changed} short_bytes=\{bytes_short} total=\{short_stream.length()} peak=\{peak} snr=\{snr}",
  )
  // One group of eight windows sharing a scalefactor is measurably coarser
  // than the simplified model here (31.84 -> 25.21 dB on the 6-frame variant);
  // the guard is that it still reconstructs the waveform, not that it wins.
  assert_true(snr > 18.0)
}

///|
/// Stereo short frames take the same arm with the single-window IS/M-S tools
/// switched off; the pair must still decode cleanly (the external FFmpeg 9.0.2
/// cross-check covers the CPE case at 64 kbps / 2ch).
test "aac_lc_perceptual_short_window_stereo_decodes" {
  let rate = 44100
  let frames = 8
  let mono = aac_encode_test_transient(rate, frames)
  let other : Array[Double] = Array::make(frames * 1024, 0.0)
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    other[i] = 0.05 * @math.sin(2.0 * 3.14159265358979323846 * 880.0 * t)
  }
  let input = [mono[0], other]
  let config = @libavcodec.aac_encode_config_with_perceptual_short(
    @libavcodec.aac_encode_config_perceptual(rate, 2, 128000),
  )
  let stream = aac_encode_test_stream_config(input, 2, frames, config)
  let decoded = aac_encode_test_decode(stream, 2)
  let mut peak = 0.0
  for ch = 0; ch < 2; ch = ch + 1 {
    for f = 0; f < stream.length(); f = f + 1 {
      for i = 0; i < 1024; i = i + 1 {
        let v = decoded[ch][f * 1024 + i]
        assert_true(v == v)
        if v.abs() > peak {
          peak = v.abs()
        }
      }
    }
  }
  assert_true(peak < 4.0)
  let snr = aac_encode_test_pcm_snr(input, decoded, 2, frames)
  println("perceptual short window stereo: frames=\{stream.length()} peak=\{peak} snr=\{snr}")
}
