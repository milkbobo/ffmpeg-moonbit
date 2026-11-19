///|
/// `§458` constant rate factor for the HEVC encoder (x265 `--crf` semantics,
/// model shared with the H.264 encoder's `§435`): quality-driven per-picture
/// QPs. The CRF value is the baseline QP (`round(crf)`); every later
/// picture's QP bends around it by its temporal complexity — the luma SAD
/// against the previous display frame, subsampled to every other row and
/// sample — relative to the running mean of the samples seen so far:
///
/// ```text
/// qp_i = round(base + 6 * (qcompress - 1) * log2(cplx_i / mean(cplx_1..i)))
/// ```
///
/// With x265's default `qcompress = 0.6` that is -2.4 QP per doubling of
/// complexity: pictures harder than the running average refine, easier ones
/// coarsen, ±6 QP of deviation saturates. The first picture has no temporal
/// predecessor and codes at `base`; picture 1's sample joins the mean first,
/// so its ratio is 1 and it also sits at `base`. The recurrence is strictly
/// display-causal (sample `i` only needs frames `i-1` and `i` in display
/// order), which is what makes it order-stable under the B-slice coding
/// reordering (I0, P2, B1, ...): QPs are computed for display positions and
/// the coding loop merely looks them up.
/// (`qcompress` 0.6 and the ±6 saturation are inlined at the use sites — the
/// package's whitebox tests ride the V8 `__moonbit__init__` local limit, and
/// every top-level `let` costs one init local.)

///|
/// The causal CRF controller: the baseline QP plus the running mean of the
/// temporal-complexity samples (display positions 1..i; position 0
/// contributes no sample and codes at `base`).
priv struct HevcCrf {
  base : Int32
  mut sum : Int64
  mut count : Int32
}

///|
/// Baseline QP from a CRF value. Negative values mean "off" at the entry
/// points and never reach here.
fn HevcCrf::create(crf : Double) -> HevcCrf {
  let q = crf.round().to_int()
  { base: if q < 0 { 0 } else if q > 51 { 51 } else { q }, sum: 0L, count: 0, }
}

///|
/// QP for a picture of temporal complexity `cplx` (luma SAD against the
/// previous display frame). The sample joins the running mean first, so
/// picture 1 always sits at the baseline and the offsets of a sequence
/// balance around it. Integer QPs; `Double` only inside the ratio, and IEEE
/// arithmetic keeps it deterministic across backends.
fn HevcCrf::qp_for(self : HevcCrf, cplx : Int64) -> Int32 {
  self.sum = self.sum + cplx
  self.count = self.count + 1
  let avg = self.sum.to_double() / self.count.to_double()
  let dev = 6.0
  // All-static sequence (mean ~ 0): nothing to be easier or harder than.
  // A static picture against a moving mean is maximally cheap: saturate.
  let off = if avg < 0.5 {
    0.0
  } else if cplx == 0L {
    dev
  } else {
    6.0 * (0.6 - 1.0) * @math.log2(cplx.to_double() / avg)
  }
  let clamped = if off < -dev { -dev } else if off > dev { dev } else { off }
  let q = (self.base.to_double() + clamped).round().to_int()
  if q < 0 {
    0
  } else if q > 51 {
    51
  } else {
    q
  }
}

///|
/// Luma SAD between two sample planes (the luma `FixedArray[Int32]` of
/// consecutive display frames): every other row, every other sample. The
/// absolute scale does not matter (only within-sequence ratios feed the QP),
/// so the bit depth never needs folding in.
fn hevc_enc_crf_sad(
  prev : FixedArray[Int32],
  cur : FixedArray[Int32],
  width : Int32,
  height : Int32,
) -> Int64 {
  let mut sum : Int64 = 0L
  for y = 0; y < height; y = y + 2 {
    let base = y * width
    for x = 0; x < width; x = x + 2 {
      let d = prev[base + x] - cur[base + x]
      if d > 0 {
        sum = sum + d.to_int64()
      } else {
        sum = sum - d.to_int64()
      }
    }
  }
  sum
}

///|
/// The batch driver: per-display-position QPs for a whole frame array,
/// evaluating the causal recurrence in display order. `hevc_encode_sequence`
/// calls this once and the coding loop looks frames up by display index, so
/// the B-slice reordering never reorders the controller.
fn hevc_enc_crf_qps(
  frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])],
  width : Int32,
  height : Int32,
  crf : Double,
) -> Array[Int32] {
  let rc = HevcCrf::create(crf)
  let qps : Array[Int32] = []
  for i = 0; i < frames.length(); i = i + 1 {
    if i == 0 {
      qps.push(rc.base)
    } else {
      let (py, _, _) = frames[i - 1]
      let (cy, _, _) = frames[i]
      qps.push(rc.qp_for(hevc_enc_crf_sad(py, cy, width, height)))
    }
  }
  qps
}
