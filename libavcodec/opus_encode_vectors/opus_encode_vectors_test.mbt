/// Opus (native FFmpeg CELT-only) encoder tests.
///
/// The fixtures (`fixtures.mbt`) hold the exact f32le planar PCM fed to the
/// patched FFmpeg 9.0.2 reference harness and the byte-exact packet stream it
/// produced (packets concatenated without their u32 length prefixes). The
/// reference applies the same deterministic-math patch as the port (see
/// `_ref/opus/ref_det.c`): `log2f`/`expf`/`atan2f`/`cos`/`sin` replaced by
/// fixed formulas, the forward MDCT computed as the direct double-precision
/// evaluation of `libavutil/tx_template.c`'s naive reference instead of the
/// FFT-based `av_tx`, and the Bessel filter coefficients dumped from
/// `bessel_init` (they involve `tanf`).
///
/// Deviations from upstream, all verified against the C reference:
///   - direct MDCT instead of `av_tx` (both sides);
///   - deterministic libm replacements (both sides);
///   - Bessel coefficients from the dump instead of `tanf` at init.

///|
fn[T] opus_test_ok(r : Result[T, String]) -> T {
  match r {
    Ok(v) => v
    Err(e) => {
      println("Opus test error: \{e}")
      abort("unexpected error")
    }
  }
}

///|
/// Encode the whole fixture and return (frames, concatenated packets).
fn opus_test_encode(
  planes : Array[Array[Float]],
  channels : Int,
  bit_rate : Int,
) -> (Int, Bytes) {
  let config = @libavcodec.opus_encode_config(channels, bit_rate)
  let enc = opus_test_ok(@libavcodec.opus_encoder_new(config))
  let per_frame = 960
  let frames = planes[0].length() / per_frame
  let parts : Array[Bytes] = []
  for f in 0..<frames {
    let input : Array[Array[Float]] = []
    for ch in 0..<channels {
      let plane : Array[Float] = Array::make(per_frame, 0.0)
      for i in 0..<per_frame {
        plane[i] = planes[ch][f * per_frame + i]
      }
      input.push(plane)
    }
    match opus_test_ok(enc.encode(input)) {
      Some(b) => parts.push(b)
      None => ()
    }
  }
  for b in opus_test_ok(enc.flush()) {
    parts.push(b)
  }
  let all : Array[Byte] = []
  for f in 0..<parts.length() {
    for i in 0..<parts[f].length() {
      all.push(parts[f][i])
    }
  }
  (frames, Bytes::from_array(all))
}

///|
/// Decimal-string PCM fixture -> per-channel Float planes (ch0 then ch1).
fn opus_test_planes(fixture : Array[Array[String]], channels : Int) -> Array[Array[Float]] raise {
  let samples = fixture[0].length()
  let planes : Array[Array[Float]] = []
  for ch in 0..<channels {
    let plane : Array[Float] = Array::make(samples, 0.0)
    for i in 0..<samples {
      plane[i] = Float::from_double(@string.parse_double(fixture[ch][i]))
    }
    planes.push(plane)
  }
  planes
}

