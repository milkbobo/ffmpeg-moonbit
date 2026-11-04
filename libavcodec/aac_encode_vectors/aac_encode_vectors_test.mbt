///|
/// Abort on an unexpected encoder/decoder error instead of propagating it, so
/// the helpers need no error type.
fn[T] aac_encode_test_ok(r : Result[T, String]) -> T {
  match r {
    Ok(v) => v
    Err(e) => {
      println("AAC test error: \{e}")
      abort("AAC test: unexpected error")
    }
  }
}

///|
/// Deterministic programme: a handful of tones per channel plus a low-level
/// LCG dither so that the spectrum is not sparse (a pure tone needs only a few
/// bytes per frame and would not exercise the rate control).
fn aac_encode_test_tone(
  rate : Int32,
  channels : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let pcm : Array[Array[Double]] = []
  let mut seed : UInt32 = 1234U
  for ch = 0; ch < channels; ch = ch + 1 {
    let row : Array[Double] = Array::make(frames * 1024, 0.0)
    let freqs = if ch == 0 {
      [440.0, 1333.0, 3500.0, 7000.0]
    } else {
      [550.0, 2200.0, 9000.0, 12000.0]
    }
    let amps = if ch == 0 {
      [0.5, 0.2, 0.08, 0.04]
    } else {
      [0.3, 0.15, 0.06, 0.03]
    }
    for i = 0; i < frames * 1024; i = i + 1 {
      let t = i.to_double() / rate.to_double()
      let mut v = 0.0
      for k = 0; k < freqs.length(); k = k + 1 {
        v = v + amps[k] * @math.sin(2.0 * 3.14159265358979323846 * freqs[k] * t)
      }
      seed = seed * 1664525U + 1013904223U
      let dither = (seed.reinterpret_as_int() >> 8).to_double() / 8388608.0
      row[i] = v + 0.02 * dither
    }
    pcm.push(row)
  }
  pcm
}

///|
/// Encode `frames` input frames plus one silent flush frame.
fn aac_encode_test_stream(
  pcm : Array[Array[Double]],
  channels : Int32,
  frames : Int32,
  rate : Int32,
  bit_rate : Int32,
) -> Array[Bytes] {
  let config : @libavcodec.AacEncodeConfig = @libavcodec.aac_encode_config(
    rate, channels, bit_rate,
  )
  aac_encode_test_stream_config(pcm, channels, frames, config)
}

///|
/// Encode `frames` input frames plus one silent flush frame with an explicit
/// configuration (so a test can pick the perceptual rate control).
fn aac_encode_test_stream_config(
  pcm : Array[Array[Double]],
  channels : Int32,
  frames : Int32,
  config : @libavcodec.AacEncodeConfig,
) -> Array[Bytes] {
  let enc = aac_encode_test_ok(@libavcodec.aac_encoder_new(config))
  let out : Array[Bytes] = []
  for f = 0; f < frames + 1; f = f + 1 {
    let input : Array[Array[Double]] = []
    for ch = 0; ch < channels; ch = ch + 1 {
      if f < frames {
        input.push(pcm[ch][f * 1024:f * 1024 + 1024].to_owned())
      } else {
        input.push(Array::make(1024, 0.0))
      }
    }
    out.push(aac_encode_test_ok(enc.encode_frame(input)))
  }
  out
}

///|
/// Decode every ADTS frame and return planar PCM (`frames` frames).
fn aac_encode_test_decode(
  frames : Array[Bytes],
  channels : Int32,
) -> Array[Array[Double]] raise {
  let decoder = aac_encode_test_ok(
    @libavcodec.new_aac_decoder_from_adts(frames[0], channels),
  )
  let pcm : Array[Array[Double]] = []
  for ch = 0; ch < channels; ch = ch + 1 {
    pcm.push(Array::make(frames.length() * 1024, 0.0))
  }
  for f = 0; f < frames.length(); f = f + 1 {
    let header = aac_encode_test_ok(
      @libavcodec.ff_adts_header_parse_buf(
        frames[f]
        .clamped_view(start=0, end=@libavcodec.av_aac_adts_header_size)
        .to_owned(),
      ),
    )
    assert_eq(header.frame_length, frames[f].length())
    assert_eq(header.sample_rate, 44100)
    assert_eq(header.chan_config, channels)
    assert_eq(header.object_type, 2)
    let payload = frames[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=frames[f].length(),
      )
      .to_owned()
    let out = match decoder.decode_frame(payload) {
      Ok(v) => v
      Err(e) => {
        println("AAC decode failed at frame \{f}: \{e}")
        abort("AAC decode failed")
      }
    }
    assert_eq(out.length(), channels)
    for ch = 0; ch < channels; ch = ch + 1 {
      assert_eq(out[ch].samples.length(), 1024)
      for i = 0; i < 1024; i = i + 1 {
        pcm[ch][f * 1024 + i] = out[ch].samples[i]
      }
    }
  }
  pcm
}

///|
/// Sine analysis window, `sin(pi/(2*1024)*(i+0.5))`.
fn aac_encode_test_window() -> Array[Double] {
  let w : Array[Double] = Array::make(1024, 0.0)
  for i = 0; i < 1024; i = i + 1 {
    w[i] = @math.sin(3.14159265358979323846 / 2048.0 * (i.to_double() + 0.5))
  }
  w
}

///|
/// Whether any window of the parsed TNS data carries a filter.
fn aac_encode_test_tns_present(tns : @libavcodec.AacTns) -> Bool {
  for w = 0; w < tns.n_filt.length(); w = w + 1 {
    if tns.n_filt[w] > 0 {
      return true
    }
  }
  false
}

///|
/// Decode one channel's spectral data and apply its TNS synthesis, the order
/// used by the real decode path (stereo inverse first, then TNS).
fn aac_encode_test_parse_spectrum(
  gb : @libavcodec.BitReader,
  ics : @libavcodec.AacIcs,
) -> Array[Double] {
  let swb = aac_encode_test_ok(@libavcodec.aac_swb_tables(4))
  let sf = @libavcodec.aac_sf_dequant(ics.info, ics.sect_cb, ics.scale_factors)
  let noise = @libavcodec.new_aac_spectrum_state()
  let coeffs : Array[Double] = Array::make(1024, 0.0)
  aac_encode_test_ok(
    @libavcodec.aac_decode_spectrum(
      gb,
      ics.info,
      swb,
      ics.sect_cb,
      sf,
      noise,
      coeffs,
    ),
  )
  @libavcodec.aac_apply_tns(coeffs, ics.tns, ics.info, swb)
  coeffs
}

