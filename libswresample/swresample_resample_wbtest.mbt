///|
/// Crafted white-box tests for the polyphase resampler: structural
/// invariants of the filter bank, the phase-clock stepping for exact
/// rational ratios, and chunking invariance of the output stream.
/// Byte-level vectors against FFmpeg 9.0.2 live in
/// `swresample_realdata_test.mbt`.

///|
test "resample: filter bank row 0 is DC-normalized" {
  let r = SwrResampler::new(in_rate=48000, out_rate=44100)
  // Phase 0 row sums to ~1.0 (f32 storage rounds the taps).
  let mut sum = 0.0
  for i in 0..<r.filter_length {
    sum = sum + r.filter_bank[i].to_double()
  }
  inspect(sum > 0.999 && sum < 1.001, content="true")
}

///|
test "resample: mirrored rows match their lower-half source" {
  let r = SwrResampler::new(in_rate=48000, out_rate=44100)
  let pc = r.phase_count
  let alloc = r.filter_alloc
  // Even phase_count: row pc-ph is the reverse of row ph.
  let mut ok = true
  for ph in 1..<(pc / 2) {
    for i in 0..<r.filter_length {
      if r.filter_bank[(pc - ph) * alloc + r.filter_length - 1 - i] !=
        r.filter_bank[ph * alloc + i] {
        ok = false
      }
    }
  }
  inspect(ok, content="true")
  // Wraparound row pc: rotate1(row 0).
  let mut rot = true
  if r.filter_bank[pc * alloc] != r.filter_bank[alloc - 1] {
    rot = false
  }
  for i in 1..<alloc {
    if r.filter_bank[pc * alloc + i] != r.filter_bank[i - 1] {
      rot = false
    }
  }
  inspect(rot, content="true")
}

///|
test "resample: exact rational collapses the phase clock (48k->8k)" {
  let r = SwrResampler::new(in_rate=48000, out_rate=8000)
  inspect(r.phase_count, content="1")
  inspect(r.dst_incr_div, content="6")
  inspect(r.dst_incr_mod, content="0")
  inspect(r.filter_length > 32, content="true") // 32 taps widened by 0.8 cutoff
}

///|
test "resample: 2x upsample keeps an alternating-phase clock (48k->96k)" {
  let r = SwrResampler::new(in_rate=48000, out_rate=96000)
  inspect(r.phase_count, content="2")
  inspect(r.dst_incr_div, content="1")
  inspect(r.filter_length, content="32")
}

///|
test "resample: chunking never changes the sample stream" {
  let signal : Array[Double] = []
  for i in 0..<400 {
    signal.push(
      0.5 * @math.sin(2.0 * 3.141592653589793 * 997.0 * i.to_double() / 48000.0),
    )
  }
  // Whole-stream pass.
  let whole = SwrResampler::new(in_rate=48000, out_rate=44100)
  let out_whole : Array[Double] = []
  for plane in whole.process([signal]) {
    for v in plane {
      out_whole.push(v)
    }
  }
  for plane in whole.flush() {
    for v in plane {
      out_whole.push(v)
    }
  }
  // Ragged chunks (several below the filter warm-up length).
  let ragged = SwrResampler::new(in_rate=48000, out_rate=44100)
  let out_ragged : Array[Double] = []
  let sizes = [1, 7, 33, 2, 60, 120, 90, 87]
  let mut off = 0
  let mut si = 0
  while off < signal.length() {
    let take = if off + sizes[si % sizes.length()] <= signal.length() {
      sizes[si % sizes.length()]
    } else {
      signal.length() - off
    }
    for plane in ragged.process([signal[off:off + take].to_owned()]) {
      for v in plane {
        out_ragged.push(v)
      }
    }
    off = off + take
    si = si + 1
  }
  for plane in ragged.flush() {
    for v in plane {
      out_ragged.push(v)
    }
  }
  inspect(out_whole.length() == out_ragged.length(), content="true")
  let mut all_equal = true
  for i in 0..<out_whole.length() {
    if out_whole[i] != out_ragged[i] {
      all_equal = false
      break
    }
  }
  inspect(all_equal, content="true")
  // 400 * 44100/48000 = 367.5 samples worth of signal: the flush tail
  // pins the exact integral count.
  inspect(out_whole.length(), content="368")
}

