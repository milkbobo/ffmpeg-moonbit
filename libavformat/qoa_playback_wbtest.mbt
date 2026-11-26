///|
/// The first two frames from FATE coin_48_1_152 and banjo_48_2_303.
/// Retain the original LMS state and slices, trimming to 27 and 19 samples
/// and fixing the header lengths. PCM references use FFmpeg 9.0.2 s16le.
let qoa_mono_fixture = b"cW9hZgAAAC4BALuAABsAKAAAAAAAAAAAAAAAAOAAQADAT9u4g6Em4roTLwpSDCDQAQC7gAATACD0IRBLCcTxEPQECzbafgTKZAmJ31lNsTQ="

///|
let qoa_stereo_fixture = b"cW9hZgAAAC4CALuAABsASAAAAAAAAAAAAAAAAOAAQAAAAAAAAAAAAAAAAADgAEAALjEEEpggEEguMQQSmCAQSBXSKKZuYlS+EMoAI15hNBoCALuAABMAOAOuAvoA/v3j/0EDB97nPVkE2QQVAcn+Jv3iBJbfJDy2RlCIBkgmLF1CEZAGSCFkqw=="

///|
test "QOA playback matches FFmpeg with independent LMS frame state" {
  for
    (b64, channels, first_size, last_size, md5) in [
      (qoa_mono_fixture, 1, 40, 32, "db03f2371b581dcf5e6bc31292d01868"),
      (qoa_stereo_fixture, 2, 72, 56, "8cfa3cf30ff4b5c1486b076d0b427feb"),
    ] {
    let data = @libavutil.av_base64_decode(b64, 256).unwrap()
    let track = av_qoa_open(data).unwrap()
    assert_eq(track.frames.map(p => (p.pos, p.pts, p.duration, p.size)), [
      (8L, 0L, 27, first_size),
      ((8 + first_size).to_int64(), 27L, 19, last_size),
    ])
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name, "qoa")
    assert_eq(audio.codec_id, "qoa")
    assert_eq(audio.channels, channels)
    assert_eq(audio.sample_rate, 48000)
    assert_eq(audio.duration_seconds, Some(46.0 / 48000.0))
    assert_eq(audio.samples[0].length(), 46)
    let wave = audio.to_wav_s16()
    let demux = av_wav_open(wave).unwrap()
    let start = demux.data_offset.to_int()
    assert_eq(
      caf_md5(wave[start:start + demux.data_size.to_int()].to_owned()),
      md5,
    )
  }
}

///|
test "QOA validates frame and file lengths" {
  let file = @libavutil.av_base64_decode(qoa_mono_fixture, 256).unwrap()
  assert_true(
    av_qoa_open(file[:file.length() - 1].to_owned())
    is Err("qoa: truncated frame"),
  )
  let bad_count = file.to_array()
  bad_count[7] = 45
  assert_true(
    av_qoa_open(Bytes::from_array(bad_count))
    is Err("qoa: frame samples exceed file sample count"),
  )
  let short_frame = file.to_array()
  short_frame[15] = 16
  assert_true(
    av_qoa_open(Bytes::from_array(short_frame))
    is Err("qoa: frame size too small for slices"),
  )
}
