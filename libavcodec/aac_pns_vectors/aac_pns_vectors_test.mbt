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
