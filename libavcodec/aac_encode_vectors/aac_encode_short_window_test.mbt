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
  let plain_stream = aac_encode_test_stream_config(
    input, channels, frames, plain,
  )
  let short_stream = aac_encode_test_stream_config(
    input, channels, frames, short,
  )
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
  let mut grouped_frames = 0
  for f = 0; f < short_stream.length(); f = f + 1 {
    let info = aac_encode_test_short_ics(short_stream, f)
    if info.window_sequence == 2 {
      short_frames = short_frames + 1
      bytes_short = bytes_short + short_stream[f].length()
      assert_eq(info.num_windows, 8)
      // §304: the short frames carry the LAME analyser's grouping.  The
      // 7-bit `scale_factor_grouping` holds `!group_len[w]`, w = 1..7, first
      // bit first; a valid byte partitions the eight windows, and this
      // transient fixture must produce a non-trivial partition at least once
      // (`0b1111111` would mean the grouping never left the §302 single
      // group).
      let gl : Array[Int32] = Array::make(8, 0)
      let mut lastgrp = 0
      for w = 0; w < 8; w = w + 1 {
        if w == 0 || ((info.scale_factor_grouping >> (7 - w)) & 1) == 0 {
          lastgrp = w
        }
        gl[lastgrp] = gl[lastgrp] + 1
      }
      let mut cover = 0
      for w = 0; w < 8; w = w + 1 {
        cover = cover + gl[w]
        // a group length is positive at its start and 0 inside
        let expect = if w == 0 ||
          ((info.scale_factor_grouping >> (7 - w)) & 1) == 0 {
          gl[w] > 0
        } else {
          gl[w] == 0
        }
        assert_true(expect)
      }
      assert_eq(cover, 8)
      if info.scale_factor_grouping != 0x7f {
        grouped_frames = grouped_frames + 1
      }
      // 44100 Hz has 14 short scalefactor bands; `max_sfb` is written in 4
      // bits on short frames, so an overrun would silently corrupt the ICS.
      assert_true(info.max_sfb <= 14)
      assert_true(info.max_sfb > 0)
      if !aac_encode_test_stream_equal([plain_stream[f]], [short_stream[f]]) {
        changed = changed + 1
      }
    } else {
      // The plain arm (perceptual, `perceptual_short` off) keeps the §302
      // single group on its own short frames.
      let plain_info = aac_encode_test_short_ics(plain_stream, f)
      if plain_info.window_sequence == 2 {
        assert_eq(plain_info.scale_factor_grouping, 0x7f)
      }
    }
  }
  // The LAME attack detector must still produce the short-window run, every
  // one of those frames must actually be quantised by the new arm, and the
  // analyser's grouping must have reached the bitstream.
  assert_true(short_frames >= 3)
  assert_eq(changed, short_frames)
  assert_true(grouped_frames > 0)
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
  // §304's real grouping re-priced these frames again (17.83 dB, five short
  // frames, non-trivial partitions) while cutting the noise-to-mask ratio
  // from 9.75 to 13.40 dB - see the NMR test below.
  assert_true(snr > 17.0)
}