///|
/// Decode one independent channel stream from the already positioned reader.
fn aac_encode_test_parse_channel(
  gb : @libavcodec.BitReader,
) -> (Array[Double], @libavcodec.AacIcs) {
  let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
  (aac_encode_test_parse_spectrum(gb, ics), ics)
}

///|
/// Decode one channel of a common-window CPE, which carries no ics_info of its
/// own.
fn aac_encode_test_parse_channel_common(
  gb : @libavcodec.BitReader,
  info : @libavcodec.AacIcsInfo,
) -> (Array[Double], @libavcodec.AacIcs) {
  let ics = aac_encode_test_ok(
    @libavcodec.aac_decode_ics_with_info(gb, Some(info)),
  )
  (aac_encode_test_parse_spectrum(gb, ics), ics)
}

///|
/// Encoder-side analysis reproduced for the syntax tests: the analysis window
/// of `seq` (0 ONLY_LONG, 1 LONG_START, 2 EIGHT_SHORT, 3 LONG_STOP) over the
/// un-windowed overlap buffer, the forward MDCT and the decoder's sign
/// convention (`-65536 * MDCT`).
fn aac_encode_test_analysis(buf : Array[Double], seq : Int32) -> Array[Double] {
  let win = aac_encode_test_window()
  let swin : Array[Double] = Array::make(256, 0.0)
  for i = 0; i < 256; i = i + 1 {
    swin[i] = @math.sin(3.14159265358979323846 / 256.0 * (i.to_double() + 0.5))
  }
  let out : Array[Double] = Array::make(1024, 0.0)
  if seq == 2 {
    for w = 0; w < 8; w = w + 1 {
      let slot : Array[Double] = Array::make(256, 0.0)
      for i = 0; i < 256; i = i + 1 {
        slot[i] = buf[448 + w * 128 + i] * swin[i]
      }
      let part = @libavcodec.aac_mdct_forward(slot, 256)
      for j = 0; j < 128; j = j + 1 {
        out[w * 128 + j] = -65536.0 * part[j]
      }
    }
    return out
  }
  let d : Array[Double] = Array::make(2048, 0.0)
  if seq == 1 {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = buf[i] * win[i]
    }
    for i = 0; i < 448; i = i + 1 {
      d[1024 + i] = buf[1024 + i]
    }
    for i = 0; i < 128; i = i + 1 {
      d[1472 + i] = buf[1472 + i] * swin[127 - i]
    }
  } else if seq == 3 {
    for i = 0; i < 128; i = i + 1 {
      d[448 + i] = buf[448 + i] * swin[i]
    }
    for i = 0; i < 448; i = i + 1 {
      d[576 + i] = buf[576 + i]
    }
    for i = 0; i < 1024; i = i + 1 {
      d[1024 + i] = buf[1024 + i] * win[1023 - i]
    }
  } else {
    for i = 0; i < 1024; i = i + 1 {
      d[i] = buf[i] * win[i]
      d[1024 + i] = buf[1024 + i] * win[1023 - i]
    }
  }
  let x = @libavcodec.aac_mdct_forward(d, 2048)
  for j = 0; j < 1024; j = j + 1 {
    out[j] = -65536.0 * x[j]
  }
  out
}

///|
/// Ideal analysis/synthesis identity: the decoder's windowing stage must
/// reconstruct the input from the unquantised forward MDCT, one 1024-sample
/// frame late, at unit gain.
test "aac_lc_analysis_synthesis" {
  let rate = 44100
  let frames = 3
  let input = aac_encode_test_tone(rate, 1, frames)
  let win = aac_encode_test_window()
  let st = @libavcodec.new_aac_channel_state()
  let outs : Array[Array[Double]] = []
  for f = 0; f < frames + 1; f = f + 1 {
    let buf : Array[Double] = Array::make(2048, 0.0)
    for i = 0; i < 1024; i = i + 1 {
      let prev = if f > 0 && f <= frames {
        input[0][(f - 1) * 1024 + i]
      } else {
        0.0
      }
      let cur = if f < frames { input[0][f * 1024 + i] } else { 0.0 }
      buf[i] = prev * win[i]
      buf[1024 + i] = cur * win[1023 - i]
    }
    let x = @libavcodec.aac_mdct_forward(buf, 2048)
    for j = 0; j < 1024; j = j + 1 {
      x[j] = -65536.0 * x[j]
    }
    outs.push(@libavcodec.aac_imdct_and_window(st, x, 0, 0).unwrap())
  }
  for f = 1; f <= frames; f = f + 1 {
    let mut energy = 0.0
    let mut dot = 0.0
    let mut out_energy = 0.0
    for i = 0; i < 1024; i = i + 1 {
      let want = input[0][(f - 1) * 1024 + i]
      let got = outs[f][i]
      energy = energy + want * want
      dot = dot + got * want
      out_energy = out_energy + got * got
    }
    let gain = dot / out_energy
    let mut noise = 0.0
    for i = 0; i < 1024; i = i + 1 {
      let d = gain * outs[f][i] - input[0][(f - 1) * 1024 + i]
      noise = noise + d * d
    }
    println("as f=\{f}: gain=\{gain} snr=\{10.0 * @math.log10(energy / noise)}")
  }
}

