/// MoonBit port of FFmpeg 9.0.2 `opus/enc_psy.c` (encoder psychoacoustics):
/// per-step analysis (windowed 20 ms MDCT, band energies/tonality, excitation
/// tracking through the dumped Bessel filters), transient inflection points,
/// frame-size grouping. The Bessel filter coefficients are the dumped
/// outputs of `bessel_init` (they involve `tanf`); every runtime operation is
/// plain float math.

///|
/// One analysis step (`OpusPsyStep`).
priv struct OpusEncPsyStep {
  mut silence : Int
  energy : Array[Float]
  tone : Array[Float]
  stereo : Array[Float]
  change_amp : Array[Float]
  mut total_change : Float
  coeffs : Array[Array[Float]]
}

///|
fn OpusEncPsyStep::new() -> OpusEncPsyStep {
  let coeffs : Array[Array[Float]] = []
  for _c in 0..<2 {
    coeffs.push(Array::make(960, 0.0))
  }
  {
    silence: 0,
    energy: Array::make(42, 0.0),
    tone: Array::make(42, 0.0),
    stereo: Array::make(21, 0.0),
    change_amp: Array::make(42, 0.0),
    total_change: 0.0,
    coeffs,
  }
}

///|
/// `OpusBandExcitation` + the two Bessel filters per (channel, band).
priv struct OpusEncExcitation {
  mut excitation : Float
  mut excitation_dist : Float
  mut excitation_init : Float
}

///|
priv struct OpusEncBessel {
  a : Array[Float]
  b : Array[Float]
  x : Array[Float]
  y : Array[Float]
}

///|
/// Build the hi-pass filter for (ch, band) from the flat dumped table.
/// Layout: (ch*21 + band)*10 + [hi a0 a1 a2 b0 b1 | lo a0 a1 a2 b0 b1].
fn opus_enc_bessel_hi(ch : Int, band : Int) -> OpusEncBessel {
  let o = (ch * 21 + band) * 10
  {
    a: [
      opus_enc_bessel_coeffs[o],
      opus_enc_bessel_coeffs[o + 1],
      opus_enc_bessel_coeffs[o + 2],
    ],
    b: [opus_enc_bessel_coeffs[o + 3], opus_enc_bessel_coeffs[o + 4]],
    x: Array::make(3, 0.0),
    y: Array::make(3, 0.0),
  }
}

///|
fn opus_enc_bessel_lo(ch : Int, band : Int) -> OpusEncBessel {
  let o = (ch * 21 + band) * 10 + 5
  {
    a: [
      opus_enc_bessel_coeffs[o],
      opus_enc_bessel_coeffs[o + 1],
      opus_enc_bessel_coeffs[o + 2],
    ],
    b: [opus_enc_bessel_coeffs[o + 3], opus_enc_bessel_coeffs[o + 4]],
    x: Array::make(3, 0.0),
    y: Array::make(3, 0.0),
  }
}

///|
fn OpusEncBessel::filter(self : OpusEncBessel, x0 : Float) -> Float {
  self.x[2] = self.x[1]
  self.x[1] = self.x[0]
  self.x[0] = x0
  self.y[2] = self.y[1]
  self.y[1] = self.y[0]
  let t0 = self.a[0] * self.x[0]
  let t1 = self.a[1] * self.x[1]
  let t2 = self.a[2] * self.x[2]
  let t3 = self.b[0] * self.y[1]
  let t4 = self.b[1] * self.y[2]
  let acc = t0 + t1 + t2 + t3 + t4
  self.y[0] = acc
  acc
}

///|
/// Psychoacoustic context (`OpusPsyContext`). The default 360 ms lookahead
/// (`OPUS_MAX_LOOKAHEAD = 144 * 2.5`) with a 960-sample frame gives
/// `max_steps = 18`: steps buffer until the ring is full, then each call
/// decides one packet.
struct OpusEncPsy {
  steps : Array[OpusEncPsyStep]
  mut buffered_steps : Int
  mut steps_to_process : Int
  mut eof : Int
  max_steps : Int
  ex : Array[OpusEncExcitation]
  bfilter_lo : Array[OpusEncBessel]
  bfilter_hi : Array[OpusEncBessel]
  scratch : Array[Float]
  mut lambda : Float
  inflection_points : Array[Int]
  mut inflection_points_count : Int
  mut p_frames : Int
  mut p_framesize : Int
  mut avg_is_band : Float
  mut bit_rate_f : Float
}