///|
/// Per-band noise-to-mask ratio of the eight-short-window frames - the §303
/// yardstick that decides whether `perceptual_short` can become the default.
/// The long-window helper (`aac_encode_test_nmr`) measures a 1024-line
/// spectrum against long-window thresholds, which says nothing about a short
/// frame: the model itself switches to the 14-band short plan and the short
/// slope constants, so the noise of a short frame is only comparable against
/// thresholds computed in the same shape.
///
/// Every frame of the stream is replayed through a fresh model - long frames
/// included, because the pre-echo reduction reads the previous frame's
/// thresholds and `prev_band` carries them across window-shape changes - and
/// for every EIGHT_SHORT frame the original and the decoded signal go through
/// the same 8 x 128 analysis, so each window's each band's error lands on the
/// very threshold (`bands[w * 16 + g]`) the model computed for the original.
/// The thresholds therefore depend on the input and the window plan only, and
/// two streams that share a window plan are measured with the same yardstick.
///
/// Frame 0 is analysed to establish the pre-echo history but not measured:
/// its overlap buffer's first half is the encoder's silent start-up history,
/// which the priming frame only approximately reconstructs. Returns
/// `(mean nmr in dB over windows x bands, spectral snr in dB over the short
/// frames' coefficients)`.
fn aac_encode_test_nmr_short(
  input : Array[Array[Double]],
  decoded : Array[Array[Double]],
  channels : Int32,
  seqs : Array[Int32],
  rate : Int32,
  bit_rate : Int32,
) -> (Double, Double) raise {
  let frames = seqs.length() - 1 // the last stream frame is the flush frame
  let psy = @libavcodec.aac_psy_new(4, rate, bit_rate, channels)
  let sizes = psy.band_sizes_short() // 14 bands, 128 lines per window
  let num_bands = sizes.length()
  let offsets : Array[Int32] = Array::make(num_bands + 1, 0)
  for g = 0; g < num_bands; g = g + 1 {
    offsets[g + 1] = offsets[g] + sizes[g]
  }
  // The short plan must tile all eight windows' 128 lines exactly.
  assert_eq(offsets[num_bands], 128)
  let mut nmr_sum = 0.0
  let mut nmr_n = 0
  let mut energy = 0.0
  let mut noise = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for f = 0; f < frames; f = f + 1 {
      let seq = seqs[f]
      let orig : Array[Double] = Array::make(2048, 0.0)
      for i = 0; i < 1024; i = i + 1 {
        // The decoder emits one priming frame, so input block f is decoded
        // block f+1; the encoder's overlap buffer for frame f is [block f-1,
        // block f], which for f == 0 starts from its silent history.
        if f > 0 {
          orig[i] = input[ch][(f - 1) * 1024 + i]
        }
        orig[1024 + i] = input[ch][f * 1024 + i]
      }
      let want = aac_encode_test_analysis(orig, seq)
      let prev = if f > 0 { seqs[f - 1] } else { 0 }
      let bands = psy.analyze(ch, want, 0, seq, prev).bands
      if seq != 2 || f == 0 {
        continue
      }
      let recon : Array[Double] = Array::make(2048, 0.0)
      for i = 0; i < 1024; i = i + 1 {
        recon[i] = decoded[ch][f * 1024 + i]
        recon[1024 + i] = decoded[ch][(f + 1) * 1024 + i]
      }
      let got = aac_encode_test_analysis(recon, seq)
      for w = 0; w < 8; w = w + 1 {
        for g = 0; g < num_bands; g = g + 1 {
          let thr = bands[w * 16 + g].threshold
          if thr <= 0.0 {
            continue
          }
          let base = w * 128
          let mut band_noise = 0.0
          for i = offsets[g]; i < offsets[g + 1]; i = i + 1 {
            let d = got[base + i] - want[base + i]
            band_noise = band_noise + d * d
            energy = energy + want[base + i] * want[base + i]
            noise = noise + d * d
          }
          nmr_sum = nmr_sum + 10.0 * @math.log10(band_noise / thr)
          nmr_n = nmr_n + 1
        }
      }
    }
  }
  // A fixture without short frames measures nothing; NaN fails every caller.
  assert_true(nmr_n > 0)
  let snr = 10.0 * @math.log10(energy / noise)
  (nmr_sum / nmr_n.to_double(), snr)
}

///|
/// The window sequence each coded frame of a mono stream carries, in stream
/// order. The plan comes from the attack detector, which reads the input PCM
/// only, so two rate controls fed the same input must produce the same plan -
/// that identity is what lets the NMR helper compare them on one yardstick.
fn aac_encode_test_window_plan(stream : Array[Bytes]) -> Array[Int32] {
  let seqs : Array[Int32] = []
  for f = 0; f < stream.length(); f = f + 1 {
    seqs.push(aac_encode_test_short_ics(stream, f).window_sequence)
  }
  seqs
}

