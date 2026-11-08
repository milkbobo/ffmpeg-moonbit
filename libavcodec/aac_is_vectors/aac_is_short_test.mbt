///|
/// Black-box regression for the eight-short-window forms of the stereo pair of
/// tools, run against the sticky element arrays exactly like `aacenc.c`'s
/// element loop: per channel `mark_pns` + twoloop + `search_for_pns` with the
/// slot state carried across frames, then `search_for_is` + the intensity mix
/// + `search_for_ms`, all walking `w += group_len[w]`.
///
/// Expected values come from `_ref/aacenc/vectors_isms_short.txt`, produced by
/// the unmodified FFmpeg 9.0.2 pair of tools on the same phase-mixed stereo
/// spectra the port replays (window-dependent correlation sign, so both
/// intensity phases, the flip variant and mid/side wins all fire - 79 IS
/// accepts with 12 `INTENSITY_BT2` and 7 flips, 122 M/S wins over the 5
/// frames).  The `PRE` rows pin the post-PNS state both searches read, the
/// `STICKY` rows the full 128-slot state the next frame inherits.  Regenerate
/// with:
///   bash _ref/aacenc/build.sh
///   ./aac_ref.exe --isms > vectors_isms_short.txt
///   python scripts/gen_aac_isms_short_vectors.py
fn aac_isms_close(got : Double, want : Double, label : String) -> Unit raise {
  let d = (got - want).abs()
  let scale = if want.abs() > 1.0 { want.abs() } else { 1.0 }
  if d > scale * 1.0e-6 {
    fail("\{label}: got \{got}, want \{want}")
  }
}

