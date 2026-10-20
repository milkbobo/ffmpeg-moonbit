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
/// The two KBD windows AAC uses (`ff_aac_kbd_long_1024`, alpha 4.0, and
/// `ff_aac_kbd_short_128`, alpha 6.0).
let aac_kbd_long : Array[Double] = aac_kbd_window(4.0, 2048)

///|
let aac_kbd_short : Array[Double] = aac_kbd_window(6.0, 256)

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
/// Fresh state for a 1024/128 frame-length stream. */
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
/// One channel of `imdct_and_windowing` (`aacdec_dsp_template.c`): IMDCT
/// (one 2048 for long sequences, eight 256s for EIGHT_SHORT, each keeping
/// the second half like the C's `imdct_half`) then the overlap structure
/// the C describes — long-to-long transitions take the plain 512 overlap,
/// everything else goes through the 448/64 split, and `saved` carries the
/// next frame's tail.
pub fn aac_imdct_and_window(
  st : AacChannelState,
  coeffs : Array[Double],
  window_sequence : Int32,
  window_shape : Int32,
) -> Result[Array[Double], String] {
  // imdct: FFmpeg's `imdct_half` output equals the middle half of the full
  // IMDCT (verified against the direct TDAC synthesis: the aliasing
  // antisymmetry makes the quarters interchangeable).
  let buf : Array[Double] = if window_sequence == aac_eight_short {
    let v : Array[Double] = Array::make(1024, 0.0)
    for i = 0; i < 8; i = i + 1 {
      let slot : Array[Double] = Array::make(128, 0.0)
      for k = 0; k < 128; k = k + 1 {
        slot[k] = coeffs[i * 128 + k]
      }
      let part = aac_imdct(slot, 256)
      for k = 0; k < 128; k = k + 1 {
        v[i * 128 + k] = part[64 + k]
      }
    }
    v
  } else {
    let part = aac_imdct(coeffs, 2048)
    let v : Array[Double] = Array::make(1024, 0.0)
    for k = 0; k < 1024; k = k + 1 {
      v[k] = part[512 + k]
    }
    v
  }
  // Window shapes: the current frame picks the current-side windows, the
  // previous frame's shape the overlap side (`use_kb_window[0/1]` in the C).
  let lwin_prev = if st.prev_window_shape != 0 {
    aac_kbd_long
  } else {
    aac_full_window(1024)
  }
  let swin_prev = if st.prev_window_shape != 0 {
    aac_kbd_short
  } else {
    aac_full_window(128)
  }
  let swin = if window_shape != 0 {
    aac_kbd_short
  } else {
    aac_full_window(128)
  }
  let saved = st.saved
  let out : Array[Double] = Array::make(1024, 0.0)
  let temp : Array[Double] = Array::make(128, 0.0)
  // window overlapping
  let prev_long = st.prev_window_sequence == aac_only_long ||
    st.prev_window_sequence == aac_long_stop
  let cur_long = window_sequence == aac_only_long ||
    window_sequence == aac_long_start
  if prev_long && cur_long {
    aac_fmul_window(out, 0, saved, 0, buf, 0, lwin_prev, 512)
  } else {
    for i = 0; i < 448; i = i + 1 {
      out[i] = saved[i]
    }
    if window_sequence == aac_eight_short {
      aac_fmul_window(
        out,
        448 + 0 * 128,
        saved,
        448,
        buf,
        0 * 128,
        swin_prev,
        64,
      )
      aac_fmul_window(
        out,
        448 + 1 * 128,
        buf,
        0 * 128 + 64,
        buf,
        1 * 128,
        swin,
        64,
      )
      aac_fmul_window(
        out,
        448 + 2 * 128,
        buf,
        1 * 128 + 64,
        buf,
        2 * 128,
        swin,
        64,
      )
      aac_fmul_window(
        out,
        448 + 3 * 128,
        buf,
        2 * 128 + 64,
        buf,
        3 * 128,
        swin,
        64,
      )
      aac_fmul_window(temp, 0, buf, 3 * 128 + 64, buf, 4 * 128, swin, 64)
      for i = 0; i < 64; i = i + 1 {
        out[448 + 4 * 128 + i] = temp[i]
      }
    } else {
      aac_fmul_window(out, 448, saved, 448, buf, 0, swin_prev, 64)
      for i = 0; i < 448; i = i + 1 {
        out[576 + i] = buf[64 + i]
      }
    }
  }
  // buffer update
  if window_sequence == aac_eight_short {
    for i = 0; i < 64; i = i + 1 {
      saved[i] = temp[64 + i]
    }
    aac_fmul_window(saved, 64, buf, 4 * 128 + 64, buf, 5 * 128, swin, 64)
    aac_fmul_window(saved, 192, buf, 5 * 128 + 64, buf, 6 * 128, swin, 64)
    aac_fmul_window(saved, 320, buf, 6 * 128 + 64, buf, 7 * 128, swin, 64)
    for i = 0; i < 64; i = i + 1 {
      saved[448 + i] = buf[7 * 128 + 64 + i]
    }
  } else if window_sequence == aac_long_start {
    for i = 0; i < 448; i = i + 1 {
      saved[i] = buf[512 + i]
    }
    for i = 0; i < 64; i = i + 1 {
      saved[448 + i] = buf[7 * 128 + 64 + i]
    }
  } else {
    // LONG_STOP or ONLY_LONG
    for i = 0; i < 512; i = i + 1 {
      saved[i] = buf[512 + i]
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
  /// Scalefactor band geometry for the config's sampling index.
  swb : AacSwb
  /// PNS noise state (`ac->random_state`).
  noise : AacSpectrumState
}

///|
/// New decoder for `n` SCE channels. */
pub fn new_aac_decoder(config : Mpeg4AudioConfig, n : Int32) -> AacDecoder {
  let ch : Array[AacChannelState] = []
  for i = 0; i < n; i = i + 1 {
    ch.push(new_aac_channel_state())
  }
  let swb = match aac_swb_tables(config.sampling_index) {
    Ok(v) => v
    Err(_) => aac_swb_tables(0).unwrap()
  }
  { config, channels: ch, swb, noise: new_aac_spectrum_state(), }
}

///|
/// `fill_element` skip: 4-bit count (15 extends with 8 more bits) then that
/// many bytes of extension payload. */
fn aac_skip_filler(gb : BitReader) -> Result[Unit, String] {
  let cnt = gb.read(4).reinterpret_as_int()
  let mut n = cnt
  if cnt == 15 {
    n = cnt + gb.read(8).reinterpret_as_int() - 1
  }
  // `n` is the byte length of the extension payload that follows; an
  // empty FIL (count 0) carries no payload at all.
  if n < 0 || gb.bits_left() < 8 * n {
    return Err("filler overruns the frame")
  }
  gb.skip(8 * n)
  Ok(())
}

///|
/// `ID_PCE` element id (program_config_element). */
let aac_id_pce : Int32 = 5

///|
/// Skip a `program_config_element` (`decode_pce`): channel-map entries are
/// 5 bits (is_cpe + tag) except LFE (tag only), the comment field is
/// length-prefixed bytes, and a height extension (marker 0xAC) is rejected.
fn aac_skip_pce(gb : BitReader) -> Result[Unit, String] {
  // `payload_alignment`: the byte-align reference is the start of the
  // raw_data_block, which is byte aligned here (bit count 0).
  let ref_bit = 0
  gb.skip(2)
  // object_type
  gb.skip(4)
  // sampling_frequency_index (a mismatch only warns in the C)
  let num_front = gb.read(4).reinterpret_as_int()
  let num_side = gb.read(4).reinterpret_as_int()
  let num_back = gb.read(4).reinterpret_as_int()
  let num_lfe = gb.read(2).reinterpret_as_int()
  let num_assoc = gb.read(3).reinterpret_as_int()
  let num_cc = gb.read(4).reinterpret_as_int()
  if gb.read1() != 0 {
    gb.skip(4)
  }
  if gb.read1() != 0 {
    gb.skip(4)
  }
  if gb.read1() != 0 {
    gb.skip(3)
  }
  println(
    "PCE front=\{num_front} side=\{num_side} back=\{num_back} lfe=\{num_lfe} assoc=\{num_assoc} cc=\{num_cc} left=\{gb.bits_left()} pos=\{gb.count()}",
  )
  if gb.bits_left() <
    5 * (num_front + num_side + num_back + num_cc) +
    4 * (num_lfe + num_assoc + num_cc) {
    return Err("program_config_element overruns the frame")
  }
  gb.skip(5 * (num_front + num_side + num_back))
  gb.skip(4 * num_lfe)
  gb.skip(4 * num_assoc)
  gb.skip(5 * num_cc)
  // `relative_align_get_bits` against the element start.
  let n = (ref_bit - gb.count()) & 7
  if n != 0 {
    gb.skip(n)
  }
  let comment_bits = gb.read(8).reinterpret_as_int() * 8
  if gb.bits_left() < comment_bits {
    return Err("program_config_element overruns the frame")
  }
  if comment_bits >= 16 + 2 * (num_front + num_side + num_back) &&
    gb.show(8) == 0xACU {
    return Err("PCE height extension is not supported")
  }
  gb.skip(comment_bits)
  Ok(())
}

///|
/// Decode one `raw_data_block` (spec 4.4.1) holding one SCE plus optional
/// filler, ending with ID_END: ICS (sections/scalefactors), spectral data
/// (codebooks 1..11 with escapes, intensity and noise bands), TNS and the
/// ONLY_LONG IMDCT/windowing pipeline.
pub fn AacDecoder::decode_frame(
  self : AacDecoder,
  data : Bytes,
) -> Result[Array[AacPcm], String] {
  let gb = BitReader::new(data)
  let mut elem = gb.read(3).reinterpret_as_int()
  // Elements before the SCE may be filler (the native encoder writes an
  // identification comment into the first frames).
  while elem == aac_id_filler || elem == aac_id_pce {
    let r = if elem == aac_id_filler {
      aac_skip_filler(gb)
    } else {
      aac_skip_pce(gb)
    }
    match r {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    if gb.bits_left() < 3 {
      return Err("missing ID_END")
    }
    elem = gb.read(3).reinterpret_as_int()
  }
  if elem != aac_id_sce {
    return Err("only single channel elements are supported")
  }
  // element_instance_tag (spec 4.4.2; `decode_sce` skips it).
  gb.skip(4)
  let ics = match aac_decode_ics(gb) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let max_sfb = ics.info.max_sfb
  if max_sfb > self.swb.num_long && ics.info.window_sequence != aac_eight_short {
    return Err("max_sfb exceeds the scalefactor band count")
  }
  if ics.info.window_sequence == aac_eight_short && max_sfb > self.swb.num_short {
    return Err("max_sfb exceeds the scalefactor band count")
  }
  let sf = aac_sf_dequant(ics.info, ics.sect_cb, ics.scale_factors)
  let coeffs : Array[Double] = Array::make(1024, 0.0)
  match
    aac_decode_spectrum(
      gb,
      ics.info,
      self.swb,
      ics.sect_cb,
      sf,
      self.noise,
      coeffs,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if ics.tns_present != 0 {
    aac_apply_tns(coeffs, ics.tns, ics.info, self.swb)
  }
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
      match aac_skip_filler(gb) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if elem == aac_id_pce {
      match aac_skip_pce(gb) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if elem == aac_id_sce {
      // A second SCE belongs to the next channel of a multichannel
      // configuration this decoder does not assemble; stop here like the
      // mono scope does elsewhere.
      break
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