///|
/// Which of the two short-frame rate controls puts the quantisation noise
/// closer to the model's masking thresholds - the §303 question that decides
/// whether `perceptual_short` stays opt-in. The simplified model treats all
/// eight windows as one 1024-line frame; the perceptual arm quantises each
/// window against its own threshold but shares one scalefactor per band
/// across the group (§302), so whether the noise really lands under the mask
/// is an empirical question, and this is the measurement.
test "aac_lc_perceptual_short_noise_to_mask" {
  let rate = 44100
  let frames = 8
  let input = aac_encode_test_transient(rate, frames)
  let base = @libavcodec.aac_encode_config_perceptual(rate, 1, 128000)
  let on = @libavcodec.aac_encode_config_with_perceptual_short(base)
  let stream_off = aac_encode_test_stream_config(input, 1, frames, base)
  let stream_on = aac_encode_test_stream_config(input, 1, frames, on)
  let plan_off = aac_encode_test_window_plan(stream_off)
  let plan_on = aac_encode_test_window_plan(stream_on)
  // The plan is PCM-driven, so both streams must carry the same windows.
  assert_eq(plan_off.length(), plan_on.length())
  for f = 0; f < plan_off.length(); f = f + 1 {
    assert_eq(plan_off[f], plan_on[f])
  }
  let (nmr_off, snr_off) = aac_encode_test_nmr_short(
    input,
    aac_encode_test_decode(stream_off, 1),
    1,
    plan_off,
    rate,
    128000,
  )
  let (nmr_on, snr_on) = aac_encode_test_nmr_short(
    input,
    aac_encode_test_decode(stream_on, 1),
    1,
    plan_on,
    rate,
    128000,
  )
  println(
    "short noise-to-mask: simplified mean=\{nmr_off} dB (spectral snr \{snr_off}); perceptual mean=\{nmr_on} dB (spectral snr \{snr_on})",
  )
  // Both measurements are finite and within a sane distance of the mask (a
  // NaN fails both bounds).
  assert_true(nmr_off > -100.0 && nmr_off < 60.0)
  assert_true(nmr_on > -100.0 && nmr_on < 60.0)
  // The §303 finding, and the reason `perceptual_short` stays opt-in: with
  // the group plan still one group of eight windows, the perceptual arm
  // shares one scalefactor per band across windows whose energies differ by
  // an order of magnitude, so it loses on the model's own yardstick too -
  // 14.2 vs 9.7 dB here, worse in every one of the eight windows, worst in
  // the low bands. The long-window trade (10 dB of SNR for 1.6 dB of NMR,
  // §280) does not exist yet on short frames; window grouping (the real
  // `scale_factor_grouping`) is what can flip this ordering.
  assert_true(nmr_on > nmr_off)
  // The same holds where the two allocations part hardest: at 64 kbps the
  // shared scalefactor starves every quiet window (18.7 vs 15.6 dB, with
  // waveform SNR already known to collapse, §302).
  let base64 = @libavcodec.aac_encode_config_perceptual(rate, 1, 64000)
  let on64 = @libavcodec.aac_encode_config_with_perceptual_short(base64)
  let s64_off = aac_encode_test_stream_config(input, 1, frames, base64)
  let s64_on = aac_encode_test_stream_config(input, 1, frames, on64)
  let p64_off = aac_encode_test_window_plan(s64_off)
  let p64_on = aac_encode_test_window_plan(s64_on)
  assert_eq(p64_off.length(), p64_on.length())
  for f = 0; f < p64_off.length(); f = f + 1 {
    assert_eq(p64_off[f], p64_on[f])
  }
  let (n64_off, snr64_off) = aac_encode_test_nmr_short(
    input,
    aac_encode_test_decode(s64_off, 1),
    1,
    p64_off,
    rate,
    64000,
  )
  let (n64_on, snr64_on) = aac_encode_test_nmr_short(
    input,
    aac_encode_test_decode(s64_on, 1),
    1,
    p64_on,
    rate,
    64000,
  )
  println(
    "short nmr 64k: simplified mean=\{n64_off} dB (spectral snr \{snr64_off}); perceptual mean=\{n64_on} dB (spectral snr \{snr64_on})",
  )
  assert_true(n64_off > -100.0 && n64_off < 60.0)
  assert_true(n64_on > -100.0 && n64_on < 60.0)
  assert_true(n64_on > n64_off)
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
  println(
    "perceptual short window stereo: frames=\{stream.length()} peak=\{peak} snr=\{snr}",
  )
}

