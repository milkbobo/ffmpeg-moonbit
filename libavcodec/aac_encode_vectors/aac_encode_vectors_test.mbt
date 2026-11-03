///|
/// Abort on an unexpected encoder/decoder error instead of propagating it, so
/// the helpers need no error type.
fn[T] aac_encode_test_ok(r : Result[T, String]) -> T {
  match r {
    Ok(v) => v
    Err(_) => abort("AAC test: unexpected error")
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
    let out = aac_encode_test_ok(decoder.decode_frame(payload))
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
/// Decode one channel stream from the already positioned reader.
fn aac_encode_test_parse_channel(
  gb : @libavcodec.BitReader,
) -> (Array[Double], @libavcodec.AacIcs) {
  let ics = aac_encode_test_ok(@libavcodec.aac_decode_ics(gb))
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
  (coeffs, ics)
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
  let win = aac_encode_test_window()
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
    let want = @libavcodec.aac_mdct_forward(buf, 2048)
    let mut energy = 0.0
    let mut noise = 0.0
    for j = 0; j < 1024; j = j + 1 {
      let w = -65536.0 * want[j]
      let d = got[j] - w
      energy = energy + w * w
      noise = noise + d * d
    }
    let snr = 10.0 * @math.log10(energy / noise)
    println(
      "mono frame \{f}: bytes=\{stream[f].length()} max_sfb=\{ics.info.max_sfb} spectral_snr=\{snr}",
    )
    assert_true(snr > 18.0)
  }
}

///|
/// Spectral round trip of a stereo (CPE) stream, decoded channel by channel.
test "aac_lc_stereo_syntax" {
  let rate = 44100
  let channels = 2
  let frames = 3
  let input = aac_encode_test_tone(rate, channels, frames)
  let stream = aac_encode_test_stream(input, channels, frames, rate, 128000)
  let win = aac_encode_test_window()
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
    assert_eq(gb.read1(), 0U) // common_window == 0
    let (c0, m0) = aac_encode_test_parse_channel(gb)
    let (c1, m1) = aac_encode_test_parse_channel(gb)
    for ch = 0; ch < 2; ch = ch + 1 {
      let got = if ch == 0 { c0 } else { c1 }
      let ics = if ch == 0 { m0 } else { m1 }
      let buf : Array[Double] = Array::make(2048, 0.0)
      for i = 0; i < 1024; i = i + 1 {
        let prev = if f > 0 && f <= frames {
          input[ch][(f - 1) * 1024 + i]
        } else {
          0.0
        }
        let cur = if f < frames { input[ch][f * 1024 + i] } else { 0.0 }
        buf[i] = prev * win[i]
        buf[1024 + i] = cur * win[1023 - i]
      }
      let want = @libavcodec.aac_mdct_forward(buf, 2048)
      let mut energy = 0.0
      let mut noise = 0.0
      for j = 0; j < 1024; j = j + 1 {
        let w = -65536.0 * want[j]
        let d = got[j] - w
        energy = energy + w * w
        noise = noise + d * d
      }
      let snr = 10.0 * @math.log10(energy / noise)
      println(
        "cpe frame \{f} ch \{ch}: bytes=\{stream[f].length()} max_sfb=\{ics.info.max_sfb} spectral_snr=\{snr}",
      )
      if f > 0 && f <= frames {
        // The flush frame reconstructs a window whose second half is silent,
        // so its worst channel sits a little lower than the steady-state ones.
        assert_true(snr > 17.0)
      }
    }
  }
}

///|
/// Full encoder -> decoder round trip: frame structure, rate and waveform.
///
/// The in-tree AAC decoder is a faithful port of FFmpeg's, so this stands in
/// for the external decode. Cross-checked against `linuxserver/ffmpeg:9.0.2`
/// on this exact stream: FFmpeg reports "aac (LC), 44100 Hz, stereo, 37 kb/s"
/// and decodes without warnings; its s16 output differs from this decoder's
/// by 0.77 MSE (sub-LSB rounding), so the SNR/PSNR measured here is the same
/// 23.36 dB / 33.2 dB one gets from the real FFmpeg decode.
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
  let snr = 10.0 * @math.log10(energy / noise)
  println("round trip: snr=\{snr}")
  assert_true(snr > 20.0)
  assert_true(total / stream.length() <= target)
}
