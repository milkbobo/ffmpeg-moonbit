///|
fn argo_test_encode(channels : Int32) -> Bytes raise MediaError {
  let samples = Array::makei(1059 * channels, i => i * 12289 % 65536 - 32768)
  let wav = wav_muxer_new(22050, channels, 16).unwrap()
  wav.write_samples(samples[:])
  decode_audio_file(wav.finish()).to_argo_asf()
}

///|
test "Argonaut ASF matches FFmpeg across packet boundaries and a short final block" {
  for
    (channels, container_md5, pcm_md5) in [
      (
        1, "69c6d8fd5a8693ad732b1449f1af4018", "33446e6ec78f1d9581b82bbf162fe671",
      ),
      (
        2, "c2ca4ee0dbb88206565cef05081a1aa0", "402e0cd6ffb8152424bc39ea4ee4dce1",
      ),
    ] {
    let data = argo_test_encode(channels)
    assert_eq(telephony_md5(data), container_md5)
    let media = MediaFile::open(data, filename="test.asf")
    assert_eq(media.format_name(), "argo_asf")
    let first = media.next_packet().unwrap()
    let tail = media.next_packet().unwrap()
    assert_eq((first.pts, first.data.length()), (0L, 32 * 17 * channels))
    assert_eq((tail.pts, tail.data.length()), (1024L, 2 * 17 * channels))
    assert_true(media.next_packet() is None)
    let decoded = decode_audio_file(data)
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.samples()[0].length(), 1088)
    let pcm = decoded.to_wav_s16()
    let offset = av_wav_open(pcm).unwrap().data_offset.to_int()
    assert_eq(telephony_md5(pcm[offset:].to_owned()), pcm_md5)
  }
}

///|
test "Argonaut ASF corrects the v1.1 sample rate and rejects truncated blocks" {
  let v2 = argo_test_encode(1)
  let v1 = Bytes::makei(v2.length(), i => {
    match i {
      4 => 1
      36 => 0x44
      37 => 0xac
      _ => v2[i]
    }
  })
  let decoded = decode_audio_file(v1)
  assert_eq(decoded.sample_rate(), 22050)
  assert_eq(decoded.samples(), decode_audio_file(v2).samples())
  assert_true(
    argo_asf_open(v2[:v2.length() - 1].to_owned())
    is Err("argo ASF: missing or truncated ADPCM blocks"),
  )
}
