///|
test "RoQ audio skips video chunks, clamps PCM and resets predictors per packet" {
  let data = b"\x84\x10\xff\xff\xff\xff\x1e\x00\x21\x10\x04\x00\x00\x00\x7f\x80\xff\x7f\x02\x83\x01\x10\x08\x00\x00\x00\x00\x00\x40\x00\x40\x00\x08\x00\x04\x00\x21\x10\x02\x00\x00\x00\xff\x01\x03\x84"
  let media = MediaFile::open(data)
  assert_eq(media.format_name(), "roq")
  assert_eq(media.next_packet().unwrap().pts, 0L)
  assert_eq(media.next_packet().unwrap().pts, 2L)
  assert_true(media.next_packet() is None)
  let audio = decode_audio_file(data)
  assert_eq(audio.channels(), 2)
  assert_eq(audio.sample_rate(), 22050)
  assert_eq(
    audio.samples().map(plane => plane.map(x => (x * 32768.0).to_int())),
    [[-32768, -32764, 265], [32767, 32758, -272]],
  )
  let truncated = Ok(MediaFile::open(data[:data.length() - 1].to_owned())) catch {
    error => Err(error)
  }
  assert_true(truncated is Err(DemuxError("roq: truncated chunk")))
}

///|
test "RoQ stereo export matches FFmpeg across the initial and regular chunks" {
  let pcm = Array::makei(6615 * 2, i => {
    let frame = i / 2
    let value = if i % 2 == 0 { frame * 271 } else { frame * 743 + 21973 }
    value % 65536 - 32768
  })
  let wav = wav_muxer_new(22050, 2, 16).unwrap()
  wav.write_samples(pcm[:])
  let encoded = decode_audio_file(wav.finish()).to_roq()
  assert_eq(telephony_md5(encoded), "27b6b5fa1566f263c8db33f38c4f4991")
  let media = MediaFile::open(encoded)
  assert_eq(media.next_packet().unwrap().data.length(), 5880 * 2 + 8)
  let last = media.next_packet().unwrap()
  assert_eq(last.pts, 5880L)
  assert_eq(last.data.length(), 735 * 2 + 8)
  assert_true(media.next_packet() is None)
}

///|
test "short RoQ export pads only to the last complete audio frame" {
  let wav = wav_muxer_new(22050, 1, 16).unwrap()
  let pcm = Array::make(1000, 0)
  wav.write_samples(pcm[:])
  let encoded = decode_audio_file(wav.finish()).to_roq()
  assert_eq(encoded.length(), 8 + 8 + 1470)
  let audio = decode_audio_file(encoded)
  assert_eq(audio.samples()[0].length(), 1470)
  assert_true(audio.samples()[0].iter().all(sample => sample == 0.0))
}
