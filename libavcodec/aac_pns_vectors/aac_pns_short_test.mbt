///|
/// Black-box regression for the eight-short-window forms of `mark_pns` and
/// `search_for_pns`, run against the sticky element arrays exactly like
/// `aacenc.c`'s element loop.
///
/// Expected values come from `_ref/aacenc/vectors_pns_short.txt`, produced by
/// running the unmodified FFmpeg 9.0.2 pair of tools on the same eight windows
/// the port analyses, with the frame-start `> RESERVED_BT` cleanup and the
/// sticky `sf_idx`/`band_type`/`zeroes` slot arrays carried across frames -
/// `search_for_pns` prices a group's inner windows against slots twoloop never
/// wrote that frame, so the sticky model is part of what the vectors pin (the
/// `STICKY` blocks are the end-of-frame state C's element carries forward).
/// Regenerate with:
///   bash _ref/aacenc/build.sh
///   ./aac_ref.exe --pns --short > vectors_pns_short.txt
///   python scripts/gen_aac_pns_short_vectors.py
///
/// Integer decisions are asserted exactly; `pns_ener` is an f32 quantity
/// compared by relative tolerance, like the long-window regression.
fn aac_pns_s_close(got : Double, want : Double, label : String) -> Unit raise {
  let d = (got - want).abs()
  let scale = if want.abs() > 1.0 { want.abs() } else { 1.0 }
  if d > scale * 1.0e-6 {
    fail("\{label}: got \{got}, want \{want}")
  }
}

