///|
/// 6.1(back) and 5.1.2(back) are not representable in ADTS: the fixed header's
/// 3-bit channel_configuration truncates the 4-bit ASC values 11/14 to 3/6, so
/// libfdk_aac output cannot be decoded through an ADTS header. These streams
/// are therefore decoded as raw access units with the ASC channel
/// configuration, still matching FFmpeg's native decoder sample for sample.
test "sbr extra: 6.1(back) and 5.1.2(back) raw-AU SBR" {
  let cases : Array[(String, String, Array[Int32], String, Int32, Int32)] = [
    (
      "he_61", @aac_sbr_extra_vectors.he_61_raw_b64, @aac_sbr_extra_vectors.he_61_sizes,
      @aac_sbr_extra_vectors.he_61_ref_b64, 7, 11,
    ),
    (
      "he_512b", @aac_sbr_extra_vectors.he_512b_raw_b64, @aac_sbr_extra_vectors.he_512b_sizes,
      @aac_sbr_extra_vectors.he_512b_ref_b64, 8, 14,
    ),
  ]
  for c in cases {
    let (name, raw_b64, sizes, pcm_b64, nch, chan_config) = c
    let raw = sbr_extra_b64(raw_b64, 8192)
    let pcm = sbr_extra_b64(pcm_b64, 1 << 20)
    sbr_extra_check_au(name, raw, sizes, pcm, nch, chan_config)
  }
}
