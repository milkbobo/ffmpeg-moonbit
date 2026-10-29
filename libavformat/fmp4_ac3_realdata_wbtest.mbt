///|
/// fMP4 AC-3/E-AC-3 tests.  The raw frames are the FFmpeg 9.0.2 fixtures from
/// the codec tests; one init segment (`ac-3`/`dac3`, `ec-3`/`dec3`) plus two
/// media segments are concatenated and parsed by `av_mov_open`.  External
/// FFmpeg 9.0.2 decodes both fragment sequences byte-identically to the raw
/// streams.

///|
let fmp4_ac3_b64 : Bytes = b"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"

///|
let fmp4_eac3_b64 : Bytes = b"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"

///|
fn fmp4_cont_split(data : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 0
  while pos + 8 <= data.length() {
    let hdr = @libavcodec.ac3_parse_header(data[pos:].to_owned()).unwrap()
    frames.push(data[pos:pos + hdr.frame_size].to_owned())
    pos = pos + hdr.frame_size
  }
  frames
}

///|
fn fmp4_cont_join(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
test "fMP4 muxer: AC-3 and E-AC-3 segments round-trip" {
  let ac3 = @libavutil.av_base64_decode(fmp4_ac3_b64, 100000).unwrap()
  let eac3 = @libavutil.av_base64_decode(fmp4_eac3_b64, 100000).unwrap()
  let ac3_frames = fmp4_cont_split(ac3)
  let eac3_frames = fmp4_cont_split(eac3)

  let init = fmp4_ac3_init_segment(ac3_frames[0]).unwrap()
  let seg0 = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(ac3_frames[0], 1536, true),
    fmp4_sample(ac3_frames[1], 1536, true),
  ]).unwrap()
  let seg1 = fmp4_media_segment(1, 2, 3072L, [
    fmp4_sample(ac3_frames[2], 1536, true),
    fmp4_sample(ac3_frames[3], 1536, true),
  ]).unwrap()
  let bytes = fmp4_cont_join([init, seg0, seg1])
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "ac-3")
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.channels, 1U)
  assert_eq(track.timescale, 48000U)
  assert_eq(track.samples.length(), 4)
  for i, sample in track.samples {
    assert_eq(sample.dts, (i * 1536).to_int64())
    assert_eq(sample.duration, 1536U)
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytes[start:end].to_owned(), ac3_frames[i])
  }

  let init_e = fmp4_eac3_init_segment(eac3_frames[0]).unwrap()
  let seg0e = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(eac3_frames[0], 1536, true),
    fmp4_sample(eac3_frames[1], 1536, true),
  ]).unwrap()
  let seg1e = fmp4_media_segment(1, 2, 3072L, [
    fmp4_sample(eac3_frames[2], 1536, true),
    fmp4_sample(eac3_frames[3], 1536, true),
  ]).unwrap()
  let bytese = fmp4_cont_join([init_e, seg0e, seg1e])
  let moviee = av_mov_open(bytese).unwrap()
  assert_eq(moviee.tracks.length(), 1)
  let tracke = moviee.tracks[0]
  assert_eq(tracke.codec, "ec-3")
  assert_eq(tracke.sample_rate, 48000U)
  assert_eq(tracke.channels, 2U)
  assert_eq(tracke.samples.length(), 4)
  for i, sample in tracke.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytese[start:end].to_owned(), eac3_frames[i])
  }
}
