///|
/// White-box test for the H.264 Baseline I-picture reconstruction path against
/// FFmpeg 9.0.2's `-skip_loop_filter all` output for the real vector in
/// `h264_decode_realdata.mbt`.
///
/// The stream has two IDR frames (64x48, 4x3 macroblocks, one slice each).
/// Expected per-frame YUV420P MD5s:
///   frame 0: da26f3c6711e214ec4372d361256714c
///   frame 1: 1586ccec95606bf17189273f2b58399d

fn h264_hex(bytes : FixedArray[Byte], n : Int) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

fn h264_yuv_md5(frame : H264Frame) -> String {
  let yuv = frame.yuv420p()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  h264_hex(digest, 16)
}

test "h264: baseline 64x48 IDR frames match FFmpeg skip_loop_filter YUV" {
  let data = @libavutil.av_base64_decode(h264_baseline_b64, 4096).unwrap()
  assert_eq(data.length(), 3111)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  let f0 = frames[0]
  let f1 = frames[1]
  assert_eq(f0.width, 64)
  assert_eq(f0.height, 48)
  assert_eq(f0.yuv420p().length(), 4608)
  assert_eq(h264_yuv_md5(f0), "da26f3c6711e214ec4372d361256714c")
  assert_eq(h264_yuv_md5(f1), "1586ccec95606bf17189273f2b58399d")
}

test "h264: reconstructed frame is not a flat prediction" {
  // Guard against a decoder that silently emits only prediction (no
  // residual): the testsrc2 frames contain strong edges, so at least the
  // luma plane must use a wide range of sample values.
  let data = @libavutil.av_base64_decode(h264_baseline_b64, 4096).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  let y = frames[0].y
  let mut lo = 255
  let mut hi = 0
  for i = 0; i < 64 * 48; i = i + 1 {
    if y[i] < lo {
      lo = y[i]
    }
    if y[i] > hi {
      hi = y[i]
    }
  }
  assert_true(hi - lo > 32)
}


test "h264: smooth gradient stream matches FFmpeg (I16x16 luma DC)" {
  let data = @libavutil.av_base64_decode(h264_smooth_b64, 8192).unwrap()
  assert_eq(data.length(), 1852)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "2a669a38852259d19cb8e6a47c636f58")
  assert_eq(h264_yuv_md5(frames[1]), "4134a7443a5aea6d556991b76f927c73")
}

test "h264: flat color stream matches FFmpeg (I16x16 DC/VERT, no residual)" {
  let data = @libavutil.av_base64_decode(h264_flat_b64, 4096).unwrap()
  assert_eq(data.length(), 728)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "6b020c288feee0476f843bc661767cce")
  assert_eq(h264_yuv_md5(frames[1]), "6b020c288feee0476f843bc661767cce")
}

test "h264: cropped 88x56 stream matches FFmpeg (SPS frame cropping)" {
  // 88x56 is not macroblock aligned: the SPS codes 6x4 MB and crops the
  // right/bottom edges. This pins the cropping path (`crop_left`/`crop_top`
  // offsets and the visible-area pack in `H264Frame::yuv420p`) which the
  // 64x48 vectors never exercise.
  let data = @libavutil.av_base64_decode(h264_crop_b64, 8192).unwrap()
  assert_eq(data.length(), 3639)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(frames[0].width, 88)
  assert_eq(frames[0].height, 56)
  assert_eq(frames[0].yuv420p().length(), 88 * 56 * 3 / 2)
  assert_eq(h264_yuv_md5(frames[0]), "5caea57669dc7e596d069df0f0be9676")
  assert_eq(h264_yuv_md5(frames[1]), "3457eb7fad46d633d0064c1c56bf88c3")
}

test "h264: qp=40 stream matches FFmpeg (coarse quantisation)" {
  // At qp=40 most AC coefficients are zero: this drives the CAVLC
  // total_zeros / run_before paths with long zero runs.
  let data = @libavutil.av_base64_decode(h264_qp40_b64, 4096).unwrap()
  assert_eq(data.length(), 2283)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(frames[0].width, 80)
  assert_eq(frames[0].height, 64)
  assert_eq(h264_yuv_md5(frames[0]), "a63a4b6e69e85238c5cf938f80b544a0")
  assert_eq(h264_yuv_md5(frames[1]), "74e5d157112a08a8b3ea0296562bf06a")
}

