///|
test "sbr extra: multichannel HE-AAC upsamples every element" {
  let cases : Array[(String, String, String, Int32)] = [
    (
      "he_51", @aac_sbr_extra_vectors.multichannel_51_adts_b64, @aac_sbr_extra_vectors.multichannel_51_pcm_b64,
      6,
    ),
    (
      "he_50", @aac_sbr_extra_vectors.multichannel_50_adts_b64, @aac_sbr_extra_vectors.multichannel_50_pcm_b64,
      5,
    ),
    (
      "he_71", @aac_sbr_extra_vectors.multichannel_71_adts_b64, @aac_sbr_extra_vectors.multichannel_71_pcm_b64,
      8,
    ),
  ]
  for c in cases {
    let (name, adts_b64, pcm_b64, nch) = c
    let adts = sbr_extra_b64(adts_b64, 8192)
    let pcm = sbr_extra_b64(pcm_b64, 1 << 20)
    sbr_extra_check(name, adts, pcm, nch)
  }
}
