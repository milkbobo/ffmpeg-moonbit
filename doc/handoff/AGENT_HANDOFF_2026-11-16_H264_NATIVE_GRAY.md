# H.264 native grayscale input

Used moonbit-c-binding and make-moonbit-c-bindings. Inspected upstream
../libavcodec/libx264.c: pix_fmts_all and convert_pix_fmt explicitly support
GRAY8/GRAY10 as X264_CSP_I400.

## Implementation

- Added public X264PixelFormat Gray8 / Gray10le, stable selectors 6/7.
- C uses AVPixFmtDescriptor component count to require zero-length U/V for
  monochrome and copy only luma. Borrowed buffers remain call-scoped; no new
  extern signature or ownership change.
- FFmpeg decodes these streams into 420 plus neutral chroma, so the packed
  decoder kind mapping is unchanged.
- Found and fixed H264Frame::yuvp rounding down subsampled chroma dimensions
  for odd visible monochrome sizes. It now rounds up as FFmpeg does. The native
  odd-sized test failed on packed-byte comparison before this correction.

## Tests and documentation

- Native grayscale test passes: 35x19, 8/10-bit, CAVLC/CABAC, forced B-frame
  schedule, seven frames each. Rejects nonempty input chroma, verifies actual B
  pictures, zero FFmpeg decoder warnings/errors, neutral U/V and complete pixels
  equal to the pure MoonBit display-order decoder.
- README checked examples 2/2, including public grayscale encode/decode.
- Native existing 420 round trips 4/4 and 422/444 chroma test 1/1.
- Existing monochrome decoder regressions wasm-gc 5/5; chroma crop regression
  wasm 1/1. Wasm debug whitebox failed to instantiate due to local-count limit;
  wasm-gc rerun passed. Wasm check passed with the existing ABR Show warning.
- Native moon info reports the two intended new enum variants.
- Grayscale native test also passes under ASan plus leak detection, without a
  sanitizer report. Same libc-forwarding allocator adaptation as NATIVE_CHROMA;
  stubs/generated code instrumented, upstream static archives uninstrumented.
  Temporary package flags and container allocator restored afterward.

No full native suite rerun; no commit; previous worktree edits preserved.
