///|
/// FFmpeg 9.0.2 generated PCM, with CCE declarations in MP4 ASC/PCE.
/// LGPL-2.1-or-later.
test "aac CCE 960: independent source overlap and CPE selection match FFmpeg" {
  let asc = @libavutil.av_base64_decode(
    aac_coupling_960_stereo_independent_config_b64, 1024,
  ).unwrap()
  assert_eq(@libavcodec.new_aac_decoder_from_asc(asc).unwrap().coupling_tags, [
    9,
  ])
  aac_check_asc_mp4(
    aac_coupling_960_stereo_independent_mp4_b64,
    aac_coupling_960_stereo_independent_config_b64,
    aac_coupling_960_stereo_independent_pcm_b64,
    aac_coupling_960_stereo_independent_packets,
    [0, 1],
    frame_length=960,
  )
}

///|
test "aac CCE 960: all coupling points with grouped short windows match FFmpeg" {
  let asc = @libavutil.av_base64_decode(
    aac_coupling_960_multiple_config_b64, 1024,
  ).unwrap()
  assert_eq(@libavcodec.new_aac_decoder_from_asc(asc).unwrap().coupling_tags, [
    9, 2, 5,
  ])
  aac_check_asc_mp4(
    aac_coupling_960_multiple_mp4_b64,
    aac_coupling_960_multiple_config_b64,
    aac_coupling_960_multiple_pcm_b64,
    aac_coupling_960_multiple_packets,
    [0, 1],
    frame_length=960,
  )
}