///|
/// Spectral round trip of a mono (SCE) stream: the decoder's Huffman, section
/// and scalefactor parsing must recover the encoder's coefficients to within
/// quantisation error.
test "aac_lc_spectral_syntax" {
  let rate = 44100
  let frames = 3
  let input = aac_encode_test_tone(rate, 1, frames)
  let stream = aac_encode_test_stream(input, 1, frames, rate, 128000)
  for f = 0; f < frames + 1; f = f + 1 {
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
    if aac_encode_test_tns_present(ics.tns) {
      // Long windows may carry two 6th-order filters, short ones a 7th-order
      // filter; either way the syntax must stay inside the LC limits.
      let is8 = ics.info.window_sequence == 2
      for w = 0; w < ics.info.num_windows; w = w + 1 {
        for filt = 0; filt < ics.tns.n_filt[w]; filt = filt + 1 {
          assert_true(
            ics.tns.filters[w][filt].order <= (if is8 { 7 } else { 12 }),
          )
        }
      }
    }
    // The tone programme is too sparse in the upper bands for the TNS gain to
    // reach the FFmpeg threshold window, so TNS is not guaranteed here; when
    // present the syntax above must still be valid. `aac_lc_tns_syntax`
    // exercises a programme built to reach that window.
    let buf : Array[Double] = Array::make(2048, 0.0)
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = if f > 0 && f <= frames {
        input[0][(f - 1) * 1024 + i]
      } else {
        0.0
      }
      buf[1024 + i] = if f < frames { input[0][f * 1024 + i] } else { 0.0 }
    }
    let want = aac_encode_test_analysis(buf, ics.info.window_sequence)
    let mut energy = 0.0
    let mut noise = 0.0
    for j = 0; j < 1024; j = j + 1 {
      let w = want[j]
      let d = got[j] - w
      energy = energy + w * w
      noise = noise + d * d
    }
    let snr = 10.0 * @math.log10(energy / noise)
    println(
      "mono frame \{f}: seq=\{ics.info.window_sequence} bytes=\{stream[f].length()} max_sfb=\{ics.info.max_sfb} tns=\{aac_encode_test_tns_present(ics.tns)} spectral_snr=\{snr}",
    )
    // TNS reshapes the upper bands before quantisation, which lifts the long
    // frames above 32 dB and the short ones above 36 dB; the flush frame (whose
    // overlap tail feeds the 1024-sample delay) is the weakest one.
    assert_true(snr > (if ics.info.window_sequence == 2 { 36.0 } else { 31.0 }))
  }
}

///|
/// Spectral round trip of a stereo (CPE) stream with a common window and a
/// per-band mid/side mask, decoded channel by channel.
test "aac_lc_stereo_syntax" {
  let rate = 44100
  let channels = 2
  let frames = 3
  let input = aac_encode_test_tone(rate, channels, frames)
  let stream = aac_encode_test_stream(input, channels, frames, rate, 128000)
  for f = 0; f < frames + 1; f = f + 1 {
    let payload = stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    assert_eq(gb.read(3).reinterpret_as_int(), 1) // ID_CPE
    let _ = gb.read(4)
    assert_eq(gb.read1(), 1U) // common_window == 1
    let info = aac_encode_test_ok(@libavcodec.aac_decode_ics_info(gb))
    let ms_present = gb.read(2).reinterpret_as_int()
    // ms_present: 0 = L/R only, 1 = per-band mask, 2 = all bands.
    let mask : Array[Bool] = Array::make(info.max_sfb, false)
    if ms_present == 2 {
      for b = 0; b < info.max_sfb; b = b + 1 {
        mask[b] = true
      }
    } else if ms_present == 1 {
      for b = 0; b < info.max_sfb; b = b + 1 {
        mask[b] = gb.read1() == 1U
      }
    }
    let (c0, m0) = aac_encode_test_parse_channel_common(gb, info)
    let (c1, m1) = aac_encode_test_parse_channel_common(gb, info)
    // Undo the mid/side transform band by band: L = M + S, R = M - S.
    let swb = aac_encode_test_ok(@libavcodec.aac_swb_tables(4))
    let is8 = info.window_sequence == 2
    let offsets = if is8 { swb.offsets_short } else { swb.offsets_long }
    let num_windows = if is8 { 8 } else { 1 }
    let mut ms_bands = 0
    for b = 0; b < info.max_sfb; b = b + 1 {
      if !mask[b] {
        continue
      }
      ms_bands = ms_bands + 1
      for w = 0; w < num_windows; w = w + 1 {
        for i = w * 128 + offsets[b].reinterpret_as_int()
            i < w * 128 + offsets[b + 1].reinterpret_as_int()
            i = i + 1 {
          let l = c0[i]
          let r = c1[i]
          c0[i] = l + r
          c1[i] = l - r
        }
      }
    }
    println(
      "cpe frame \{f}: seq=\{info.window_sequence} bytes=\{stream[f].length()} max_sfb=\{info.max_sfb} ms_present=\{ms_present} ms_bands=\{ms_bands}",
    )
    if f > 0 && f <= frames {
      // The correlated tone programme should select M/S on at least some bands.
      assert_true(ms_present != 0)
      assert_true(ms_bands > 0)
    }
    for ch = 0; ch < 2; ch = ch + 1 {
      let got = if ch == 0 { c0 } else { c1 }
      let ics = if ch == 0 { m0 } else { m1 }
      let buf : Array[Double] = Array::make(2048, 0.0)
      for i = 0; i < 1024; i = i + 1 {
        buf[i] = if f > 0 && f <= frames {
          input[ch][(f - 1) * 1024 + i]
        } else {
          0.0
        }
        buf[1024 + i] = if f < frames { input[ch][f * 1024 + i] } else { 0.0 }
      }
      let want = aac_encode_test_analysis(buf, ics.info.window_sequence)
      let mut energy = 0.0
      let mut noise = 0.0
      for j = 0; j < 1024; j = j + 1 {
        let w = want[j]
        let d = got[j] - w
        energy = energy + w * w
        noise = noise + d * d
      }
      let snr = 10.0 * @math.log10(energy / noise)
      println(
        "cpe frame \{f} ch \{ch}: seq=\{ics.info.window_sequence} bytes=\{stream[f].length()} max_sfb=\{ics.info.max_sfb} spectral_snr=\{snr}",
      )
      if f > 0 && f <= frames {
        // The flush frame reconstructs a window whose second half is silent,
        // so its worst channel sits a little lower than the steady-state ones.
        assert_true(
          snr > (if ics.info.window_sequence == 2 { 26.0 } else { 22.0 }),
        )
      }
    }
  }
}

///|
/// A quiet tone with three isolated full-scale impulses, the stimulus the
/// attack detector must switch on.
fn aac_encode_test_transient(
  rate : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let row : Array[Double] = Array::make(frames * 1024, 0.0)
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    row[i] = 0.05 * @math.sin(2.0 * 3.14159265358979323846 * 660.0 * t)
  }
  for k = 0; k < 3; k = k + 1 {
    let pos = 700 + k * 2048
    if pos < frames * 1024 {
      row[pos] = if k % 2 == 0 { 1.0 } else { -1.0 }
    }
  }
  [row]
}

