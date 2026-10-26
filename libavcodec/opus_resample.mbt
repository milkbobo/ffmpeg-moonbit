///|
/// MoonBit port of the libswresample float polyphase resampler used by the
/// FFmpeg 9.0.2 Opus decoder (`libswresample/resample.c`, `resample_template.c`
/// and the planar-float path of `swresample.c`), specialized to the exact
/// configuration `opus/dec.c` builds: AV_SAMPLE_FMT_FLTP in and out, mono or
/// stereo, out rate 48000 Hz, `filter_size` 16, `phase_shift` 10, Kaiser
/// window (beta 9), `linear_interp` on, `exact_rational` on, no async/PTS
/// handling, no dither, no rematrix and no compensation. All SILK sample
/// rates (8/12/16/24 kHz) upsample to 48 kHz through an exact rational ratio,
/// so `frac` and `dst_incr_mod` stay zero and only the common (non-linear)
/// resample kernel ever runs; the linear kernel is ported anyway for
/// completeness. Reference outputs must come from an assembly-free FFmpeg
/// build: the x86 resample kernels use FMA and produce different low float
/// bits than this scalar port. LGPL-2.1-or-later.

///|
/// sin(M_PI * ph / phase_count) for the `build_filter` sin_lut, one entry per
/// (phase_count, ph) pair actually reachable by the SILK upsamplers. The
/// arguments are computed exactly as in C (`M_PI * ph / phase_count`), and the
/// values are the glibc `sin` results, pinned by bit pattern in the white-box
/// test so WebAssembly's sine cannot shift a ulp.
let swr_sin_lut : FixedArray[FixedArray[Double]] = [
  // phase_count 2 (24 kHz): ph 0..1
  [0.0, 1.0],
  // phase_count 3 (16 kHz): ph 0..2
  [0.0, 0.8660254037844386, 0.8660254037844387],
  // phase_count 4 (12 kHz): ph 0..2
  [0.0, 0.7071067811865476, 1.0],
  // phase_count 6 (8 kHz): ph 0..3
  [0.0, 0.49999999999999994, 0.8660254037844386, 1.0],
]

///|
let swr_pi : Double = 3.14159265358979323846

///|
fn swr_sin(phase_count : Int32, ph : Int32) -> Double {
  let row = match phase_count {
    2 => 0
    3 => 1
    4 => 2
    6 => 3
    _ => abort("swr: missing sin_lut entry")
  }
  swr_sin_lut[row][ph]
}

///|
/// GCD reduction of an exact rational; `av_reduce` with a bound above the
/// exact value returns the same fully reduced fraction.
fn swr_reduce(num : Int32, den : Int32) -> (Int32, Int32) {
  let mut a = num
  let mut b = den
  while b != 0 {
    let t = a % b
    a = b
    b = t
  }
  if a > 1 {
    (num / a, den / a)
  } else {
    (num, den)
  }
}

///|
/// Planar float audio view: `chans[c]` is channel c's storage and `pos` the
/// current sample offset. Persistent buffers use the whole array; local
/// pointers advance `pos` exactly like the C pointer arithmetic.
priv struct AudioBuf {
  chans : Array[Array[Float]]
  mut pos : Int32
}

///|
fn AudioBuf::copy_from(self : AudioBuf, src : AudioBuf, count : Int32) -> Unit {
  for c in 0..<self.chans.length() {
    let dst = self.chans[c]
    let from = src.chans[c]
    for i in 0..<count {
      dst[self.pos + i] = from[src.pos + i]
    }
  }
}

///|
/// Grow every channel storage to hold at least `count` samples from offset 0,
/// preserving existing content (`swri_realloc_audio`).
fn AudioBuf::ensure(self : AudioBuf, count : Int32) -> Unit {
  for c in 0..<self.chans.length() {
    let old = self.chans[c]
    if old.length() < count {
      let grown : Array[Float] = []
      for i in 0..<(count * 2) {
        grown.push(if i < old.length() { old[i] } else { 0.0 })
      }
      self.chans[c] = grown
    }
  }
}

