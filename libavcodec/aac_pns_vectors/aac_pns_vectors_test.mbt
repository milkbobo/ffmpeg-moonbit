///|
/// Black-box regression for the encoder-side PNS decision (`mark_pns`).
///
/// Expected values come from `_ref/aacenc/aac_ref.exe --pns`, which runs the
/// unmodified FFmpeg 9.0.2 `mark_pns` (`aaccoder.c:631`) on an LCG-noise
/// spectrum. Regenerate with:
///   bash _ref/aacenc/build.sh
///   python scripts/gen_aac_pns_vectors.py
///
/// The psy bands that feed `mark_pns` are recomputed here from the same
/// spectra: the psy port is bit-exact against `aacpsy.c` (§277), so this keeps
/// the fixture to the inputs that matter (spectrum -> can_pns / pns_ener) and
/// also pins the psy-to-PNS interface.
test "PNS mark_pns matches FFmpeg 9.0.2 aaccoder.c (5 frames x 49 bands)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  let offsets : Array[Int32] = []
  let mut acc = 0
  offsets.push(0)
  for g in 0..<sizes.length() {
    acc = acc + sizes[g]
    offsets.push(acc)
  }
  let num_swb = sizes.length()
  let mut can_pns = 0
  for f in 0..<5 {
    let r = ctx.analyze(0, @aac_pns_vectors.aac_pns_spec[f], 0, 0, 0)
    let mark = @libavcodec.aac_pns_mark(
      r.bands, offsets, num_swb, 44100, 128000, 2, 120.0,
    )
    // The reference harness runs the quantiser after `mark_pns`, and the
    // quantiser writes its bandwidth back into the psy context (sticky, with
    // the 1.15 PNS factor). Frames 1..4 are therefore analysed wider than
    // frame 0, which is what the reference vectors reflect.
    ctx.set_cutoff(mark.bandwidth)
    for g in 0..<num_swb {
      let want_can = @aac_pns_vectors.aac_pns_ref_can[f][g]
      if mark.can_pns[g] != want_can {
        fail(
          "frame \{f} band \{g}: can_pns \{mark.can_pns[g]} != \{want_can} (energy \{r.bands[g].energy}, ref energy \{@aac_pns_vectors.aac_pns_ref_ener[f][g]}, threshold \{r.bands[g].threshold}, spread \{r.bands[g].spread})",
        )
      }
      if mark.can_pns[g] == 1 {
        can_pns = can_pns + 1
      }
      let want = @aac_pns_vectors.aac_pns_ref_ener[f][g]
      let got = mark.pns_ener[g]
      let tol = if want.abs() > 1.0 { want.abs() * 1.0e-6 } else { 1.0e-6 }
      if (got - want).abs() > tol {
        fail("frame \{f} band \{g}: pns_ener \{got} != \{want}")
      }
    }
  }
  println("PNS: can_pns bands over 5 frames = \{can_pns}")
  // The noise fixture has to actually exercise the accept path: 99 of the 245
  // bands are marked in the reference, all of them between 4 kHz and cutoff.
  assert_true(can_pns == 99)
}

