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
/// Everything the encoder consumes - `is_mask`, the resulting `ms_mask`, the
/// right channel's band type, the two `is_ener` values, the per-phase `pass`
/// flags and `cpe->is_mode` - is asserted **exactly**. The `dist1`/`dist2`
/// magnitudes are measured instead: they only matter through the comparison
/// that the `pass` flags already pin, and one of them currently lands a few
/// float ulps off (`PORTING_HISTORY.md` §292 records the gap: §278 only ever
/// asserted the search's per-band *decisions*, never a cost magnitude at a
/// non-unit lambda, so the accumulation gap shows up here first).

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
  let mut max_gap = 0.0
  let mut max_label = ""
  for f in 0..<frames {
    let d = @libavcodec.aac_is_in(
      @aac_is_vectors.aac_is_spec0[f],
      @aac_is_vectors.aac_is_spec1[f],
      sizes,
      @aac_is_vectors.aac_is_thr0[f],
      @aac_is_vectors.aac_is_thr1[f],
      @aac_is_vectors.aac_is_sf0[f],
      @aac_is_vectors.aac_is_sf1[f],
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
        if out.is_ener0[g] != @aac_is_vectors.aac_is_ref_ener0[f][g] {
          fail(
            "frame \{f} band \{g}: is_ener0 \{out.is_ener0[g]} != \{@aac_is_vectors.aac_is_ref_ener0[f][g]}",
          )
        }
        if out.is_ener1[g] != @aac_is_vectors.aac_is_ref_ener1[f][g] {
          fail(
            "frame \{f} band \{g}: is_ener1 \{out.is_ener1[g]} != \{@aac_is_vectors.aac_is_ref_ener1[f][g]}",
          )
        }
      } else if out.band_type1[g] != 0 {
        fail("frame \{f} band \{g}: band type set on an unselected band")
      }
      let costs : Array[(Double, Double, String)] = [
        (out.dist11[g], @aac_is_vectors.aac_is_ref_d11[f][g], "phase-1 dist1"),
        (out.dist12[g], @aac_is_vectors.aac_is_ref_d12[f][g], "phase-1 dist2"),
        (out.dist21[g], @aac_is_vectors.aac_is_ref_d21[f][g], "phase+1 dist1"),
        (out.dist22[g], @aac_is_vectors.aac_is_ref_d22[f][g], "phase+1 dist2"),
      ]
      for (got, want, name) in costs {
        let base = if want.abs() > 1.0 { want.abs() } else { 1.0 }
        let rel = (got - want).abs() / base
        if rel > max_gap {
          max_gap = rel
          max_label = "frame \{f} band \{g} \{name}: \{got} vs \{want}"
        }
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
  println(
    "IS vectors: \{is_bands} intensity bands over \{frames} frames; worst cost gap = \{max_gap} (\{max_label})",
  )
  assert_true(is_bands > 0)
  assert_true(max_gap < 1.0e-5)
}
