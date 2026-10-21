///|
/// White-box tests for HEVC 4:2:2: half-width/full-height chroma planes, two
/// vertically stacked chroma transform blocks per luma TU, `tab_mode_idx`
/// chroma intra mode remapping, generic chroma QP mapping and chroma motion
/// compensation with hshift = 1, vshift = 0. Streams and FFmpeg 9.0.2 frame
/// MD5s live in `hevc_422_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_y422_unfiltered : Array[String] = [
  "4085d465d9d1164fe3af5e1e849d05c8",
  "4baac5545285ca23dc2154c8892ac1c0",
  "03d22d1ba0c69f0c7263633b998fc06d",
]

///|
let hevc_y422_filtered : Array[String] = [
  "ea9301464f531bf9a6711ea29b572d2d",
  "1508ac03a7af029f5d268216174a25eb",
  "f641d6584683b84e2c8301eadf82ca41",
]

///|
let hevc_y422b_unfiltered : Array[String] = [
  "871ba4a6407a5a60b05f0e6263193470",
  "c01f84a872410e92c535a534f2c3456a",
  "318ac82ad1c6ee1256dd5938e43bef0a",
  "dab123c30532ef41a17bf3b9019f6ff6",
  "aaec905362c7e39d2c3aa986595ceb79",
  "9cc6cd8fd0ca7ef1ab4d810fa01b7c9f",
  "bcbdcc401175ecce4fdfacd6541ccc67",
]

///|
let hevc_y422b_filtered : Array[String] = [
  "506ca0f411057d880725d91b5b4a19b2",
  "5828196e9cbe41307a49fd21b1e8dafb",
  "d1b08d117c053f2da0d7c8b8134d97c6",
  "b0c157ebec2a9185a0c11357d7d4cbdb",
  "0f489f638efc97e5a9447ebbce2a429e",
  "d7cd7bbcd6f7121398635b13703fe8bb",
  "976f3e23c2c149c2ced8301f343fd4f9",
]

///|
let hevc_m10_422_unfiltered : Array[String] = [
  "a681a1972c0670c424009277b116410b",
  "f45da78ef80855b41f038d3baca079da",
  "e902157f5389305b60aeb617626a7339",
  "be53485a3f93d62cb3f18679bcb83bc1",
  "8a6241e12d9ccc52fac731039b938b30",
  "c303f3e3f4c8aa8080a6763fabe72133",
  "f3076850fd16ecdc3f9863d3eb87c01c",
]

///|
let hevc_m10_422_filtered : Array[String] = [
  "b09403163a2cff00a749e2036d5096c3",
  "50ff034752c5b2b42287b6d7e4c5828a",
  "def683dbf663201b3d1d0253fe4c7e33",
  "ba231f6597d25e0af01f23cd39596905",
  "7f77d57e6cbaee88a3bee8f971767e80",
  "c81320fdfee872f6f819e59cd26473dc",
  "abfed7436d69a71e36d975fce6c59887",
]

///|
test "hevc 4:2:2: 8-bit I/P pre- and post-loop-filter MD5s" {
  hevc_check_stream_ex(hevc_y422_b64, hevc_y422_unfiltered, false)
  hevc_check_stream_ex(hevc_y422_b64, hevc_y422_filtered, true)
}

///|
test "hevc 4:2:2: 8-bit B frames with weighted prediction" {
  hevc_check_stream_ex(hevc_y422b_b64, hevc_y422b_unfiltered, false)
  hevc_check_stream_ex(hevc_y422b_b64, hevc_y422b_filtered, true)
}

///|
test "hevc 4:2:2: 10-bit B frames with weighted prediction" {
  hevc_check_bitdepth_stream(hevc_m10_422_b64, false, hevc_m10_422_unfiltered)
  hevc_check_bitdepth_stream(hevc_m10_422_b64, true, hevc_m10_422_filtered)
}

///|
test "hevc 4:2:2: standalone intra decode matches FFmpeg" {
  let idr = @libavutil.av_base64_decode(hevc_y422_idr_b64, 20000).unwrap()
  match ff_hevc_decode_intra_frame_unfiltered(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_y422_unfiltered[0])
    Err(e) => fail("unfiltered intra decode failed: " + e)
  }
  match ff_hevc_decode_intra_frame(idr, false, 0) {
    Ok(pic) => assert_eq(hevc_yuv_md5(pic), hevc_y422_filtered[0])
    Err(e) => fail("filtered intra decode failed: " + e)
  }
}
