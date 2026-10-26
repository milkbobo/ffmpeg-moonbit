///|
/// White-box tests for HEVC monochrome (`chroma_format_idc = 0`): luma-only
/// plane allocation, intra/inter prediction, residual coding, deblocking and
/// SAO. Streams and FFmpeg 9.0.2 frame MD5s live in
/// `hevc_monochrome_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_gray_unfiltered : Array[String] = [
  "df67ce5ce2c0c331099ba5678c098db9", "ca72ea27f8a7756e440c87d48f4cbc78", "1e29b0067c374318453a39f0dfadf0eb",
  "1e29b0067c374318453a39f0dfadf0eb", "1e29b0067c374318453a39f0dfadf0eb", "1e29b0067c374318453a39f0dfadf0eb",
  "1e29b0067c374318453a39f0dfadf0eb",
]

///|
let hevc_gray_filtered : Array[String] = [
  "d435794679afa7bfbc4f679d1f9c5c43", "8f5d94079d8e043ad556617820efc3e7", "530f1f5589bbe24659b78f28b88cc64d",
  "eec8e8439d98312add43109985ed4449", "218a4980b583adc62aa34ac186b98cf6", "4699ac72337cf81a0d139fc89f0bc0ca",
  "f1c8fe0c6bf14e3c72fb7b124d4c4e22",
]

///|
let hevc_m10_gray_unfiltered : Array[String] = [
  "a71e93fb1711cead4fd7c19ab6989932", "63dc7f703cb6e2d9e7e85769cfc2f458", "83f8f988e898c480172d9b0913115e3e",
  "83f8f988e898c480172d9b0913115e3e", "83f8f988e898c480172d9b0913115e3e", "83f8f988e898c480172d9b0913115e3e",
  "83f8f988e898c480172d9b0913115e3e",
]

///|
let hevc_m10_gray_filtered : Array[String] = [
  "55589ee67fbe6b3dad220940fc24c259", "e2a044411a9754d2d91bcfb7cf97a930", "d89de381395639e9e84ff9cd8c8537e4",
  "d89de381395639e9e84ff9cd8c8537e4", "d89de381395639e9e84ff9cd8c8537e4", "d89de381395639e9e84ff9cd8c8537e4",
  "d89de381395639e9e84ff9cd8c8537e4",
]

///|
test "hevc monochrome: 8-bit I/P/B pre- and post-loop-filter MD5s" {
  hevc_check_stream_ex(hevc_gray_b64, hevc_gray_unfiltered, false)
  hevc_check_stream_ex(hevc_gray_b64, hevc_gray_filtered, true)
}

///|
test "hevc monochrome: 10-bit I/P/B pre- and post-loop-filter MD5s" {
  hevc_check_bitdepth_stream(hevc_m10_gray_b64, false, hevc_m10_gray_unfiltered)
  hevc_check_bitdepth_stream(hevc_m10_gray_b64, true, hevc_m10_gray_filtered)
}

///|
test "hevc monochrome: standalone intra decode matches FFmpeg" {
  let idr = @libavutil.av_base64_decode(hevc_gray_idr_b64, 20000).unwrap()
  match ff_hevc_decode_intra_frame_unfiltered(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_gray_unfiltered[0])
    Err(e) => fail("unfiltered intra decode failed: " + e)
  }
  match ff_hevc_decode_intra_frame(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_gray_filtered[0])
    Err(e) => fail("filtered intra decode failed: " + e)
  }
}
