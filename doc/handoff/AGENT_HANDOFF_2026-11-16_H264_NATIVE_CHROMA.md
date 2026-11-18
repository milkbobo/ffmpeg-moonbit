# Native libx264 chroma inputs

Continued H.264 encoding using moonbit-c-binding and make-moonbit-c-bindings.
Consulted the other MoonBit skills; retained the existing implementation and
package layout rather than introducing declaration-only scaffolds or proofs of C.

## Change

- X264PixelFormat adds Yuv422p/Yuv422p10le/Yuv444p/Yuv444p10le.
- Stable selectors 2..5 map to FFmpeg formats in the private C boundary.
- Sample width and chroma subsampling come from AVPixFmtDescriptor, replacing
  hardcoded 420 plane sizes. No FFI signature or ownership change.
- New chroma_input_wbtest covers all four at 34x18: short U rejection, successful
  encoding after rejection, repeated close, zero FFmpeg decoder diagnostics,
  and visible-plane FNV digests equal to the pure MoonBit decoder.
- README.mbt.md includes a passing public API example. The old packed decoder
  helper remains 420-only; the frame probe handles all formats.

## Validation

- New native test: 1/1 (four formats, three pictures each).
- Existing native round-trip tests (`x264 *round-trip*`): 4/4, including 420
  baseline, CABAC/B, global headers, and ten-bit.
- README checked example: 1/1.
- Native package check and native moon info passed (two existing derive warnings).
  This toolchain writes canonical wasm interfaces only, reporting the native
  API including the four new variants in the moon info output.
- Wasm project check passed; deny-warn fails on pre-existing deprecated Array
  Show interpolation in h264_enc_stream_abr_test.mbt:131.
- ASan + leak detection passed the new native test. The companion runner cannot
  select this package/test and assumes an empty libmoonbitrun.o disables mimalloc.
  This toolchain calls mi_malloc/mi_free explicitly, so a temporary libc-forwarding
  allocator object was needed (.scratch/h264_chroma_asan_allocator.c). GCC ASan
  compile/stub/link flags were applied temporarily; package config and allocator
  restored after validation. Upstream static FFmpeg/x264 archives are uninstrumented.
- Full native suite was stopped after several minutes in the expensive oracle
  cases; no full-suite pass is claimed. Focused regression gates above passed.

No commit made; existing unrelated worktree changes preserved.

## Follow-up: packed oracle planes

The previous 420-only limitation is now removed. `x264_decode_annexb` accepts
422/444 at 8/10 bits as well as the existing 420 at 8/9/10 bits. Sink kind
0..2 retains its meaning, 3/4 denotes 422 at 8/10, 5/6 denotes 444 at 8/10.
C sink dimensions come from AVPixFmtDescriptor; MoonBit plane offsets use
rounded-up chroma geometry. Payload shape uses Int64 and bounds luma size
against payload before computing the total, avoiding count/size overflow.
No extern signature or ownership changes.

The native input test now uses 34x19 for 422 and 35x19 for 444 (both depths).
It compares packed Y/U/V bytes directly against the pure decoder on all three
pictures, in addition to checking the independent frame digests and diagnostics.
It passes normally and with ASan/leak detection (same allocator adaptation as
above). Existing 420 round-trip tests pass 4/4; the expanded public README example
encodes and reads back 444 planes, 1/1. Wasm check passes with the same pre-existing
ABR warning; native moon info passes and adds no further public declarations.
ASan package flags and container allocator restored. No full-suite rerun.
