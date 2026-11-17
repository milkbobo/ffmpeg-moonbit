///|
/// `§435` constant rate factor (x264 `--crf`): quality-driven per-picture
/// QPs. The CRF value is the baseline QP (`round(crf)`); every later
/// picture's QP bends around it by its temporal complexity — the luma SAD
/// against the previous display frame, subsampled to every other row and
/// byte — relative to the running mean of the samples seen so far:
///
/// ```text
/// qp_i = round(base + 6 * (qcompress - 1) * log2(cplx_i / mean(cplx_1..i)))
/// ```
///
/// With x264's default `qcompress = 0.6` that is -2.4 QP per doubling of
/// complexity: pictures harder than the running average refine, easier
/// ones coarsen, ±6 QP of deviation saturates. The first picture has no
/// temporal predecessor and codes at `base`. The recurrence is strictly
/// display-causal (sample `i` only needs frames `i-1` and `i`), which is
/// what keeps the batch entries and the streaming encoder byte-identical
/// under CRF: both evaluate the same formula in display order.
/// (`qcompress` 0.6 and the ±6 saturation are inlined at the use sites —
/// the package's whitebox test unit rides the V8 `__moonbit__init` local
/// limit, and every top-level `let` costs one init local.)

///|
/// The causal CRF controller: the baseline QP plus the running mean of
/// the temporal-complexity samples (display positions 1..i; position 0
/// contributes no sample and codes at `base`).
struct H264Crf {
  base : Int32
  mut sum : Int64
  mut count : Int32
}

///|
/// Baseline QP from a CRF value. Negative values mean "off" at the entry
/// points and never reach here.
fn H264Crf::create(crf : Double) -> H264Crf {
  let q = crf.round().to_int()
  { base: if q < 0 { 0 } else if q > 51 { 51 } else { q }, sum: 0L, count: 0, }
}

///|
/// QP for a picture of temporal complexity `cplx` (luma SAD against the
/// previous display frame). The sample joins the running mean first, so
/// picture 1 always sits at the baseline and the offsets of a sequence
/// balance around it. Integer QPs; `Double` only inside the ratio, and
/// IEEE arithmetic keeps it deterministic across backends.
fn H264Crf::qp_for(self : H264Crf, cplx : Int64) -> Int32 {
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
/// Luma SAD between two packed raw planes (the luma Bytes of consecutive
/// display frames): every other row, every other byte — the low byte of
/// each sample at 16-bit depths, half the pixels at 8-bit. The absolute
/// scale does not matter (only within-sequence ratios feed the QP), so
/// the depths never need unpacking.
fn h264_enc_crf_sad(prev : Bytes, cur : Bytes, height : Int32) -> Int64 {
  let row = prev.length() / height
  let mut sum : Int64 = 0L
  for y = 0; y < height; y = y + 2 {
    let base = y * row
    for x = 0; x < row; x = x + 2 {
      let d = prev[base + x].to_int() - cur[base + x].to_int()
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
/// running the same causal recurrence the streaming encoder evaluates
/// push by push (this is the stream==batch invariant under CRF).
fn h264_enc_crf_qps(
  frames : Array[(Bytes, Bytes, Bytes)],
  height : Int32,
  crf : Double,
) -> Array[Int32] {
  let rc = H264Crf::create(crf)
  let qps : Array[Int32] = []
  for i = 0; i < frames.length(); i = i + 1 {
    if i == 0 {
      qps.push(rc.base)
    } else {
      let (py, _, _) = frames[i - 1]
      let (cy, _, _) = frames[i]
      qps.push(rc.qp_for(h264_enc_crf_sad(py, cy, height)))
    }
  }
  qps
}

///|
/// `§435` streaming: the display-causal CRF QP for the frame being
/// pushed (advances the controller; the raw luma of the previous push is
/// kept for the SAD). Only called with CRF on.
fn H264StreamEncoder::crf_qp_for(self : H264StreamEncoder, y : Bytes) -> Int32 {
  let rc = match self.crf {
    Some(r) => r
    None => return self.qp
  }
  let q = match self.prev_y {
    None => rc.base
    Some(prev) => rc.qp_for(h264_enc_crf_sad(prev, y, self.height))
  }
  self.prev_y = Some(y)
  q
}

///|
/// `§435` streaming: the picture QP proposal. CRF (mutually exclusive
/// with ABR by `open`) hands in the push-computed `hint`; without CRF
/// this is the ABR controller's suggestion (the flat `qp` when ABR is
/// off too). CRF hints keep the format range — the near-lossless QPs are
/// the caller's choice, not a solver artifact.
fn H264StreamEncoder::pic_suggest(
  self : H264StreamEncoder,
  hint : Int32,
) -> Int32 {
  match self.crf {
    Some(_) =>
      if hint < 0 {
        0
      } else if hint > h264_rc_qp_max {
        h264_rc_qp_max
      } else {
        hint
      }
    None => self.abr_suggest()
  }
}

///|
/// `§435` streaming: the PPS base QP. The B-line batch entry writes its
/// PPS with `pic_init_qp = qps[0]` — under CRF the first picture's QP,
/// the baseline. The streaming IDR/I pictures mirror that so the plain
/// CRF path stays byte-identical to the batch entry; the P-line keeps
/// the caller's `qp` as its PPS base (like `h264_encode_frames_qps`).
fn H264StreamEncoder::pps_qp(self : H264StreamEncoder) -> Int32 {
  match self.crf {
    Some(rc) => if self.b_slices { rc.base } else { self.qp }
    None => self.qp
  }
}