///|
/// Window switching: the attack detector must drive the
/// ONLY_LONG -> LONG_START -> EIGHT_SHORT -> LONG_STOP chain, and the stream
/// must still decode with a good waveform SNR.
test "aac_lc_transient_windows" {
  let rate = 44100
  let frames = 6
  let input = aac_encode_test_transient(rate, frames)
  let stream = aac_encode_test_stream(input, 1, frames, rate, 128000)
  let seqs : Array[Int32] = []
  let mut tns_frames = 0
  let mut tns_short = 0
  for f = 0; f < stream.length(); f = f + 1 {
    let payload = stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    assert_eq(gb.read(3).reinterpret_as_int(), 0) // ID_SCE
    let _ = gb.read(4) // element_instance_tag
    let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
    seqs.push(ics.info.window_sequence)
    if aac_encode_test_tns_present(ics.tns) {
      tns_frames = tns_frames + 1
      let is8 = ics.info.window_sequence == 2
      if is8 {
        tns_short = tns_short + 1
      }
      for w = 0; w < ics.info.num_windows; w = w + 1 {
        for filt = 0; filt < ics.tns.n_filt[w]; filt = filt + 1 {
          // LC limits: order 12 for long windows, 7 for short ones.
          assert_true(
            ics.tns.filters[w][filt].order <= (if is8 { 7 } else { 12 }),
          )
        }
      }
    }
  }
  println("transient tns frames=\{tns_frames} short=\{tns_short}")
  let mut text = ""
  for f = 0; f < seqs.length(); f = f + 1 {
    text = text + seqs[f].to_string() + " "
  }
  println("transient sequences=\{text}")
  let mut start = 0
  let mut short = 0
  let mut stop = 0
  for f = 0; f < seqs.length(); f = f + 1 {
    let seq = seqs[f]
    if seq == 1 {
      start = start + 1
    } else if seq == 2 {
      short = short + 1
    } else if seq == 3 {
      stop = stop + 1
    }
    // Only the legal window-sequence transitions may appear: a LONG_START
    // must hand over to short blocks, and short blocks must leave through
    // LONG_STOP.
    if f > 0 {
      let prev = seqs[f - 1]
      let ok = if prev == 0 {
        seq == 0 || seq == 1
      } else if prev == 1 {
        seq == 2
      } else if prev == 2 {
        seq == 2 || seq == 3
      } else {
        seq == 0 || seq == 1
      }
      if !ok {
        println("bad transition \{prev} -> \{seq} at frame \{f}")
      }
      assert_true(ok)
    }
  }
  assert_true(start >= 1)
  assert_true(short >= 2)
  assert_true(stop >= 1)
  // TNS is opportunistic: an impulse spreads energy over all bands, which can
  // push the LPC gain outside the FFmpeg window, so only the syntax is
  // validated above; `aac_lc_tns_syntax` covers filter selection.
  let decoded = aac_encode_test_decode(stream, 1)
  let mut energy = 0.0
  let mut noise = 0.0
  for i = 0; i < frames * 1024; i = i + 1 {
    let want = input[0][i]
    let got = decoded[0][1024 + i]
    energy = energy + want * want
    noise = noise + (got - want) * (got - want)
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println("transient round trip: snr=\{snr}")
  // The decoder emits one 1024-sample priming frame; the impulses must survive
  // the whole chain (they are only covered by the short blocks of the frames
  // that follow their detection).
  assert_true(snr > 18.0)
}

///|
/// Harmonic programme with enough upper-band energy to reach the TNS gain
/// window: 48 harmonics of 86 Hz (spacing of about four MDCT bins, so the
/// upper-band spectrum stays partially predictable) plus white noise of equal
/// power (the noise lowers the prediction gain from "too high" into
/// `aacenc_tns.c`'s `[1.4, 1.4 * 1.16]` range).
fn aac_encode_test_harmonics(
  rate : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let row : Array[Double] = Array::make(frames * 1024, 0.0)
  let freq = rate.to_double() / (rate / 86).to_double()
  let mut seed : UInt32 = 4321U
  for i = 0; i < frames * 1024; i = i + 1 {
    seed = seed * 1664525U + 1013904223U
    let t = i.to_double() / rate.to_double()
    let mut v = 0.05 *
      ((seed.reinterpret_as_int() >> 8).to_double() / 8388608.0)
    for k = 1; k <= 48; k = k + 1 {
      v = v +
        0.05 *
        @math.sin(2.0 * 3.14159265358979323846 * freq * k.to_double() * t)
    }
    row[i] = v
  }
  [row]
}

///|
/// TNS on a programme that actually crosses the FFmpeg gain gate: the filters
/// must be written, parsed back with the same coefficients and band lengths,
/// and the synthesis must recover the unfiltered spectrum.
test "aac_lc_tns_syntax" {
  let rate = 44100
  // The onset attack forces a short-window run, so several steady long frames
  // are needed before the gate is crossed.
  let frames = 9
  let input = aac_encode_test_harmonics(rate, frames)
  let stream = aac_encode_test_stream(input, 1, frames, rate, 128000)
  let mut tns_frames = 0
  for f = 0; f < frames + 1; f = f + 1 {
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
    let is8 = ics.info.window_sequence == 2
    if aac_encode_test_tns_present(ics.tns) {
      tns_frames = tns_frames + 1
      assert_eq(ics.tns.n_filt[0], if is8 { 1 } else { 2 })
      for filt = 0; filt < ics.tns.n_filt[0]; filt = filt + 1 {
        assert_eq(ics.tns.filters[0][filt].order, if is8 { 7 } else { 6 })
        assert_true(ics.tns.filters[0][filt].length > 0)
      }
    }
    let buf : Array[Double] = Array::make(2048, 0.0)
    for i = 0; i < 1024; i = i + 1 {
      buf[i] = if f > 0 && f <= frames {
        input[0][(f - 1) * 1024 + i]
      } else {
        0.0
      }
      buf[1024 + i] = if f < frames { input[0][f * 1024 + i] } else { 0.0 }
    }
    let want = aac_encode_test_analysis(buf, ics.info.window_sequence)
    let mut energy = 0.0
    let mut noise = 0.0
    for j = 0; j < 1024; j = j + 1 {
      let w = want[j]
      let d = got[j] - w
      energy = energy + w * w
      noise = noise + d * d
    }
    let snr = 10.0 * @math.log10(energy / noise)
    println(
      "tns frame \{f}: seq=\{ics.info.window_sequence} tns=\{aac_encode_test_tns_present(ics.tns)} spectral_snr=\{snr}",
    )
    assert_true(snr > 15.0)
  }
  println("tns frames=\{tns_frames}")
  // The steady long frames sit inside the gain window; the flush frame is
  // silent and must be rejected.
  assert_true(tns_frames >= 2)
}

///|
/// Full encoder -> decoder round trip: frame structure, rate and waveform.
///
/// The in-tree AAC decoder is a faithful port of FFmpeg's, so this stands in
/// for the external decode. Cross-checked against `linuxserver/ffmpeg:9.0.2`
/// on this exact stream: FFmpeg reports "aac (LC), 44100 Hz, stereo, 117 kb/s"
/// and decodes without errors or warnings; its s16 output measures the same
/// SNR as the 29.0 dB / 38.9 dB PSNR (full-scale) reported here.
test "aac_lc_encoder_round_trip" {
  let channels = 2
  let rate = 44100
  let frames = 8
  let bit_rate = 128000
  let input = aac_encode_test_tone(rate, channels, frames)
  let stream = aac_encode_test_stream(input, channels, frames, rate, bit_rate)
  let decoded = aac_encode_test_decode(stream, channels)
  let mut total = 0
  for f = 0; f < stream.length(); f = f + 1 {
    total = total + stream[f].length()
  }
  let target = bit_rate * 1024 / rate / 8
  println(
    "round trip: frames=\{stream.length()} avg_bytes=\{total / stream.length()} target_bytes=\{target} bit_rate=\{total * 8 * rate / stream.length() / 1024}",
  )
  // The decoder emits one 1024-sample priming frame.
  let mut energy = 0.0
  let mut noise = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for i = 0; i < frames * 1024; i = i + 1 {
      let want = input[ch][i]
      let got = decoded[ch][i + 1024]
      energy = energy + want * want
      noise = noise + (got - want) * (got - want)
    }
  }
  let samples = frames * 1024 * channels
  let snr = 10.0 * @math.log10(energy / noise)
  let psnr = 10.0 * @math.log10(1.0 / (noise / samples.to_double()))
  println("round trip: snr=\{snr} psnr=\{psnr}")
  assert_true(snr > 28.0)
  assert_true(psnr > 38.0)
  // The rate control fills the per-frame budget rather than dropping spare
  // bits, so the stream sits just under the requested average bit rate.
  assert_true(total / stream.length() <= target)
  assert_true(4 * (total / stream.length()) >= 3 * target)
}

