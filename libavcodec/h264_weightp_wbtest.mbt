///|
/// White-box tests for H.264 explicit weighted P prediction, reference-list
/// modification and picture-identity deblocking boundary strengths. Streams
/// and FFmpeg 9.0.2 frame MD5s live in `h264_weightp_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn h264_check_frames(
  b64 : Bytes,
  refs : Array[String],
  skip_lf : Bool,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 100000).unwrap()
  let frames = h264_decode_annexb_frames(data, skip_lf).unwrap()
  assert_eq(frames.length(), refs.length())
  for i = 0; i < refs.length(); i = i + 1 {
    assert_eq(h264_yuv_md5(frames[i]), refs[i])
  }
}

///|
let wp_unfiltered : Array[String] = [
  "910380cd4c3a8eee2559b7cb16ccd3b2",
  "f9ca8e495643ed81ab15294651c9e98d",
  "a86742aca5fbab895e9438c3851284a1",
  "1a3265c9469d4246ed93d8cb6a85725f",
  "0520b58938be1fa41c15db57c32b38e8",
  "0eb4713cbab606199f4518778aba2f51",
  "a05f675ed4a8b219ebbf7430263fafff",
]

///|
let wp_filtered : Array[String] = [
  "910380cd4c3a8eee2559b7cb16ccd3b2",
  "056114ca64a35c917f7e2657182ccdbc",
  "70a3b8efed6b6546f8f47c4de910e9a5",
  "9640845df5845d611a6e8e2fcfde94a3",
  "b7050709bf7e039cd59d136a5e1e229d",
  "d5a5f1b76c20776a6da46f7028ca731c",
  "d62113f31ed9522b2485bf5ce9348686",
]

///|
let r4_unfiltered : Array[String] = [
  "910380cd4c3a8eee2559b7cb16ccd3b2",
  "f9ca8e495643ed81ab15294651c9e98d",
  "e279cbe8dce6593e4070c769ee0ebbad",
  "fad5d9032e8befffc64d9fef51cea668",
  "7fe9937b3366d5747e296e73c82d8d19",
  "aca78249f2f723bf090f5c3e29a438a9",
  "be8b294020191719a8a552154ca7212b",
]

///|
let r4_filtered : Array[String] = [
  "910380cd4c3a8eee2559b7cb16ccd3b2",
  "056114ca64a35c917f7e2657182ccdbc",
  "8a3c495691f1113fa1283c68822e38af",
  "0d542fdd5cbe53cd4bc467a17550c89f",
  "5bbdfd77e6b8b1a35ffa5f347c49362e",
  "899d9d400475fad0b699159e22f1a6ba",
  "d8602087979bec916a9cada3ae452398",
]

///|
test "h264: explicit weighted P prediction matches ffmpeg" {
  h264_check_frames(h264_wp_b64, wp_unfiltered, true)
  h264_check_frames(h264_wp_b64, wp_filtered, false)
}

///|
test "h264: four-reference reordering and deblocking match ffmpeg" {
  h264_check_frames(h264_r4_b64, r4_unfiltered, true)
  h264_check_frames(h264_r4_b64, r4_filtered, false)
}