///|
/// `OPUS_MAX_LOOKAHEAD` (enc.h): `(FF_BUFQUEUE_SIZE - 1) * 2.5` ms.
let opus_enc_max_lookahead : Float = 360.0

///|
fn OpusEncPsy::new(channels : Int) -> OpusEncPsy {
  // ceilf(max_delay_ms * sample_rate / (1000 * frame_size)), the C defaults
  let max_steps = ((opus_enc_max_lookahead * 48000.0) / (1000.0 * 960.0))
    .to_double().ceil().to_int()
  let steps : Array[OpusEncPsyStep] = []
  for _i in 0..<max_steps {
    steps.push(OpusEncPsyStep::new())
  }
  let ex : Array[OpusEncExcitation] = []
  let lo : Array[OpusEncBessel] = []
  let hi : Array[OpusEncBessel] = []
  for ch in 0..<channels {
    for band in 0..<21 {
      ex.push({ excitation: 0.0, excitation_dist: 0.0, excitation_init: 0.0 })
      lo.push(opus_enc_bessel_lo(ch, band))
      hi.push(opus_enc_bessel_hi(ch, band))
    }
  }
  {
    steps,
    buffered_steps: 0,
    steps_to_process: 0,
    eof: 0,
    max_steps,
    ex,
    bfilter_lo: lo,
    bfilter_hi: hi,
    scratch: Array::make(1920, 0.0),
    lambda: 1.0,
    inflection_points: Array::make(max_steps, 0),
    inflection_points_count: 0,
    p_frames: 1,
    p_framesize: 3,
    avg_is_band: 20.0,
    bit_rate_f: 0.0,
  }
}

///|
/// `step_collect_psy_metrics` for the single-buffered step (frame_size 960
/// means one bufqueue entry fills the whole analysis window).
fn OpusEncPsy::collect_step(
  self : OpusEncPsy,
  index : Int,
  bufqueue : Array[OpusEncPcmFrame],
  channels : Int,
) -> Unit {
  let st = self.steps[index]
  let half = 960
  for ch in 0..<channels {
    for i in 0..<(half << 1) {
      self.scratch[i] = 0.0
    }
    // C copies `steps_per_half` entries below the analysis point and
    // `steps_per_half` at/after it. With frame_size 960 that is exactly two
    // bufqueue entries: `bufqueue[index]` (the preceding frame, used as the
    // left half/overlap) and `bufqueue[index + 1]` (the frame being analysed).
    if index < bufqueue.length() {
      let cur = bufqueue[index]
      let n = cur.nb_samples.min(half)
      for i in 0..<n {
        self.scratch[i] = cur.data[ch][i]
      }
    }
    if index + 1 < bufqueue.length() {
      let cur = bufqueue[index + 1]
      let n = cur.nb_samples.min(half)
      for i in 0..<n {
        self.scratch[half + i] = cur.data[ch][i]
      }
    }
    for i in 0..<(half << 1) {
      self.scratch[i] = self.scratch[i] * opus_enc_psy_window_3[i]
    }
    opus_enc_mdct_fwd(st.coeffs[ch], 0, self.scratch, 960, 68.0, 1)
  }
  for ch in 0..<channels {
    for i in 0..<21 {
      let mut energy : Float = 0.0
      let mut dist_dev : Float = 0.0
      let range = opus_celt_freq_range[i] << 3
      let off = opus_celt_freq_bands[i] << 3
      for j in 0..<range {
        let c = st.coeffs[ch][off + j]
        energy += c * c
      }
      let e_sqrt = Float::from_double(energy.to_double().sqrt())
      st.energy[ch * 21 + i] = st.energy[ch * 21 + i] + e_sqrt
      let avg_c_s : Float = energy / Float::from_int(range)
      for j in 0..<range {
        let c_s = st.coeffs[ch][off + j] * st.coeffs[ch][off + j]
        let d = avg_c_s - c_s
        dist_dev += d * d
      }
      let t_sqrt = Float::from_double(dist_dev.to_double().sqrt())
      st.tone[ch * 21 + i] = st.tone[ch * 21 + i] + t_sqrt
    }
  }
  if channels > 1 {
    for i in 0..<21 {
      let mut incompat : Float = 0.0
      let range = opus_celt_freq_range[i] << 3
      let off = opus_celt_freq_bands[i] << 3
      for j in 0..<range {
        let d = st.coeffs[0][off + j] - st.coeffs[1][off + j]
        incompat += d * d
      }
      st.stereo[i] = Float::from_double(incompat.to_double().sqrt())
    }
  }
  for ch in 0..<channels {
    for i in 0..<21 {
      let idx = ch * 21 + i
      let ex = self.ex[idx]
      let bp1 = self.bfilter_lo[idx].filter(st.energy[idx])
      let bp2 = self.bfilter_hi[idx].filter(bp1)
      let bp_e = bp2 * bp2
      if bp_e > ex.excitation {
        st.change_amp[idx] = bp_e - ex.excitation
        st.total_change = st.total_change + st.change_amp[idx]
        ex.excitation = bp_e
        ex.excitation_init = bp_e
        ex.excitation_dist = 0.0
      }
      if ex.excitation > 0.0 {
        let one : Float = 1.0
        let decay = one / opus_enc_expf(ex.excitation_dist)
        let lo = ex.excitation_init / 20.0
        let hi = ex.excitation_init / 1.09
        let clipped = if decay < lo {
          lo
        } else if decay > hi {
          hi
        } else {
          decay
        }
        ex.excitation = ex.excitation - clipped
        if ex.excitation < 0.0 {
          ex.excitation = 0.0
        }
        ex.excitation_dist = ex.excitation_dist + 1.0
      }
    }
  }
  // silence: no channel has any energy in this step
  let mut any = 0
  for ch in 0..<channels {
    for i in 0..<21 {
      if st.energy[ch * 21 + i] != 0.0 {
        any = 1
      }
    }
  }
  st.silence = if any != 0 { 0 } else { 1 }
}

