///|
/// Black-box regression for the two-loop quantizer.
///
/// Expected values come from `_ref/aacenc/vectors.txt`, produced by the
/// unmodified FFmpeg 9.0.2 `search_for_quantizers_twoloop`
/// (`aaccoder_twoloop.h`) running on the same deterministic spectrum and on
/// the psy model output of `aacpsy.c`.  Regenerate with:
///   bash _ref/aacenc/build.sh && ./aac_ref.exe > vectors.txt
///   python scripts/gen_aac_psy_vectors.py
///
/// `sf_idx`, `band_type` and `zeroes` are integer decisions and must agree
/// bit for bit (245 bands over 5 frames).  `maxval` is a float pipeline
/// (`abs_pow34` + `find_max_val`) and is compared with a relative tolerance.
///
/// Domain adapter (§366): the vectors pin C's 1x coefficient/psy domain, but
/// the live encoder feeds the search its 2x coefficients and 4x psy bands
/// (see `aac_psy_bands_encoder_domain`), and the search's initial ladder and
/// `uplims` floor are tuned to that domain.  The fixture therefore doubles
/// the spectrum (exact) and scales the port-psy bands by exactly 4, and the
/// search then tracks the reference at a constant `sf == ref + 4` offset;
/// `maxval` is `|c|^{3/4}`-shaped, so it scales by exactly `2^{3/4}`.
test "twoloop matches FFmpeg 9.0.2 for 5 frames x 49 bands" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  if sizes.length() != 49 {
    fail("44.1 kHz long window must have 49 scalefactor bands")
  }
  for f in 0..<5 {
    let spec = @aac_psy_vectors.aac_psy_spec[f]
    let psy = ctx.analyze(0, spec, 0, 0, 0)
    let spec2 : Array[Double] = spec.map(x => x * 2.0)
    let r = @libavcodec.aac_twoloop_search(
      spec2,
      sizes,
      @libavcodec.aac_psy_bands_encoder_domain(psy.bands),
      psy.alloc,
      128000,
      44100,
      2,
      120.0,
      @libavcodec.aac_two_shape_long(),
    )
    // The reference oscillates between two scalefactor sets and always runs
    // the full iteration budget; matching that is part of the contract.
    if r.iters != 30 {
      fail("frame \{f}: expected 30 iterations, got \{r.iters}")
    }
    for g in 0..<49 {
      if r.sf[g] != @aac_psy_vectors.aac_psy_ref_two_sf[f][g] + 4 {
        fail(
          "frame \{f} band \{g}: sf_idx \{r.sf[g]} != \{@aac_psy_vectors.aac_psy_ref_two_sf[f][g] + 4}",
        )
      }
      if r.cb[g] != @aac_psy_vectors.aac_psy_ref_two_cb[f][g] {
        fail(
          "frame \{f} band \{g}: band_type \{r.cb[g]} != \{@aac_psy_vectors.aac_psy_ref_two_cb[f][g]}",
        )
      }
      if r.zeroes[g] != @aac_psy_vectors.aac_psy_ref_two_zeroes[f][g] {
        fail(
          "frame \{f} band \{g}: zeroes \{r.zeroes[g]} != \{@aac_psy_vectors.aac_psy_ref_two_zeroes[f][g]}",
        )
      }
      // `|2c|^{3/4} == 2^{3/4} * |c|^{3/4}` in real arithmetic; the 1e-5
      // relative tolerance absorbs the f32 pipeline's rounding of the factor.
      let want = @aac_psy_vectors.aac_psy_ref_two_maxval[f][g] *
        1.681792830507429
      let got = r.maxvals[g]
      let limit = if want > 1.0 { want * 1.0e-5 } else { 1.0e-5 }
      if (got - want).abs() > limit {
        fail("frame \{f} band \{g}: maxval \{got} != \{want}")
      }
    }
  }
}

///|
/// An all-zero spectrum forces every band to zero and returns before the
/// rate loop (`if (!allz) return`), leaving the scalefactors at
/// `SCALE_ONE_POS` and no codebook selected.
test "twoloop zeroes a silent spectrum" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  let spec : Array[Double] = Array::make(1024, 0.0)
  let psy = ctx.analyze(0, spec, 0, 0, 0)
  let r = @libavcodec.aac_twoloop_search(
    spec,
    sizes,
    psy.bands,
    psy.alloc,
    128000,
    44100,
    2,
    120.0,
    @libavcodec.aac_two_shape_long(),
  )
  for g in 0..<49 {
    if r.zeroes[g] != 1 {
      fail("band \{g}: silent band must be zeroed")
    }
    if r.cb[g] != 0 {
      fail("band \{g}: zeroed band must have no codebook")
    }
    if r.sf[g] != 144 {
      // SCALE_ONE_POS + the +4 sf-domain shift (see the domain-adapter
      // note on the main test).
      fail("band \{g}: expected SCALE_ONE_POS + 4, got \{r.sf[g]}")
    }
    if r.maxvals[g] != 0.0 {
      fail("band \{g}: expected zero peak")
    }
  }
  if r.tbits != 0 {
    fail("expected no bits for a silent frame, got \{r.tbits}")
  }
}

///|
/// Structural invariants of the search result: codebooks stay inside
/// 1..11 for coded bands, and the scalefactor of consecutive non-zero bands
/// never differs by more than the 60 steps the bitstream can express.
test "twoloop keeps codebooks and scalefactor deltas legal" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  for f in 0..<5 {
    let spec = @aac_psy_vectors.aac_psy_spec[f]
    let psy = ctx.analyze(0, spec, 0, 0, 0)
    let r = @libavcodec.aac_twoloop_search(
      spec,
      sizes,
      psy.bands,
      psy.alloc,
      128000,
      44100,
      2,
      120.0,
      @libavcodec.aac_two_shape_long(),
    )
    let mut prev = -1
    let mut coded = 0
    for g in 0..<49 {
      if r.zeroes[g] == 1 {
        if r.cb[g] != 0 {
          fail("frame \{f} band \{g}: zeroed band carries codebook \{r.cb[g]}")
        }
        continue
      }
      coded = coded + 1
      if r.cb[g] < 1 || r.cb[g] > 11 {
        fail("frame \{f} band \{g}: codebook \{r.cb[g]} out of range")
      }
      if r.sf[g] < 60 || r.sf[g] > 219 {
        fail("frame \{f} band \{g}: scalefactor \{r.sf[g]} out of range")
      }
      if prev >= 0 && (r.sf[g] - prev).abs() > 60 {
        fail(
          "frame \{f} band \{g}: scalefactor delta \{r.sf[g] - prev} exceeds 60",
        )
      }
      prev = r.sf[g]
    }
    if coded == 0 {
      fail("frame \{f}: no band coded")
    }
  }
}