///|
priv struct SwrFilter {
  bank : FixedArray[Float]
  alloc : Int32
  filter_length : Int32
  phase_count : Int32
}

///|
/// The resampler context plus the `swr_convert` bookkeeping state
/// (`in_buffer`, `in_buffer_index/count`, `resample_in_constraint`,
/// `flushed`).
pub struct OpusResampler {
  priv mut filter : SwrFilter
  priv mut index : Int32
  priv mut frac : Int32
  priv mut src_incr : Int32
  priv mut dst_incr : Int32
  priv mut dst_incr_div : Int32
  priv mut dst_incr_mod : Int32
  priv channels : Int32
  priv out_sample_rate : Int32
  priv mut in_sample_rate : Int32
  priv in_buffer : AudioBuf
  priv mut in_buffer_index : Int32
  priv mut in_buffer_count : Int32
  priv mut in_constraint : Bool
  priv mut flushed : Bool
  priv mut opened : Bool
}

///|
/// Polyphase filter bank (`build_filter`): double-precision sinc with a
/// Kaiser window, normalized per phase 0, mirrored for even phase counts.
/// Only the Kaiser branch is implemented — FFmpeg's Opus decoder uses the
/// default `SWR_FILTER_TYPE_KAISER`.
fn swr_build_filter(
  factor : Double,
  tap_count : Int32,
  alloc : Int32,
  phase_count : Int32,
) -> SwrFilter {
  let bank : FixedArray[Float] = FixedArray::make(
    alloc * (phase_count + 2),
    0.0,
  )
  let ph_nb = if phase_count % 2 == 1 {
    phase_count
  } else {
    phase_count / 2 + 1
  }
  let center = (tap_count - 1) / 2
  let tab : FixedArray[Double] = FixedArray::make(tap_count + 1, 0.0)
  let mut norm = 0.0
  for ph in 0..<ph_nb {
    let mut s = swr_sin(phase_count, ph)
    for i in 0..<tap_count {
      let x = swr_pi *
        ((i - center).to_double() - ph.to_double() / phase_count.to_double()) *
        factor
      let mut y : Double = if x == 0.0 {
        1.0
      } else if factor == 1.0 {
        s / x
      } else {
        @math.sin(x) / x
      }
      let w = 2.0 * x / (factor * tap_count.to_double() * swr_pi)
      let clipped = if 1.0 - w * w > 0.0 { 1.0 - w * w } else { 0.0 }
      y *= @libavutil.av_bessel_i0(9.0 * clipped.sqrt())
      tab[i] = y
      s = -s
      if ph == 0 {
        norm += y
      }
    }
    for i in 0..<tap_count {
      bank[ph * alloc + i] = Float::from_double(tab[i] * 1.0 / norm)
    }
    if phase_count % 2 == 1 {
      continue
    }
    for i in 0..<tap_count {
      bank[(phase_count - ph) * alloc + (tap_count - 1 - i)] = bank[ph * alloc +
        i]
    }
  }
  // Wrap-around tail so the linear kernel can read filter rows shifted by
  // one input sample without extra branching.
  let base = alloc * phase_count
  for j in 0..<(alloc - 1) {
    bank[base + 1 + j] = bank[j]
  }
  bank[base] = bank[alloc - 1]
  { bank, alloc, filter_length: tap_count, phase_count, }
}

///|
/// Create the resampler with `opus/dec.c`'s option set: FLTP in/out,
/// 48 kHz output, filter_size 16, phase_shift 10, Kaiser beta 9,
/// linear_interp on, exact_rational on.
pub fn OpusResampler::new(
  channels : Int32,
  out_sample_rate : Int32,
) -> OpusResampler {
  let chans : Array[Array[Float]] = []
  for _ in 0..<channels {
    chans.push([])
  }
  {
    filter: {
      bank: FixedArray::make(1, 0.0),
      alloc: 0,
      filter_length: 0,
      phase_count: 0,
    },
    index: 0,
    frac: 0,
    src_incr: 1,
    dst_incr: 1,
    dst_incr_div: 0,
    dst_incr_mod: 0,
    channels,
    out_sample_rate,
    in_sample_rate: 0,
    in_buffer: { chans, pos: 0, },
    in_buffer_index: 0,
    in_buffer_count: 0,
    in_constraint: false,
    flushed: false,
    opened: false,
  }
}