///|
test "IS/MS match FFmpeg 9.0.2 on eight short windows (5 frames, stereo pair)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes_short()
  let offsets : Array[Int32] = []
  let mut acc = 0
  offsets.push(0)
  for g in 0..<sizes.length() {
    acc = acc + sizes[g]
    offsets.push(acc)
  }
  let num_swb = sizes.length()
  // Two channels' sticky slot state, zeroed like FFmpeg's calloc'd element.
  let st_sf : Array[Array[Int32]] = [Array::make(128, 0), Array::make(128, 0)]
  let st_cb : Array[Array[Int32]] = [Array::make(128, 0), Array::make(128, 0)]
  let st_z : Array[Array[Int32]] = [Array::make(128, 0), Array::make(128, 0)]
  // One LCG chain shared by both channels, like `s->random_state`.
  let mut random_state = 0
  let mut is_bands = 0
  let mut flip_bands = 0
  let mut ms_bands = 0
  for f in 0..<5 {
    let spec0 = @aac_is_vectors.aac_isms_spec0[f]
    let spec1 = @aac_is_vectors.aac_isms_spec1[f]
    // `aacenc.c:929-933` cleanup on both channels.
    for ch = 0; ch < 2; ch = ch + 1 {
      for slot = 0; slot < 128; slot = slot + 1 {
        if st_cb[ch][slot] > 12 {
          st_cb[ch][slot] = 0
        }
      }
    }
    let shape = @libavcodec.aac_two_shape_short(
      @aac_is_vectors.aac_isms_group_len[f],
    )
    // One analyze per channel; the pair shares the reservoir, like the
    // single group-analyze call the harness makes.  `bitres.alloc` is
    // element-level state, so what survives is the *last* channel's pass.
    // The §366 domain adapter applies from here down: doubled spectra, 4x
    // energy/threshold bands (`spread` is dimensionless), sf == ref + 4.
    let r0 = ctx.analyze(0, spec0, 0, 2, 0)
    let r1 = ctx.analyze(1, spec1, 0, 2, 0)
    if r1.alloc != @aac_is_vectors.aac_isms_alloc[f] {
      fail(
        "frame \{f}: alloc \{r1.alloc} != \{@aac_is_vectors.aac_isms_alloc[f]}",
      )
    }
    let bands0 = @libavcodec.aac_psy_bands_encoder_domain(r0.bands)
    let bands1 = @libavcodec.aac_psy_bands_encoder_domain(r1.bands)
    let spec0_2 : Array[Double] = spec0.map(x => x * 2.0)
    let spec1_2 : Array[Double] = spec1.map(x => x * 2.0)
    // Per channel: mark_pns, twoloop (on the sticky arrays), search_for_pns.
    for ch = 0; ch < 2; ch = ch + 1 {
      let r = if ch == 0 { bands0 } else { bands1 }
      let spec = if ch == 0 { spec0_2 } else { spec1_2 }
      let mark = @libavcodec.aac_pns_mark(
        r, offsets, num_swb, shape, 44100, 128000, 2, 120.0,
      )
      ctx.set_cutoff(mark.bandwidth)
      // The pair shares the element grant (`bitres.alloc /= chans`).
      let alloc = r1.alloc / 2
      let _ = @libavcodec.aac_twoloop_search_pns(
        spec,
        sizes,
        r,
        alloc,
        128000,
        44100,
        2,
        120.0,
        // The harness runs `pns = 1, intensity_stereo = 1` (the pair of
        // switches feeds twoloop's bandwidth compensation).
        @libavcodec.aac_twoloop_pns(mark.can_pns, true, true),
        shape,
        sticky=@libavcodec.aac_two_sticky(st_sf[ch], st_cb[ch], st_z[ch]),
      )
      let out = @libavcodec.aac_pns_search(
        @libavcodec.aac_pns_search_in(
          spec,
          sizes,
          offsets,
          r,
          shape,
          st_sf[ch],
          st_cb[ch],
          st_z[ch],
          mark.can_pns,
          mark.pns_ener,
          random_state,
        ),
        44100,
        128000,
        2,
        120.0,
      )
      random_state = out.random_state
      for slot = 0; slot < 128; slot = slot + 1 {
        st_cb[ch][slot] = out.cb[slot]
        st_z[ch][slot] = out.zeroes[slot]
      }
    }
    // The post-PNS state the stereo tools (and the next frame) see.
    let slots = @aac_is_vectors.aac_isms_slot[f]
    for i in 0..<slots.length() {
      let slot = slots[i]
      if st_sf[0][slot] != @aac_is_vectors.aac_isms_pre0_sf[f][i] + 4 {
        fail(
          "frame \{f} slot \{slot}: pre0 sf \{st_sf[0][slot]} != \{@aac_is_vectors.aac_isms_pre0_sf[f][i] + 4}",
        )
      }
      if st_cb[0][slot] != @aac_is_vectors.aac_isms_pre0_bt[f][i] {
        fail(
          "frame \{f} slot \{slot}: pre0 bt \{st_cb[0][slot]} != \{@aac_is_vectors.aac_isms_pre0_bt[f][i]}",
        )
      }
      if st_z[0][slot] != @aac_is_vectors.aac_isms_pre0_z[f][i] {
        fail(
          "frame \{f} slot \{slot}: pre0 z \{st_z[0][slot]} != \{@aac_is_vectors.aac_isms_pre0_z[f][i]}",
        )
      }
      if st_sf[1][slot] != @aac_is_vectors.aac_isms_pre1_sf[f][i] + 4 {
        fail(
          "frame \{f} slot \{slot}: pre1 sf \{st_sf[1][slot]} != \{@aac_is_vectors.aac_isms_pre1_sf[f][i] + 4}",
        )
      }
      if st_cb[1][slot] != @aac_is_vectors.aac_isms_pre1_bt[f][i] {
        fail(
          "frame \{f} slot \{slot}: pre1 bt \{st_cb[1][slot]} != \{@aac_is_vectors.aac_isms_pre1_bt[f][i]}",
        )
      }
    }
    for slot = 0; slot < 128; slot = slot + 1 {
      if st_sf[0][slot] != @aac_is_vectors.aac_isms_sticky0_sf[f][slot] + 4 ||
        st_cb[0][slot] != @aac_is_vectors.aac_isms_sticky0_bt[f][slot] ||
        st_z[0][slot] != @aac_is_vectors.aac_isms_sticky0_z[f][slot] {
        fail("frame \{f}: ch0 sticky slot \{slot} diverged")
      }
      if st_sf[1][slot] != @aac_is_vectors.aac_isms_sticky1_sf[f][slot] + 4 ||
        st_cb[1][slot] != @aac_is_vectors.aac_isms_sticky1_bt[f][slot] ||
        st_z[1][slot] != @aac_is_vectors.aac_isms_sticky1_z[f][slot] {
        fail("frame \{f}: ch1 sticky slot \{slot} diverged")
      }
    }
    // The thresholds in slot layout, one row per channel.
    let thr0 : Array[Double] = Array::make(128, 0.0)
    let thr1 : Array[Double] = Array::make(128, 0.0)
    for slot = 0; slot < 128; slot = slot + 1 {
      thr0[slot] = bands0[slot].threshold
      thr1[slot] = bands1[slot].threshold
    }
    // `ff_aac_search_for_is` on the raw spectra (PNS synthesises at decode
    // time, so the coefficients are still the analysis output here).
    let isr = @libavcodec.aac_is_search(
      @libavcodec.aac_is_in(
        spec0_2,
        spec1_2,
        sizes,
        shape,
        thr0,
        thr1,
        st_sf[0],
        st_sf[1],
        st_cb[0],
        st_cb[1],
        st_z[0],
        st_z[1],
        num_swb,
      ),
      44100,
      120.0,
    )
    for i in 0..<slots.length() {
      let slot = slots[i]
      if isr.is_mask[slot] != @aac_is_vectors.aac_isms_is_mask[f][i] {
        fail(
          "frame \{f} slot \{slot}: is_mask \{isr.is_mask[slot]} != \{@aac_is_vectors.aac_isms_is_mask[f][i]}",
        )
      }
      if isr.ms_mask[slot] != @aac_is_vectors.aac_isms_is_ms[f][i] {
        fail(
          "frame \{f} slot \{slot}: is ms_mask \{isr.ms_mask[slot]} != \{@aac_is_vectors.aac_isms_is_ms[f][i]}",
        )
      }
      // `band_type1` carries a value only where the search claimed the band;
      // elsewhere the harness prints the post-PNS codebook, which the MSDUMP
      // rows below cover instead.
      if isr.is_mask[slot] == 1 {
        if isr.band_type1[slot] != @aac_is_vectors.aac_isms_is_bt[f][i] {
          fail(
            "frame \{f} slot \{slot}: is bt1 \{isr.band_type1[slot]} != \{@aac_is_vectors.aac_isms_is_bt[f][i]}",
          )
        }
        is_bands = is_bands + 1
        if isr.ms_mask[slot] == 1 {
          flip_bands = flip_bands + 1
        }
        aac_isms_close(
          isr.is_ener0[slot],
          @aac_is_vectors.aac_isms_is_e0[f][i],
          "frame \{f} slot \{slot} is_ener0",
        )
        aac_isms_close(
          isr.is_ener1[slot],
          @aac_is_vectors.aac_isms_is_e1[f][i],
          "frame \{f} slot \{slot} is_ener1",
        )
      }
    }
    // The intensity mix, on copies - the mid/side search reads the mixed pair.
    let left = spec0_2.copy()
    let right = spec1_2.copy()
    let flip : Array[Bool] = Array::make(128, false)
    for slot = 0; slot < 128; slot = slot + 1 {
      flip[slot] = isr.ms_mask[slot] == 1
    }
    let group_len = @aac_is_vectors.aac_isms_group_len[f]
    @libavcodec.aac_is_apply(
      left,
      right,
      offsets,
      num_swb,
      8,
      group_len,
      isr.band_type1,
      flip,
      isr.is_ener0,
    )
    // The right channel's band type the mid/side search must see: 14/15 where
    // intensity claimed the band, the post-PNS type elsewhere.
    let cb1 : Array[Int32] = Array::make(128, 0)
    for slot = 0; slot < 128; slot = slot + 1 {
      cb1[slot] = if isr.is_mask[slot] == 1 {
        isr.band_type1[slot]
      } else {
        st_cb[1][slot]
      }
    }
    let ms = @libavcodec.aac_ms_search(
      @libavcodec.aac_ms_in(
        left,
        right,
        sizes,
        shape,
        thr0,
        thr1,
        st_sf[0],
        st_sf[1],
        st_cb[0],
        cb1,
        st_z[0],
        st_z[1],
        isr.is_mask,
        isr.ms_mask,
        num_swb,
      ),
      120.0,
    )
    for i in 0..<slots.length() {
      let slot = slots[i]
      if ms.ms_mask[slot] != @aac_is_vectors.aac_isms_ms_mask[f][i] {
        fail(
          "frame \{f} slot \{slot}: ms_mask \{ms.ms_mask[slot]} != \{@aac_is_vectors.aac_isms_ms_mask[f][i]}",
        )
      }
      if ms.sf0[slot] != @aac_is_vectors.aac_isms_ms_sf0[f][i] + 4 {
        fail(
          "frame \{f} slot \{slot}: ms sf0 \{ms.sf0[slot]} != \{@aac_is_vectors.aac_isms_ms_sf0[f][i] + 4}",
        )
      }
      if ms.cb0[slot] != @aac_is_vectors.aac_isms_ms_cb0[f][i] {
        fail(
          "frame \{f} slot \{slot}: ms cb0 \{ms.cb0[slot]} != \{@aac_is_vectors.aac_isms_ms_cb0[f][i]}",
        )
      }
      if ms.sf1[slot] != @aac_is_vectors.aac_isms_ms_sf1[f][i] + 4 {
        fail(
          "frame \{f} slot \{slot}: ms sf1 \{ms.sf1[slot]} != \{@aac_is_vectors.aac_isms_ms_sf1[f][i] + 4}",
        )
      }
      if ms.cb1[slot] != @aac_is_vectors.aac_isms_ms_cb1[f][i] {
        fail(
          "frame \{f} slot \{slot}: ms cb1 \{ms.cb1[slot]} != \{@aac_is_vectors.aac_isms_ms_cb1[f][i]}",
        )
      }
      if ms.ms_mask[slot] == 1 {
        ms_bands = ms_bands + 1
      }
    }
    // C's element carries the stereo rewrites into the next frame: the search
    // only writes group-start slots, but the *next* frame's grouping can turn
    // one of them into an inner window, whose rate loop then scales from the
    // rewritten value.  Zeroes are untouched by both tools.
    for slot = 0; slot < 128; slot = slot + 1 {
      st_sf[0][slot] = ms.sf0[slot]
      st_cb[0][slot] = ms.cb0[slot]
      st_sf[1][slot] = ms.sf1[slot]
      st_cb[1][slot] = ms.cb1[slot]
    }
  }
  println(
    "IS/MS short: is=\{is_bands} (flips \{flip_bands}) ms=\{ms_bands} over 5 frames",
  )
  // Both tools have to actually fire on the fixture, flips included.
  assert_true(is_bands > 0)
  assert_true(flip_bands > 0)
  assert_true(ms_bands > 0)
}
