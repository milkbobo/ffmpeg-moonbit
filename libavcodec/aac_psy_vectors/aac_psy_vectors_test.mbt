///|
/// Black-box regression for the 3GPP psychoacoustic model.
///
/// Expected values come from `_ref/aacenc/vectors.txt`, produced by running
/// the unmodified FFmpeg 9.0.2 `aacpsy.c` (`psy_3gpp_analyze_channel`) on the
/// same deterministic spectrum. Regenerate with:
///   bash _ref/aacenc/build.sh && ./aac_ref.exe > vectors.txt
///   python scripts/gen_aac_psy_vectors.py
///
/// The C side is f32 throughout while the port computes in f64 with f32
/// rounding at libm boundaries, so integer outputs (bits / alloc / fill) are
/// asserted exactly and floating outputs use tight relative tolerances.
/// One band (frame 4, band 0) sits on a reduction/linearization boundary and
/// drifts by ~1e-4 relative; the threshold tolerance is 5e-4 to cover that
/// single ulp-amplified case while still catching any structural error.
fn aac_psy_close(
  got : Double,
  want : Double,
  tol : Double,
  label : String,
) -> Unit raise {
  let d = (got - want).abs()
  let scale = want.abs()
  let limit = if scale > 1.0 { scale * tol } else { tol }
  if d > limit {
    fail("\{label}: got \{got}, want \{want}, tolerance \{tol}")
  }
}

///|
test "3GPP psy matches FFmpeg 9.0.2 aacpsy.c (5 frames x 49 bands)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  for f in 0..<5 {
    let r = ctx.analyze(0, @aac_psy_vectors.aac_psy_spec[f], 0)
    if r.alloc != @aac_psy_vectors.aac_psy_ref_alloc[f] {
      fail(
        "frame \{f}: alloc \{r.alloc} != \{@aac_psy_vectors.aac_psy_ref_alloc[f]}",
      )
    }
    if r.fill_level != @aac_psy_vectors.aac_psy_ref_fill[f] {
      fail("frame \{f}: reservoir fill level mismatch")
    }
    aac_psy_close(
      r.entropy,
      @aac_psy_vectors.aac_psy_ref_entropy[f],
      0.00001,
      "frame \{f} entropy",
    )
    if r.bands.length() != 49 {
      fail("frame \{f}: expected 49 scalefactor bands")
    }
    for g in 0..<49 {
      let b = r.bands[g]
      // Integer decisions must agree bit for bit.
      if b.bits != @aac_psy_vectors.aac_psy_ref_bits[f][g] {
        fail(
          "frame \{f} band \{g}: bits \{b.bits} != \{@aac_psy_vectors.aac_psy_ref_bits[f][g]}",
        )
      }
      aac_psy_close(
        b.energy,
        @aac_psy_vectors.aac_psy_ref_energy[f][g],
        0.00001,
        "frame \{f} band \{g} energy",
      )
      aac_psy_close(
        b.threshold,
        @aac_psy_vectors.aac_psy_ref_threshold[f][g],
        0.0005,
        "frame \{f} band \{g} threshold",
      )
      aac_psy_close(
        b.spread,
        @aac_psy_vectors.aac_psy_ref_spread[f][g],
        0.00001,
        "frame \{f} band \{g} spread",
      )
    }
  }
}

///|
/// The model owns cross-frame state (`prev_band` for pre-echo control,
/// `pe.min/max`, `fill_level`, `bitres.alloc`). Feeding the same spectrum
/// twice must not produce the same thresholds.
test "3GPP psy keeps cross-frame pre-echo state" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let spec = @aac_psy_vectors.aac_psy_spec[0]
  let first = ctx.analyze(0, spec, 0)
  let second = ctx.analyze(0, spec, 0)
  let mut changed = 0
  for g in 0..<49 {
    let d = first.bands[g].threshold - second.bands[g].threshold
    if d.abs() > 1.0 {
      changed += 1
    }
  }
  if changed == 0 {
    fail("pre-echo state was not carried across frames")
  }
}

///|
/// Context construction covers the full static coefficient set (long and
/// short window tables) for a standard sample rate without producing
/// non-finite thresholds.
test "3GPP psy band plan and finite thresholds" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let r = ctx.analyze(0, @aac_psy_vectors.aac_psy_spec[2], 0)
  if r.bands.length() != 49 {
    fail("44100 Hz long window must have 49 bands")
  }
  for g in 0..<49 {
    let b = r.bands[g]
    if b.threshold.is_nan() || b.threshold.is_inf() {
      fail("band \{g}: non-finite threshold")
    }
    if b.energy < 0.0 || b.threshold < 0.0 {
      fail("band \{g}: negative energy or threshold")
    }
  }
}