///|
/// Set the input sample rate and (re)initialize, matching
/// `av_opt_set_int(swr, "in_sample_rate", ...)` + `swr_init` +
/// `resample_init`: the filter bank is only rebuilt when the ratio changes,
/// while `index`/`frac` and all buffer state reset on every call.
pub fn OpusResampler::open(
  self : OpusResampler,
  in_sample_rate : Int32,
) -> Unit {
  let phase_shift = 10
  let filter_size = 16
  let cutoff = 0.97
  let mut factor = self.out_sample_rate.to_double() *
    cutoff /
    in_sample_rate.to_double()
  if factor > 1.0 {
    factor = 1.0
  }
  let mut phase_count = 1 << phase_shift
  // exact_rational: replace the phase count with the exact reduced ratio
  // whenever it fits below the power-of-two phase count.
  let (num, _den) = swr_reduce(self.out_sample_rate, in_sample_rate)
  if num > 0 && num <= phase_count {
    phase_count = num
  }
  let mut filter_length = Float::from_double(filter_size.to_double() / factor)
    .ceil()
    .to_int()
  if filter_length < 1 {
    filter_length = 1
  }
  if filter_length > 1 && filter_length % 2 == 1 {
    filter_length += 1
  }
  let alloc = if filter_length % 8 == 0 {
    filter_length
  } else {
    filter_length + 8 - filter_length % 8
  }
  if self.filter.phase_count != phase_count ||
    self.filter.filter_length != filter_length {
    self.filter = swr_build_filter(factor, filter_length, alloc, phase_count)
  }
  let (src_incr, dst_incr) = swr_reduce(
    self.out_sample_rate,
    in_sample_rate * phase_count,
  )
  let mut src = src_incr
  let mut dst = dst_incr
  while dst < 1 << 20 && src < 1 << 20 {
    dst *= 2
    src *= 2
  }
  self.src_incr = src
  self.dst_incr = dst
  self.dst_incr_div = dst / src
  self.dst_incr_mod = dst % src
  self.index = -phase_count * ((filter_length - 1) / 2)
  self.frac = 0
  self.in_sample_rate = in_sample_rate
  self.in_buffer_index = 0
  self.in_buffer_count = 0
  self.in_constraint = false
  self.flushed = false
  self.opened = true
}

///|
/// `swr_close`: drop buffered samples and reset conversion state; the filter
/// bank survives for reuse at the same ratio.
pub fn OpusResampler::close(self : OpusResampler) -> Unit {
  self.in_buffer_index = 0
  self.in_buffer_count = 0
  self.in_constraint = false
  self.flushed = false
  self.opened = false
}

///|
/// `swr_is_initialized`.
pub fn OpusResampler::is_opened(self : OpusResampler) -> Bool {
  self.opened
}

///|
/// Current input sample rate (read by the Opus orchestration to detect
/// rate changes that require a resampler flush).
pub fn OpusResampler::in_rate(self : OpusResampler) -> Int32 {
  self.in_sample_rate
}

