///|
fn rso_wve_reference_input(frames : Int32) -> DecodedAudio raise MediaError {
  let wav = wav_muxer_new(8000, 1, 16).unwrap()
  let samples = Array::makei(frames, i => ((19 * i + 37) % 256 - 128) * 256)
  wav.write_samples(samples[:])
  decode_audio_file(wav.finish())
}

///|
test "Mindstorms RSO matches FFmpeg on both sides of its length limit" {
  for
    (frames, hash) in [
      (5203, "d72e17e963ecdd808c0b9078c9ffc8ef"),
      (70019, "84f5a2509315dcb91179ce01aa340b0c"),
    ] {
    let input = rso_wve_reference_input(frames)
    let data = input.to_rso()
    assert_eq(caf_md5(data), hash)
    assert_eq(pb_be16(data, 2), frames.min(65535).reinterpret_as_uint())
    let track = rso_open(data).unwrap()
    assert_eq(track.frames[1].pts, 512L)
    assert_eq(track.total_samples, frames.to_int64())
    let decoded = decode_audio_file(data, filename="audio.rso")
    assert_eq(decoded.format_name(), "rso")
    assert_eq(decoded.samples(), input.samples())
    assert_true(rso_open(data[:12].to_owned()) is Err(_))
  }
}

///|
test "Psion WVE writes G.711 A-law and matches FFmpeg decoded PCM" {
  let input = rso_wve_reference_input(5203)
  let data = input.to_wve()
  assert_eq(caf_md5(data), "9df230199dc55726090da5c6da2c8547")
  let track = wve_open(data).unwrap()
  assert_eq(track.total_samples, 5203L)
  assert_eq(track.frames[1].pts, 512L)
  let audio = decode_audio_file(data)
  assert_eq(audio.format_name(), "wve")
  assert_eq(audio.codec_id(), "pcm_alaw")
  let wav = audio.to_wav_s16()
  let demux = av_wav_open(wav).unwrap()
  let start = demux.data_offset.to_int()
  assert_eq(
    caf_md5(wav[start:start + demux.data_size.to_int()].to_owned()),
    "3ceee662e7b08169966a6c7e5db5523c",
  )
  assert_true(
    wve_open(data[:data.length() - 1].to_owned())
    is Err("wve: missing or truncated A-law payload"),
  )
}