///|
/// `search_for_change_points` (recursive, resolution 1).
fn OpusEncPsy::search_change_points(
  self : OpusEncPsy,
  tgt_change : Float,
  offset_s : Int,
  offset_e : Int,
  resolution : Int,
  level : Int,
) -> Unit {
  if offset_e - offset_s <= resolution {
    return
  }
  let mut c_change : Float = 0.0
  let mut i = offset_s
  while i < offset_e {
    c_change += self.steps[i].total_change
    if c_change > tgt_change {
      break
    }
    i += 1
  }
  if i == offset_e {
    return
  }
  self.search_change_points(tgt_change / 2.0, offset_s, i, resolution, level + 1)
  self.inflection_points[self.inflection_points_count] = i
  self.inflection_points_count += 1
  self.search_change_points(tgt_change / 2.0, i + 1, offset_e, resolution, level + 1)
}

///|
/// `flush_silent_frames` + `psy_output_groups`.
fn OpusEncPsy::output_groups(self : OpusEncPsy) -> Unit {
  self.p_frames = 1
  self.p_framesize = 3
  if self.steps[0].silence == 1 {
    let step_samples = 960
    let mut silent = 0
    while silent < self.buffered_steps {
      if self.steps[silent].silence == 0 {
        break
      }
      silent += 1
    }
    silent -= 1
    if silent >= 0 {
      let mut fsize = 3
      while fsize > 0 {
        let packet_samples = 2 * 15 * (1 << (fsize + 2))
        let steps_per_packet = packet_samples / step_samples
        if steps_per_packet >= 1 && silent >= steps_per_packet {
          let frames = (silent / steps_per_packet).min(5760 / packet_samples)
          self.p_frames = frames
          self.p_framesize = fsize
          return
        }
        fsize -= 1
      }
    }
  }
}

///|
/// `ff_opus_psy_process`: returns true when the caller should wait (more
/// buffering needed), false when a packet decision is ready in p_*.
fn OpusEncPsy::process(
  self : OpusEncPsy,
  bufqueue : Array[OpusEncPcmFrame],
  channels : Int,
) -> Bool {
  if self.buffered_steps < self.max_steps && self.eof == 0 {
    // awin = OPUS_BLOCK_SIZE(bsize_analysis) / frame_size = 960/960 = 1:
    // one bufqueue entry fills the analysis half-window
    let awin = 1
    self.steps_to_process += 1
    if self.steps_to_process >= awin {
      self.collect_step(self.buffered_steps - awin + 1, bufqueue, channels)
      self.steps_to_process = 0
    }
    self.buffered_steps += 1
    if self.buffered_steps < self.max_steps {
      return true
    }
  }
  let mut total_change : Float = 0.0
  for i in 0..<self.buffered_steps {
    total_change += self.steps[i].total_change
  }
  self.inflection_points_count = 0
  self.search_change_points(total_change / 2.0, 0, self.buffered_steps, 1, 0)
  self.output_groups()
  false
}
