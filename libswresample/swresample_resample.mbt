///|
/// libswresample port, slice 2: the native swr polyphase resampler
/// (`libswresample/resample.c` + the float path of
/// `resample_template.c`, driven by the `swresample.c` buffering
/// semantics that affect output values: `invert_initial_buffer`'s
/// mirrored start-up history, `multiple_resample`'s window bound and
/// `resample_flush`'s mirrored tail).  Arithmetic is IEEE float32
/// exactly like the C FLTP path; double appears only where the C uses
/// it (filter design, the linear-interpolation weight, `lrintf`
/// arguments).  Streaming output values depend only on the input
/// stream and the (index, frac) phase state, never on chunk
/// boundaries, so the simplified pull driver here is value-exact
/// against the C one.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the
/// same license.

///|
/// `M_PI` as a double literal (same nearest-double as C).
let swr_resample_pi : Double = 3.141592653589793

///|
/// Window shape of the polyphase filter bank (`SwrFilterType`).
pub enum SwrFilterType {
  Cubic
  BlackmanNuttall
  Kaiser
}

///|
pub(all) suberror SwrResampleError {
  InvalidResampleConfig(String)
} derive(Debug)

///|
pub extend SwrResampleError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The polyphase resampler state (per-context, shared across
/// channels exactly like the C: one (index, frac) clock, lockstep
/// per-channel evaluation).
pub struct SwrResampler {
  filter_bank : FixedArray[Float]
  filter_length : Int32
  filter_alloc : Int32
  phase_count : Int32
  linear : Bool
  src_incr : Int32
  dst_incr : Int32
  dst_incr_div : Int32
  dst_incr_mod : Int32
  inv_src_incr : Double
  // Clock state: `index` in [0, phase_count), `frac` in [0, src_incr).
  mut index : Int32
  mut frac : Int32
  // Per-channel input history; consumed samples are dropped from the
  // front.  Until `primed` this holds the raw start-up samples.
  hist : Array[Array[Float]]
  mut primed : Bool
}

///|
fn swr_resample_gcd(a : Int32, b : Int32) -> Int32 {
  let mut x = if a < 0 { -a } else { a }
  let mut y = if b < 0 { -b } else { b }
  while y != 0 {
    let t = x % y
    x = y
    y = t
  }
  x
}

///|
/// `build_filter` (double design, float storage): one polyphase row
/// per phase, taps normalized by the phase-0 DC gain, mirrored rows
/// for the upper half and the rotated `phase_count` wraparound row
/// used by the linear kernel.
fn swr_resample_build_filter(
  factor : Double,
  tap_count : Int32,
  alloc : Int32,
  phase_count : Int32,
  filter_type : SwrFilterType,
  kaiser_beta : Double,
) -> FixedArray[Float] {
  // Invariant (from resample_init): tap_count is 1 or even.
  let ph_nb = if phase_count % 2 == 1 {
    phase_count
  } else {
    phase_count / 2 + 1
  }
  let center = (tap_count - 1) / 2
  let bank : FixedArray[Float] = FixedArray::make(
    (phase_count + 1) * alloc,
    0.0,
  )
  let sin_lut : Array[Double] = []
  if factor == 1.0 {
    // Pure interpolation: the sinc degenerates to the sign-alternating
    // sin(pi*ph/N)/(pi*x) form with a precomputed sign.
    for ph in 0..<ph_nb {
      sin_lut.push(
        @math.sin(swr_resample_pi * ph.to_double() / phase_count.to_double()) *
        (if center % 2 == 1 { 1.0 } else { -1.0 }),
      )
    }
  }
  let tab : Array[Double] = Array::make(tap_count, 0.0)
  let mut norm = 0.0
  for ph in 0..<ph_nb {
    let mut s = if factor == 1.0 { sin_lut[ph] } else { 0.0 }
    for i in 0..<tap_count {
      let x = swr_resample_pi *
        (
          i.to_double() -
          center.to_double() -
          ph.to_double() / phase_count.to_double()
        ) *
        factor
      let mut y = if x == 0.0 {
        1.0
      } else if factor == 1.0 {
        s / x
      } else {
        @math.sin(x) / x
      }
      match filter_type {
        Cubic => {
          // First-derivative -0.5 Keys cubic; note the C resets x to
          // the UN-scaled offset here (no pi).
          let cx = if (
              i.to_double() -
              center.to_double() -
              ph.to_double() / phase_count.to_double()
            ) *
            factor <
            0.0 {
            -((
              i.to_double() -
              center.to_double() -
              ph.to_double() / phase_count.to_double()
            ) *
            factor)
          } else {
            (
              i.to_double() -
              center.to_double() -
              ph.to_double() / phase_count.to_double()
            ) *
            factor
          }
          let d = -0.5
          if cx < 1.0 {
            y = 1.0 -
              3.0 * cx * cx +
              2.0 * cx * cx * cx +
              d * (-cx * cx + cx * cx * cx)
          } else {
            y = d * (-4.0 + 8.0 * cx - 5.0 * cx * cx + cx * cx * cx)
          }
        }
        BlackmanNuttall => {
          let w = 2.0 * x / (factor * tap_count.to_double())
          let t = -@math.cos(w)
          y = y *
            (
              0.3635819 -
              0.4891775 * t +
              0.1365995 * (2.0 * t * t - 1.0) -
              0.0106411 * (4.0 * t * t * t - 3.0 * t)
            )
        }
        Kaiser => {
          let w = 2.0 * x / (factor * tap_count.to_double() * swr_resample_pi)
          let inner = 1.0 - w * w
          let arg = if inner > 0.0 { kaiser_beta * inner.sqrt() } else { 0.0 }
          y = y * @libavutil.av_bessel_i0(arg)
        }
      }
      tab[i] = y
      s = -s
      if ph == 0 {
        norm = norm + y
      }
    }
    for i in 0..<tap_count {
      // FLTP storage: (float)(tab[i] * 1<<0 / norm).
      bank[ph * alloc + i] = Float::from_double(tab[i] / norm)
    }
    if phase_count % 2 == 1 {
      continue
    }
    for i in 0..<tap_count {
      bank[(phase_count - ph) * alloc + (tap_count - 1 - i)] = bank[ph * alloc +
        i]
    }
  }
  // Wraparound row `phase_count`: rotate1(row 0) over the full alloc
  // width (the two memcpys in resample_init).
  let last = bank[alloc - 1]
  for i = alloc - 1; i > 0; i = i - 1 {
    bank[phase_count * alloc + i] = bank[i - 1]
  }
  bank[phase_count * alloc] = last
  bank
}

///|
/// Create a resampler for `in_rate -> out_rate` planar float audio
/// with `channels` planes.  Defaults mirror `libswresample/options.c`:
/// 32 taps, phase_shift 10, linear interpolation enabled, kaiser
/// window beta 9, cutoff 0.97, exact rational phases.  Equal rates are
/// rejected - that path is the slice-1 convert-only `Swr`.
///
/// ```mbt check
/// test {
///   let r = @swr.SwrResampler::new(in_rate=48000, out_rate=8000)
///   inspect(r.phase_count, content="1")
///   inspect(r.dst_incr_div, content="6")
/// }
/// ```
pub fn SwrResampler::new(
  in_rate~ : Int32,
  out_rate~ : Int32,
  channels~ : Int32 = 1,
  filter_size~ : Int32 = 32,
  phase_shift~ : Int32 = 10,
  linear~ : Bool = true,
  cutoff~ : Double = 0.0,
  filter_type~ : SwrFilterType = Kaiser,
  kaiser_beta~ : Double = 9.0,
  exact_rational~ : Bool = true,
) -> SwrResampler raise SwrResampleError {
  guard in_rate > 0 && out_rate > 0 else {
    raise InvalidResampleConfig("resample: rates must be positive")
  }
  guard in_rate != out_rate else {
    raise InvalidResampleConfig(
      "resample: equal rates - use the convert path (Swr) instead",
    )
  }
  guard channels >= 1 else {
    raise InvalidResampleConfig("resample: channels must be >= 1")
  }
  guard filter_size >= 1 else {
    raise InvalidResampleConfig("resample: filter_size must be >= 1")
  }
  guard phase_shift >= 0 && phase_shift <= 16 else {
    raise InvalidResampleConfig("resample: phase_shift must be in 0..=16")
  }
  let cutoff_v = if cutoff != 0.0 { cutoff } else { 0.97 }
  let factor = if out_rate.to_double() * cutoff_v / in_rate.to_double() < 1.0 {
    out_rate.to_double() * cutoff_v / in_rate.to_double()
  } else {
    1.0
  }
  let mut phase_count = 1 << phase_shift
  let mut filter_length = if (filter_size.to_double() / factor).ceil() > 1.0 {
    (filter_size.to_double() / factor).ceil().to_int()
  } else {
    1
  }
  if filter_length > 1 {
    filter_length = (filter_length + 1) & -2
  }
  // exact_rational: collapse the phase count to the reduced ratio
  // numerator when it fits (phase_count_compensation feeds only
  // swr_set_compensation, out of scope here).
  if exact_rational {
    let pce = out_rate / swr_resample_gcd(out_rate, in_rate)
    if pce <= phase_count {
      phase_count = pce
    }
  }
  let filter_alloc = (filter_length + 7) & -8
  let filter_bank = swr_resample_build_filter(
    factor, filter_length, filter_alloc, phase_count, filter_type, kaiser_beta,
  )
  // av_reduce(out_rate, in_rate * phase_count) then the doubling loop.
  let g = swr_resample_gcd(out_rate, in_rate * phase_count)
  let mut src_incr = out_rate / g
  let mut dst_incr = in_rate * phase_count / g
  while dst_incr < 1048576 && src_incr < 1048576 {
    dst_incr = dst_incr * 2
    src_incr = src_incr * 2
  }
  {
    filter_bank,
    filter_length,
    filter_alloc,
    phase_count,
    linear,
    src_incr,
    dst_incr,
    dst_incr_div: dst_incr / src_incr,
    dst_incr_mod: dst_incr % src_incr,
    inv_src_incr: 1.0 / src_incr.to_double(),
    index: 0,
    frac: 0,
    hist: {
      // Fresh array per channel - Array::make(channels, []) would alias
      // one array across all channels.
      let h : Array[Array[Float]] = []
      for _ in 0..<channels {
        h.push([])
      }
      h
    },
    primed: false,
  }
}

///|
/// Feed one chunk of planar input (values in [-1, 1], f32 domain like
/// the C FLTP path); returns every fully computable output sample.
/// Chunks may have any size >= 1.
pub fn SwrResampler::process(
  self : SwrResampler,
  chunk : Array[Array[Double]],
) -> Array[Array[Double]] raise SwrResampleError {
  guard chunk.length() == self.hist.length() else {
    raise InvalidResampleConfig("resample: chunk channel count mismatch")
  }
  for plane in chunk {
    guard plane.length() == chunk[0].length() else {
      raise InvalidResampleConfig("resample: unequal plane lengths")
    }
  }
  if chunk[0].length() == 0 {
    return []
  }
  for ch in 0..<chunk.length() {
    for sample in chunk[ch] {
      self.hist[ch].push(Float::from_double(sample))
    }
  }
  if !self.primed {
    // invert_initial_buffer: wait for filter_length + 1 samples, then
    // mirror s[-n] = s[n] for n = 1..filter_length and start the clock
    // at s[-K], K = (filter_length-1)/2, with index = 0.
    if self.hist[0].length() < self.filter_length + 1 {
      return []
    }
    let k = (self.filter_length - 1) / 2
    for ch in 0..<self.hist.length() {
      let h = self.hist[ch]
      let rebuilt : Array[Float] = []
      for n = k; n >= 1; n = n - 1 {
        rebuilt.push(h[n])
      }
      for v in h {
        rebuilt.push(v)
      }
      self.hist[ch] = rebuilt
    }
    self.primed = true
    self.index = 0
    self.frac = 0
  }
  self.swr_resample_drain()
}

///|
/// Flush at end of stream: mirror the tail
/// (`(min(history, filter_length) + 1) / 2` samples) and emit the
/// remaining output.  Must be called exactly once, after the last
/// `process`.
pub fn SwrResampler::flush(self : SwrResampler) -> Array[Array[Double]] {
  // Never primed (fewer than filter_length + 1 samples ever seen): the
  // C keeps waiting inside invert_initial_buffer forever, so even the
  // flush emits nothing.
  if !self.primed {
    return []
  }
  let hist_len = self.hist[0].length()
  let shorter = if hist_len < self.filter_length {
    hist_len
  } else {
    self.filter_length
  }
  let reflection = (shorter + 1) / 2
  for ch in 0..<self.hist.length() {
    for j in 0..<reflection {
      let h = self.hist[ch]
      h.push(h[hist_len - 1 - j])
    }
  }
  self.swr_resample_drain()
}

///|
/// One `multiple_resample` with unlimited out_count: the window bound
/// alone decides how many samples are computable, then the
/// resample_common / resample_linear float kernels run for every
/// channel in lockstep.
fn SwrResampler::swr_resample_drain(
  self : SwrResampler,
) -> Array[Array[Double]] {
  let pc = self.phase_count
  let fl = self.filter_length
  let alloc = self.filter_alloc
  let bank = self.filter_bank
  let hist_len = self.hist[0].length()
  let end_index : Int64 = (1L + hist_len.to_int64() - fl.to_int64()) *
    pc.to_int64()
  let delta_frac : Int64 = (end_index - self.index.to_int64()) *
    self.src_incr.to_int64() -
    self.frac.to_int64()
  let n_out = if delta_frac <= 0L {
    0
  } else {
    ((delta_frac + self.dst_incr.to_int64() - 1L) / self.dst_incr.to_int64()).to_int()
  }
  if n_out == 0 {
    // Normalized contract: always one (possibly empty) plane per channel.
    return Array::make(self.hist.length(), [])
  }
  let out : Array[Array[Float]] = Array::make(self.hist.length(), [])
  for ch in 0..<out.length() {
    out[ch] = Array::make(n_out, 0.0)
  }
  let mut index = self.index
  let mut frac = self.frac
  let mut sample_index = 0
  let use_linear = self.linear && (self.frac != 0 || self.dst_incr_mod != 0)
  for j in 0..<n_out {
    let base = index * alloc
    for ch in 0..<out.length() {
      let h = self.hist[ch]
      if use_linear {
        let mut val : Float = 0.0
        let mut v2 : Float = 0.0
        for i in 0..<fl {
          val = val + h[sample_index + i] * bank[base + i]
          v2 = v2 + h[sample_index + i] * bank[base + i + alloc]
        }
        let diff = (v2 - val).to_double() * self.inv_src_incr * frac.to_double()
        val = Float::from_double(val.to_double() + diff)
        out[ch][j] = val
      } else {
        let mut val : Float = 0.0
        let mut val2 : Float = 0.0
        let mut i = 0
        while i + 1 < fl {
          val = val + h[sample_index + i] * bank[base + i]
          val2 = val2 + h[sample_index + i + 1] * bank[base + i + 1]
          i = i + 2
        }
        if i < fl {
          val = val + h[sample_index + i] * bank[base + i]
        }
        out[ch][j] = val + val2
      }
    }
    frac = frac + self.dst_incr_mod
    index = index + self.dst_incr_div
    if frac >= self.src_incr {
      frac = frac - self.src_incr
      index = index + 1
    }
    while index >= pc {
      sample_index = sample_index + 1
      index = index - pc
    }
  }
  self.index = index
  self.frac = frac
  // Drop consumed history (mirror taps included) from the front.
  for ch in 0..<self.hist.length() {
    self.hist[ch] = self.hist[ch][sample_index:].to_owned()
  }
  let widened : Array[Array[Double]] = Array::make(out.length(), [])
  for ch in 0..<out.length() {
    widened[ch] = Array::make(n_out, 0.0)
    for j in 0..<n_out {
      widened[ch][j] = out[ch][j].to_double()
    }
  }
  widened
}

///|
/// One resampled float32 sample to s16 with the C FLTP->S16 output
/// conversion semantics: the scale product rounds in f32 first, then
/// `av_clip_int16(lrintf(..))`.
pub fn swr_f32_to_s16(y : Float) -> Int32 {
  swr_clip_int16(swr_lrintf((y * (32768.0 : Float)).to_double()))
}
