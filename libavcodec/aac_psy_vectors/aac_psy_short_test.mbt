///|
/// Black-box regression for the eight-short-window branch of the 3GPP model.
///
/// Expected values come from `_ref/aacenc/vectors_short.txt`, produced by
/// running the unmodified FFmpeg 9.0.2 `aacpsy.c`
/// (`psy_3gpp_analyze_channel`, `wi->num_windows == 8`) on the same
/// deterministic spectrum. Regenerate with:
///   bash _ref/aacenc/build.sh
///   ./aac_ref.exe --short > vectors_short.txt
///   python scripts/gen_aac_psy_short_vectors.py
///
/// As in the long-window regression, integer outputs (`bits` / `alloc` /
/// `fill_level`) are asserted exactly and floats by relative tolerance, because
/// the reference is f32 while the port computes in f64 with f32 rounding at the
/// libm boundaries.
fn aac_psy_short_close(
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
/// `EIGHT_SHORT_SEQUENCE` in FFmpeg's enum (`aacpsy.h`: only_long = 0,
/// long_start = 1, eight_short = 2, long_stop = 3), which is what
/// `AacPsyContext::analyze` keys the window shape on.
let aac_psy_short_seq : Int32 = 2

///|
let aac_psy_only_long_seq : Int32 = 0

///|
let aac_psy_long_start_seq : Int32 = 1

///|
test "3GPP psy eight short windows matches FFmpeg 9.0.2 aacpsy.c (5 frames x 8 x 14)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  for f in 0..<5 {
    // The harness alternates the previous frame's sequence so both pre-echo
    // guards fire: after LONG_START only window 0 skips the reduction.
    let prev = if f % 2 == 1 {
      aac_psy_long_start_seq
    } else {
      aac_psy_only_long_seq
    }
    let r = ctx.analyze(
      0,
      @aac_psy_vectors.aac_psy_short_spec[f],
      0,
      aac_psy_short_seq,
      prev,
    )
    if r.num_windows != 8 {
      fail("frame \{f}: eight short windows must report num_windows = 8")
    }
    if r.num_bands != 14 {
      fail("frame \{f}: 44100 Hz short plan has 14 bands, got \{r.num_bands}")
    }
    if r.bands.length() != 128 {
      fail("frame \{f}: short bands must use the 128-slot layout")
    }
    if r.alloc != @aac_psy_vectors.aac_psy_short_alloc[f] {
      fail(
        "frame \{f}: alloc \{r.alloc} != \{@aac_psy_vectors.aac_psy_short_alloc[f]}",
      )
    }
    if r.fill_level != @aac_psy_vectors.aac_psy_short_fill[f] {
      fail("frame \{f}: reservoir fill level mismatch")
    }
    aac_psy_short_close(
      r.entropy,
      @aac_psy_vectors.aac_psy_short_entropy[f],
      0.00001,
      "frame \{f} entropy",
    )
    let slots = @aac_psy_vectors.aac_psy_short_slot[f]
    for i in 0..<112 {
      // Window `i / 14`, band `i % 14` at slot `w * 16 + g` - the stride every
      // C consumer indexes with.
      let want_slot = i / 14 * 16 + i % 14
      if slots[i] != want_slot {
        fail("frame \{f} record \{i}: fixture slot \{slots[i]} != \{want_slot}")
      }
      let b = r.bands[slots[i]]
      if b.bits != @aac_psy_vectors.aac_psy_short_bits[f][i] {
        fail(
          "frame \{f} slot \{slots[i]}: bits \{b.bits} != \{@aac_psy_vectors.aac_psy_short_bits[f][i]}",
        )
      }
      aac_psy_short_close(
        b.energy,
        @aac_psy_vectors.aac_psy_short_energy[f][i],
        0.00001,
        "frame \{f} slot \{slots[i]} energy",
      )
      aac_psy_short_close(
        b.threshold,
        @aac_psy_vectors.aac_psy_short_threshold[f][i],
        0.0005,
        "frame \{f} slot \{slots[i]} threshold",
      )
      aac_psy_short_close(
        b.spread,
        @aac_psy_vectors.aac_psy_short_spread[f][i],
        0.00001,
        "frame \{f} slot \{slots[i]} spread",
      )
    }
  }
}

///|
/// The bands beyond each window's 14 records are padding, not data: the slot
/// layout is shared with the long window, so a short analysis must leave the
/// gaps it does not write at zero instead of carrying the previous frame there.
test "3GPP psy short analysis leaves slot padding empty" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  // A long frame first, so stale values could leak in if the publish loop or
  // the array were the wrong size.
  let _long_warmup = ctx.analyze(
    0,
    @aac_psy_vectors.aac_psy_short_spec[0],
    0,
    aac_psy_only_long_seq,
    aac_psy_only_long_seq,
  )
  let r = ctx.analyze(
    0,
    @aac_psy_vectors.aac_psy_short_spec[1],
    0,
    aac_psy_short_seq,
    aac_psy_only_long_seq,
  )
  for s in 0..<128 {
    if s % 16 >= 14 {
      let b = r.bands[s]
      if b.energy != 0.0 || b.threshold != 0.0 || b.bits != 0 {
        fail("slot \{s}: padding slot must stay empty")
      }
    }
  }
}

///|
/// The shape really switches plans: the same spectrum analysed as one long
/// window reports 49 bands, as eight short windows 14 per window, and the bit
/// demand comes from the short-window slope set.
test "3GPP psy short plan differs from the long plan" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let spec = @aac_psy_vectors.aac_psy_short_spec[3]
  let long_r = ctx.analyze(
    0, spec, 0, aac_psy_only_long_seq, aac_psy_only_long_seq,
  )
  let short_r = ctx.analyze(
    0, spec, 0, aac_psy_short_seq, aac_psy_only_long_seq,
  )
  if long_r.num_windows != 1 || long_r.num_bands != 49 {
    fail("only_long must analyse 49 bands in one window")
  }
  if short_r.num_windows != 8 || short_r.num_bands != 14 {
    fail("eight_short must analyse 14 bands in each of 8 windows")
  }
  if long_r.alloc == short_r.alloc {
    fail(
      "short frames use PSY_3GPP_SAVE/SPEND slopes; the bit demand cannot match",
    )
  }
  let mut differ = 0
  for g in 0..<14 {
    if (long_r.bands[g].energy - short_r.bands[g].energy).abs() > 1.0 {
      differ += 1
    }
  }
  if differ == 0 {
    fail("the two band plans must slice the spectrum differently")
  }
}
