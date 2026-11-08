///|
/// Black-box regression for the ported intensity stereo search.
///
/// Expected values come from `_ref/aacenc/aac_ref.exe --is`, which runs the
/// unmodified FFmpeg 9.0.2 `ff_aac_search_for_is` (`libavcodec/aacenc_is.c`) on
/// the channel-pair state the MoonBit encoder reaches at its stereo stage.
/// Regenerate with:
///   bash _ref/aacenc/build.sh
///   moon test --target wasm libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log
///   python scripts/gen_aac_is_vectors.py .scratch/is_dump/enc.log
///
/// The fixture therefore pins the *algorithm*, not its inputs: the spectra,
/// both channels' masking thresholds and both channels' twoloop outcome are
/// exactly what the reference was handed, so any difference here is a
/// difference in the cost comparison, the phase choice or the exclusions.
///
/// Everything is asserted **exactly**. Earlier drafts of this file measured the
/// `dist1`/`dist2` magnitudes instead of comparing them, because the escape
/// codebook's `c*cbrtf(c)` was being recomputed with a double `cbrt`; §293
/// traces that to 2196 one-ulp disagreements with the encoder's own
/// single-precision `cbrtf` and fixes it with a transcribed table, and §295
/// closed the last gap of the same kind (C's `float` literals have to be stored
/// as f32 values) in the mid/side search below.
///
/// What the encoder consumes - `is_mask`, the resulting `ms_mask`, the
/// right channel's band type, the two `is_ener` values, the per-phase `pass`
/// flags and `cpe->is_mode` - is asserted exactly, and so are the magnitudes:
/// one test per tool, both pinning the comparison itself rather than only its
/// outcome.
///
/// Domain adapter (§366): the vectors pin C's 1x coefficient domain, but the
/// stereo searches now run in the live encoder's domain (2x coefficients, 4x
/// thresholds, sf == ref + 4 - see `aac_psy_bands_encoder_domain`).  The
/// fixtures below double the spectra, scale the thresholds by exactly 4 and
/// shift the incoming scalefactors by +4.  Integer decisions still compare
/// exactly; the float cost sums and energy ratios are compared by a relative
/// tolerance, because the pow34 pipelines on doubled inputs carry ulp-level
/// noise the 1x reference never made.
fn aac_is_v_close(got : Double, want : Double, label : String) -> Unit raise {
  let d = (got - want).abs()
  let scale = if want.abs() > 1.0 { want.abs() } else { 1.0 }
  if d > scale * 1.0e-6 {
    fail("\{label}: got \{got}, want \{want}")
  }
}

