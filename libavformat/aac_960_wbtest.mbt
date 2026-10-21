///|
/// FFmpeg 9.0.2 reference PCM, including first/final scalefactor bands
/// and all four window sequences with alternating sine/KBD shapes.
/// LGPL-2.1-or-later.
test "aac 960: MP4 mono full-band geometry and window transitions match FFmpeg" {
  aac_check_asc_mp4(
    aac_960_mono_mp4_b64,
    aac_960_mono_config_b64,
    aac_960_mono_pcm_b64,
    aac_960_mono_packets,
    [2],
    frame_length=960,
  )
}

///|
test "aac 960: MP4 CPE independent window shapes match FFmpeg" {
  aac_check_asc_mp4(
    aac_960_stereo_mp4_b64,
    aac_960_stereo_config_b64,
    aac_960_stereo_pcm_b64,
    aac_960_stereo_packets,
    [0, 1],
    frame_length=960,
  )
}
