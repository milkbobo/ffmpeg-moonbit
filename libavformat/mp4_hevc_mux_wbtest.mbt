///|
/// HEVC-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
let mp4_hevc_hvcc_b64 : Bytes = b"AQFgAAAAkAAAAAAAHvAA/P34+AAADwOgAAEAGEABDAH//wFgAAADAJAAAAMAAAMAHpKAkKEAAQAoQgEBAWAAAAMAkAAAAwAAAwAeoCCDFlkq5MrwFoCAAAADAIAAAAMChKIAAQAGRAHBc9CJ"

///|
test "mp4 muxer: HEVC samples and hvcC round-trip" {
  let hvcc = @libavutil.av_base64_decode(mp4_hevc_hvcc_b64, 1024).unwrap()
  let mux = mp4_hevc_muxer_new(64, 48, hvcc, timescale=90000).unwrap()
  mux.write_packet(b"\x00\x00\x01\x02", duration=3000, keyframe=true).unwrap()
  mux.write_packet(b"\x00\x00\x01\x03", duration=3000, keyframe=false).unwrap()
  let bytes = mux.finish()
  let track = av_mov_open(bytes).unwrap().tracks[0]
  assert_eq(track.codec, "hvc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.extradata.unwrap(), hvcc)
  assert_eq(track.samples.length(), 2)
  for i in 0..<2 {
    let sample = track.samples[i]
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i == 0)
  }
}