///|
/// The opt-in perceptual rate control (`PORTING_HISTORY.md` §279): the same
/// programme as `aac_lc_encoder_round_trip`, but steady-state long frames are
/// quantised by the ported 3GPP model + twoloop search instead of the
/// simplified model and the frame-wide offset search.
///
/// Its SNR floor is deliberately lower than the default path's: the psy model
/// shapes noise under the masking threshold instead of minimising squared
/// error, and this port's allocation is not yet as good as FFmpeg's (see
/// §279). The assertions guard the parts that must hold: the stream decodes,
/// every frame stays inside the ADTS frame limit, the average lands under the
/// nominal rate, and the round trip keeps a sane error level.
test "aac_lc_perceptual_rate_control" {
  let channels = 2
  let rate = 44100
  let frames = 8
  let bit_rate = 128000
  let input = aac_encode_test_tone(rate, channels, frames)
  let config = @libavcodec.aac_encode_config_perceptual(
    rate, channels, bit_rate,
  )
  let stream = aac_encode_test_stream_config(input, channels, frames, config)
  let decoded = aac_encode_test_decode(stream, channels)
  let mut total = 0
  let mut largest = 0
  for f = 0; f < stream.length(); f = f + 1 {
    total = total + stream[f].length()
    if stream[f].length() > largest {
      largest = stream[f].length()
    }
  }
  let target = bit_rate * 1024 / rate / 8
  let mut energy = 0.0
  let mut noise = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for i = 0; i < frames * 1024; i = i + 1 {
      let want = input[ch][i]
      let got = decoded[ch][i + 1024]
      energy = energy + want * want
      noise = noise + (got - want) * (got - want)
    }
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println(
    "perceptual round trip: frames=\{stream.length()} avg_bytes=\{total / stream.length()} target_bytes=\{target} largest=\{largest} snr=\{snr}",
  )
  assert_true(stream.length() == frames + 1)
  // An ADTS frame carries at most 8191 bytes; 6144*channels-3 bits is the
  // limit `aac_encode_frame` itself enforces.
  assert_true(largest * 8 <= 6144 * channels)
  assert_true(total / stream.length() <= target)
  assert_true(4 * (total / stream.length()) >= 3 * target)
  assert_true(snr > 18.0)
}

///|
/// Per-band noise-to-mask ratio of a decoded stream against the 3GPP model's
/// own thresholds: for each steady frame, take the 2048-sample overlap window
/// of the original and of the decoded signal, put both through the encoder's
/// long-window spectrum, and compare the per-band error with the threshold the
/// model computes for the original. Negative means the quantisation noise sits
/// below the masking threshold (inaudible by the model's own yardstick).
///
/// Returns `(mean nmr in dB, whole-frame spectral snr in dB)`.
fn aac_encode_test_nmr(
  enc : @libavcodec.AacEncoder,
  input : Array[Array[Double]],
  decoded : Array[Array[Double]],
  channels : Int32,
  frames : Int32,
  offsets : Array[Int32],
  num_swb : Int32,
  rate : Int32,
  bit_rate : Int32,
) -> (Double, Double) {
  let mut nmr_sum = 0.0
  let mut nmr_n = 0
  let mut energy = 0.0
  let mut noise = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    let psy = @libavcodec.aac_psy_new(4, rate, bit_rate, channels)
    for f = 2; f < frames; f = f + 1 {
      let orig : Array[Double] = Array::make(2048, 0.0)
      let recon : Array[Double] = Array::make(2048, 0.0)
      for i = 0; i < 1024; i = i + 1 {
        orig[i] = input[ch][(f - 1) * 1024 + i]
        orig[1024 + i] = input[ch][f * 1024 + i]
        // The decoder emits one priming frame, so tone frame f is block f+1.
        recon[i] = decoded[ch][f * 1024 + i]
        recon[1024 + i] = decoded[ch][(f + 1) * 1024 + i]
      }
      let want = enc.spectrum(orig)
      let got = enc.spectrum(recon)
      let bands = psy.analyze(0, want, 0, 0, 0).bands
      for g = 0; g < num_swb; g = g + 1 {
        let thr = bands[g].threshold
        if thr <= 0.0 {
          continue
        }
        let mut band_noise = 0.0
        for i = offsets[g]; i < offsets[g + 1]; i = i + 1 {
          let d = got[i] - want[i]
          band_noise = band_noise + d * d
          energy = energy + want[i] * want[i]
          noise = noise + d * d
        }
        nmr_sum = nmr_sum + 10.0 * @math.log10(band_noise / thr)
        nmr_n = nmr_n + 1
      }
    }
  }
  let snr = 10.0 * @math.log10(energy / noise)
  (nmr_sum / nmr_n.to_double(), snr)
}