///|
/// `invert_initial_buffer`: while the filter index is negative, mirror the
/// start of the input into the front of `in_buffer` so the filter has
/// history, then normalize `index` to non-negative. Returns
/// (skip, in_buffer_index, in_buffer_count); skip = 0 means nothing to do,
/// -1 means more input is needed first.
fn OpusResampler::invert_initial_buffer(
  self : OpusResampler,
  src : AudioBuf,
  in_count : Int32,
) -> (Int32, Int32, Int32) {
  let filter_length = self.filter.filter_length
  if self.index >= 0 {
    return (0, self.in_buffer_index, self.in_buffer_count)
  }
  let mut out_idx = self.in_buffer_index
  let mut out_sz = self.in_buffer_count
  let num = if in_count + out_sz < filter_length + 1 {
    in_count + out_sz
  } else {
    filter_length + 1
  }
  self.in_buffer.ensure(filter_length * 2 + 1)
  for n in out_sz..<num {
    for c in 0..<self.channels {
      self.in_buffer.chans[c][filter_length + n] = src.chans[c][src.pos +
        n -
        out_sz]
    }
  }
  if num < filter_length + 1 {
    out_sz = num
    out_idx = filter_length
    self.in_buffer_index = out_idx
    self.in_buffer_count = out_sz
    return (-1, out_idx, out_sz)
  }
  for n in 1..<=filter_length {
    for c in 0..<self.channels {
      self.in_buffer.chans[c][filter_length - n] = self.in_buffer.chans[c][filter_length +
        n]
    }
  }
  let res = num - out_sz
  out_idx = filter_length
  while self.index < 0 {
    out_idx -= 1
    self.index += self.filter.phase_count
  }
  let bound = if out_sz + filter_length > 1 + filter_length * 2 {
    out_sz + filter_length
  } else {
    1 + filter_length * 2
  }
  out_sz = bound - out_idx
  self.in_buffer_index = out_idx
  self.in_buffer_count = out_sz
  (if res > 0 { res } else { 0 }, out_idx, out_sz)
}

///|
/// `resample_flush`: reflect the buffer tail so a flush can produce the
/// remaining filtered samples.
fn OpusResampler::flush_buffer(self : OpusResampler) -> Unit {
  let filter_length = self.filter.filter_length
  let head = if self.in_buffer_count < filter_length {
    self.in_buffer_count
  } else {
    filter_length
  }
  let reflection = (head + 1) / 2
  self.in_buffer.ensure(
    self.in_buffer_index + self.in_buffer_count + reflection,
  )
  for c in 0..<self.channels {
    let buf = self.in_buffer.chans[c]
    let end = self.in_buffer_index + self.in_buffer_count
    for j in 0..<reflection {
      buf[end + j] = buf[end - j - 1]
    }
  }
  self.in_buffer_count += reflection
}

///|
/// Float `resample_common` for one channel: even/odd tap pair accumulation,
/// exactly the C template's two-accumulator structure. Takes the context's
/// raw `index`/`frac`, normalizes on entry like the C, and returns
/// (consumed input samples, final index, final frac) without committing.
fn OpusResampler::resample_channel_common(
  self : OpusResampler,
  dst : Array[Float],
  dst_pos : Int32,
  src : Array[Float],
  src_pos : Int32,
  sample_index_ : Int32,
  index_ : Int32,
  frac_ : Int32,
  n : Int32,
) -> (Int32, Int32, Int32) {
  let bank = self.filter.bank
  let alloc = self.filter.alloc
  let phase_count = self.filter.phase_count
  let filter_length = self.filter.filter_length
  let mut sample_index = sample_index_
  let mut index = index_
  let mut frac = frac_
  while index >= phase_count {
    sample_index += 1
    index -= phase_count
  }
  for dst_index in 0..<n {
    let filter = alloc * index
    let base = src_pos + sample_index
    let mut val : Float = 0.0
    let mut val2 : Float = 0.0
    let mut i = 0
    while i + 1 < filter_length {
      val += src[base + i] * bank[filter + i]
      val2 += src[base + i + 1] * bank[filter + i + 1]
      i += 2
    }
    if i < filter_length {
      val += src[base + i] * bank[filter + i]
    }
    dst[dst_pos + dst_index] = val + val2
    frac += self.dst_incr_mod
    index += self.dst_incr_div
    if frac >= self.src_incr {
      frac -= self.src_incr
      index += 1
    }
    while index >= phase_count {
      sample_index += 1
      index -= phase_count
    }
  }
  (sample_index, index, frac)
}

