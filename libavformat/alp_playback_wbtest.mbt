///|
test "ALP PCM matches FFmpeg across packet boundaries" {
  let pcm = Array::makei(4102 * 2, i => {
    let frame = i / 2
    let value = if i % 2 == 0 { frame * 271 } else { frame * 743 + 21973 }
    value % 65536 - 32768
  })
  let wav = wav_muxer_new(32000, 2, 16).unwrap()
  wav.write_samples(pcm[:])
  let encoded = decode_audio_file(wav.finish()).to_alp(pcm=true)
  assert_eq(telephony_md5(encoded), "ad234f72726d56b5b309ed44df4bd464")
  let media = MediaFile::open(encoded)
  assert_eq(media.format_name(), "alp")
  let first = media.next_packet().unwrap()
  let tail = media.next_packet().unwrap()
  assert_eq((first.pts, first.data.length(), first.keyframe), (0L, 4096, true))
  assert_eq((tail.pts, tail.data.length(), tail.keyframe), (4096L, 6, false))
  assert_true(media.next_packet() is None)
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.channels(), 2)
  assert_eq(decoded.sample_rate(), 32000)
  let output = decoded.to_wav_s16()
  let wav = av_wav_open(output).unwrap()
  assert_eq(
    telephony_md5(output[wav.data_offset.to_int():].to_owned()),
    "f09abe95434219d908e0dba31597a88f",
  )
  let truncated = Ok(MediaFile::open(encoded[:encoded.length() - 1].to_owned())) catch {
    error => Err(error)
  }
  assert_true(truncated is Err(DemuxError("alp: incomplete channel pair")))
}

///|
test "ALP TUN preserves the final unpaired sample and repeats its predictor" {
  let wav = wav_muxer_new(22050, 2, 16).unwrap()
  let samples = [1000, -1000]
  wav.write_samples(samples[:])
  let encoded = decode_audio_file(wav.finish()).to_alp()
  assert_eq(encoded, b"ALP \x08\x00\x00\x00ADPCM\x00\x00\x02\x70\xf0")
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.sample_rate(), 22050)
  assert_eq(decoded.samples(), [
    [12.0 / 32768.0, 12.0 / 32768.0],
    [-12.0 / 32768.0, -12.0 / 32768.0],
  ])
}
