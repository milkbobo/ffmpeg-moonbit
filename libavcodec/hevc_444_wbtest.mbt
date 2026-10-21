///|
/// White-box tests for HEVC 4:4:4: full-size chroma planes, per-PU chroma
/// intra modes, 4x4 chroma transform units, 4:4:4 chroma QP mappings in
/// residual coding and deblocking, plus chroma motion compensation with
/// hshift = vshift = 0. Streams and FFmpeg 9.0.2 frame MD5s live in
/// `hevc_444_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_y444_unfiltered : Array[String] = [
  "9ea6ee2abaa485ef5c8c21f5f5bb6825",
  "3d803299b5f85555d0f4e6f77d7ffee2",
  "84ba28bd328d70fac3e8ef58d300395b",
]

///|
let hevc_y444_filtered : Array[String] = [
  "e1495c7108e39e513e3e0a389b603620",
  "278d57d72e9d724ba9563113a8babc99",
  "a34d9f97156b1bcbdd2c7cc9d503145a",
]

///|
let hevc_y444b_unfiltered : Array[String] = [
  "46ef1d4786496f885cfef24ec1c21427",
  "4acf30a89ac580f125a5c09de6cee868",
  "c467994123da19ee8d5f3ea89358f3b2",
  "c467994123da19ee8d5f3ea89358f3b2",
  "c89496645d9fd038cb92ca243a8f8adf",
  "c89496645d9fd038cb92ca243a8f8adf",
  "112c0612cd4f82a006ab57bb7f9af370",
]

///|
let hevc_y444b_filtered : Array[String] = [
  "4aac5042eb5a6c1e6a1608ca01979e7c",
  "2e2f55c1a393906a67de1acafcb14676",
  "dc32105bfd284f1ac85720e686fc6c5c",
  "1496257ee68effe4bbf054dec5b59dfa",
  "9a4326afe2c799e688c6aefe716b7dd6",
  "ab27ca52e550aa1159ff68466803492c",
  "9c523a781ab7decf209281ed164ca777",
]

///|
let hevc_m10_444_unfiltered : Array[String] = [
  "bd04bd6e6a54934f30ca7e36d34c0d14",
  "fd588ce5607e15151dda9edede3ac516",
  "7414da08eaea200543cca9dc4ff8e2e3",
  "202c813f31620e2f98fbc97517630fe7",
  "202c813f31620e2f98fbc97517630fe7",
  "202c813f31620e2f98fbc97517630fe7",
  "202c813f31620e2f98fbc97517630fe7",
]

///|
let hevc_m10_444_filtered : Array[String] = [
  "234b2d08e09c3f0595d713e4b85758c4",
  "5f066a6d2d65eacaf892f580c5e68a1d",
  "caded75acc5225b64eefd58d1417843e",
  "023afa9a4c276c709f9b25005cb425f2",
  "023afa9a4c276c709f9b25005cb425f2",
  "023afa9a4c276c709f9b25005cb425f2",
  "023afa9a4c276c709f9b25005cb425f2",
]

///|
test "hevc 4:4:4: 8-bit I/P pre- and post-loop-filter MD5s" {
  hevc_check_stream_ex(hevc_y444_b64, hevc_y444_unfiltered, false)
  hevc_check_stream_ex(hevc_y444_b64, hevc_y444_filtered, true)
}

///|
test "hevc 4:4:4: 8-bit B frames with weighted prediction" {
  hevc_check_stream_ex(hevc_y444b_b64, hevc_y444b_unfiltered, false)
  hevc_check_stream_ex(hevc_y444b_b64, hevc_y444b_filtered, true)
}

///|
test "hevc 4:4:4: 10-bit B frames with weighted prediction" {
  hevc_check_bitdepth_stream(hevc_m10_444_b64, false, hevc_m10_444_unfiltered)
  hevc_check_bitdepth_stream(hevc_m10_444_b64, true, hevc_m10_444_filtered)
}

///|
test "hevc 4:4:4: standalone intra decode matches FFmpeg" {
  let idr = @libavutil.av_base64_decode(hevc_y444_idr_b64, 20000).unwrap()
  match ff_hevc_decode_intra_frame_unfiltered(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_y444_unfiltered[0])
    Err(e) => fail("unfiltered intra decode failed: " + e)
  }
  match ff_hevc_decode_intra_frame(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_y444_filtered[0])
    Err(e) => fail("filtered intra decode failed: " + e)
  }
}
