///|
/// H.264 + AAC MP4 muxer tests: both tracks are parsed back by `av_mov_open`.

///|
let mp4_av_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mp4 muxer: H.264 + AAC tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(mp4_av_avcc_b64, 1024).unwrap()
  let mux = mp4_av_muxer_new(64, 48, avcc, 48000, 2).unwrap()
  mux.write_video(b"\x00\x00\x01\x02", duration=3000, keyframe=true).unwrap()
  mux.write_video(b"\x00\x00\x01\x03", duration=3000).unwrap()
  mux.write_audio(b"\xAA\x01").unwrap()
  mux.write_audio(b"\xAA\x02").unwrap()
  mux.write_audio(b"\xAA\x03").unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  let video = movie.tracks[0]
  let audio = movie.tracks[1]
  assert_eq(video.codec, "avc1")
  assert_eq(video.width, 64)
  assert_eq(video.height, 48)
  assert_eq(video.samples.length(), 2)
  assert_eq(audio.codec, "mp4a")
  assert_eq(audio.sample_rate, 48000U)
  assert_eq(audio.channels, 2U)
  assert_eq(audio.samples.length(), 3)
  let vpayloads : Array[Bytes] = [
    b"\x00\x00\x01\x02", b"\x00\x00\x01\x03",
  ]
  for i in 0..<2 {
    let s = video.samples[i]
    assert_eq(s.dts, (i * 3000).to_int64())
    assert_eq(s.duration, 3000U)
    assert_eq(s.keyframe, i == 0)
    let start = s.offset.to_int()
    assert_eq(
      bytes[start:start + s.size.reinterpret_as_int()].to_owned(),
      vpayloads[i],
    )
  }
  let apayloads : Array[Bytes] = [b"\xAA\x01", b"\xAA\x02", b"\xAA\x03"]
  for i in 0..<3 {
    let s = audio.samples[i]
    assert_eq(s.dts, (i * 1024).to_int64())
    assert_eq(s.duration, 1024U)
    let start = s.offset.to_int()
    assert_eq(
      bytes[start:start + s.size.reinterpret_as_int()].to_owned(),
      apayloads[i],
    )
  }
}

///|
test "mp4 muxer: invalid A/V parameters are rejected" {
  let avcc = @libavutil.av_base64_decode(mp4_av_avcc_b64, 1024).unwrap()
  match mp4_av_muxer_new(64, 48, avcc, 12345, 2) {
    Ok(_) => fail("unsupported sample rate must fail")
    Err(_) => ()
  }
  let mux = mp4_av_muxer_new(64, 48, avcc, 48000, 2).unwrap()
  match mux.write_video(Bytes::new(0), duration=3000) {
    Ok(_) => fail("empty video packet must fail")
    Err(_) => ()
  }
}