///|
test "PNS mark/search matches FFmpeg 9.0.2 on eight short windows (5 frames, sticky slots)" {
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
  // The sticky element state, zeroed like FFmpeg's calloc'd element and
  // carried across the whole replay.
  let st_sf : Array[Int32] = Array::make(128, 0)
  let st_cb : Array[Int32] = Array::make(128, 0)
  let st_z : Array[Int32] = Array::make(128, 0)
  let mut random_state = 0
  let mut noise_bands = 0
  let mut can_total = 0
  for f in 0..<5 {
    let spec = @aac_pns_vectors.aac_pns_s_spec[f]
    let r = ctx.analyze(
      0,
      spec,
      0,
      2,
      if @aac_pns_vectors.aac_pns_s_prev[f] == 1 {
        1
      } else {
        0
      },
    )
    if r.alloc != @aac_pns_vectors.aac_pns_s_alloc[f] {
      fail(
        "frame \{f}: alloc \{r.alloc} != \{@aac_pns_vectors.aac_pns_s_alloc[f]}",
      )
    }
    let shape = @libavcodec.aac_two_shape_short(
      @aac_pns_vectors.aac_pns_s_group_len[f],
    )
    // `aacenc.c:929-933`: drop everything above RESERVED_BT; `sf_idx` and
    // `zeroes` stay sticky.
    for slot = 0; slot < 128; slot = slot + 1 {
      if st_cb[slot] > 12 {
        st_cb[slot] = 0
      }
    }
    // `mark_pns` runs on the psy bands analyse() just published; the quantiser
    // writes its boosted bandwidth back into the psy context afterwards, so
    // the next frame is analysed wider (same chain as the long vectors).
    let mark = @libavcodec.aac_pns_mark(
      r.bands,
      offsets,
      num_swb,
      shape,
      44100,
      128000,
      2,
      120.0,
    )
    ctx.set_cutoff(mark.bandwidth)
    // The search's returned arrays alias the sticky ones it ran on, so every
    // assertion below reads the element state directly.
    let _ = @libavcodec.aac_twoloop_search_pns(
      spec,
      sizes,
      r.bands,
      r.alloc,
      128000,
      44100,
      2,
      120.0,
      // The harness runs `pns = 1, intensity_stereo = 0`.
      @libavcodec.aac_twoloop_pns(mark.can_pns, true, false),
      shape,
      // The search runs on the sticky element arrays, like C's.
      sticky=@libavcodec.aac_two_sticky(st_sf, st_cb, st_z),
    )
    // The group-start result is what feeds `search_for_pns`; assert it at
    // the same slots (twoloop itself is pinned by the §301 vectors).
    let slots = @aac_pns_vectors.aac_pns_s_slot[f]
    for i in 0..<slots.length() {
      let slot = slots[i]
      if st_sf[slot] != @aac_pns_vectors.aac_pns_s_two_sf[f][i] {
        fail(
          "frame \{f} slot \{slot}: two sf \{st_sf[slot]} != \{@aac_pns_vectors.aac_pns_s_two_sf[f][i]}",
        )
      }
      if st_cb[slot] != @aac_pns_vectors.aac_pns_s_two_cb[f][i] {
        fail(
          "frame \{f} slot \{slot}: two cb \{st_cb[slot]} != \{@aac_pns_vectors.aac_pns_s_two_cb[f][i]}",
        )
      }
      if st_z[slot] != @aac_pns_vectors.aac_pns_s_two_z[f][i] {
        fail(
          "frame \{f} slot \{slot}: two zeroes \{st_z[slot]} != \{@aac_pns_vectors.aac_pns_s_two_z[f][i]}",
        )
      }
      if mark.can_pns[slot] != @aac_pns_vectors.aac_pns_s_can[f][i] {
        fail(
          "frame \{f} slot \{slot}: can_pns \{mark.can_pns[slot]} != \{@aac_pns_vectors.aac_pns_s_can[f][i]}",
        )
      }
      if mark.can_pns[slot] == 1 {
        can_total = can_total + 1
      }
    }
    // `search_for_pns`: reads the sticky arrays (inner-window slots included),
    // writes its noise decisions back onto them.
    let out = @libavcodec.aac_pns_search(
      @libavcodec.aac_pns_search_in(
        spec,
        sizes,
        offsets,
        r.bands,
        shape,
        st_sf,
        st_cb,
        st_z,
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
      st_cb[slot] = out.cb[slot]
      st_z[slot] = out.zeroes[slot]
    }
    for i in 0..<slots.length() {
      let slot = slots[i]
      if st_cb[slot] != @aac_pns_vectors.aac_pns_s_bt[f][i] {
        fail(
          "frame \{f} slot \{slot}: band_type \{st_cb[slot]} != \{@aac_pns_vectors.aac_pns_s_bt[f][i]}",
        )
      }
      if st_z[slot] != @aac_pns_vectors.aac_pns_s_z[f][i] {
        fail(
          "frame \{f} slot \{slot}: zeroes \{st_z[slot]} != \{@aac_pns_vectors.aac_pns_s_z[f][i]}",
        )
      }
      if st_cb[slot] == 13 {
        noise_bands = noise_bands + 1
      }
      aac_pns_s_close(
        out.pns_ener[slot],
        @aac_pns_vectors.aac_pns_s_ener[f][i],
        "frame \{f} slot \{slot} pns_ener",
      )
    }
    // The end-of-frame sticky arrays are C's carried-forward element state.
    for slot = 0; slot < 128; slot = slot + 1 {
      if st_sf[slot] != @aac_pns_vectors.aac_pns_s_sticky_sf[f][slot] {
        fail(
          "frame \{f} sticky sf[\{slot}]: \{st_sf[slot]} != \{@aac_pns_vectors.aac_pns_s_sticky_sf[f][slot]}",
        )
      }
      if st_cb[slot] != @aac_pns_vectors.aac_pns_s_sticky_cb[f][slot] {
        fail(
          "frame \{f} sticky cb[\{slot}]: \{st_cb[slot]} != \{@aac_pns_vectors.aac_pns_s_sticky_cb[f][slot]}",
        )
      }
      if st_z[slot] != @aac_pns_vectors.aac_pns_s_sticky_z[f][slot] {
        fail(
          "frame \{f} sticky z[\{slot}]: \{st_z[slot]} != \{@aac_pns_vectors.aac_pns_s_sticky_z[f][slot]}",
        )
      }
    }
  }
  println(
    "PNS short: noise bands \{noise_bands}, can_pns slots \{can_total} over 5 frames",
  )
  // The fixture must exercise both the accept path and the sticky model: noise
  // decisions land, and later frames price inner-window slots against state
  // the earlier frames left there.
  assert_true(noise_bands > 0)
  assert_true(can_total > 0)
}