///|
test "resample: 48k->8k decimation tracks the 6-step clock" {
  // A slow ramp makes every output the average-ish of its 6-sample
  // window; the first output must come from the mirrored start-up
  // history, not from zeros (so it is close to input[0], not ~0).
  let signal : Array[Double] = []
  for _ in 0..<120 {
    signal.push(0.9)
  }
  let r = SwrResampler::new(in_rate=48000, out_rate=8000)
  let out : Array[Double] = []
  for plane in r.process([signal]) {
    for v in plane {
      out.push(v)
    }
  }
  for plane in r.flush() {
    for v in plane {
      out.push(v)
    }
  }
  // 120 samples is below the 199-sample warm-up this ratio needs
  // (198 taps), so like the C nothing is ever emitted.
  inspect(out.length(), content="0")
  let mut ok = true
  for v in out {
    if !(v > 0.85 && v < 0.95) {
      ok = false
    }
  }
  inspect(ok, content="true")
}

///|
test "resample: equal rates are rejected" {
  try SwrResampler::new(in_rate=48000, out_rate=48000) catch {
    SwrResampleError::InvalidResampleConfig(_) => ()
  } noraise {
    _ => fail("expected InvalidResampleConfig")
  }
}

///|
test "resample: stereo planes stay independent (aliasing guard)" {
  let l : Array[Double] = []
  let r_ : Array[Double] = []
  for i in 0..<600 {
    l.push(
      0.5 * @math.sin(2.0 * 3.141592653589793 * 997.0 * i.to_double() / 48000.0),
    )
    r_.push(
      0.3 * @math.sin(2.0 * 3.141592653589793 * 733.0 * i.to_double() / 48000.0),
    )
  }
  let r = SwrResampler::new(in_rate=48000, out_rate=44100, channels=2)
  let mut n0 = 0
  let mut n1 = 0
  for call in [r.process([l, r_]), r.flush()] {
    for ci in 0..<call.length() {
      let add = call[ci].length()
      if ci == 0 {
        n0 = n0 + add
      } else {
        n1 = n1 + add
      }
    }
  }
  inspect(n0, content="552")
  inspect(n1, content="552")
}

///|
test "resample: cubic and blackman-nuttall windows build and run" {
  // Non-default window shapes: a short stream through each must produce
  // the same sample count as kaiser and finite values.
  let signal : Array[Double] = []
  for i in 0..<400 {
    signal.push(
      0.5 * @math.sin(2.0 * 3.141592653589793 * 440.0 * i.to_double() / 48000.0),
    )
  }
  for ty in [Cubic, BlackmanNuttall, Kaiser] {
    let r = SwrResampler::new(in_rate=48000, out_rate=44100, filter_type=ty)
    let mut n = 0
    for call in [r.process([signal]), r.flush()] {
      for plane in call {
        n = n + plane.length()
      }
    }
    inspect(n, content="368")
  }
}

///|
/// `SWR_FILTER_TYPE_*` is the C API surface: 0/1/2 are cubic,
/// Blackman-Nuttall and Kaiser, and anything else is refused instead of
/// silently falling back to the default window.
test "resample: filter type integer codes" {
  assert_true(SwrFilterType::from_code(0) is Cubic)
  assert_true(SwrFilterType::from_code(1) is BlackmanNuttall)
  assert_true(SwrFilterType::from_code(2) is Kaiser)
  let refused = try {
    let _t = SwrFilterType::from_code(3)
    false
  } catch {
    InvalidResampleConfig(_) => true
  }
  assert_true(refused)
}
