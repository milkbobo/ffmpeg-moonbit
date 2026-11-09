///|
/// Black-box regression for the eight-short-window form of the twoloop
/// quantiser search.
///
/// Expected values come from `_ref/aacenc/vectors_short.txt`, produced by
/// running the unmodified FFmpeg 9.0.2 `aaccoder_twoloop.h` on the same eight
/// windows the port analyses (the harness forces `EIGHT_SHORT_SEQUENCE`, since
/// upstream only reaches it when the psy model's block switcher asks for it).
/// Regenerate with:
///   bash _ref/aacenc/build.sh
///   ./aac_ref.exe --short > vectors_short.txt
///   python scripts/gen_aac_twoloop_short_vectors.py
///
/// `sf_idx` / `band_type` / `zeroes` are integer decisions and asserted
/// exactly; `maxvals` is an f32 quantity compared by relative tolerance, like
/// the long-window regression.
fn aac_two_short_close(
  got : Double,
  want : Double,
  tol : Double,
  label : String,
) -> Unit raise {
  let d = (got - want).abs()
  let scale = if want.abs() > 1.0 { want.abs() } else { 1.0 }
  if d > scale * tol {
    fail("\{label}: got \{got}, want \{want}, tolerance \{tol}")
  }
}

///|
/// FFmpeg's `window_sequence` enum: 0 `ONLY_LONG`, 1 `LONG_START`,
/// 2 `EIGHT_SHORT`, 3 `LONG_STOP`.
let aac_two_seq_only_long : Int32 = 0

///|
let aac_two_seq_long_start : Int32 = 1

///|
let aac_two_seq_eight_short : Int32 = 2

///|
test "twoloop eight short windows matches FFmpeg 9.0.2 aaccoder.c (5 frames x 8 windows)" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes_short()
  if sizes.length() != 14 {
    fail("44100 Hz short plan must have 14 bands, got \{sizes.length()}")
  }
  for f in 0..<5 {
    let r = ctx.analyze(
      0,
      @aac_twoloop_vectors.aac_two_short_spec[f],
      0,
      aac_two_seq_eight_short,
      if @aac_twoloop_vectors.aac_two_short_prev[f] == 1 {
        aac_two_seq_long_start
      } else {
        aac_two_seq_only_long
      },
    )
    // The search's `destbits` come from the analysis, so pin that hand-off too.
    if r.alloc != @aac_twoloop_vectors.aac_two_short_alloc[f] {
      fail(
        "frame \{f}: alloc \{r.alloc} != \{@aac_twoloop_vectors.aac_two_short_alloc[f]}",
      )
    }
    let two = @libavcodec.aac_twoloop_search(
      @aac_twoloop_vectors.aac_two_short_spec[f],
      sizes,
      r.bands,
      r.alloc,
      128000,
      44100,
      2,
      120.0,
      @libavcodec.aac_two_shape_short(
        @aac_twoloop_vectors.aac_two_short_group_len[f],
      ),
    )
    let slots = @aac_twoloop_vectors.aac_two_short_slot[f]
    for i in 0..<slots.length() {
      let slot = slots[i]
      if slot % 16 >= 14 {
        fail("frame \{f} record \{i}: slot \{slot} is not a band of a window")
      }
      if two.sf[slot] != @aac_twoloop_vectors.aac_two_short_sf[f][i] {
        fail(
          "frame \{f} slot \{slot}: sf \{two.sf[slot]} != \{@aac_twoloop_vectors.aac_two_short_sf[f][i]}",
        )
      }
      if two.cb[slot] != @aac_twoloop_vectors.aac_two_short_cb[f][i] {
        fail(
          "frame \{f} slot \{slot}: cb \{two.cb[slot]} != \{@aac_twoloop_vectors.aac_two_short_cb[f][i]}",
        )
      }
      if two.zeroes[slot] != @aac_twoloop_vectors.aac_two_short_zeroes[f][i] {
        fail(
          "frame \{f} slot \{slot}: zeroes \{two.zeroes[slot]} != \{@aac_twoloop_vectors.aac_two_short_zeroes[f][i]}",
        )
      }
      aac_two_short_close(
        two.maxvals[slot],
        @aac_twoloop_vectors.aac_two_short_maxvals[f][i],
        0.00001,
        "frame \{f} slot \{slot} maxval",
      )
      // The contract the bitstream writer relies on.
      if two.zeroes[slot] != 0 && two.cb[slot] != 0 {
        fail("frame \{f} slot \{slot}: zeroed band carries codebook")
      }
    }
  }
}

///|
/// The grouping really is threaded through the search: the same frame under the
/// all-singleton grouping (eight independent windows) and under the grouping C
/// picked must reach different scalefactors, because a group shares one
/// scalefactor across its windows and its cost is the sum over them.
test "twoloop short search depends on the window grouping" {
  let ctx = @libavcodec.aac_psy_new(4, 44100, 128000, 2)
  let sizes = ctx.band_sizes_short()
  let spec = @aac_twoloop_vectors.aac_two_short_spec[0]
  let gl = @aac_twoloop_vectors.aac_two_short_group_len[0]
  let r = ctx.analyze(
    0, spec, 0, aac_two_seq_eight_short, aac_two_seq_only_long,
  )
  let grouped = @libavcodec.aac_twoloop_search(
    spec,
    sizes,
    r.bands,
    r.alloc,
    128000,
    44100,
    2,
    120.0,
    @libavcodec.aac_two_shape_short(gl),
  )
  let flat = @libavcodec.aac_twoloop_search(
    spec,
    sizes,
    r.bands,
    r.alloc,
    128000,
    44100,
    2,
    120.0,
    @libavcodec.aac_two_shape_short([1, 1, 1, 1, 1, 1, 1, 1]),
  )
  let mut differ = 0
  let mut w = 0
  while w < 8 {
    let base = w * 16
    for g in 0..<14 {
      if grouped.sf[base + g] != flat.sf[base + g] {
        differ = differ + 1
      }
    }
    w = w + gl[w]
  }
  if differ == 0 {
    fail("grouping had no effect on the short search")
  }
}
