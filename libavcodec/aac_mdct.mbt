///|
/// MoonBit port of the AAC IMDCT and windowing half of FFmpeg 9.0.2
/// `libavcodec/aac/aacdec_dsp_template.c` (`imdct_and_windowing`) plus the
/// raw_data_block / SCE/CPE/LFE element framing of `aacdec.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C runs a split-radix FFT based MDCT; this port uses the direct
/// (textbook) MDCT/IMDCT pair, exact but O(N^2) — fine for tests and small
/// inputs, a target for later optimisation. Both sine and KBD windows and
/// all four window sequences are implemented. The synthesis wrapper maps
/// the textbook inverse to FFmpeg's half-inverse sign and float PCM scale.

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
/// `ff_kbd_window_init` (`libavcodec/kbdwin.c`): the Kaiser-Bessel-derived
/// window of `n` points with sharpness `alpha`, through `av_bessel_i0`.
pub fn aac_kbd_window(alpha : Double, n : Int32) -> Array[Double] {
  let half = n / 2
  let temp : Array[Double] = Array::make(half + 1, 0.0)
  let pi = 3.14159265358979323846
  let alpha2 = 4.0 * (alpha * pi / n.to_double()) * (alpha * pi / n.to_double())
  let mut scale = 0.0
  for i = 0; i <= half; i = i + 1 {
    let t = i.to_double() * (n - i).to_double() * alpha2
    temp[i] = @libavutil.av_bessel_i0(t.sqrt())
    let w = if i > 0 && i < half { 2.0 } else { 1.0 }
    scale = scale + temp[i] * w
  }
  scale = 1.0 / (scale + 1.0)
  let win : Array[Double] = Array::make(n, 0.0)
  let mut sum = 0.0
  for i = 0; i <= half; i = i + 1 {
    sum = sum + temp[i]
    win[i] = (sum * scale).sqrt()
  }
  for i = half + 1; i < n; i = i + 1 {
    sum = sum + temp[n - i]
    win[i] = (sum * scale).sqrt()
  }
  win
}

///|
/// The four window tables AAC uses: `sine_1024` / `aac_kbd_long_1024`
/// (alpha 4.0) for long sequences and `sine_128` / `aac_kbd_short_128`
/// (alpha 6.0) for short ones — all `2*hop`-point HALF windows
/// (`ff_sine_window_init`: `w[i] = sin((i+0.5)·pi/(2n))`, `kbdwin.c`:
/// n = 1024 / 128), the length the C passes to `vector_fmul_window`.
let aac_sine_long : Array[Double] = aac_sine_half_window(1024)

///|
let aac_sine_short : Array[Double] = aac_sine_half_window(128)

///|
let aac_kbd_long : Array[Double] = aac_kbd_window(4.0, 1024)

///|
let aac_kbd_short : Array[Double] = aac_kbd_window(6.0, 128)

///|
let aac_sine_long_960 : Array[Double] = aac_sine_half_window(960)

///|
let aac_sine_short_120 : Array[Double] = aac_sine_half_window(120)

///|
let aac_kbd_long_960 : Array[Double] = aac_kbd_window(4.0, 960)

///|
let aac_kbd_short_120 : Array[Double] = aac_kbd_window(6.0, 120)