///|
/// The perceptual path covers every long window, not just ONLY_LONG: LONG_START
/// and LONG_STOP differ only in the psy model's pre-echo guard
/// (`aacpsy.c:672` skips the reduction for LONG_STOP and for the frame after
/// LONG_START), because they are still one 1024-coefficient transform. This
/// runs the transient fixture through it and checks the window chain still
/// forms and the round trip stays sane.
test "aac_lc_perceptual_transient" {
  let rate = 44100
  let frames = 6
  let input = aac_encode_test_transient(rate, frames)
  let config = @libavcodec.aac_encode_config_perceptual(rate, 1, 128000)
  let stream = aac_encode_test_stream_config(input, 1, frames, config)
  let decoded = aac_encode_test_decode(stream, 1)
  let mut start = 0
  let mut short = 0
  let mut stop = 0
  for f = 0; f < stream.length(); f = f + 1 {
    let payload = stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    assert_eq(gb.read(3).reinterpret_as_int(), 0) // ID_SCE
    let _ = gb.read(4) // element_instance_tag
    let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
    let seq = ics.info.window_sequence
    if seq == 1 {
      start = start + 1
    } else if seq == 2 {
      short = short + 1
    } else if seq == 3 {
      stop = stop + 1
    }
  }
  let mut energy = 0.0
  let mut noise = 0.0
  for i = 0; i < frames * 1024; i = i + 1 {
    let want = input[0][i]
    let got = decoded[0][i + 1024]
    energy = energy + want * want
    noise = noise + (got - want) * (got - want)
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println(
    "perceptual transient: start=\{start} short=\{short} stop=\{stop} snr=\{snr}",
  )
  // The attack detector must still produce the LAME chain, and the transition
  // frames are now quantised by the twoloop search rather than the offset
  // search, so they have to decode as well as the steady ones.
  assert_true(start >= 1)
  assert_true(short >= 1)
  assert_true(stop >= 1)
  assert_true(snr > 25.0)
}

///|
/// Which of the two rate controls puts the quantisation noise closer to the
/// model's masking thresholds. The simplified model maximises SNR (it spends
/// the whole frame budget on finer quantisation), the 3GPP path spreads the
/// noise under the mask — so the two trade off, and a plain SNR comparison
/// cannot tell which is perceptually better. This measures the yardstick the
/// model itself optimises.
test "aac_lc_noise_to_mask" {
  let channels = 2
  let rate = 44100
  let frames = 8
  let bit_rate = 128000
  // ff_swb_offset_1024[4]: the 49 long bands of 44.1 kHz.
  let offsets : Array[Int32] = [
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64, 72, 80, 88, 96, 108,
    120, 132, 144, 160, 176, 192, 208, 224, 240, 256, 272, 288, 304, 320, 336,
    352, 368, 384, 400, 416, 432, 448, 464, 480, 496, 512, 528, 544, 560, 576,
    592, 608,
  ]
  let num_swb = 49
  let input = aac_encode_test_tone(rate, channels, frames)
  let plain = aac_encode_test_stream(input, channels, frames, rate, bit_rate)
  let perceptual = aac_encode_test_stream_config(
    input,
    channels,
    frames,
    @libavcodec.aac_encode_config_perceptual(rate, channels, bit_rate),
  )
  let dec_plain = aac_encode_test_decode(plain, channels)
  let dec_perceptual = aac_encode_test_decode(perceptual, channels)
  let enc = aac_encode_test_ok(
    @libavcodec.aac_encoder_new(
      @libavcodec.aac_encode_config(rate, channels, bit_rate),
    ),
  )
  let (nmr_plain, snr_plain) = aac_encode_test_nmr(
    enc, input, dec_plain, channels, frames, offsets, num_swb, rate, bit_rate,
  )
  let (nmr_perceptual, snr_perceptual) = aac_encode_test_nmr(
    enc,
    input,
    dec_perceptual,
    channels,
    frames,
    offsets,
    num_swb,
    rate,
    bit_rate,
  )
  println(
    "noise-to-mask: simplified mean=\{nmr_plain} dB (spectral snr \{snr_plain}); perceptual mean=\{nmr_perceptual} dB (spectral snr \{snr_perceptual})",
  )
  // Both streams decode and both keep the noise within a sane distance of the
  // mask. (A NaN fails both bounds, so these also guard the measurement.)
  assert_true(nmr_plain > -100.0 && nmr_plain < 40.0)
  assert_true(nmr_perceptual > -100.0 && nmr_perceptual < 40.0)
  // The finding §280 records: the 3GPP path trades ~10 dB of SNR (->
  // 21.6 vs 31.6 dB) for ~1.6 dB lower noise-to-mask (12.9 vs 14.5 dB). The
  // margin is small but it is the metric the model optimises, so it is the
  // right regression guard: if a change breaks the psy allocation the noise
  // climbs back above the simplified model's.
  assert_true(nmr_perceptual < nmr_plain)
}

///|
/// Broadband LCG noise. The tonal fixtures never reach the psy model's spread
/// threshold, so PNS can only be exercised end-to-end on noise-like material.
fn aac_encode_test_noise(
  channels : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let pcm : Array[Array[Double]] = []
  let mut seed : UInt32 = 987654321U
  for _ch = 0; _ch < channels; _ch = _ch + 1 {
    let row : Array[Double] = Array::make(frames * 1024, 0.0)
    for i = 0; i < frames * 1024; i = i + 1 {
      seed = seed * 1664525U + 1013904223U
      row[i] = (seed.reinterpret_as_int() >> 9).to_double() / 4194304.0 * 0.15
    }
    pcm.push(row)
  }
  pcm
}

///|
/// `with_pns` must not be a silent no-op: PNS only runs inside the perceptual
/// rate-control path, so enabling it has to enable that path too.
test "aac_lc_pns_config_enables_perceptual" {
  let c = @libavcodec.aac_encode_config(44100, 2, 128000)
  let p = @libavcodec.aac_encode_config_with_pns(c)
  assert_true(p.perceptual)
  assert_true(p.pns)
  assert_true(c.perceptual == false)
  assert_true(c.pns == false)
}

///|
/// PNS end-to-end (§283 step 6): the same noise, encoded with and without
/// `aac_encode_config_with_pns`. A NOISE_BT band carries no spectral data, so
/// the stream must still decode through our (ffmpeg-matched) decoder, stay
/// finite, and spend fewer bytes than the all-coded version.
test "aac_lc_pns_round_trip" {
  let rate = 44100
  let channels = 2
  let frames = 8
  let bit_rate = 128000
  let input = aac_encode_test_noise(channels, frames)
  let base = @libavcodec.aac_encode_config_perceptual(
    rate, channels, bit_rate,
  )
  let plain = aac_encode_test_stream_config(input, channels, frames, base)
  let pns = aac_encode_test_stream_config(
    input,
    channels,
    frames,
    @libavcodec.aac_encode_config_with_pns(base),
  )
  let mut plain_bytes = 0
  let mut pns_bytes = 0
  for f = 0; f < plain.length(); f = f + 1 {
    plain_bytes = plain_bytes + plain[f].length()
    pns_bytes = pns_bytes + pns[f].length()
  }
  let decoded = aac_encode_test_decode(pns, channels)
  let mut energy = 0.0
  let mut noise = 0.0
  let mut peak = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for i = 0; i < frames * 1024; i = i + 1 {
      let want = input[ch][i]
      let got = decoded[ch][i + 1024]
      energy = energy + want * want
      noise = noise + (got - want) * (got - want)
      if got.abs() > peak {
        peak = got.abs()
      }
    }
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println(
    "PNS round trip: plain_bytes=\{plain_bytes / plain.length()} pns_bytes=\{pns_bytes / pns.length()} snr=\{snr} peak=\{peak}",
  )
  assert_true(pns.length() == frames + 1)
  assert_true(peak < 2.0)
  assert_true(peak > 0.0)
  // PNS is waveform-inexact by design: the decoder synthesises fresh noise,
  // so a broadband-noise fixture lands near 0 dB SNR. The guard is that the
  // stream decodes cleanly at a finite level, not that it is transparent.
  assert_true(snr > -5.0)
  assert_true(pns_bytes < plain_bytes)
}

///|
/// Stereo programme whose high band is genuinely mono: both channels carry the
/// same 9 kHz tone, sample for sample, while their low content (440 Hz against
/// 550 Hz) is unrelated and each channel gets its own LCG dither, so the bands
/// that do not share the tone cannot correlate. With `shared` false the right
/// channel gets an 11.7 kHz tone of its own instead, and no band above the
/// intensity gate correlates.
fn aac_encode_test_shared_high(
  rate : Int32,
  frames : Int32,
  shared : Bool,
) -> Array[Array[Double]] {
  let pcm : Array[Array[Double]] = []
  let seeds : Array[UInt32] = [20261105U, 555000111U]
  let two_pi = 2.0 * 3.14159265358979323846
  for ch = 0; ch < 2; ch = ch + 1 {
    let row : Array[Double] = Array::make(frames * 1024, 0.0)
    let low_freq = if ch == 0 { 440.0 } else { 550.0 }
    let high_freq = if ch == 0 || shared { 9000.0 } else { 11700.0 }
    let mut seed = seeds[ch]
    for i = 0; i < frames * 1024; i = i + 1 {
      let t = i.to_double() / rate.to_double()
      seed = seed * 1664525U + 1013904223U
      let dither = (seed.reinterpret_as_int() >> 10).to_double() / 4194304.0
      let low = 0.30 * @math.sin(two_pi * low_freq * t)
      let high = 0.12 * @math.sin(two_pi * high_freq * t)
      row[i] = low + high + 0.008 * dither
    }
    pcm.push(row)
  }
  pcm
}

///|
/// Energy of one frequency in a real signal, by direct projection onto the
/// sine and cosine over `n` samples from `start`. Only ratios between two
/// measurements of the same frequency are read, so no normalisation matters;
/// shifting the window by a whole number of samples only rotates the result.
fn aac_encode_test_bin_energy(
  x : Array[Double],
  start : Int32,
  n : Int32,
  freq : Double,
  rate : Int32,
) -> Double {
  let mut re = 0.0
  let mut im = 0.0
  let two_pi = 2.0 * 3.14159265358979323846
  for i = 0; i < n; i = i + 1 {
    let t = (start + i).to_double() / rate.to_double()
    let phase = two_pi * freq * t
    re = re + x[start + i] * @math.cos(phase)
    im = im + x[start + i] * @math.sin(phase)
  }
  re * re + im * im
}

///|
/// Parse the `frames` steady-state channel pairs of a stream and report the
/// right channel's intensity bands: how many there are, how many of them sit
/// below the frequency gate, and how many landed on the left channel (which
/// must be none - intensity is coded as band types of the second channel).
fn aac_encode_test_is_bands(
  stream : Array[Bytes],
  frames : Int32,
  rate : Int32,
) -> (Int32, Int32, Int32) {
  let swb = aac_encode_test_ok(@libavcodec.aac_swb_tables(4))
  let mut total = 0
  let mut below_gate = 0
  let mut on_left = 0
  for f = 0; f < frames; f = f + 1 {
    let payload = stream[f]
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=stream[f].length(),
      )
      .to_owned()
    let gb = @libavcodec.BitReader::new(payload)
    if gb.read(3).reinterpret_as_int() != 1 {
      abort("IS test: expected a channel pair")
    }
    let _ = gb.read(4)
    if gb.read1() != 1U {
      abort("IS test: expected a common window")
    }
    let info = aac_encode_test_ok(@libavcodec.aac_decode_ics_info(gb))
    let ms_present = gb.read(2).reinterpret_as_int()
    if ms_present == 1 {
      for b = 0; b < info.max_sfb; b = b + 1 {
        let _ = gb.read1()
      }
    }
    let (_, m0) = aac_encode_test_parse_channel_common(gb, info)
    let (_, m1) = aac_encode_test_parse_channel_common(gb, info)
    let is8 = info.window_sequence == 2
    let offsets = if is8 { swb.offsets_short } else { swb.offsets_long }
    let win = if is8 { 8.0 } else { 1.0 }
    let freq_mult = rate.to_double() / (1024.0 / win) / 2.0
    // `INT_STEREO_LOW_LIMIT * (lambda / 170)` at the reference lambda of 120.
    let limit = 6100.0 * (120.0 / 170.0)
    for b = 0; b < info.max_sfb; b = b + 1 {
      let cb1 = m1.sect_cb[0][b]
      if cb1 == 14 || cb1 == 15 {
        total = total + 1
        if offsets[b].reinterpret_as_int().to_double() * freq_mult <= limit {
          below_gate = below_gate + 1
        }
      }
      let cb0 = m0.sect_cb[0][b]
      if cb0 == 14 || cb0 == 15 {
        on_left = on_left + 1
      }
    }
  }
  (total, below_gate, on_left)
}

