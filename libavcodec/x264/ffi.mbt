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
type X264EncHandle

///|
#borrow(codec, options)
extern "c" fn x264enc_open_ffi(
  codec : Bytes,
  width : Int32,
  height : Int32,
  pix_sel : Int32,
  tb_num : Int32,
  tb_den : Int32,
  fps_num : Int32,
  fps_den : Int32,
  bit_rate : Int32,
  flags : Int32,
  options : Bytes,
) -> X264EncHandle = "x264enc_open"

///|
#borrow(enc)
extern "c" fn x264enc_status_ffi(enc : X264EncHandle) -> Int32 = "x264enc_status"

///|
#borrow(enc)
extern "c" fn x264enc_errmsg_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_errmsg"

///|
#borrow(codec)
extern "c" fn x264enc_supports_ffi(codec : Bytes, pix_sel : Int32) -> Int32 = "x264enc_supports"

///|
#borrow(enc, y, u, v)
extern "c" fn x264enc_send_frame_ffi(
  enc : X264EncHandle,
  pts : Int64,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Int32 = "x264enc_send_frame"

///|
#borrow(enc)
extern "c" fn x264enc_send_eof_ffi(enc : X264EncHandle) -> Int32 = "x264enc_send_eof"

///|
#borrow(enc)
extern "c" fn x264enc_receive_packet_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_receive_packet"

///|
#borrow(enc)
extern "c" fn x264enc_extradata_ffi(enc : X264EncHandle) -> Bytes? = "x264enc_extradata"

///|
#borrow(enc)
extern "c" fn x264enc_close_ffi(enc : X264EncHandle) -> Unit = "x264enc_close"

///|
/// Decode a whole Annex B H.264 stream with FFmpeg's real software decoder
/// (`x264dec_annexb` in the stub). The returned blob is
/// `[n_frames i32][width i32][height i32][kind i32][payload...]` with
/// `kind` 0 = yuv420p / 1 = yuv420p10le and the payload holding, per frame,
/// the packed visible-area planes Y/Cb/Cr (LE samples) — exactly
/// `H264Frame::yuvp()`'s packing. NULL means the C decode failed; the
/// stream bytes are copied into the parser during the call (`#borrow`).
#borrow(stream)
extern "c" fn x264dec_annexb_ffi(stream : Bytes) -> Bytes? = "x264dec_annexb"
