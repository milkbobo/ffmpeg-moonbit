///|
/// FFmpeg 9.0.2 G.722 output for the 31 PCM samples below.
let g722_short_reference : Bytes = b"\xb4\x85\x21\x88\x23\xbb\x20\xa0\x20\xa5\x31\xb7\x04\x0d\x84\x10"

///|
test "G.722 encoding repeats an odd final sample and matches FFmpeg" {
  let pcm = [
    0, 16080, 16426, 7721, 8682, 22143, 30558, 21530, 5989, 2359, 9916, 10344, -4831,
    -21183, -21884, -11783, -9817, -20924, -28636, -19229, -2032, 3878, -2867, -4520,
    9131, 25161, 25869, 14243, 9254, 17894, 24958,
  ]
  let wav = wav_muxer_new(16000, 1, 16).unwrap()
  wav.write_samples(pcm[:])
  let audio = decode_audio_file(wav.finish())
  assert_eq(audio.to_g722(), g722_short_reference)
}

///|
test "raw G.722 playback matches FFmpeg for 6, 7 and 8 significant bits" {
  for
    (bits, checksum) in [
      (6, "38d6de37e4d1b75aa2b84c45322ea87b"),
      (7, "ab155d3865c469eb9faa7b8dcc102c95"),
      (8, "aa68189fdb056fbdc453f8b41764cca3"),
    ] {
    let audio = decode_audio_file(
      g722_short_reference,
      filename="voice.g722",
      g722_bits=bits,
    )
    assert_eq(audio.sample_rate(), 16000)
    assert_eq(audio.samples()[0].length(), 32)
    let output = audio.to_wav_s16()
    let wav = av_wav_open(output).unwrap()
    assert_eq(
      telephony_md5(output[wav.data_offset.to_int():].to_owned()),
      checksum,
    )
  }
  let invalid = Ok(
    MediaFile::open(g722_short_reference, filename="voice.g722", g722_bits=5),
  ) catch {
    error => Err(error)
  }
  assert_true(
    invalid is Err(DemuxError("g722: codeword width must be 6, 7 or 8 bits")),
  )
}
