///|
/// White-box test for HEVC scaling lists: per-coefficient `scale_matrix` and
/// DC scale application during dequantization, using the default SPS matrices
/// signalled without explicit scaling list data. Stream and FFmpeg 9.0.2 frame
/// MD5s live in `hevc_scaling_realdata_wbtest.mbt`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
let hevc_scaling_unfiltered : Array[String] = [
  "1ef544ea8652ee00b8b71e0233e6aee2",
  "378d2fd50493ad8e00d2a5f090357777",
  "8cea92bdab1b231784bef8ba46f353f0",
]

///|
let hevc_scaling_filtered : Array[String] = [
  "1361080b7c74e05ebb6a7e6b78a178e1",
  "91eb3f5559f4f6741cdca3f0e755b37c",
  "661980ac9d1838910ac0ad5fd7e00a2d",
]

///|
test "hevc scaling lists: default matrices match FFmpeg" {
  hevc_check_stream_ex(hevc_scaling_b64, hevc_scaling_unfiltered, false)
  hevc_check_stream_ex(hevc_scaling_b64, hevc_scaling_filtered, true)
}
