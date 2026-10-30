///|
/// AV1-in-MP4 muxer tests: emitted files are parsed back by `av_mov_open`.

///|
test "mp4 muxer: AV1 samples and av1C round-trip" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let mux = mp4_av1_muxer_new(64, 48, av1c, timescale=90000).unwrap()
  mux.write_packet(b"\x0A\x0B\x0C", duration=3000, keyframe=true).unwrap()
  mux
  .write_packet(b"\x0D\x0E", duration=3000, keyframe=false, cts=1500)
  .unwrap()
  mux
  .write_packet(b"\x0F\x10\x11", duration=3000, keyframe=true, cts=-500)
  .unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  let track = movie.tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.timescale, 90000U)
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 3)
  let sizes : Array[Int32] = [3, 2, 3]
  let expected_pts : Array[Int64] = [0L, 4500L, 5500L]
  for i in 0..<3 {
    let sample = track.samples[i]
    assert_eq(sample.size, sizes[i].reinterpret_as_uint())
    assert_eq(sample.dts, (i * 3000).to_int64())
    assert_eq(sample.pts, expected_pts[i])
    assert_eq(sample.duration, 3000U)
    assert_eq(sample.keyframe, i != 1)
  }
}

///|
test "mp4 muxer: invalid AV1 parameters are rejected" {
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  match mp4_av1_muxer_new(64, 0, av1c) {
    Ok(_) => fail("zero height must fail")
    Err(_) => ()
  }
  let mux = mp4_av1_muxer_new(64, 48, av1c).unwrap()
  match mux.write_packet(Bytes::new(0)) {
    Ok(_) => fail("empty packet must fail")
    Err(_) => ()
  }
}

///|
/// av1C from an FFmpeg 9.0.2 `libaom-av1` 64x48 Main-profile MP4 (16 bytes,
/// including the four-byte record header).
let mp4_av1_real_av1c_b64 : Bytes = b"gQAMAAoKAAAAAq/3m18gCA=="

///|
/// Five temporal units of that stream (sample bytes from the source MP4).
let mp4_av1_real_frames_b64 : Array[Bytes] = [
  b"CgoAAAACr/ebXyAIMtsCFAAs4AAAkAug23HA/pBNXuZFvMxFx8QUOT2IeQyTITdBfokGV1dchYwPhLQZ3MO0NgUquXmYtg9SYOZe8Czwod8KBVRko7wPZu+R0aa/HCkqxI/vym2ttqILcatfKaJ7TASmvz9xlvKm3QNDbIkt9FmC/VkUBYOKIBf/XcfgrqFM0ffnZOdZlctOc77zigeUolMS7xiadvJ50fXISCEIuDoHCyZrYsKDXG9glJuMOd+e8C2uN8hNzjNPq78nKZrSxH6qlfGEE4aa0SGR/xs2To6oCUF9m5IUIOUhSN7stiNJP3IlITuBUSvSe1pP1Vn6KY3Yi9sY6YMutAtBwksHMB3QJ447ed6OQ4Njb7lJ7zVss2ae76x3FMSL/rscIUutoCQvVzx2d9AqRwUb9wvESUBmrXTEmeo+VaxPnf0WzyFEsbrs9Uz4oam8gizQb9CQaDwwkMi7J1X8pjg=",
  b"MjEhAnAgAAARryAIIIAJLLiAAN05ePIFz8/AG3R9NbvjqbJJKGrXFETFT/PDgbQCP504MhMpAXBAABABs+AIIIAKAACAAJtIMiYyAeEAAECDaAAQQQAUXXKAAN0E0LYphhOZPQ8kAtKz9K/IaXJoEA==",
  b"GgGo", b"MhMyAyIEwACDaAAQQQAUAAOAAJfA", b"MhIyBAAImACDaAAQQQAUAAEAmsA=",
]

///|
let mp4_av1_real_refs : Array[String] = [
  "3ea6ee5946f5fe0778f2b5225e5ff478", "d57ee243284308de047ea1c44d703f3a", "5ab3dd2eeea49c4e1477ec34aa0d6bb7",
  "5ab3dd2eeea49c4e1477ec34aa0d6bb7", "5ab3dd2eeea49c4e1477ec34aa0d6bb7",
]

///|
fn mp4_av1_real_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "mp4 muxer: real AV1 samples decode round-trip" {
  let av1c = @libavutil.av_base64_decode(mp4_av1_real_av1c_b64, 256).unwrap()
  let frames : Array[Bytes] = []
  for f in mp4_av1_real_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  assert_eq(frames.length(), 5)
  let mux = mp4_av1_muxer_new(64, 48, av1c).unwrap()
  for i, frame in frames {
    mux.write_packet(frame, duration=9000, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "av01")
  assert_eq(track.extradata.unwrap(), av1c)
  assert_eq(track.samples.length(), 5)
  let dec = @libavcodec.Av1Decoder::new()
  for i, sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = bytes[start:end].to_owned()
    assert_eq(packet, frames[i])
    let frame = match dec.decode_packet(packet) {
      Ok(Some(p)) => p
      Ok(None) => fail("av1 frame \{i} not shown")
      Err(e) => fail("av1 frame \{i}: \{e}")
    }
    assert_eq(mp4_av1_real_md5(frame.packed()), mp4_av1_real_refs[i])
  }
}