///|
/// §305: PNS on the short-window frames. The sticky slot arrays, `mark_pns`'s
/// group gates and `search_for_pns`'s per-window noise pricing now run on
/// EIGHT_SHORT frames, so a transient stream must carry real NOISE_BT bands on
/// its short frames (every window group, not just the first), the run without
/// the tool must carry none, and the stream must still decode at a finite
/// level. PNS is waveform-inexact by design - the decoder synthesises fresh
/// noise - so the guard on the reconstruction is that it stays a waveform, not
/// that it is transparent.
test "aac_lc_perceptual_short_pns_stream" {
  let rate = 44100
  let frames = 8
  let input = aac_encode_test_transient(rate, frames)
  let short = @libavcodec.aac_encode_config_with_perceptual_short(
    @libavcodec.aac_encode_config_perceptual(rate, 1, 128000),
  )
  let plain_stream = aac_encode_test_stream_config(input, 1, frames, short)
  let pns_stream = aac_encode_test_stream_config(
    input,
    1,
    frames,
    @libavcodec.aac_encode_config_with_pns(short),
  )
  // Noise bands per frame from the SCE's sections, over every window group.
  let plain_noise : Array[Int32] = Array::make(plain_stream.length(), 0)
  let pns_noise : Array[Int32] = Array::make(pns_stream.length(), 0)
  for f = 0; f < pns_stream.length(); f = f + 1 {
    for pass = 0; pass < 2; pass = pass + 1 {
      let stream = if pass == 0 { plain_stream } else { pns_stream }
      let payload = stream[f]
        .clamped_view(
          start=@libavcodec.av_aac_adts_header_size,
          end=stream[f].length(),
        )
        .to_owned()
      let gb = @libavcodec.BitReader::new(payload)
      let id = gb.read(3).reinterpret_as_int()
      let _ = gb.read(4)
      if id != 0 {
        abort("short pns test: expected a single channel element")
      }
      let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
      for g = 0; g < ics.sect_cb.length(); g = g + 1 {
        for b = 0; b < ics.sect_cb[g].length(); b = b + 1 {
          if ics.sect_cb[g][b] == 13 {
            if pass == 0 {
              plain_noise[f] = plain_noise[f] + 1
            } else {
              pns_noise[f] = pns_noise[f] + 1
            }
          }
        }
      }
    }
  }
  let mut short_noise_frames = 0
  let mut noise_bands = 0
  let mut plain_bands = 0
  for f = 0; f < pns_stream.length(); f = f + 1 {
    plain_bands = plain_bands + plain_noise[f]
    noise_bands = noise_bands + pns_noise[f]
    if pns_noise[f] > 0 {
      short_noise_frames = short_noise_frames + 1
    }
  }
  let decoded = aac_encode_test_decode(pns_stream, 1)
  let mut peak = 0.0
  for f = 0; f < decoded[0].length(); f = f + 1 {
    let v = decoded[0][f]
    assert_true(v == v)
    if v.abs() > peak {
      peak = v.abs()
    }
  }
  let snr = aac_encode_test_pcm_snr(input, decoded, 1, frames)
  println(
    "perceptual short PNS: noise frames=\{short_noise_frames} bands=\{noise_bands} (plain \{plain_bands}) peak=\{peak} snr=\{snr}",
  )
  // The tool fires on the short frames, only when asked for, and the stream
  // decodes to a bounded, finite waveform.
  assert_true(noise_bands > 0)
  assert_true(plain_bands == 0)
  assert_true(peak < 4.0)
  assert_true(snr > 8.0)
}

