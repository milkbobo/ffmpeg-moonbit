# H.264 encoder in-loop deblocking (§423)

Continued H.264 encoding migration with the moonbit-c-binding /
make-moonbit-c-bindings workflow and the moonbit-agent-guide checklist.
Upstream source of truth: `../libavcodec/h264_loopfilter.c`
(`filter_mb_dir` / `ff_h264_filter_mb`, base `a = 52 + slice_offset -
qp_bd_offset`, per-edge bS) and `../libavcodec/encode.c`. The deblock itself
is the decoder's already-pinned `h264_filter_mb`; this slice makes the encoder
use it on its own reconstruction.

## Behavior

- Opt-in `deblock~ : Bool = false` on `h264_encode_intra_frame(_cabac)`,
  `h264_encode_frames(_cabac)`, `H264StreamEncoder::open`, and the facade's
  `VideoEncConfig.deblock` / CLI `--deblock`.
- On: every finished picture is filtered in macroblock raster order exactly
  as a conforming decoder filters it, before it becomes a reference or is
  returned. `H264EncodedFrame.recon_*`, the batch `recon` array and the
  streaming `recons` therefore carry the decoder's filtered output.
- Off (default): byte-identical streams and pre-filter recon, so every
  pre-§423 pin stayed valid.
- The encoder writes `deblocking_filter_control_present_flag = 0`, so the
  slice offset is zero and the filter base is the decoder's neutral `52`.
  Passing 0 was the first draft's bug: alpha/beta thresholds collapsed and
  the filter changed nothing.

## Mirror completeness found while wiring (all real bugs)

- **CABAC I/P/B**: the decoder-context mirror (`ctx.infos`) already carries
  qp/nz/mb_type/transform_8x8, so filtering reuses it directly.
- **CAVLC I/P**: the per-MB state gained `qp` (extended, AQ-aware) and
  `tf8`; `commit_plan_state`/`commit_skip` and the three intra commit sites
  write them.
- **CAVLC B**: the mirror was missing the picture QP for coded macroblocks
  (`info.qp` defaulted to 0) and the luma-8x8 flag on the inter residual
  tail; the loop now also mirrors the final nz counts into the mirror.
  Without these two the B pictures alone mismatched the decoder.
- **Reference identity**: bS compares picture identity, not the coded
  index. The helper synthesises `L0 = idx*8+3`, `L1 = idx1*8+7` (disjoint so
  the swapped comparison in `h264_bs_pair` stays correct); encoder reference
  lists hold distinct pictures, so equality/inequality matches `ref2frm`.
- **Facade `frame_qps` duplication** (pre-existing uncommitted-chain bug):
  the stream encoder records each accepted picture's QP itself and the
  keyint batch path pushed it again (16 vs 8). Removed the facade push.

## Verification

- New `h264_enc_deblock_test.mbt` 8/8 (wasm):
  - IDR: 420/422/444 × CAVLC/CABAC recon equals the default decode and
    differs from the skip-filter decode; the fixture is asserted to change
    under the filter.
  - I+P and B schedules at 420/422/444 × both entropies: every recon equals
    the default decode.
  - 10-bit B schedule; streaming == batch bytes and filtered recons; facade
    forwards the flag; default-off stays pre-filter.
- External arbitration (`docker ffmpeg-moonbit-ffref:nine`, FFmpeg 9.0.2,
  96x64 qp26, five frames, CABAC B schedule, `--deblock`): default decode
  is zero-warning and equals the local display-order output,
  `6ed6c2cec81a95e66e174817d4c3cf8a`; `-skip_loop_filter all` gives
  `c0c67a327a578a5d497c2b4f3422dec6`, so the filter is really active. Pinned
  in the test.
- CLI: `--deblock` parse/forward test (batch == streaming, and filtered
  references change the bytes), CLI suite 24/24.
- Regressions green so far: idr 5/5 (after the frame_qps fix), cabac 10/10,
  b 8/8, multiref 14/14, combo 5/5, high10 8/8, stream 8/8,
  stream_c444 3/3, stream_c444_b 3/3, c444_b 2/2, c444_cabac 2/2,
  c422_depth 4/4, h1214 5/5, video_encoder 7/7, periodic_b 3/3,
  periodic_vbv 4/4, c444 family 10 files 1/1 each, c422 4/4,
  b_multiref 9/9, cabacrd 6/6, binter8_420 wbtest 1/1 (wasm-gc; wasm
  debug hits the known local-count limit).

## Boundaries

- Streaming ABR + deblock works through the same per-picture filter.
- `deblock` stays opt-in: flipping the default changes references and would
  re-pin the whole corpus. That is a separate, mechanical slice.

## Next candidates

- Flip the default on and re-arbitrate/re-pin the full corpus.
- Per-block QP (`mb_qp_delta`) already exercised; consider multi-slice
  deblocking only if multi-slice encoding lands.