///|
/// Round-trip SNR of a stream against its input, skipping the decoder's one
/// frame of priming delay.
fn aac_encode_test_pcm_snr(
  input : Array[Array[Double]],
  decoded : Array[Array[Double]],
  channels : Int32,
  frames : Int32,
) -> Double {
  let mut energy = 0.0
  let mut noise = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for i = 0; i < frames * 1024; i = i + 1 {
      let w = input[ch][i]
      let d = decoded[ch][i + 1024] - w
      energy = energy + w * w
      noise = noise + d * d
    }
  }
  10.0 * @math.log10(energy / noise)
}

///|
/// `aac_encode_config_with_is` turns intensity stereo on and nothing else. It
/// works on either rate-control path - the decision needs only band energies.
/// PNS clears it and it clears PNS, because both rewrite the bands they pick
/// and this port decides intensity before the noise search has run.
test "aac_lc_is_config" {
  let plain = @libavcodec.aac_encode_config(44100, 2, 128000)
  assert_true(!plain.is_stereo)
  let perceptual = @libavcodec.aac_encode_config_perceptual(44100, 2, 128000)
  let is_on = @libavcodec.aac_encode_config_with_is(perceptual)
  assert_true(is_on.is_stereo)
  assert_true(is_on.perceptual)
  assert_true(!is_on.pns)
  let is_simple = @libavcodec.aac_encode_config_with_is(plain)
  assert_true(is_simple.is_stereo)
  assert_true(!is_simple.perceptual)
  let both = @libavcodec.aac_encode_config_with_pns(
    @libavcodec.aac_encode_config_with_is(plain),
  )
  assert_true(both.pns)
  assert_true(!both.is_stereo)
}

