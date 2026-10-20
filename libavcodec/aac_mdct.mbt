///|
/// MoonBit port of the AAC IMDCT and windowing half of FFmpeg 9.0.2
/// `libavcodec/aac/aacdec_dsp_template.c` (`imdct_and_windowing`) plus the
/// raw_data_block / SCE element framing of `aacdec.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C runs a split-radix FFT based MDCT; this port uses the direct
/// (textbook) MDCT/IMDCT pair, exact but O(N^2) — fine for tests and small
/// inputs, a target for later optimisation. Window shapes: sine only (KBD
/// tables pending); windowing: ONLY_LONG (EIGHT_SHORT / the 448/512
/// LONG_START / LONG_STOP transition structure pending).

///|
/// Sine half-window of `n` points: `sin(pi/(2n) * (i + 0.5))`. */
fn aac_sine_half_window(n : Int32) -> Array[Double] {
  let w : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    w[i] = @math.sin(
      3.14159265358979323846 / (2 * n).to_double() * (i.to_double() + 0.5),
    )
  }
  w
}

///|
/// Mirrored full window of `2 * n` points from the `n`-point half. */
fn aac_full_window(n : Int32) -> Array[Double] {
  let half = aac_sine_half_window(n)
  let w : Array[Double] = Array::make(2 * n, 0.0)
  for i = 0; i < n; i = i + 1 {
    w[i] = half[i]
    w[n + i] = half[n - 1 - i]
  }
  w
}

///|
/// Direct inverse MDCT (textbook pair, `N = n/2`):
/// `out[t] = sum_j c[j] * cos(pi/N * (t + (N+1)/2) * (2j+1))` — exact TDAC
/// under the mirrored sine window (the C uses an FFT; this is O(N^2)).
pub fn aac_imdct(coef : Array[Double], n : Int32) -> Array[Double] {
  let n_half = n / 2
  let out : Array[Double] = Array::make(n, 0.0)
  let pi = 3.14159265358979323846
  let base = pi / n_half.to_double()
  let phase = (n_half + 1).to_double() / 2.0
  for t = 0; t < n; t = t + 1 {
    let tf = (t.to_double() + phase) * base
    let mut acc = 0.0
    for j = 0; j < n_half; j = j + 1 {
      let c = coef[j]
      if c != 0.0 {
        acc = acc + c * @math.cos(tf * (2 * j + 1).to_double())
      }
    }
    out[t] = acc
  }
  out
}

///| Forward MDCT (for tests): `n/2` coefficients from `n` samples, the

///|
/// matching forward transform of `aac_imdct`.
pub fn aac_mdct_forward(samples : Array[Double], n : Int32) -> Array[Double] {
  let n_half = n / 2
  let out : Array[Double] = Array::make(n_half, 0.0)
  let pi = 3.14159265358979323846
  let base = pi / n_half.to_double()
  let phase = (n_half + 1).to_double() / 2.0
  for j = 0; j < n_half; j = j + 1 {
    let jf = (2 * j + 1).to_double()
    let mut acc = 0.0
    for t = 0; t < n; t = t + 1 {
      acc = acc + samples[t] * @math.cos((t.to_double() + phase) * base * jf)
    }
    out[j] = acc
  }
  out
}

///| Per-channel decoder state: the previous frame's unwindowed IMDCT tail

///|
/// (`sce->saved`) and the previous window sequence / shape.
pub struct AacChannelState {
  saved : Array[Double]
  prev_window_sequence : Int32
  prev_window_shape : Int32
}

///|
/// Fresh state for a 1024/128 frame-length stream. */
pub fn new_aac_channel_state() -> AacChannelState {
  {
    saved: Array::make(1024, 0.0),
    prev_window_sequence: aac_only_long,
    prev_window_shape: 0,
  }
}

