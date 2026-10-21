///|
/// MP4 -> indexed/height ASC -> AAC-LC PCM, independently decoded by
/// FFmpeg 9.0.2; see scripts/generate_aac_height_vectors.py.
/// LGPL-2.1-or-later.
test "aac height: MP4 indexed config 11 is 6.1 back" {
  aac_check_asc_mp4(
    aac_height_index11_mp4_b64,
    aac_height_index11_config_b64,
    aac_height_index11_pcm_b64,
    aac_height_index11_packets,
    [0, 1, 2, 3, 4, 5, 8],
  )
}

///|
test "aac height: MP4 indexed config 12 is 7.1" {
  aac_check_asc_mp4(
    aac_height_index12_mp4_b64,
    aac_height_index12_config_b64,
    aac_height_index12_pcm_b64,
    aac_height_index12_packets,
    [0, 1, 2, 3, 4, 5, 9, 10],
  )
}

///|
test "aac height: MP4 indexed config 13 decodes all 24 channels" {
  aac_check_asc_mp4(
    aac_height_index13_mp4_b64,
    aac_height_index13_config_b64,
    aac_height_index13_pcm_b64,
    aac_height_index13_packets,
    [
      0, 1, 2, 3, 4, 5, 6, 7, 8, 35, 9, 10, 12, 14, 13, 11, 15, 17, 36, 37, 16, 38,
      39, 40,
    ],
  )
}

///|
test "aac height: MP4 indexed config 14 decodes the elevated pair" {
  aac_check_asc_mp4(
    aac_height_index14_mp4_b64,
    aac_height_index14_config_b64,
    aac_height_index14_pcm_b64,
    aac_height_index14_packets,
    [0, 1, 2, 3, 4, 5, 12, 14],
  )
}

///|
test "aac height: MP4 ASC PCE bootstraps 22.2 at 960 samples" {
  aac_check_asc_mp4(
    aac_height_pce22_960_mp4_b64,
    aac_height_pce22_960_config_b64,
    aac_height_pce22_960_pcm_b64,
    aac_height_pce22_960_packets,
    [
      0, 1, 2, 3, 4, 5, 6, 7, 8, 35, 9, 10, 12, 14, 13, 11, 15, 17, 36, 37, 16, 38,
      39, 40,
    ],
    frame_length=960,
  )
}