///|
/// Float `resample_linear` for one channel (fractional phase interpolation).
/// Dead code for the SILK exact-rational ratios but kept so non-exact rates
/// stay correct.
fn OpusResampler::resample_channel_linear(
  self : OpusResampler,
  dst : Array[Float],
  dst_pos : Int32,
  src : Array[Float],
  src_pos : Int32,
  sample_index_ : Int32,
  index_ : Int32,
  frac_ : Int32,
  n : Int32,
) -> (Int32, Int32, Int32) {
  let bank = self.filter.bank
  let alloc = self.filter.alloc
  let phase_count = self.filter.phase_count
  let filter_length = self.filter.filter_length
  let mut sample_index = sample_index_
  let mut index = index_
  let mut frac = frac_
  let inv_src_incr = 1.0 / self.src_incr.to_double()
  while index >= phase_count {
    sample_index += 1
    index -= phase_count
  }
  for dst_index in 0..<n {
    let filter = alloc * index
    let base = src_pos + sample_index
    let mut val : Float = 0.0
    let mut v2 : Float = 0.0
    for i in 0..<filter_length {
      val += src[base + i] * bank[filter + i]
      v2 += src[base + i] * bank[filter + i + alloc]
    }
    val += Float::from_double(
      (v2 - val).to_double() * inv_src_incr * frac.to_double(),
    )
    dst[dst_pos + dst_index] = val
    frac += self.dst_incr_mod
    index += self.dst_incr_div
    if frac >= self.src_incr {
      frac -= self.src_incr
      index += 1
    }
    while index >= phase_count {
      sample_index += 1
      index -= phase_count
    }
  }
  (sample_index, index, frac)
}

///|
/// `multiple_resample`: produce up to `dst_size` outputs from `src_size`
/// input samples, honoring the filter window constraint. Returns (outputs
/// produced, input samples consumed); `index`/`frac` commit after the last
/// channel, matching the C's `update_ctx` on the final channel.
fn OpusResampler::multiple_resample(
  self : OpusResampler,
  dst : AudioBuf,
  dst_size : Int32,
  src : AudioBuf,
  src_size : Int32,
) -> (Int32, Int32) {
  let end_index = (1 + src_size - self.filter.filter_length) *
    self.filter.phase_count
  let delta_frac : Int64 = (end_index - self.index).to_int64() *
    self.src_incr.to_int64() -
    self.frac.to_int64()
  let delta_n = ((delta_frac + self.dst_incr.to_int64() - 1L) /
  self.dst_incr.to_int64()).to_int()
  let mut size = if dst_size < delta_n { dst_size } else { delta_n }
  if size < 0 {
    size = 0
  }
  let mut consumed = 0
  if size > 0 {
    let linear = self.frac != 0 || self.dst_incr_mod != 0
    for c in 0..<self.channels {
      let result = if linear {
        self.resample_channel_linear(
          dst.chans[c],
          dst.pos,
          src.chans[c],
          src.pos,
          0,
          self.index,
          self.frac,
          size,
        )
      } else {
        self.resample_channel_common(
          dst.chans[c],
          dst.pos,
          src.chans[c],
          src.pos,
          0,
          self.index,
          self.frac,
          size,
        )
      }
      let (used, final_index, final_frac) = result
      consumed = used
      if c == self.channels - 1 {
        self.index = final_index
        self.frac = final_frac
      }
    }
  }
  (size, consumed)
}