///|
test "AAC intensity stereo matches FFmpeg 9.0.2 aacenc_is.c (4 frames x 49 bands)" {
  let swb = match @libavcodec.aac_swb_tables(4) {
    Ok(v) => v
    Err(e) => {
      println("AAC is test error: \{e}")
      abort("AAC is test: no swb table")
    }
  }
  let n = swb.num_long
  let sizes : Array[Int32] = []
  for g in 0..<n {
    let a = swb.offsets_long[g].reinterpret_as_int()
    let b = swb.offsets_long[g + 1].reinterpret_as_int()
    sizes.push(b - a)
  }
  let frames = @aac_is_vectors.aac_is_spec0.length()
  let mut is_bands = 0
  for f in 0..<frames {
    let d = @libavcodec.aac_is_in(
      @aac_is_vectors.aac_is_spec0[f].map(x => x * 2.0),
      @aac_is_vectors.aac_is_spec1[f].map(x => x * 2.0),
      sizes,
      @libavcodec.aac_two_shape_long(),
      @aac_is_vectors.aac_is_thr0[f].map(x => x * 4.0),
      @aac_is_vectors.aac_is_thr1[f].map(x => x * 4.0),
      @aac_is_vectors.aac_is_sf0[f].map(x => x + 4),
      @aac_is_vectors.aac_is_sf1[f].map(x => x + 4),
      @aac_is_vectors.aac_is_cb0[f],
      @aac_is_vectors.aac_is_cb1[f],
      @aac_is_vectors.aac_is_zero0[f],
      @aac_is_vectors.aac_is_zero1[f],
      n,
    )
    let out = @libavcodec.aac_is_search(d, 44100, 120.0)
    for g = 0; g < n; g = g + 1 {
      let want_mask = @aac_is_vectors.aac_is_ref_mask[f][g]
      if out.is_mask[g] != want_mask {
        fail(
          "frame \{f} band \{g}: is_mask \{out.is_mask[g]} != \{want_mask} (thresholds \{@aac_is_vectors.aac_is_thr0[f][g]} / \{@aac_is_vectors.aac_is_thr1[f][g]}, sf \{@aac_is_vectors.aac_is_sf0[f][g]} / \{@aac_is_vectors.aac_is_sf1[f][g]}, cb \{@aac_is_vectors.aac_is_cb0[f][g]} / \{@aac_is_vectors.aac_is_cb1[f][g]}, zeroes \{@aac_is_vectors.aac_is_zero0[f][g]} / \{@aac_is_vectors.aac_is_zero1[f][g]})",
        )
      }
      if out.ms_mask[g] != @aac_is_vectors.aac_is_ref_ms[f][g] {
        fail(
          "frame \{f} band \{g}: ms_mask \{out.ms_mask[g]} != \{@aac_is_vectors.aac_is_ref_ms[f][g]}",
        )
      }
      if out.pass1[g] != @aac_is_vectors.aac_is_ref_pass1[f][g] {
        fail(
          "frame \{f} band \{g}: pass1 \{out.pass1[g]} != \{@aac_is_vectors.aac_is_ref_pass1[f][g]} (costs \{out.dist11[g]}/\{out.dist12[g]} vs \{@aac_is_vectors.aac_is_ref_d11[f][g]}/\{@aac_is_vectors.aac_is_ref_d12[f][g]})",
        )
      }
      if out.pass2[g] != @aac_is_vectors.aac_is_ref_pass2[f][g] {
        fail(
          "frame \{f} band \{g}: pass2 \{out.pass2[g]} != \{@aac_is_vectors.aac_is_ref_pass2[f][g]} (costs \{out.dist21[g]}/\{out.dist22[g]} vs \{@aac_is_vectors.aac_is_ref_d21[f][g]}/\{@aac_is_vectors.aac_is_ref_d22[f][g]})",
        )
      }
      if want_mask == 1 {
        is_bands = is_bands + 1
        if out.band_type1[g] != @aac_is_vectors.aac_is_ref_bt1[f][g] {
          fail(
            "frame \{f} band \{g}: band_type \{out.band_type1[g]} != \{@aac_is_vectors.aac_is_ref_bt1[f][g]}",
          )
        }
        aac_is_v_close(
          out.is_ener0[g],
          @aac_is_vectors.aac_is_ref_ener0[f][g],
          "frame \{f} band \{g} is_ener0",
        )
        aac_is_v_close(
          out.is_ener1[g],
          @aac_is_vectors.aac_is_ref_ener1[f][g],
          "frame \{f} band \{g} is_ener1",
        )
      } else if out.band_type1[g] != 0 {
        fail("frame \{f} band \{g}: band type set on an unselected band")
      }
      let costs : Array[(Double, Double, String)] = [
        (out.dist11[g], @aac_is_vectors.aac_is_ref_d11[f][g], "phase-1 dist1"),
        (out.dist12[g], @aac_is_vectors.aac_is_ref_d12[f][g], "phase-1 dist2"),
        (out.dist21[g], @aac_is_vectors.aac_is_ref_d21[f][g], "phase+1 dist1"),
        (out.dist22[g], @aac_is_vectors.aac_is_ref_d22[f][g], "phase+1 dist2"),
        (
          out.dist11_left[g],
          @aac_is_vectors.aac_is_ref_d11l[f][g],
          "phase-1 dist1 left half",
        ),
        (
          out.dist21_left[g],
          @aac_is_vectors.aac_is_ref_d21l[f][g],
          "phase+1 dist1 left half",
        ),
      ]
      for (got, want, name) in costs {
        aac_is_v_close(got, want, "frame \{f} band \{g} \{name}")
      }
    }
    // `cpe->is_mode` is `!!count`, not the count itself.
    let mode = if out.count > 0 { 1 } else { 0 }
    if mode != @aac_is_vectors.aac_is_ref_mode[f] {
      fail(
        "frame \{f}: is_mode \{mode} != \{@aac_is_vectors.aac_is_ref_mode[f]} (\{out.count} intensity bands)",
      )
    }
  }
  // Note there is no "uncorrelated programme switches nothing" check here: a
  // cost-based search happily switches a quiet, well-masked band, because an
  // intensity position costs ~7 bits while the two coded bands cost more. That
  // is precisely the difference from §290's correlation gate, and the exact
  // per-band equality asserted above is what pins it.
  println("IS vectors: \{is_bands} intensity bands over \{frames} frames")
  assert_true(is_bands > 0)
}

