/// MPEG audio Layer II encoder (`mpegaudioenc.c`, `mp2fixed` path) tests.
///
/// The encoder produces a complete ADTS-free MPEG-1/2 Layer II stream. The
/// tests cover the header of both MPEG-1 and MPEG-2 LSF frames, the frame size
/// / padding budget, and a decoder round trip through the local Layer II
/// decoder (`decode_mp3_stream`), measuring SNR after the encoder+decoder
/// delay.

///|
/// Abort on an unexpected encoder/decoder error instead of propagating it.
fn[T] mpa_encode_test_ok(r : Result[T, String]) -> T {
  match r {
    Ok(v) => v
    Err(e) => {
      println("MP2 test error: \{e}")
      abort("MP2 test: unexpected error")
    }
  }
}

///|
/// Deterministic programme: a few tones per channel plus a low-level LCG dither.
fn mpa_encode_test_programme(
  rate : Int32,
  channels : Int32,
  frames : Int32,
) -> Array[Array[Double]] {
  let pcm : Array[Array[Double]] = []
  let mut seed : UInt32 = 9876U
  for ch = 0; ch < channels; ch = ch + 1 {
    let row : Array[Double] = Array::make(frames * 1152, 0.0)
    let freqs = if ch == 0 {
      [440.0, 1333.0, 3500.0]
    } else {
      [550.0, 2200.0, 7000.0]
    }
    let amps = if ch == 0 { [0.4, 0.2, 0.1] } else { [0.3, 0.15, 0.08] }
    for i = 0; i < frames * 1152; i = i + 1 {
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
/// Quantise a normalised sample to the int16 range used by the encoder.
fn mpa_encode_test_quant(v : Double) -> Int32 {
  let q = (v * 32767.0).to_int()
  if q > 32767 {
    32767
  } else if q < -32768 {
    -32768
  } else {
    q
  }
}

///|
/// Encode `frames` interleaved frames.
fn mpa_encode_test_stream(
  pcm : Array[Array[Double]],
  channels : Int32,
  frames : Int32,
  rate : Int32,
  bit_rate : Int32,
) -> Array[Bytes] {
  let config : @libavcodec.MpaEncodeConfig = @libavcodec.mpa_encode_config(
    rate, channels, bit_rate,
  )
  let enc = mpa_encode_test_ok(@libavcodec.mpa_encoder_new(config))
  let out : Array[Bytes] = []
  for f = 0; f < frames; f = f + 1 {
    let input : Array[Int32] = []
    for i = 0; i < 1152; i = i + 1 {
      for ch = 0; ch < channels; ch = ch + 1 {
        input.push(mpa_encode_test_quant(pcm[ch][f * 1152 + i]))
      }
    }
    out.push(mpa_encode_test_ok(enc.encode_frame(input)))
  }
  out
}

///|
/// Decode the whole stream with the local MPEG audio decoder and unpack the
/// interleaved s16 output.
fn mpa_encode_test_decode(stream : Array[Bytes]) -> Array[Int32] {
  let all : Array[Byte] = []
  for f = 0; f < stream.length(); f = f + 1 {
    for i = 0; i < stream[f].length(); i = i + 1 {
      all.push(stream[f][i])
    }
  }
  let pcm = mpa_encode_test_ok(
    @libavcodec.decode_mp3_stream(Bytes::from_array(all)),
  )
  let bytes = pcm.pcm_bytes()
  let samples : Array[Int32] = []
  for i = 0; i < bytes.length() / 2; i = i + 1 {
    let v = bytes[2 * i].to_int() + (bytes[2 * i + 1].to_int() << 8)
    samples.push(if v >= 32768 { v - 65536 } else { v })
  }
  samples
}

///|
/// Find the round-trip delay (the encoder's analysis filter and the decoder's
/// synthesis filter each contribute 481 samples) and measure the SNR of
/// channel 0 on the aligned overlap.
fn mpa_encode_test_snr(
  pcm : Array[Array[Double]],
  decoded : Array[Int32],
  frames : Int32,
  channels : Int32,
) -> (Int32, Double) {
  let n = frames * 1152
  let dlen = decoded.length() / channels
  let mut best_lag = 0
  let mut best_err = -1.0
  for lag = 0; lag < 1400; lag = lag + 1 {
    let mut err = 0.0
    for i = 1152; i < 2304; i = i + 1 {
      if lag + i < dlen && i < n {
        let want = mpa_encode_test_quant(pcm[0][i]).to_double()
        let diff = decoded[(lag + i) * channels].to_double() - want
        err = err + diff * diff
      }
    }
    if best_err < 0.0 || err < best_err {
      best_err = err
      best_lag = lag
    }
  }
  let mut sig = 0.0
  let mut noise = 0.0
  for i = 2304; i < n; i = i + 1 {
    let j = best_lag + i
    if j < dlen {
      let want = mpa_encode_test_quant(pcm[0][i]).to_double()
      let diff = decoded[j * channels].to_double() - want
      sig = sig + want * want
      noise = noise + diff * diff
    }
  }
  let snr = if noise > 0.0 { 10.0 * @math.log10(sig / noise) } else { 999.0 }
  (best_lag, snr)
}

///|
/// A 44100 Hz stereo 128 kbps stream is MPEG-1 Layer II: `0xFFFD` header, bit
/// rate index 8, sample-rate index 0, stereo mode. The frame budget is 417
/// bytes (3336 bits) plus a padding byte whenever the fractional accumulator
/// carries.
test "mp2_stereo_header_and_frame_size" {
  let rate = 44100
  let channels = 2
  let frames = 12
  let bit_rate = 128000
  let pcm = mpa_encode_test_programme(rate, channels, frames)
  let stream = mpa_encode_test_stream(pcm, channels, frames, rate, bit_rate)
  let mut total = 0
  for f = 0; f < stream.length(); f = f + 1 {
    let b = stream[f]
    let pad = (b[2].to_int() >> 1) & 1
    assert_eq(b[0].to_int(), 0xFF)
    assert_eq(b[1].to_int(), 0xFD)
    assert_eq(b[2].to_int() >> 4, 8)
    assert_eq((b[2].to_int() >> 2) & 3, 0)
    assert_eq(b[3].to_int(), 0x04)
    assert_eq(b.length(), 417 + pad)
    total = total + b.length()
  }
  // 12 * 1152 samples at 128 kbps and 44100 Hz is 5015.5 bytes; the padding
  // accumulator must land on 5015 (417 + 11 * 418).
  assert_eq(total, 5015)
  let (lag, snr) = mpa_encode_test_snr(
    pcm,
    mpa_encode_test_decode(stream),
    frames,
    channels,
  )
  println("mp2 stereo: lag=\{lag} snr=\{snr}")
  assert_true(lag > 400 && lag < 1200)
  assert_true(snr > 12.0)
}

///|
/// A 22050 Hz mono 64 kbps stream is MPEG-2 LSF: the ID bit is clear (`0xFFF5`
/// header), the bit rate index is 8 in the LSF table and the mode is single
/// channel. Frame size is 417 bytes.
test "mp2_mono_lsf_header_and_round_trip" {
  let rate = 22050
  let channels = 1
  let frames = 6
  let bit_rate = 64000
  let pcm = mpa_encode_test_programme(rate, channels, frames)
  let stream = mpa_encode_test_stream(pcm, channels, frames, rate, bit_rate)
  for f = 0; f < stream.length(); f = f + 1 {
    let b = stream[f]
    assert_eq(b[1].to_int(), 0xF5)
    assert_eq(b[2].to_int() >> 4, 8)
    assert_eq((b[2].to_int() >> 2) & 3, 0)
    assert_eq(b[3].to_int() >> 6, 3)
    assert_true(b.length() == 417 || b.length() == 418)
  }
  let (lag, snr) = mpa_encode_test_snr(
    pcm,
    mpa_encode_test_decode(stream),
    frames,
    channels,
  )
  println("mp2 mono lsf: lag=\{lag} snr=\{snr}")
  assert_true(lag > 400 && lag < 1200)
  assert_true(snr > 12.0)
}