///|
/// Hex string -> Bytes.
fn opus_test_hex_bytes(hex : String) -> Bytes {
  let out : Array[Byte] = []
  let n = hex.length() / 2
  for i in 0..<n {
    let hi = opus_test_hexval(hex[2 * i])
    let lo = opus_test_hexval(hex[2 * i + 1])
    out.push(((hi << 4) | lo).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn opus_test_hexval(c : UInt16) -> Int {
  let zero = 48
  let nine = 57
  let la = 97
  let lf = 102
  let ca = 65
  let cf = 70
  let v = c.to_int()
  if v >= zero && v <= nine {
    v - zero
  } else if v >= la && v <= lf {
    v - la + 10
  } else if v >= ca && v <= cf {
    v - ca + 10
  } else {
    0
  }
}

///|
/// Shared assertions for one vector.
fn opus_test_vector(
  name : String,
  pcm : Array[Array[String]],
  expected_hex : String,
  channels : Int,
  bit_rate : Int,
) -> Unit raise {
  let planes = opus_test_planes(pcm, channels)
  let want_raw = opus_test_hex_bytes(expected_hex)
  let (frames, stream) = opus_test_encode(planes, channels, bit_rate)
  inspect(frames > 0, content="true")
  inspect(stream.length(), content="\{want_raw.length()}")
  let mut identical = stream.length() == want_raw.length()
  if identical {
    for i in 0..<stream.length() {
      if stream[i] != want_raw[i] {
        identical = false
        println("\{name}: first diff at byte \{i}")
        break
      }
    }
  }
  inspect(identical, content="true")
}

///|
test "opus_encode_byte_exact_v1" {
  opus_test_vector(
    "v1",
    @opus_encode_vectors.opus_vec1_pcm,
    @opus_encode_vectors.opus_vec1_pkt,
    2,
    96000,
  )
}

///|
test "opus_encode_byte_exact_v2" {
  opus_test_vector(
    "v2",
    @opus_encode_vectors.opus_vec2_pcm,
    @opus_encode_vectors.opus_vec2_pkt,
    1,
    48000,
  )
}

///|
/// Encode the whole fixture and return the individual packets plus the
/// 19-byte OpusHead extradata needed by the local decoder.
fn opus_test_encode_packets(
  planes : Array[Array[Float]],
  channels : Int,
  bit_rate : Int,
) -> (Array[Bytes], Bytes) {
  let config = @libavcodec.opus_encode_config(channels, bit_rate)
  let enc = opus_test_ok(@libavcodec.opus_encoder_new(config))
  let per_frame = 960
  let frames = planes[0].length() / per_frame
  let parts : Array[Bytes] = []
  for f in 0..<frames {
    let input : Array[Array[Float]] = []
    for ch in 0..<channels {
      let plane : Array[Float] = Array::make(per_frame, 0.0)
      for i in 0..<per_frame {
        plane[i] = planes[ch][f * per_frame + i]
      }
      input.push(plane)
    }
    match opus_test_ok(enc.encode(input)) {
      Some(b) => parts.push(b)
      None => ()
    }
  }
  for b in opus_test_ok(enc.flush()) {
    parts.push(b)
  }
  (parts, enc.extradata())
}

///|
/// Best-lag SNR of one decoded channel against the encoder input. The CELT
/// decoder emits its synthesis overlap before the first sample, so the lag is
/// searched rather than assumed.
fn opus_test_delay_snr(
  want : Array[Float],
  got : Array[Float],
  max_lag : Int,
) -> (Int, Double) {
  let mut best_lag = 0
  let mut best_err = 1.0e30
  for lag in -max_lag..<max_lag {
    let mut err = 0.0
    let mut n = 0
    let start = if lag < 0 { -lag } else { 0 }
    let gstart = if lag < 0 { 0 } else { lag }
    while start + n < want.length() && gstart + n < got.length() &&
      n < 60 * 960 {
      let d = got[gstart + n].to_double() - want[start + n].to_double()
      err += d * d
      n += 1
    }
    if n > 0 && err / n.to_double() < best_err {
      best_err = err / n.to_double()
      best_lag = lag
    }
  }
  let start = if best_lag < 0 { -best_lag } else { 0 }
  let gstart = if best_lag < 0 { 0 } else { best_lag }
  let mut sig = 0.0
  let mut noise = 0.0
  let mut n = 0
  while start + n < want.length() && gstart + n < got.length() && n < 60 * 960 {
    let w = want[start + n].to_double()
    let d = got[gstart + n].to_double() - w
    sig += w * w
    noise += d * d
    n += 1
  }
  let snr = 10.0 * @math.log10(sig / (noise + 1.0e-12))
  (best_lag, snr)
}

///|
/// End-to-end round trip: encode the fixture, decode with the port's Opus
/// decoder and require a sane SNR. Opus is lossy, so this checks signal
/// integrity rather than byte equality.
fn opus_test_roundtrip(
  name : String,
  pcm : Array[Array[String]],
  channels : Int,
  bit_rate : Int,
  min_snr : Double,
) -> Unit raise {
  let planes = opus_test_planes(pcm, channels)
  let (packets, extradata) = opus_test_encode_packets(planes, channels, bit_rate)
  let head = opus_test_ok(@libavcodec.opus_parse_head(extradata))
  let decoder = opus_test_ok(@libavcodec.OpusDecoder::new(head))
  let acc : Array[Array[Float]] = [for _ in 0..<channels => []]
  for pkt in packets {
    let (pcm_out, samples) = opus_test_ok(decoder.decode_packet(Some(pkt)))
    for ch in 0..<channels {
      for i in 0..<samples {
        acc[ch].push(pcm_out[ch][i])
      }
    }
  }
  let (tail, tail_samples) = opus_test_ok(decoder.decode_packet(None))
  for ch in 0..<channels {
    for i in 0..<tail_samples {
      acc[ch].push(tail[ch][i])
    }
  }
  let (lag, snr) = opus_test_delay_snr(planes[0], acc[0], 480)
  println("\{name}: decoded \{acc[0].length()} samples, lag \{lag}, SNR \{snr} dB")
  if snr < min_snr {
    fail("\{name}: round-trip SNR \{snr} dB below \{min_snr} dB")
  }
}

///|
test "opus_encode_decode_roundtrip_v1" {
  opus_test_roundtrip(
    "v1",
    @opus_encode_vectors.opus_vec1_pcm,
    2,
    96000,
    14.0,
  )
}

///|
test "opus_encode_decode_roundtrip_v2" {
  opus_test_roundtrip(
    "v2",
    @opus_encode_vectors.opus_vec2_pcm,
    1,
    48000,
    11.5,
  )
}

///|
test "opus_encode_config_validation" {
  match @libavcodec.opus_encoder_new(@libavcodec.opus_encode_config(3, 96000)) {
    Err(_) => inspect("rejected", content="rejected")
    Ok(_) => fail("expected rejection")
  }
  let enc = opus_test_ok(
    @libavcodec.opus_encoder_new(@libavcodec.opus_encode_config(1, 48000)),
  )
  match enc.encode([Array::make(100, 0.0)]) {
    Err(_) => inspect("rejected", content="rejected")
    Ok(_) => fail("expected rejection")
  }
  // extradata: OpusHead, 19 bytes
  inspect(enc.extradata().length(), content="19")
  inspect(
    enc.extradata()[0].to_int() & 0xFF,
    content="79",
  )
}