///|
/// Black-box regression for the ported mid/side search: `_ref/aacenc/aac_ref.exe
/// --is` keeps going after the intensity stage - it mixes the intensity bands in
/// (`apply_intensity_stereo`) and then runs `search_for_ms`, which decides
/// mid/side per band and *rewrites* both channels' scalefactor and band type.
/// The fixture therefore carries, per band, the mask, the boost round that
/// settled it, the two distortion sums and the outgoing `sf_idx`/`band_type`;
/// everything is compared exactly, on the state our own (bit-exact) intensity
/// stage produced.
test "AAC mid/side search matches FFmpeg 9.0.2 aaccoder.c (4 frames x 49 bands)" {
  let swb = match @libavcodec.aac_swb_tables(4) {
    Ok(v) => v
    Err(e) => {
      println("AAC ms test error: \{e}")
      abort("AAC ms test: no swb table")
    }
  }
  let n = swb.num_long
  let offsets : Array[Int32] = []
  let sizes : Array[Int32] = []
  for g in 0..<n {
    let a = swb.offsets_long[g].reinterpret_as_int()
    let b = swb.offsets_long[g + 1].reinterpret_as_int()
    offsets.push(a)
    sizes.push(b - a)
  }
  offsets.push(swb.offsets_long[n].reinterpret_as_int())
  let frames = @aac_is_vectors.aac_is_spec0.length()
  let mut ms_bands = 0
  for f in 0..<frames {
    let spec0_2 = @aac_is_vectors.aac_is_spec0[f].map(x => x * 2.0)
    let spec1_2 = @aac_is_vectors.aac_is_spec1[f].map(x => x * 2.0)
    let thr0_4 = @aac_is_vectors.aac_is_thr0[f].map(x => x * 4.0)
    let thr1_4 = @aac_is_vectors.aac_is_thr1[f].map(x => x * 4.0)
    let sf0_4 = @aac_is_vectors.aac_is_sf0[f].map(x => x + 4)
    let sf1_4 = @aac_is_vectors.aac_is_sf1[f].map(x => x + 4)
    let isr = @libavcodec.aac_is_search(
      @libavcodec.aac_is_in(
        spec0_2,
        spec1_2,
        sizes,
        @libavcodec.aac_two_shape_long(),
        thr0_4,
        thr1_4,
        sf0_4,
        sf1_4,
        @aac_is_vectors.aac_is_cb0[f],
        @aac_is_vectors.aac_is_cb1[f],
        @aac_is_vectors.aac_is_zero0[f],
        @aac_is_vectors.aac_is_zero1[f],
        n,
      ),
      44100,
      120.0,
    )
    // The reference's mid/side search reads the spectra *after* the intensity
    // mix, so mix them the same way before comparing its decisions.
    let flip : Array[Bool] = []
    for g in 0..<n {
      flip.push(isr.ms_mask[g] == 1)
    }
    let left = spec0_2.copy()
    let right = spec1_2.copy()
    @libavcodec.aac_is_apply(
      left,
      right,
      offsets,
      n,
      1,
      @libavcodec.aac_two_shape_long().group_len,
      isr.band_type1,
      flip,
      isr.is_ener0,
    )
    // On an intensity band the right channel's type has already become 14/15.
    let cb1 : Array[Int32] = []
    for g in 0..<n {
      cb1.push(
        if isr.is_mask[g] == 1 {
          isr.band_type1[g]
        } else {
          @aac_is_vectors.aac_is_cb1[f][g]
        },
      )
    }
    let ms = @libavcodec.aac_ms_search(
      @libavcodec.aac_ms_in(
        left,
        right,
        sizes,
        @libavcodec.aac_two_shape_long(),
        thr0_4,
        thr1_4,
        sf0_4,
        sf1_4,
        @aac_is_vectors.aac_is_cb0[f],
        cb1,
        @aac_is_vectors.aac_is_zero0[f],
        @aac_is_vectors.aac_is_zero1[f],
        isr.is_mask,
        // The flip markers the intensity search left in `ms_mask`; the
        // mid/side search must carry them through untouched.
        isr.ms_mask,
        n,
      ),
      120.0,
    )
    for g in 0..<n {
      let want_mask = @aac_is_vectors.aac_is_ref_ms_mask[f][g]
      if ms.ms_mask[g] != want_mask {
        fail(
          "frame \{f} band \{g}: ms_mask \{ms.ms_mask[g]} != \{want_mask} (boost \{ms.boost[g]}, dists \{ms.dist1[g]} / \{ms.dist2[g]}, reference \{@aac_is_vectors.aac_is_ref_ms_d1[f][g]} / \{@aac_is_vectors.aac_is_ref_ms_d2[f][g]}, sf \{ms.sf0[g]}/\{ms.sf1[g]} vs \{@aac_is_vectors.aac_is_ref_ms_sf0[f][g]}/\{@aac_is_vectors.aac_is_ref_ms_sf1[f][g]})",
        )
      }
      if ms.boost[g] != @aac_is_vectors.aac_is_ref_ms_boost[f][g] {
        fail(
          "frame \{f} band \{g}: boost \{ms.boost[g]} != \{@aac_is_vectors.aac_is_ref_ms_boost[f][g]}",
        )
      }
      if ms.sf0[g] != @aac_is_vectors.aac_is_ref_ms_sf0[f][g] + 4 {
        fail(
          "frame \{f} band \{g}: sf0 \{ms.sf0[g]} != \{@aac_is_vectors.aac_is_ref_ms_sf0[f][g] + 4}",
        )
      }
      if ms.cb0[g] != @aac_is_vectors.aac_is_ref_ms_cb0[f][g] {
        fail(
          "frame \{f} band \{g}: cb0 \{ms.cb0[g]} != \{@aac_is_vectors.aac_is_ref_ms_cb0[f][g]}",
        )
      }
      if ms.sf1[g] != @aac_is_vectors.aac_is_ref_ms_sf1[f][g] + 4 {
        fail(
          "frame \{f} band \{g}: sf1 \{ms.sf1[g]} != \{@aac_is_vectors.aac_is_ref_ms_sf1[f][g] + 4}",
        )
      }
      if ms.cb1[g] != @aac_is_vectors.aac_is_ref_ms_cb1[f][g] {
        fail(
          "frame \{f} band \{g}: cb1 \{ms.cb1[g]} != \{@aac_is_vectors.aac_is_ref_ms_cb1[f][g]}",
        )
      }
      aac_is_v_close(
        ms.dist1[g],
        @aac_is_vectors.aac_is_ref_ms_d1[f][g],
        "frame \{f} band \{g} dist1",
      )
      aac_is_v_close(
        ms.dist2[g],
        @aac_is_vectors.aac_is_ref_ms_d2[f][g],
        "frame \{f} band \{g} dist2",
      )
      aac_is_v_close(
        ms.mid_cost[g],
        @aac_is_vectors.aac_is_ref_ms_cm[f][g],
        "frame \{f} band \{g} mid cost",
      )
      if ms.bits1[g] != @aac_is_vectors.aac_is_ref_ms_b1[f][g] {
        fail(
          "frame \{f} band \{g}: side bits \{ms.bits1[g]} != \{@aac_is_vectors.aac_is_ref_ms_b1[f][g]}",
        )
      }
      if ms.bmax[g] != @aac_is_vectors.aac_is_ref_ms_bmax[f][g] {
        fail(
          "frame \{f} band \{g}: bmax \{ms.bmax[g]} != \{@aac_is_vectors.aac_is_ref_ms_bmax[f][g]}",
        )
      }
      if want_mask == 1 {
        ms_bands = ms_bands + 1
      }
    }
  }
  println("MS vectors: \{ms_bands} mid/side bands over \{frames} frames")
  assert_true(ms_bands > 0)
}
