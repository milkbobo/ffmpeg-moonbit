///|
/// GSM payloads are from FATE gsm/sample-gsm-8000.mov and gsm/ciao.wav.
/// The IMA4 and G.722 payloads were encoded with FFmpeg 9.0.2.
fn check_apple_adpcm_fixture(
  file : Bytes,
  container : String,
  codec : String,
  rate : Int32,
  channels : Int32,
  count : Int32,
  expected_md5 : String,
) -> Unit raise {
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, container)
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.sample_rate, rate)
  assert_eq(audio.channels, channels)
  assert_eq(audio.duration_seconds, Some(count.to_double() / rate.to_double()))
  assert_eq(audio.read_error, "")
  for row in audio.samples {
    assert_eq(row.length(), count)
  }
  let wave = audio.to_wav_s16()
  let demux = av_wav_open(wave).unwrap()
  assert_eq(demux.data_size, (count * channels * 2).to_int64())
  assert_eq(caf_md5(wave[demux.data_offset.to_int():].to_owned()), expected_md5)
}

///|
test "aiff gsm matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Rk9STQAAAKRBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAAAMAEEAL+gAAAAAAAABHU00gAABTU05EAAAAawAAAAAAAA",
    b"AA12OK4ZupzClSbkoYVIq8vuKYM4LqWnrNxeHQyZrW5Uqc2CaC2WSB6hbwdikdfOjg685Ymq0qxnOlphTTaWkBQ9uM1h6D",
    b"ZZyCxi4huMpKosZR60Sz4+xn6N4s+9rUqLbXnTqTAA==",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "aiff", "gsm", 8000, 1, 480, "c81a416dbc23569c442d82b1a60244ee",
  )
}

///|
test "aiff g722 matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Rk9STQAAAGhBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAACgABEAM+gAAAAAAAABHNzIyAABTU05EAAAAMAAAAAAAAA",
    b"AA+pgsjiGToKBg74rIztzu6u561dHUn/LucfuX09e+9PDyfNiT1/+08A==",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "aiff", "adpcm_g722", 16000, 1, 80, "2dcbbdcab3357e0122fa29c403a953f9",
  )
}

///|
test "caf gsm matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBAv0AAAAAAAGFnc20AAAAAAAAAIQAAAKAAAAABAAAAAGNoYW4AAAAAAAAADABkAAEAAA",
    b"AAAAAAAGluZm8AAAAAAAAAUwAAAARtYWpvcl9icmFuZABxdCAgAG1pbm9yX3ZlcnNpb24ANTEyAGNvbXBhdGlibGVfYnJh",
    b"bmRzAHF0ICAAZW5jb2RlcgBMYXZmNjMuMS4xMDIAZGF0YQAAAAAAAABnAAAAANdjiuGbqcwpUm5KGFSKvL7imDOC6lp6zc",
    b"Xh0Mma1uVKnNgmgtlkgeoW8HYpHXzo4OvOWJqtKsZzpaYU02lpAUPbjNYeg2WcgsYuIbjKSqLGUetEs+PsZ+jeLPva1Ki2",
    b"1506k3Bha3QAAAAAAAAAGAAAAAAAAAAAAAAAAAAAAYAAAABgAAAAAA==",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "caf", "gsm", 8000, 1, 384, "c775ceb63c50e7591c3ff1fb4ba8c381",
  )
}

///|
test "caf wav49 matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBAv0AAAAAAAG1zADEAAAAAAAAAQQAAAUAAAAABAAAAAGNoYW4AAAAAAAAADABkAAEAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAAIYAAAAAWCidwYICAxq1cdwU",
    b"zIEZRxK99OXhIGW+I4tKYVbHbihVjZWRKNwatqyyElj4HLSUQ6ZZxhTW0PS8vqgU6PWMPKqUSd2EEK9B27pZw3gPAVrkYa",
    b"U2y2AfWU+2rI2hfDWT60SZ9c1IqBrIZPWGZbUURKgKpaHKFkSP22q34RAYu5V6yg==",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "caf", "gsm_ms", 8000, 1, 640, "44641cb80fc7e5318a063a571b90deec",
  )
}

///|
test "caf ima4 matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBAz0AAAAAAAGltYTQAAAAAAAAARAAAAEAAAAACAAAABGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAANAAAAAAAABwd3d3/pwZMiYj",
    b"gNrLqhlCNBSByryrCFI0MoDavKsIUgAAd3f//w4iJBOYvLybMFQzArjNq4oxRSMBybysCUJTIoDkxlMigMm8qwlDNSOB2r",
    b"yrCVJTIoG6zaoJMkUigbq9rAkyKEHKvJsIYzMTkNy7qiA1JQKovK2JMDQlgam9qwpCNSOB295DNSSByduqiTJFIoG5zaoJ",
    b"MTUkgbm9rIkyNSQBur2siTIQQtuaGUI0E5DMy5oQNCUSmcy7mTE1JQG5zKuJQjQkgLrN",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "caf", "adpcm_ima_qt", 16000, 2, 192, "3a5a56756d846a9e7a49cb5daa845446",
  )
}

///|
test "caf ima4-padded matches FFmpeg s16 PCM" {
  let packed = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBAz0AAAAAAAGltYTQAAAAAAAAARAAAAEAAAAACAAAABGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAANAAAAAAAABwd3d3/pwZMiYj",
    b"gNrLqhlCNBSByryrCFI0MoDavKsIUgAAd3f//w4iJBOYvLybMFQzArjNq4oxRSMBybysCUJTIoDkxlMigMm8qwlDNSOB2r",
    b"yrCVJTIoG6zaoJMkUigbq9rAkyKEHKvJsIYzMTkNy7qiA1JQKovK2JMDQlgam9qwpCNSOB295DNSSByduqiTJFIoG5zaoJ",
    b"MTUkgbm9rIkyNSQBur2siTIQQtuaGUI0E5DMy5oQNCUSmcy7mTE1JQG5zKuJQjQkgLrNcGFrdAAAAAAAAAAYAAAAAAAAAA",
    b"MAAAAAAAAAtQAAAAUAAAAG",
  ])
  let file = @libavutil.av_base64_decode(packed, 512).unwrap()
  check_apple_adpcm_fixture(
    file, "caf", "adpcm_ima_qt", 16000, 2, 181, "e44582e14e2a125b23ffd212dbd3c5f2",
  )
  let demux = av_caf_open(file).unwrap()
  assert_eq(demux.priming, 5)
  assert_eq(demux.packets.map(p => (p.pts, p.duration, p.size)), [
    (-5L, 64, 68),
    (59L, 64, 68),
    (123L, 58, 68),
  ])
  let invalid = file.to_array()
  invalid[invalid.length() - 1] = 64
  assert_true(
    av_caf_open(Bytes::from_array(invalid))
    is Err("caf: invalid fixed packet table"),
  )
}