///|
/// Direct inverse MDCT (textbook pair, `N = n/2`):
/// Spec MDCT/IMDCT pair (ISO/IEC 14496-3 §4.6.10) with `n/2` coefficients
/// per block of `n` samples:
/// `y[t] = sum_j c[j] * cos(pi/(2*(n/2)) * (t + (n/2+1)/2) * (2j+1))`,
/// i.e. the classical `cos(pi/N * (t + 1/2 + N/2) * (j + 1/2))` kernel with
/// `N = n/2` coefficients. The port evaluates it directly (the C goes
/// through an FFT; this is O(N^2) but exact).
pub fn aac_imdct(coef : Array[Double], n : Int32) -> Array[Double] {
  let n_half = n / 2
  let out : Array[Double] = Array::make(n, 0.0)
  let pi = 3.14159265358979323846
  let base = pi / (2.0 * n_half.to_double())
  let phase = (n_half + 1).to_double() / 2.0
  // Synthesis carries the 2/N normalisation (the analysis does not), the
  // combination under which Princen-Bradley overlap-add reconstructs.
  let inv = 2.0 / n_half.to_double()
  for t = 0; t < n; t = t + 1 {
    let tf = (t.to_double() + phase) * base
    let mut acc = 0.0
    for j = 0; j < n_half; j = j + 1 {
      let c = coef[j]
      if c != 0.0 {
        acc = acc + c * @math.cos(tf * (2 * j + 1).to_double())
      }
    }
    out[t] = acc * inv
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
  let base = pi / (2.0 * n_half.to_double())
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
  mut prev_window_sequence : Int32
  mut prev_window_shape : Int32
}

///|
/// Fresh state for a 1024/128 or 960/120 frame-length stream. */
pub fn new_aac_channel_state() -> AacChannelState {
  {
    saved: Array::make(1024, 0.0),
    prev_window_sequence: aac_only_long,
    prev_window_shape: 0,
  }
}

///|
/// Window sequence constants beyond `aac_only_long` / `aac_eight_short`
/// (`aac_ics.mbt`): 1 LONG_START, 3 LONG_STOP. */
let aac_long_start : Int32 = 1

///|
let aac_long_stop : Int32 = 3

///|
/// `vector_fmul_window(dst, src0, src1, win, len)` of `float_dsp.c`: writes
/// `2*len` entries — `dst[k] = src0[k]*win[2len-1-k] - src1[len-1-k]*win[k]`
/// for `k < len` and `dst[len+j] = src0[len-1-j]*win[len-1-j] +
/// src1[j]*win[len+j]` for the second half.
fn aac_fmul_window(
  dst : Array[Double],
  dstoff : Int32,
  src0 : Array[Double],
  src0off : Int32,
  src1 : Array[Double],
  s1off : Int32,
  win : Array[Double],
  len : Int32,
) -> Unit {
  for k = 0; k < len; k = k + 1 {
    dst[dstoff + k] = src0[src0off + k] * win[2 * len - 1 - k] -
      src1[s1off + len - 1 - k] * win[k]
    dst[dstoff + len + k] = src0[src0off + len - 1 - k] * win[len - 1 - k] +
      src1[s1off + k] * win[len + k]
  }
}

///|
/// `imdct_and_windowing` and `imdct_and_windowing_960` from FFmpeg:
/// long/short transforms use 1024/128 or 960/120 coefficients. Short-window
/// input always has stride 128; the inverse output uses packed stride 128
/// or 120. Overlap uses the corresponding 448/64 or 420/60 transition,
/// and `saved` carries the next frame's tail.
pub fn aac_imdct_and_window(
  st : AacChannelState,
  coeffs : Array[Double],
  window_sequence : Int32,
  window_shape : Int32,
  frame_length_short~ : Bool = false,
) -> Result[Array[Double], String] {
  let long_len = if frame_length_short { 960 } else { 1024 }
  let short_len = long_len / 8
  let half_long = long_len / 2
  let half_short = short_len / 2
  let flat = 7 * half_short
  // `ff_tx_mdct_naive_inv` returns the NEGATED middle half of the
  // textbook inverse. `init_dsp` also sets scale = 1/(N*32768), while
  // aac_imdct uses 2/N, so convert by -1/65536 for float PCM.
  let buf : Array[Double] = if window_sequence == aac_eight_short {
    let v : Array[Double] = Array::make(long_len, 0.0)
    for i = 0; i < 8; i = i + 1 {
      let slot : Array[Double] = Array::make(short_len, 0.0)
      // FFmpeg keeps a 1024-entry spectral buffer even for 960 frames.
      for k = 0; k < short_len; k = k + 1 {
        slot[k] = coeffs[i * 128 + k]
      }
      let part = aac_imdct(slot, 2 * short_len)
      for k = 0; k < short_len; k = k + 1 {
        v[i * short_len + k] = -part[half_short + k] / 65536.0
      }
    }
    v
  } else {
    let part = aac_imdct(coeffs, 2 * long_len)
    let v : Array[Double] = Array::make(long_len, 0.0)
    for k = 0; k < long_len; k = k + 1 {
      v[k] = -part[half_long + k] / 65536.0
    }
    v
  }
  // Window shapes: the current frame picks the current-side windows, the
  // previous frame's shape the overlap side (`use_kb_window[0/1]` in the C).
  let lwin_prev = if st.prev_window_shape != 0 {
    if frame_length_short {
      aac_kbd_long_960
    } else {
      aac_kbd_long
    }
  } else if frame_length_short {
    aac_sine_long_960
  } else {
    aac_sine_long
  }
  let swin_prev = if st.prev_window_shape != 0 {
    if frame_length_short {
      aac_kbd_short_120
    } else {
      aac_kbd_short
    }
  } else if frame_length_short {
    aac_sine_short_120
  } else {
    aac_sine_short
  }
  let swin = if window_shape != 0 {
    if frame_length_short {
      aac_kbd_short_120
    } else {
      aac_kbd_short
    }
  } else if frame_length_short {
    aac_sine_short_120
  } else {
    aac_sine_short
  }
  let saved = st.saved
  let out : Array[Double] = Array::make(long_len, 0.0)
  let temp : Array[Double] = Array::make(short_len, 0.0)
  // window overlapping
  let prev_long = st.prev_window_sequence == aac_only_long ||
    st.prev_window_sequence == aac_long_stop
  let cur_long = window_sequence == aac_only_long ||
    window_sequence == aac_long_start
  if prev_long && cur_long {
    aac_fmul_window(out, 0, saved, 0, buf, 0, lwin_prev, half_long)
  } else {
    for i = 0; i < flat; i = i + 1 {
      out[i] = saved[i]
    }
    if window_sequence == aac_eight_short {
      aac_fmul_window(
        out,
        flat + 0 * short_len,
        saved,
        flat,
        buf,
        0 * short_len,
        swin_prev,
        half_short,
      )
      aac_fmul_window(
        out,
        flat + 1 * short_len,
        buf,
        0 * short_len + half_short,
        buf,
        1 * short_len,
        swin,
        half_short,
      )
      aac_fmul_window(
        out,
        flat + 2 * short_len,
        buf,
        1 * short_len + half_short,
        buf,
        2 * short_len,
        swin,
        half_short,
      )
      aac_fmul_window(
        out,
        flat + 3 * short_len,
        buf,
        2 * short_len + half_short,
        buf,
        3 * short_len,
        swin,
        half_short,
      )
      aac_fmul_window(
        temp,
        0,
        buf,
        3 * short_len + half_short,
        buf,
        4 * short_len,
        swin,
        half_short,
      )
      for i = 0; i < half_short; i = i + 1 {
        out[flat + 4 * short_len + i] = temp[i]
      }
    } else {
      aac_fmul_window(out, flat, saved, flat, buf, 0, swin_prev, half_short)
      for i = 0; i < flat; i = i + 1 {
        out[flat + short_len + i] = buf[half_short + i]
      }
    }
  }
  // buffer update
  if window_sequence == aac_eight_short {
    for i = 0; i < half_short; i = i + 1 {
      saved[i] = temp[half_short + i]
    }
    aac_fmul_window(
      saved,
      half_short,
      buf,
      4 * short_len + half_short,
      buf,
      5 * short_len,
      swin,
      half_short,
    )
    aac_fmul_window(
      saved,
      half_short + short_len,
      buf,
      5 * short_len + half_short,
      buf,
      6 * short_len,
      swin,
      half_short,
    )
    aac_fmul_window(
      saved,
      half_short + 2 * short_len,
      buf,
      6 * short_len + half_short,
      buf,
      7 * short_len,
      swin,
      half_short,
    )
    for i = 0; i < half_short; i = i + 1 {
      saved[flat + i] = buf[7 * short_len + half_short + i]
    }
  } else if window_sequence == aac_long_start {
    for i = 0; i < flat; i = i + 1 {
      saved[i] = buf[half_long + i]
    }
    for i = 0; i < half_short; i = i + 1 {
      saved[flat + i] = buf[7 * short_len + half_short + i]
    }
  } else {
    // LONG_STOP or ONLY_LONG
    for i = 0; i < half_long; i = i + 1 {
      saved[i] = buf[half_long + i]
    }
  }
  st.prev_window_sequence = window_sequence
  st.prev_window_shape = window_shape
  Ok(out)
}

///|
/// `raw_data_block` element ids (spec 4.4.1): 0 SCE, 1 CPE, 6 FIL, 7 END. */
let aac_id_sce : Int32 = 0

///|
let aac_id_cpe : Int32 = 1

///|
let aac_id_cce : Int32 = 2

///|
let aac_id_lfe : Int32 = 3

///|
let aac_id_data : Int32 = 4

///|
let aac_id_filler : Int32 = 6

///|
/// `ID_END`. */
let aac_id_end : Int32 = 7

///|
/// One decoded channel of a frame: 1024 or 960 double samples. */
pub struct AacPcm {
  /// The windowed output samples of this frame.
  samples : Array[Double]
}

///|
/// AAC-LC decoder for SCE/CPE/LFE elements with indexed or PCE layouts. */
pub struct AacDecoder {
  /// AudioSpecificConfig the stream was opened with.
  config : Mpeg4AudioConfig
  /// History storage slots, keyed by element identity rather than output index.
  channels : Array[AacChannelState]
  /// FFmpeg element output order; history slots are bound by element key.
  mut layout : Array[AacLayoutChannel]
  state_keys : Array[Int32]
  /// CCE overlap histories, indexed by instance tag; never output channels.
  coupling_states : Array[AacChannelState?]
  /// PCE/ASC declarations, separate from the audible channel layout.
  mut coupling_tags : Array[Int32]
  /// Scalefactor band geometry for the config's sampling index.
  swb : AacSwb
  /// PNS noise state (`ac->random_state`).
  noise : AacSpectrumState
  /// Per-element SBR state keyed by element key (type*32 + tag*2).
  sbr_states : Map[Int32, AacSbr]
  /// `m4ac.sbr` evolution: 0 absent, 1 present, -1 unknown (ADTS).
  mut sbr_signalling : Int32
  /// `m4ac.ps` evolution, same encoding.
  mut ps_signalling : Int32
  /// Frames fully decoded; approximates `OC_LOCKED` for implicit SBR.
  mut frames_decoded : Int32
}

///|
/// New decoder with capacity for `n` independent channel window states.
/// Indexed configurations 1..7 and 11..14 initialize the layout; config 0 obtains
/// its layout from an in-band PCE. Insufficient capacity is a decode error.
pub fn new_aac_decoder(config : Mpeg4AudioConfig, n : Int32) -> AacDecoder {
  let ch : Array[AacChannelState] = []
  for i = 0; i < n; i = i + 1 {
    ch.push(new_aac_channel_state())
  }
  let swb = match
    aac_swb_tables(
      config.sampling_index,
      frame_length_short=config.frame_length_short,
    ) {
    Ok(v) => v
    Err(_) =>
      aac_swb_tables(0, frame_length_short=config.frame_length_short).unwrap()
  }
  let layout = match aac_default_layout(config.chan_config) {
    Ok(v) => v
    Err(_) => [] // report unsupported configurations from decode_frame
  }
  {
    config,
    channels: ch,
    layout,
    state_keys: Array::make(n, -1),
    coupling_states: Array::make(16, None),
    coupling_tags: [],
    swb,
    noise: new_aac_spectrum_state(),
    sbr_states: Map([]),
    sbr_signalling: config.sbr,
    ps_signalling: config.ps,
    frames_decoded: 0,
  }
}

///|
/// `ID_PCE` element id (program_config_element). */
let aac_id_pce : Int32 = 5

///|
/// Decode every channel element before updating layout and window history.
/// Indexed configurations and PCEs follow FFmpeg's element output order; the
/// overlap buffers are bound to (element type, tag, subchannel), not to
/// bitstream arrival order. CCEs have separate histories; height uses three layers.
pub fn AacDecoder::decode_frame(
  self : AacDecoder,
  data : Bytes,
) -> Result[Array[AacPcm], String] {
  match self.decode_frame_with_consumed(data) {
    Ok((frames, _)) => Ok(frames)
    Err(e) => Err(e)
  }
}

///|
/// Like `decode_frame`, but also reports the bytes belonging to this
/// raw_data_block (`buf_consumed` in FFmpeg's AAC decoder).  A packet may
/// contain several concatenated raw AAC frames; callers advance by the
/// returned length (trailing zero padding is folded into the last frame).
pub fn AacDecoder::decode_frame_with_consumed(
  self : AacDecoder,
  data : Bytes,
) -> Result[(Array[AacPcm], Int32), String] {
  let random_state = self.noise.random_state
  match self.decode_raw_block(data) {
    Ok(v) => Ok(v)
    Err(e) => {
      self.noise.random_state = random_state
      Err(e)
    }
  }
}

///|
fn AacDecoder::decode_raw_block(
  self : AacDecoder,
  data : Bytes,
) -> Result[(Array[AacPcm], Int32), String] {
  if self.config.chan_config < 0 ||
    self.config.chan_config > 14 ||
    (self.config.chan_config > 7 && self.config.chan_config < 11) {
    return Err("unsupported AAC channel configuration")
  }
  let gb = BitReader::new(data)
  if gb.bits_left() < 3 {
    return Err("missing channel element")
  }
  let mut layout = self.layout
  let mut coupling_tags = self.coupling_tags
  let implicit = layout.length() == 0
  let mut pce_seen = false
  let mut audio_elements = 0
  let decoded : Array[AacDecodedSpectrum] = []
  let couplings : Array[AacCoupling] = []
  let keys : Array[Int32] = []
  let seen = Array::make(128, false)
  // che_prev of aacdec.c: the element the next TYPE_FIL extension targets.
  let mut prev_elem : Int32 = -1
  let mut prev_tag : Int32 = -1
  while true {
    if gb.bits_left() < 3 {
      return Err("missing ID_END")
    }
    let elem = gb.read(3).reinterpret_as_int()
    if elem == aac_id_end {
      break
    }
    if elem == aac_id_filler {
      let prev_key : Int32 = if prev_elem < 0 {
        -1
      } else {
        prev_elem * 32 + prev_tag * 2
      }
      match self.decode_fill_element(gb, prev_key, prev_elem) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      continue
    }
    if elem == aac_id_pce {
      if pce_seen {
        return Err("multiple PCEs are not supported")
      }
      coupling_tags = []
      layout = match aac_decode_pce(gb, coupling_tags~) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      pce_seen = true
      continue
    }
    if elem != aac_id_sce &&
      elem != aac_id_cpe &&
      elem != aac_id_cce &&
      elem != aac_id_lfe &&
      elem != aac_id_data {
      return Err("unsupported raw_data_block element \{elem}")
    }
    if elem != aac_id_data &&
      elem != aac_id_cce &&
      implicit &&
      !pce_seen &&
      audio_elements != 0 {
      return Err("AAC channel layout is required for multiple elements")
    }
    if gb.bits_left() < 4 {
      return Err("missing element instance tag")
    }
    let tag = gb.read(4).reinterpret_as_int()
    if elem == aac_id_data {
      match aac_skip_data_element(gb) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      continue
    }
    let key = elem * 32 + tag * 2
    if seen[key] {
      return Err("duplicate AAC channel element")
    }
    seen[key] = true
    if elem == aac_id_cce {
      match self.decode_coupling(gb, tag) {
        Ok(v) => couplings.push(v)
        Err(e) => return Err(e)
      }
      continue
    }
    // FFmpeg's indexed stereo configuration also admits dual-mono SCEs.
    if self.config.chan_config == 2 &&
      audio_elements == 0 &&
      elem == 0 &&
      !pce_seen &&
      layout.length() == 2 &&
      layout[0].element_type == 1 {
      layout = aac_layout_from_elements([
        { kind: 0, tag: 0, group: 1, },
        { kind: 0, tag: 1, group: 1, },
      ]).unwrap()
    }
    if layout.length() != 0 {
      let mut declared = false
      for channel in layout {
        if channel.key() == key {
          declared = true
        }
      }
      if !declared {
        return Err("channel element is not declared in AAC layout")
      }
    }
    let count = if elem == aac_id_cpe { 2 } else { 1 }
    if decoded.length() + count > self.channels.length() {
      return Err("insufficient AAC channel states")
    }
    if elem == aac_id_cpe {
      let pair = match self.decode_pair(gb) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      decoded.push(pair.left)
      decoded.push(pair.right)
      keys.push(key)
      keys.push(key + 1)
    } else {
      match self.decode_spectrum(gb, None) {
        Ok(v) => decoded.push(v)
        Err(e) => return Err(e)
      }
      keys.push(key)
    }
    audio_elements = audio_elements + 1
    if elem < 4 {
      prev_elem = elem
      prev_tag = tag
    }
  }
  if decoded.length() == 0 {
    return Err("missing channel element")
  }
  // Preserve the original syntax-only API for an unconfigured single
  // SCE/CPE, while requiring an explicit layout for multiple elements.
  if layout.length() == 0 {
    let inferred : Array[AacLayoutChannel] = []
    for key in keys {
      inferred.push({
        element_type: key / 32,
        element_tag: key % 32 / 2,
        element_channel: key & 1,
        position: if key / 32 == 3 {
          3
        } else if keys.length() == 1 {
          2
        } else {
          key & 1
        },
      })
    }
    layout = inferred
  }
  if layout.length() != decoded.length() {
    return Err("AAC frame does not contain every declared channel")
  }
  let next_keys = Array::make(self.state_keys.length(), -1)
  for i = 0; i < self.state_keys.length(); i = i + 1 {
    for channel in layout {
      if channel.key() == self.state_keys[i] {
        next_keys[i] = self.state_keys[i]
      }
    }
  }
  let inputs : Array[Int32] = []
  let states : Array[Int32] = []
  for channel in layout {
    let key = channel.key()
    let mut input = -1
    for i = 0; i < keys.length(); i = i + 1 {
      if keys[i] == key {
        input = i
      }
    }
    if input < 0 {
      return Err("AAC frame does not contain every declared channel")
    }
    inputs.push(input)
    let mut state = -1
    for i = 0; i < next_keys.length(); i = i + 1 {
      if next_keys[i] == key {
        state = i
      }
    }
    if state < 0 {
      for i = 0; i < next_keys.length(); i = i + 1 {
        if state < 0 && next_keys[i] < 0 {
          state = i
        }
      }
      if state < 0 {
        return Err("insufficient AAC channel states")
      }
      next_keys[state] = key
    }
    states.push(state)
  }
  // Validate all CCE targets before advancing any overlap history.
  for coupling in couplings {
    if pce_seen || (self.config.chan_config == 0 && self.layout.length() != 0) {
      let mut declared = false
      for tag in coupling_tags {
        if tag == coupling.tag {
          declared = true
        }
      }
      if !declared {
        return Err("coupling element is not declared in AAC PCE")
      }
    }
    for target in coupling.targets {
      if !seen[target.kind * 32 + target.tag * 2] {
        return Err("CCE target is missing from the AAC frame")
      }
    }
  }
  if pce_seen {
    for tag = 0; tag < 16; tag = tag + 1 {
      let mut declared = false
      for id in coupling_tags {
        if id == tag {
          declared = true
        }
      }
      if !declared {
        self.coupling_states[tag] = None
      }
    }
  }
  // C processes CCEs in tag order before CPE/SCE, including source TNS.
  couplings.sort_by((a, b) => a.tag - b.tag)
  let coupling_pcm : Array[Array[Double]] = []
  for coupling in couplings {
    let spectrum = coupling.spectrum
    let info = spectrum.ics.info
    if spectrum.ics.tns_present != 0 {
      aac_apply_tns(spectrum.coeffs, spectrum.ics.tns, info, self.swb)
    }
    let state = match self.coupling_states[coupling.tag] {
      Some(v) => v
      None => new_aac_channel_state()
    }
    if coupling.point == 3 {
      coupling_pcm.push(
        aac_imdct_and_window(
          state,
          spectrum.coeffs,
          info.window_sequence,
          info.window_shape,
          frame_length_short=self.config.frame_length_short,
        ).unwrap(),
      )
    } else {
      coupling_pcm.push([])
      state.prev_window_sequence = info.window_sequence
      state.prev_window_shape = info.window_shape
    }
    self.coupling_states[coupling.tag] = Some(state)
  }
  let out : Array[AacPcm] = []
  for channel = 0; channel < layout.length(); channel = channel + 1 {
    let spectrum = decoded[inputs[channel]]
    let ics = spectrum.ics
    let state = states[channel]
    if self.state_keys[state] != layout[channel].key() {
      self.channels[state] = new_aac_channel_state()
    }
    aac_apply_spectral_couplings(
      spectrum.coeffs,
      layout[channel].key(),
      couplings,
      0,
      self.swb,
    )
    if ics.tns_present != 0 {
      aac_apply_tns(spectrum.coeffs, ics.tns, ics.info, self.swb)
    }
    aac_apply_spectral_couplings(
      spectrum.coeffs,
      layout[channel].key(),
      couplings,
      1,
      self.swb,
    )
    match
      aac_imdct_and_window(
        self.channels[state],
        spectrum.coeffs,
        ics.info.window_sequence,
        ics.info.window_shape,
        frame_length_short=self.config.frame_length_short,
      ) {
      Ok(samples) => {
        for i = 0; i < couplings.length(); i = i + 1 {
          let coupling = couplings[i]
          if coupling.point == 3 {
            for target in coupling.targets {
              if aac_coupling_target_gain(target, layout[channel].key())
                is Some(index) {
                let gain = coupling.gains[index][0]
                for k = 0; k < samples.length(); k = k + 1 {
                  samples[k] = samples[k] + gain * coupling_pcm[i][k]
                }
              }
            }
          }
        }
        out.push({ samples, })
      }
      Err(e) => return Err(e)
    }
  }
  self.layout = layout
  self.coupling_tags = coupling_tags
  for i = 0; i < next_keys.length(); i = i + 1 {
    self.state_keys[i] = next_keys[i]
  }
  self.config.channels = layout.length()
  if pce_seen {
    self.config.chan_config = 0
  }
  match self.apply_sbr(out, layout) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.frames_decoded = self.frames_decoded + 1
  let mut consumed = (gb.count() + 7) >> 3
  if consumed > data.length() {
    consumed = data.length()
  }
  let mut offset = consumed
  while offset < data.length() && data[offset] == b' ' {
    offset = offset + 1
  }
  let used = if data.length() > offset { consumed } else { data.length() }
  Ok((out, used))
}
