///|
/// HEVC-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
let mp4_hevc_hvcc_b64 : Bytes = b"AQFgAAAAkAAAAAAAHvAA/P34+AAADwOgAAEAGEABDAH//wFgAAADAJAAAAMAAAMAHpKAkKEAAQAoQgEBAWAAAAMAkAAAAwAAAwAeoCCDFlkq5MrwFoCAAAADAIAAAAMChKIAAQAGRAHBc9CJ"

///|
test "mp4 muxer: HEVC samples and hvcC round-trip" {
  let hvcc = @libavutil.av_base64_decode(mp4_hevc_hvcc_b64, 1024).unwrap()
  let mux = mp4_hevc_muxer_new(64, 48, hvcc, timescale=90000).unwrap()
  mux.write_packet(b"\x00\x00\x01\x02", duration=3000, keyframe=true).unwrap()
  mux
  .write_packet(b"\x00\x00\x01\x03", duration=3000, keyframe=false, cts=3000)
  .unwrap()
  mux
  .write_packet(b"\x00\x00\x01\x04", duration=3000, keyframe=false, cts=-1000)
  .unwrap()
  let bytes = mux.finish()
  let track = av_mov_open(bytes).unwrap().tracks[0]
  assert_eq(track.codec, "hvc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.extradata.unwrap(), hvcc)
  assert_eq(track.samples.length(), 3)
  let expected_pts : Array[Int64] = [0L, 6000L, 5000L]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.pts, expected_pts[i])
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i == 0)
  }
}

///|
test "mp4 muxer: real HEVC samples decode round-trip" {
  let stream = @libavutil.av_base64_decode(mkv_hevc_stream_b64, 1000000).unwrap()
  let hvcc = @libavutil.av_base64_decode(mkv_hevc_hvcc_b64, 1024).unwrap()
  let packets = mkv_hevc_au_packets(stream)
  assert_eq(packets.length(), 5)
  let mux = mp4_hevc_muxer_new(64, 64, hvcc).unwrap()
  for i, packet in packets {
    mux.write_packet(packet, duration=3000, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "hvc1")
  assert_eq(track.width, 64)
  assert_eq(track.height, 64)
  assert_eq(track.extradata.unwrap(), hvcc)
  assert_eq(track.samples.length(), 5)
  let all : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in bytes[start:end] {
      all.push(b)
    }
  }
  let frames = @libavcodec.ff_hevc_decode_frames_ex(
    Bytes::from_array(all),
    true,
    4,
    true,
  ).unwrap()
  let sorted = frames.copy()
  sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  assert_eq(sorted.length(), mkv_hevc_refs.length())
  for i = 0; i < mkv_hevc_refs.length(); i = i + 1 {
    assert_eq(mkv_hevc_md5(sorted[i].yuvp(8)), mkv_hevc_refs[i])
  }
}