test "h264: qp=10 stream matches FFmpeg (dense residual)" {
  let data = @libavutil.av_base64_decode(h264_qp10_b64, 8192).unwrap()
  assert_eq(data.length(), 4906)
  let frames = h264_decode_annexb_i_frames_ex(data, true).unwrap()
  assert_eq(frames.length(), 2)
  assert_eq(h264_yuv_md5(frames[0]), "5fd796cc06fe08e308df49234a7f8150")
  assert_eq(h264_yuv_md5(frames[1]), "2aa0cd872e25d5e9ea8854f42bfc1ae5")
}

// ---------------------------------------------------------------------------
// Deblocking: the default entry point filters in-loop, so its output must match
// FFmpeg's *default* decode (no -skip_loop_filter).
// ---------------------------------------------------------------------------

///| Decode a stream with the in-loop deblocking filter enabled.
fn h264_md5_deblocked(b64 : Bytes, hint : Int) -> Array[String] {
  let data = @libavutil.av_base64_decode(b64, hint).unwrap()
  let frames = h264_decode_annexb_i_frames(data).unwrap()
  let out : Array[String] = []
  for i = 0; i < frames.length(); i = i + 1 {
    out.push(h264_yuv_md5(frames[i]))
  }
  out
}

test "h264: deblocking matches FFmpeg default output (3 original streams)" {
  // Frame 1 of `smooth` and both frames of `flat` are unchanged by the filter
  // (their edges stay below alpha/beta), so only some MD5s differ from the
  // -skip_loop_filter vectors above.
  assert_eq(h264_md5_deblocked(h264_baseline_b64, 4096), [
    "095a7084754121e94abd275275268b05", "744e00a9075b4f5a3907525031b533d4",
  ])
  assert_eq(h264_md5_deblocked(h264_smooth_b64, 8192), [
    "6aa85cc9db0f631abc1404782c2fb242", "4134a7443a5aea6d556991b76f927c73",
  ])
  assert_eq(h264_md5_deblocked(h264_flat_b64, 4096), [
    "6b020c288feee0476f843bc661767cce", "6b020c288feee0476f843bc661767cce",
  ])
}

test "h264: deblocking matches FFmpeg default output (crop / qp variants)" {
  assert_eq(h264_md5_deblocked(h264_crop_b64, 8192), [
    "853f979d9d0708f592428250e04a1371", "f1d044be682d70f5a230567158bbcc8f",
  ])
  assert_eq(h264_md5_deblocked(h264_qp40_b64, 4096), [
    "92dc4b6e77f344e713e61695446fbfa5", "8382629af59f4af56b5106c8d783b1bb",
  ])
  // qp=10: alpha/beta are too small for the filter to trigger on this content.
  assert_eq(h264_md5_deblocked(h264_qp10_b64, 8192), [
    "5fd796cc06fe08e308df49234a7f8150", "2aa0cd872e25d5e9ea8854f42bfc1ae5",
  ])
}

// ---------------------------------------------------------------------------
// Unsupported inputs: every one of these must come back as `Err`, never as a
// panic and never as silently wrong pixels.
// ---------------------------------------------------------------------------

///| Error string of a stream that must be rejected (`"no error"` if decoded).
fn h264_err(b64 : Bytes, hint : Int) -> String {
  let data = @libavutil.av_base64_decode(b64, hint).unwrap()
  match h264_decode_annexb_i_frames(data) {
    Ok(_) => "no error"
    Err(e) => e
  }
}

test "h264: P slices are rejected" {
  // keyint=10: frame 0 decodes as I, then the P slice must abort the decode.
  // `h264_slice.mbt` reports unsupported slice types as `PATCHWELCOME`, the
  // same token FFmpeg's `AVERROR_PATCHWELCOME` uses for this case.
  assert_eq(h264_err(h264_pslice_b64, 4096), "PATCHWELCOME")
}

test "h264: multiple slices per picture are rejected" {
  assert_eq(
    h264_err(h264_multislice_b64, 4096),
    "multi-slice pictures are not supported",
  )
}

test "h264: CABAC entropy coding is rejected" {
  assert_eq(h264_err(h264_cabac_b64, 4096), "CABAC is not supported")
}

test "h264: 4:2:2 chroma format is rejected" {
  assert_eq(h264_err(h264_422_b64, 4096), "only 4:2:0 is supported")
}

test "h264: 10-bit sample depth is rejected" {
  assert_eq(h264_err(h264_10bit_b64, 4096), "only 8-bit decoding is supported")
}