///|
/// Step 2 of §283, done in one pass (§285 showed it cannot be split): every
/// PNS coupling in the twoloop rate loop — the `spread_thr_r` ranking computed
/// with the initial distortion limits, `ff_pns_bits` in the bit count, the
/// 1.15 bandwidth factor, and the `overdist`-driven zeroing block. The C
/// reference `--pns` run calls `mark_pns` and then the unmodified twoloop, so
/// its `TWOBAND` lines are the golden `sf/cb/zeroes`.
test "PNS-aware twoloop matches FFmpeg 9.0.2 (5 frames x 49 bands)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  let offsets : Array[Int32] = []
  let mut acc = 0
  offsets.push(0)
  for g in 0..<sizes.length() {
    acc = acc + sizes[g]
    offsets.push(acc)
  }
  let num_swb = sizes.length()
  let mut bad = 0
  for f in 0..<5 {
    let r = ctx.analyze(0, @aac_pns_vectors.aac_pns_spec[f], 0, 0, 0)
    let mark = @libavcodec.aac_pns_mark(
      r.bands, offsets, num_swb, 44100, 128000, 2, 120.0,
    )
    let two = @libavcodec.aac_twoloop_search_pns(
      @aac_pns_vectors.aac_pns_spec[f],
      sizes,
      r.bands,
      r.alloc,
      128000,
      44100,
      2,
      120.0,
      // The reference harness runs `pns = 1, intensity_stereo = 0`, and twoloop's
      // bandwidth compensation reads the *pair* of switches (§296).
      @libavcodec.aac_twoloop_pns(mark.can_pns, true, false),
    )
    // The C reference writes the quantiser's bandwidth back into the psy
    // context, where it sticks for later frames (§284).
    ctx.set_cutoff(mark.bandwidth)
    for g in 0..<num_swb {
      let wsf = @aac_pns_vectors.aac_pns_ref_sf[f][g]
      let wcb = @aac_pns_vectors.aac_pns_ref_cb[f][g]
      let wzero = @aac_pns_vectors.aac_pns_ref_zero[f][g]
      if two.sf[g] != wsf || two.cb[g] != wcb || two.zeroes[g] != wzero {
        bad = bad + 1
        if bad <= 8 {
          println(
            "frame \{f} band \{g}: got \{two.sf[g]}/\{two.cb[g]}/\{two.zeroes[g]} want \{wsf}/\{wcb}/\{wzero}",
          )
        }
      }
    }
  }
  println("PNS twoloop mismatching bands: \{bad} / 245")
  assert_true(bad == 0)
}

///|
/// Step 3 of §283: `search_for_pns` (`aaccoder.c:489`). The C harness runs it
/// after `mark_pns` and the PNS-aware twoloop and dumps `PNSFINAL` — the final
/// band type (13 = NOISE_BT), scalefactor, zero flag and noise energy. The LCG
/// state is carried across frames, so this test threads it through too.
test "PNS search_for_pns matches FFmpeg 9.0.2 (5 frames x 49 bands)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes()
  let offsets : Array[Int32] = []
  let mut acc = 0
  offsets.push(0)
  for g in 0..<sizes.length() {
    acc = acc + sizes[g]
    offsets.push(acc)
  }
  let num_swb = sizes.length()
  let mut random_state : Int32 = 0
  let mut bad = 0
  let mut noise_bands = 0
  for f in 0..<5 {
    let spec = @aac_pns_vectors.aac_pns_spec[f]
    let r = ctx.analyze(0, spec, 0, 0, 0)
    let mark = @libavcodec.aac_pns_mark(
      r.bands, offsets, num_swb, 44100, 128000, 2, 120.0,
    )
    let two = @libavcodec.aac_twoloop_search_pns(
      spec,
      sizes,
      r.bands,
      r.alloc,
      128000,
      44100,
      2,
      120.0,
      // The reference harness runs `pns = 1, intensity_stereo = 0`, and twoloop's
      // bandwidth compensation reads the *pair* of switches (§296).
      @libavcodec.aac_twoloop_pns(mark.can_pns, true, false),
    )
    let out = @libavcodec.aac_pns_search(
      @libavcodec.aac_pns_search_in(
        spec, sizes, offsets, r.bands, two.sf, two.cb, two.zeroes,
        mark.can_pns, mark.pns_ener, random_state,
      ),
      44100,
      128000,
      2,
      120.0,
    )
    random_state = out.random_state
    ctx.set_cutoff(mark.bandwidth)
    for g in 0..<num_swb {
      let wbt = @aac_pns_vectors.aac_pns_ref_final_bt[f][g]
      let wsf = @aac_pns_vectors.aac_pns_ref_final_sf[f][g]
      let wzero = @aac_pns_vectors.aac_pns_ref_final_zero[f][g]
      if out.cb[g] != wbt || two.sf[g] != wsf || out.zeroes[g] != wzero {
        bad = bad + 1
        if bad <= 8 {
          println(
            "frame \{f} band \{g}: got \{out.cb[g]}/\{two.sf[g]}/\{out.zeroes[g]} want \{wbt}/\{wsf}/\{wzero}",
          )
        }
      }
      if wbt == 13 {
        noise_bands = noise_bands + 1
      }
    }
  }
  println(
    "PNS search_for_pns mismatching bands: \{bad} / 245 (noise bands \{noise_bands})",
  )
  assert_true(noise_bands > 0)
  assert_true(bad == 0)
}