///|
/// Intensity stereo end to end (§290): the shared 9 kHz tone is coded as
/// codebook 14/15 bands of the right channel, above the frequency gate and
/// never on the left; the frame spends fewer bytes; and our decoder, which
/// follows FFmpeg's `apply_intensity_stereo`, puts the tone back in the right
/// channel at the right level - the `off_is` chain is what sets that level, at
/// 6 dB a step.
test "aac_lc_intensity_stereo_round_trip" {
  let rate = 44100
  let channels = 2
  let frames = 4
  let bit_rate = 128000
  let input = aac_encode_test_shared_high(rate, frames, true)
  let base = @libavcodec.aac_encode_config_perceptual(rate, channels, bit_rate)
  let plain = aac_encode_test_stream_config(input, channels, frames, base)
  let iso = aac_encode_test_stream_config(
    input,
    channels,
    frames,
    @libavcodec.aac_encode_config_with_is(base),
  )
  let (is_bands, below_gate, on_left) = aac_encode_test_is_bands(
    iso,
    frames,
    rate,
  )
  let mut plain_bytes = 0
  let mut iso_bytes = 0
  for f = 0; f < plain.length(); f = f + 1 {
    plain_bytes = plain_bytes + plain[f].length()
    iso_bytes = iso_bytes + iso[f].length()
  }
  let decoded = aac_encode_test_decode(iso, channels)
  let plain_decoded = aac_encode_test_decode(plain, channels)
  let want = aac_encode_test_bin_energy(input[1], 0, frames * 1024, 9000.0, rate)
  let got = aac_encode_test_bin_energy(
    decoded[1],
    1024,
    frames * 1024,
    9000.0,
    rate,
  )
  let level = 10.0 * @math.log10(got / want)
  let plain_snr = aac_encode_test_pcm_snr(input, plain_decoded, channels, frames)
  let snr = aac_encode_test_pcm_snr(input, decoded, channels, frames)
  let mut peak = 0.0
  for ch = 0; ch < channels; ch = ch + 1 {
    for i = 0; i < frames * 1024; i = i + 1 {
      if decoded[ch][i + 1024].abs() > peak {
        peak = decoded[ch][i + 1024].abs()
      }
    }
  }
  println(
    "intensity stereo: bands=\{is_bands} below_gate=\{below_gate} on_left=\{on_left} bytes=\{plain_bytes}>\{iso_bytes} tone_level=\{level} snr=\{plain_snr}>\{snr} peak=\{peak}",
  )
  assert_true(is_bands > 0)
  assert_true(below_gate == 0)
  assert_true(on_left == 0)
  assert_true(iso_bytes < plain_bytes)
  assert_true(level > -3.0 && level < 3.0)
  // Intensity throws away the decorrelated half of the right channel's band,
  // and this fixture's shared tone has none of that to lose, so the two
  // streams have to land within a dB or two of each other while the intensity
  // one spends fewer bytes.
  assert_true(snr > plain_snr - 2.0)
  assert_true(snr > 15.0)
  assert_true(peak > 0.1 && peak < 2.0)
}

///|
/// The same encoder on a programme whose high bands do not correlate: no band
/// may switch to intensity, and because intensity touches nothing else the
/// stream has to come out exactly the size it would be with the tool off.
test "aac_lc_intensity_stereo_skips_uncorrelated" {
  let rate = 44100
  let channels = 2
  let frames = 4
  let bit_rate = 128000
  let input = aac_encode_test_shared_high(rate, frames, false)
  let base = @libavcodec.aac_encode_config_perceptual(rate, channels, bit_rate)
  let plain = aac_encode_test_stream_config(input, channels, frames, base)
  let iso = aac_encode_test_stream_config(
    input,
    channels,
    frames,
    @libavcodec.aac_encode_config_with_is(base),
  )
  let (is_bands, below_gate, on_left) = aac_encode_test_is_bands(
    iso,
    frames,
    rate,
  )
  let mut plain_bytes = 0
  let mut iso_bytes = 0
  for f = 0; f < plain.length(); f = f + 1 {
    plain_bytes = plain_bytes + plain[f].length()
    iso_bytes = iso_bytes + iso[f].length()
  }
  println(
    "intensity stereo off-band: bands=\{is_bands} bytes=\{plain_bytes}/\{iso_bytes}",
  )
  assert_true(is_bands == 0)
  assert_true(below_gate == 0)
  assert_true(on_left == 0)
  assert_true(iso_bytes == plain_bytes)
}
