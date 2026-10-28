///|
/// `mp4_faststart`: the H.264 writer output is rewritten to
/// `ftyp`+`moov`+`mdat`; chunk offsets are shifted so the file still demuxes
/// and decodes to the FFmpeg frame references.

///|
fn mp4_faststart_test_offset(data : Bytes, tag : String) -> Int32 {
  let mut off = 0
  while off + 8 <= data.length() {
    let size = ((data[off].to_uint() << 24) |
    (data[off + 1].to_uint() << 16) |
    (data[off + 2].to_uint() << 8) |
    data[off + 3].to_uint()).reinterpret_as_int()
    if size < 8 {
      return -1
    }
    let mut matches = true
    for i = 0; i < 4; i = i + 1 {
      if data[off + 4 + i].to_int() != tag[i].to_int() {
        matches = false
      }
    }
    if matches {
      return off
    }
    off = off + size
  }
  -1
}

///|
test "mp4: faststart moves moov before mdat and keeps decoding" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let mux = mp4_h264_muxer_new(64, 48, avcc).unwrap()
  for i, sample in samples {
    mux.write_packet(sample, duration=9000, keyframe=i == 0).unwrap()
  }
  let plain = mux.finish()
  assert_true(
    mp4_faststart_test_offset(plain, "mdat") <
    mp4_faststart_test_offset(plain, "moov"),
  )
  let fast = match mp4_faststart(plain) {
    Ok(v) => v
    Err(e) => fail("faststart failed: \{e}")
  }
  let ftyp_end = mp4_faststart_test_offset(plain, "mdat")
  assert_eq(mp4_faststart_test_offset(fast, "ftyp"), 0)
  assert_eq(mp4_faststart_test_offset(fast, "moov"), ftyp_end)
  let plain_moov = mp4_faststart_test_offset(plain, "moov")
  let moov_size = plain.length() - plain_moov
  assert_eq(mp4_faststart_test_offset(fast, "mdat"), ftyp_end + moov_size)
  assert_eq(fast.length(), plain.length())
  // mdat payload is unchanged; only moov offsets move.
  let plain_mdat = mp4_faststart_test_offset(plain, "mdat")
  let fast_mdat = mp4_faststart_test_offset(fast, "mdat")
  let mdat_size = plain_moov - plain_mdat
  for i = 0; i < mdat_size; i = i + 1 {
    assert_eq(plain[plain_mdat + i], fast[fast_mdat + i])
  }
  let movie = match av_mov_open(fast) {
    Ok(v) => v
    Err(e) => fail("faststart demux failed: \{e}")
  }
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.samples.length(), 5)
  let payload : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in fast[start:end] {
      payload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
  let bad = mp4_faststart(b"\x00\x00\x00\x08ftyp")
  assert_true(bad is Err(_))
}
