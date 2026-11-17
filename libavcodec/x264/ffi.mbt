///|
/// Raw extern declarations over the libx264 stub (native-only). Everything
/// here is package-private; the safe surface is in x264.mbt. `x264enc_open`
/// ALWAYS returns a handle: this toolchain's optional return for external
/// objects does not map a raw pointer to Some (verified against moon
/// 0.1.20261104), so failures surface as a failed-open handle checked via
/// `x264enc_status` / `x264enc_errmsg` right after the call. The
/// blob-returning entries encode status in-band and use NULL only for
/// allocation failures. The stub copies plane bytes in during send_frame
/// and packet payloads out during receive_packet, so every Bytes parameter
/// is call-scoped (`#borrow`).
// type X264EncHandle

///|
// #borrow(codec, options)
// extern "c" fn x264enc_open_ffi(
//   codec : Bytes,
//   width : Int32,
//   height : Int32,
//   pix_sel : Int32,
//   tb_num : Int32,
//   tb_den : Int32,
//   fps_num : Int32,
//   fps_den : Int32,
//   bit_rate : Int32,
//   flags : Int32,
//   rc_max_rate : Int32,
//   rc_buffer_size : Int32,
//   color_range : Int32,
//   colorspace : Int32,
//   color_primaries : Int32,
//   color_trc : Int32,
//   chroma_sample_location : Int32,
//   sar_num : Int32,
//   sar_den : Int32,
//   options : Bytes,
// ) -> X264EncHandle = "x264enc_open"

///|
// #borrow(enc)
// extern "c" fn x264enc_status_ffi(enc : X264EncHandle) -> Int32 = "x264enc_status"

///|
// #borrow(enc)
// extern "c" fn x264enc_errmsg_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_errmsg"

///|
// #borrow(codec)
// extern "c" fn x264enc_supports_ffi(codec : Bytes, pix_sel : Int32) -> Int32 = "x264enc_supports"

///|
/// `pict_sel` mirrors libx264.c's `frame->pict_type` switch:
/// 0 auto, 1 I without forced-idr (open-GOP keyframe), 2 I with
/// forced-idr (IDR), 3 P, 4 B. `a53` / `sei_unreg` / `roi_blob` /
/// `hint_blob` are per-picture side-data payloads (empty = absent):
/// AV_FRAME_DATA_A53_CC, AV_FRAME_DATA_SEI_UNREGISTERED,
/// AV_FRAME_DATA_REGIONS_OF_INTEREST (24 LE bytes per region: top,
/// bottom, left, right, qoffset num, den) and AV_FRAME_DATA_VIDEO_HINT
/// (16 LE bytes per rect: x, y, width, height).
/// `stereo3d_sel`: 0 absent, 1..7 = the libx264.c STEREO3D switch.
/// `hint_type`: 0 absent, 1 = CONSTANT rects, 2 = CHANGED rects.
// #borrow(enc, y, u, v, a53, sei_unreg, roi_blob, hint_blob)
// extern "c" fn x264enc_send_frame_ffi(
//   enc : X264EncHandle,
//   pts : Int64,
//   y : Bytes,
//   u : Bytes,
//   v : Bytes,
//   pict_sel : Int32,
//   a53 : Bytes,
//   sei_unreg : Bytes,
//   roi_blob : Bytes,
//   stereo3d_sel : Int32,
//   hint_type : Int32,
//   hint_blob : Bytes,
// ) -> Int32 = "x264enc_send_frame"

///|
// #borrow(enc)
// extern "c" fn x264enc_send_eof_ffi(enc : X264EncHandle) -> Int32 = "x264enc_send_eof"

///|
// #borrow(enc)
// extern "c" fn x264enc_receive_packet_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_receive_packet"

///|
// #borrow(enc)
// extern "c" fn x264enc_extradata_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_extradata"

///|
// #borrow(enc)
// extern "c" fn x264enc_close_ffi(enc : X264EncHandle) -> Unit = "x264enc_close"

///|
/// Decode a whole Annex B H.264 stream with FFmpeg's real software decoder
/// (`x264dec_annexb` in the stub). The returned blob is
/// `[n_frames i32][width i32][height i32][kind i32][color_range i32]
/// [colorspace i32][color_primaries i32][color_trc i32][chroma_location i32]
/// [payload...]` with `kind` 0/1/2 = 420 at 8/10/9 bits, 3/4 = 422 at 8/10,
/// 5/6 = 444 at 8/10, 7 = gbrp; the five colour ints are the first frame's
/// VUI-derived AVCOL_* / AVCHROMA_LOC_* values; payload per frame,
/// the packed visible-area planes Y/Cb/Cr (LE samples) — exactly
/// `H264Frame::yuvp()`'s packing. NULL means the C decode failed; the
/// stream bytes are copied into the parser during the call (`#borrow`).
// #borrow(stream)
// extern "c" fn x264dec_annexb_ffi(stream : Bytes) -> Bytes? = "x264dec_annexb"

///|
/// C-side Annex B layout / decoder-diagnostic probe (`x264probe_annexb` in
/// the stub): inventories NAL types, records the AUs FFmpeg's H.264 parser
/// split, decodes with the real software decoder, and counts the WARNING /
/// ERROR diagnostics raised. The stream bytes are copied into the parser
/// during the call, so the parameter is call-scoped (`#borrow`).
// #borrow(stream)
// extern "c" fn x264probe_annexb_ffi(stream : Bytes) -> Bytes? = "x264probe_annexb"

///|
/// C-side frame-level arbitration probe (`x264probe_frames` in the stub):
/// decodes with FFmpeg's real H.264 decoder and returns, per output
/// picture, the picture type / key-frame / display-order metadata and an
/// FNV-1a digest of the visible-area planes. The stream bytes are copied
/// into the parser during the call, so the parameter is call-scoped
/// (`#borrow`); a NULL return means the C decode failed.
// #borrow(stream)
// extern "c" fn x264probe_frames_ffi(stream : Bytes) -> Bytes? = "x264probe_frames"