///|
/// The `resample()` driver from `swresample.c`: invert the initial buffer,
/// then alternate between consuming buffered samples and the direct path,
/// refilling `in_buffer` with what remains. `padless` is 7 for the x86
/// reference build.
fn OpusResampler::resample(
  self : OpusResampler,
  out : AudioBuf,
  out_count : Int32,
  in_ : AudioBuf,
  in_count_ : Int32,
) -> Int32 {
  let mut out_count = out_count
  let mut ret_sum = 0
  let mut border = 0
  let mut padless = 7
  let in_buf = AudioBuf::{ chans: in_.chans, pos: in_.pos, }
  let mut in_count = in_count_
  let out_view = AudioBuf::{ chans: out.chans, pos: out.pos, }
  let tmp = AudioBuf::{ chans: self.in_buffer.chans, pos: 0, }
  let (skip, idx, cnt) = self.invert_initial_buffer(in_buf, in_count)
  self.in_buffer_index = idx
  self.in_buffer_count = cnt
  if skip == -1 {
    return 0
  } else if skip > 0 {
    in_buf.pos += skip
    in_count -= skip
    self.in_constraint = false
  }
  for ;; {
    if !self.in_constraint && self.in_buffer_count > 0 {
      tmp.pos = self.in_buffer_index
      let out_here = AudioBuf::{ chans: out_view.chans, pos: out_view.pos, }
      let (ret, consumed) = self.multiple_resample(
        out_here,
        out_count,
        tmp,
        self.in_buffer_count,
      )
      out_count -= ret
      ret_sum += ret
      out_view.pos += ret
      self.in_buffer_count -= consumed
      self.in_buffer_index += consumed
      if in_count == 0 {
        break
      }
      if self.in_buffer_count <= border {
        in_buf.pos -= self.in_buffer_count
        in_count += self.in_buffer_count
        self.in_buffer_count = 0
        self.in_buffer_index = 0
        border = 0
      }
    }
    if (self.flushed || in_count > padless) && self.in_buffer_count == 0 {
      self.in_buffer_index = 0
      let out_here = AudioBuf::{ chans: out_view.chans, pos: out_view.pos, }
      let avail = if in_count - padless > 0 { in_count - padless } else { 0 }
      let (ret, consumed) = self.multiple_resample(
        out_here, out_count, in_buf, avail,
      )
      out_count -= ret
      ret_sum += ret
      out_view.pos += ret
      in_count -= consumed
      in_buf.pos += consumed
    }
    let size = self.in_buffer_index + self.in_buffer_count + in_count
    if size > self.in_buffer.chans[0].length() &&
      self.in_buffer_count + in_count <= self.in_buffer_index {
      tmp.pos = self.in_buffer_index
      self.in_buffer.copy_from(tmp, self.in_buffer_count)
      self.in_buffer_index = 0
    } else {
      self.in_buffer.ensure(size)
    }
    if in_count > 0 {
      let mut count = in_count
      if self.in_buffer_count > 0 &&
        self.in_buffer_count + 2 < count &&
        out_count > 0 {
        count = self.in_buffer_count + 2
      }
      tmp.pos = self.in_buffer_index + self.in_buffer_count
      for c in 0..<self.channels {
        let dst_arr = self.in_buffer.chans[c]
        let src_arr = in_buf.chans[c]
        for i in 0..<count {
          dst_arr[tmp.pos + i] = src_arr[in_buf.pos + i]
        }
      }
      self.in_buffer_count += count
      in_count -= count
      border += count
      in_buf.pos += count
      self.in_constraint = false
      if self.in_buffer_count != count || in_count > 0 {
        continue
      }
      if padless > 0 {
        padless = 0
        continue
      }
    }
    break
  }
  self.in_constraint = out_count > 0
  ret_sum
}

///|
/// `swr_convert`: feed `in_count` input samples and pull up to `out_count`
/// output samples, or flush with `in_ = None`. Returns samples written per
/// channel. Package-private: `AudioBuf` views are an implementation detail
/// consumed by the Opus packet orchestration in this package.
fn OpusResampler::convert(
  self : OpusResampler,
  out : AudioBuf,
  out_count : Int32,
  in_ : AudioBuf?,
  in_count : Int32,
) -> Int32 {
  if !self.opened {
    abort("swr: resampler not initialized")
  }
  match in_ {
    None => {
      if !self.flushed {
        self.flush_buffer()
      }
      self.in_constraint = false
      self.flushed = true
      self.resample(out, out_count, AudioBuf::{ chans: out.chans, pos: 0, }, 0)
    }
    Some(data) => self.resample(out, out_count, data, in_count)
  }
}
