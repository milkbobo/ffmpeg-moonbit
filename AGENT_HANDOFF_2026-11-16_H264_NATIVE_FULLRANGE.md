# H.264 native full-range inputs and VUI colour metadata

Continued the H.264 encode migration with moonbit-c-binding,
make-moonbit-c-bindings and the moonbit-agent-guide checklist. Upstream
source of truth: ../libavcodec/libx264.c pix_fmts_all (the yuvj aliases
were the last accepted pixel formats missing from the binding) and
X264_init's colour-metadata copy onto x264_param_t.vui
(libx264.c:1332-1347), plus ../libavcodec/encode.c ff_encode_preinit.

## Surface

- `X264PixelFormat` gains `Yuvj420p` / `Yuvj422p` / `Yuvj444p`
  (selectors 15-17). Plane geometry matches the limited-range planar
  formats; the C stub maps them onto AV_PIX_FMT_YUVJ*.
- `X264Encoder::open` gains five optional colour-metadata parameters
  (`color_range`, `colorspace`, `color_primaries`, `color_trc`,
  `chroma_sample_location`) holding the raw AVCOL_* / AVCHROMA_LOC_*
  values. The stub applies each field only when it differs from that
  enumeration's UNSPECIFIED value, mirroring libx264.c's guards. Twelve
  `x264_color_*` / `x264_col_*` / `x264_chroma_loc_*` constants expose
  the common values. No ownership or ABI-class change: the five ints are
  primitives appended to the open signature.
- `x264_decode_annexb`'s blob header grows 16 -> 36 bytes: the first
  frame's VUI-derived `color_range` / `colorspace` / `color_primaries` /
  `color_trc` / `chroma_location` now ride the header, surfaced as
  `X264DecFrames` fields. All existing plane readers shift by the same
  20 bytes.

## Semantics pinned while testing (all verified against real streams)

- **AVCOL_SPC_UNSPECIFIED is 2, not 0** (0 is RGB). The stub's sentinel
  and MoonBit's `colorspace` default are both 2; an explicit 0 passes
  through and makes FFmpeg decode a 4:4:4 stream as GBRP
  (h264_slice.c get_pixel_format prefers GBRP for RGB colourspace).
  An early 0-sentinel draft injected RGB into every open and flipped the
  existing 444 round-trip to GBRP — caught by the binding family.
- **FFmpeg 9 pins yuvj formats to full-range**: encode.c
  ff_encode_preinit force-writes `avctx->color_range = AVCOL_RANGE_JPEG`
  for every selected yuvj format before the wrapper's private init, so
  `color_range=1` cannot suppress full-range signalling; the format IS
  the range.
- **A present video_signal_type collapses the range export to the
  binary MPEG/JPEG pair** (h264_slice.c:1115-1116), and colour
  description lives inside video_signal_type, so any explicit colour
  metadata yields color_range=MPEG on decode.
- **AVFrame colour fields initialise to each type's own UNSPECIFIED**
  (libavutil/frame.c: primaries/trc/colorspace = 2, range/chroma = 0),
  and decode.c fill_frame_props copies the context values across; x264
  writes an explicit colour_description with the spec's unspecified
  triple (2,2,2), so even a metadata-free stream decodes with
  primaries/trc/colorspace = 2 and range = MPEG.
- **chroma_location is exported unconditionally** (h264_slice.c:1134);
  a VUI without chroma_loc_info parses to the spec default LEFT (1).

## Tests and verification

- New `fullrange_input_wbtest.mbt` 2/2 (docker native, nine-x264):
  yuvj 420/422/444 round trips at 34x18 (even geometry required for the
  420/422 subsampling) with zero-decoder-diagnostics, full-range read
  back, packed planes equal to the pure MoonBit decoder; explicit-MPEG
  suppression attempt, BT.709 description + centred chroma location pass
  through, metadata-free stream expectations per the semantics above.
  Both tests also pass under ASan + leak detection (libc-forwarding
  allocator adaptation of NATIVE_CHROMA; temporary package flags and the
  allocator copy restored/removed afterwards).
- README.mbt.md: full-range/colour-metadata sections plus a checked
  public example exercising `Yuvj420p` + `colorspace`/`color_trc`
  ("native full-range encoder example", 1/1).
- Fast regression families rerun green: binding 3/3, supports 1/1,
  lifecycle 4/4, options 3/3 (its raw extern call gained the five new
  args), grayscale/encode/forced/global/10-bit/ultrafast/medium 1/1 each.
- `asan_probe_harness.c` open prototype and both call sites synced to
  the 18-argument signature.
- Native `moon info` reports exactly the intended additions: three
  enum variants, five optional open parameters, twelve constants and the
  decoder colour fields. Wasm `moon check` clean (native-only package);
  host wasm `h264_enc_stream_abr_test.mbt` 3/3 confirms the uncommitted
  main-package chain still green.

## Baseline repairs and oracle-family triage (read before rerunning)

- **Repaired an uncommitted-chain breakage**: the worktree moon.pkg had
  dropped the `libavutil` wbtest import while `x264_wbtest.mbt`'s
  `x264_md5` still uses `@libavutil.av_md5_sum`. wbtest files compile
  per-file, so only `-f` filters landing in `x264_wbtest.mbt` (the whole
  oracle family) died with E4037 — single-file families kept passing and
  hid it. The import is restored; moon.pkg now matches HEAD exactly.
- **Oracle family verdicts** (per-file compilation means one docker
  container must be budgeted ~5 min full native build before the first
  family; subsequent families in the same container are incremental):
  - green: adaptive 2/2, mixed 1/1, multiref 4/4, online 5/5, pure* 6/6.
  - frame 4 tests 1 fail: "frame probe separates I/P-only from
    B-reordered streams" — **verified red at HEAD 94e87d7 via a throwaway
    git worktree** ("legacy I/P-only stream reported a B picture"):
    `h264_encode_frames` has defaulted `b_slices=true` since §403 while
    this test's plain leg still expects an I/P-only stream. Pre-existing
    committed breakage, unrelated to this slice and to the uncommitted
    chain; fix belongs in a follow-up (pass `b_slices=false` in the
    helper's plain leg or redesign the assertion).
  - probe 3 tests 1 fail in the first (contaminated) batch; not
    re-verified clean — same suspected HEAD-era breakage family.
  - not run (container build-time budget eaten by a config-flip race
    with the ASan validation; rerun cleanly): periodic, rate-controlled,
    short, legacy, VBV, P-slice, Intra, CABAC, high, B-, forced, keyframe,
    aq, plus the "pure H264" stems.
- **Racing hazard recorded**: running an ASan package-flag window while
  a background family batch shares the same mount invalidates that
  batch's incremental cache mid-flight; keep ASan windows and batch
  reruns strictly sequential.

No commit; the existing uncommitted worktree chain is preserved.