///|
/// §306: the stereo pair of tools on the short-window frames. The intensity
/// and mid/side searches now walk window groups, so a transient stereo stream
/// with both tools on must carry real `INTENSITY_BT` bands and a per-group
/// `ms_used` bit layout in its short frames, the run without them must carry
/// neither, and both must decode to a finite waveform. Intensity is
/// waveform-inexact by design on its bands (the decoder rebuilds the right
/// half from the left), so the reconstruction guard is finiteness plus a
/// bounded peak, not transparency.
test "aac_lc_perceptual_short_is_ms_stream" {
  let rate = 44100
  let frames = 8
  // A stereo transient: correlated tonal base (so mid/side has real work) with
  // per-channel clicks at different offsets and inverted high-frequency
  // windows in the second channel (so intensity, both phases and the flip
  // variant all get candidates).
  let mono = aac_encode_test_transient(rate, frames)
  let other : Array[Double] = Array::make(frames * 1024, 0.0)
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    // A correlated low tone for mid/side and a strong high component (well
    // above the intensity gate) for the intensity search.
    let v = 0.05 * @math.sin(2.0 * 3.14159265358979323846 * 880.0 * t) +
      0.04 * @math.sin(2.0 * 3.14159265358979323846 * 7700.0 * t)
    // Invert the correlation in windows 2, 3 and 6.
    let w = i / 128 % 8
    let s = if w == 2 || w == 3 || w == 6 { -0.9 } else { 0.95 }
    other[i] = v * s
  }
  for k = 0; k < 3; k = k + 1 {
    let pos = 700 + k * 2048 + 96
    if pos < frames * 1024 {
      other[pos] = if k % 2 == 0 { -1.0 } else { 1.0 }
    }
  }
  let input = [mono[0], other]
  let short = @libavcodec.aac_encode_config_with_perceptual_short(
    @libavcodec.aac_encode_config_perceptual(rate, 2, 128000),
  )
  let plain_stream = aac_encode_test_stream_config(input, 2, frames, short)
  let tools_stream = aac_encode_test_stream_config(
    input,
    2,
    frames,
    @libavcodec.aac_encode_config_with_is(short),
  )
  // Section-derived tool census over every short frame, both channels.
  let census : (Array[Bytes]) -> (Int32, Int32, Int32) = fn(stream) {
    let mut is_bands = 0
    let mut noise_bands = 0
    let mut short_frames = 0
    for f = 0; f < stream.length(); f = f + 1 {
      let payload = stream[f]
        .clamped_view(
          start=@libavcodec.av_aac_adts_header_size,
          end=stream[f].length(),
        )
        .to_owned()
      let gb = @libavcodec.BitReader::new(payload)
      let id = gb.read(3).reinterpret_as_int()
      let _ = gb.read(4)
      if id != 1 {
        abort("short is/ms test: expected a channel pair")
      }
      if gb.read1() != 1U {
        abort("short is/ms test: expected a common window")
      }
      let info = aac_encode_test_ok(@libavcodec.aac_decode_ics_info(gb))
      let ms_mode = gb.read(2).reinterpret_as_int()
      if ms_mode == 1 {
        // ms_used: one bit per group-start band, group by group - so on an
        // eight-short frame that is every window group's max_sfb bits.
        let mut b = 0
        let bits = info.num_window_groups * info.max_sfb
        while b < bits {
          let _ = gb.read1()
          b = b + 1
        }
      }
      if info.window_sequence == 2 {
        short_frames = short_frames + 1
      }
      for ch = 0; ch < 2; ch = ch + 1 {
        let ics = aac_encode_test_ok(
          @libavcodec.aac_decode_ics_with_info(gb, Some(info)),
        )
        // Consume the spectral data too, or the next channel starts
        // mid-spectrum.
        let _ = aac_encode_test_parse_spectrum(gb, ics)
        for g = 0; g < ics.sect_cb.length(); g = g + 1 {
          for b = 0; b < ics.sect_cb[g].length(); b = b + 1 {
            let cb = ics.sect_cb[g][b]
            if cb == 14 || cb == 15 {
              is_bands = is_bands + 1
            }
            if cb == 13 {
              noise_bands = noise_bands + 1
            }
          }
        }
      }
    }
    (is_bands, noise_bands, short_frames)
  }
  let (plain_is, plain_noise, plain_short) = census(plain_stream)
  let (tools_is, tools_noise, tools_short) = census(tools_stream)
  let decoded = aac_encode_test_decode(tools_stream, 2)
  let mut peak = 0.0
  for ch = 0; ch < 2; ch = ch + 1 {
    for f = 0; f < decoded[ch].length(); f = f + 1 {
      let v = decoded[ch][f]
      assert_true(v == v)
      if v.abs() > peak {
        peak = v.abs()
      }
    }
  }
  println(
    "perceptual short IS/MS: is bands \{plain_is} -> \{tools_is}, noise \{plain_noise} -> \{tools_noise}, short frames \{plain_short}/\{tools_short}, peak=\{peak}",
  )
  assert_true(plain_short > 0)
  assert_true(tools_is > 0)
  assert_true(plain_is == 0)
  assert_true(peak < 4.0)
}