///|
/// One channel of `imdct_and_windowing`, ONLY_LONG sequences: textbook TDAC
/// overlap `out[k] = tail[k] * W[N+k] + v[k] * W[k]` with the mirrored
/// 2048-point sine window and the previous frame's unwindowed IMDCT tail.
/// EIGHT_SHORT / LONG_START / LONG_STOP windowing (the 448/512 transition
/// structure of the C) is pending.
pub fn aac_imdct_and_window(
  st : AacChannelState,
  coeffs : Array[Double],
  window_sequence : Int32,
  window_shape : Int32,
) -> Result[Array[Double], String] {
  if window_shape != 0 {
    return Err("KBD windows are not supported yet")
  }
  if window_sequence != aac_only_long ||
    st.prev_window_sequence != aac_only_long {
    return Err("only ONLY_LONG windowing is supported yet")
  }
  let n = 2048
  let half = 1024
  let w = aac_full_window(half)
  let v = aac_imdct(coeffs, n)
  let out : Array[Double] = Array::make(half, 0.0)
  for k = 0; k < half; k = k + 1 {
    out[k] = st.saved[k] * w[half + k] + v[k] * w[k]
  }
  for i = 0; i < half; i = i + 1 {
    st.saved[i] = v[half + i]
  }
  ignore(window_shape)
  Ok(out)
}

///|
/// `raw_data_block` element ids (spec 4.4.1): 0 SCE, 1 CPE, 6 FIL, 7 END. */
let aac_id_sce : Int32 = 0

///|
let aac_id_filler : Int32 = 6

///|
/// `ID_END`. */
let aac_id_end : Int32 = 7

///|
/// One decoded channel of a frame: 1024 double samples. */
pub struct AacPcm {
  /// The 1024 windowed output samples of this frame.
  samples : Array[Double]
}

///|
/// A minimal SCE-only AAC-LC decoder. */
pub struct AacDecoder {
  /// AudioSpecificConfig the stream was opened with.
  config : Mpeg4AudioConfig
  channels : Array[AacChannelState]
}

///|
/// New decoder for `n` SCE channels. */
pub fn new_aac_decoder(config : Mpeg4AudioConfig, n : Int32) -> AacDecoder {
  let ch : Array[AacChannelState] = []
  for i = 0; i < n; i = i + 1 {
    ch.push(new_aac_channel_state())
  }
  { config, channels: ch, }
}

///|
/// Decode one `raw_data_block` (spec 4.4.1) holding one SCE plus optional
/// filler, ending with ID_END. With only codebook-0 sections available the
/// spectral coefficients are all zero; the element framing, ICS/TNS parse
/// and windowing pipeline are exercised end to end.
pub fn AacDecoder::decode_frame(
  self : AacDecoder,
  data : Bytes,
) -> Result[Array[AacPcm], String] {
  let gb = BitReader::new(data)
  let mut elem = gb.read(3).reinterpret_as_int()
  if elem != aac_id_sce {
    return Err("only single channel elements are supported")
  }
  let ics = match aac_decode_ics(gb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // All-zero coefficients (codebook 0 sections only, see aac_ics.mbt).
  let coeffs : Array[Double] = Array::make(1024, 0.0)
  let out = match
    aac_imdct_and_window(
      self.channels[0],
      coeffs,
      ics.info.window_sequence,
      ics.info.window_shape,
    ) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  // Remaining elements up to ID_END.
  elem = gb.read(3).reinterpret_as_int()
  while elem != aac_id_end {
    if elem == aac_id_filler {
      let cnt = gb.read(4).reinterpret_as_int()
      let mut n = cnt
      if cnt == 15 {
        n = cnt + gb.read(8).reinterpret_as_int() - 1
      }
      if n < 1 || gb.bits_left() < 8 * (n - 1) + 3 {
        return Err("filler overruns the frame")
      }
      for _i = 0; _i < n - 1; _i = _i + 1 {
        gb.skip(8)
      }
    } else {
      return Err("unsupported raw_data_block element \{elem}")
    }
    if gb.bits_left() < 3 {
      return Err("missing ID_END")
    }
    elem = gb.read(3).reinterpret_as_int()
  }
  Ok([{ samples: out, }])
}
