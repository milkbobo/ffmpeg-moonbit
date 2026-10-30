///|
/// Real H.264 MP4 with B-frames (x264 bf=3, 64x48, 8 frames). Remuxing
/// through `Mp4H264Muxer` must preserve every sample's PTS/DTS via `ctts`
/// and keep the decoded frames identical.

///|
let mp4_bframes_src_b64 : Bytes = b"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"

///|
fn mp4_bframes_md5(frame : @libavcodec.H264Frame) -> String {
  let yuv = frame.yuvp()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
fn mp4_bframes_decode(
  avcc : Bytes,
  payloads : Array[Bytes],
) -> Array[String] raise {
  let samples : Array[Bytes] = [fmp4_h264_avcc_params(avcc)]
  for p in payloads {
    samples.push(p)
  }
  let annex = fmp4_h264_annexb(avcc, samples)
  let dec = @libavcodec.new_h264_decoder()
  let frames = dec.decode_annexb(annex, false).unwrap()
  let ordered = @libavcodec.h264_display_order(frames)
  let md5s : Array[String] = []
  for frame in ordered {
    md5s.push(mp4_bframes_md5(frame))
  }
  md5s
}

///|
test "mp4: H.264 B-frames round-trip PTS through ctts" {
  let src_bytes = @libavutil.av_base64_decode(mp4_bframes_src_b64, 100000).unwrap()
  let movie = av_mov_open(src_bytes).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  let avcc = track.extradata.unwrap()
  let mux = mp4_h264_muxer_new(
    track.width,
    track.height,
    avcc,
    timescale=track.timescale.reinterpret_as_int(),
  ).unwrap()
  let src_payloads : Array[Bytes] = []
  let mut reordered = false
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let payload = src_bytes[start:end].to_owned()
    src_payloads.push(payload)
    if sample.pts != sample.dts {
      reordered = true
    }
    mux
    .write_packet(
      payload,
      duration=sample.duration.reinterpret_as_int(),
      keyframe=sample.keyframe,
      cts=(sample.pts - sample.dts).to_int(),
    )
    .unwrap()
  }
  assert_true(reordered, msg="fixture must contain reordered B-frames")
  let out = mux.finish()
  let remux = av_mov_open(out).unwrap()
  let rt = remux.tracks[0]
  assert_eq(rt.samples.length(), track.samples.length())
  // The writer has no edit list, so DTS starts at 0 instead of the source's
  // negative first DTS; PTS-DTS and the DTS deltas must match exactly.
  let src_base = track.samples[0].dts
  let out_base = rt.samples[0].dts
  for i in 0..<track.samples.length() {
    let a = track.samples[i]
    let b = rt.samples[i]
    assert_eq(b.pts - b.dts, a.pts - a.dts, msg="cts \{i}")
    assert_eq(b.dts - out_base, a.dts - src_base, msg="dts \{i}")
    assert_eq(b.duration, a.duration, msg="duration \{i}")
    assert_eq(b.keyframe, a.keyframe, msg="key \{i}")
  }
  let out_payloads : Array[Bytes] = []
  for sample in rt.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    out_payloads.push(out[start:end].to_owned())
  }
  let src_md5 = mp4_bframes_decode(avcc, src_payloads)
  let out_md5 = mp4_bframes_decode(avcc, out_payloads)
  assert_eq(out_md5.length(), src_md5.length())
  for i in 0..<src_md5.length() {
    assert_eq(out_md5[i], src_md5[i], msg="frame \{i}")
  }
}

///|
test "mp4: negative ctts offsets use version 1" {
  let avcc = b"\x01\x42\xc0\x1e\xff\xe1\x00\x04\x67\x42\xc0\x1e\x01\x00\x04\x68\xce\x3c\x80"
  let mux = mp4_h264_muxer_new(64, 48, avcc, timescale=90000).unwrap()
  // dts 0/3000/6000; pts 0/9000/3000 -> cts 0/+6000/-3000.
  mux
  .write_packet(b"\x00\x00\x00\x01\x65", duration=3000, keyframe=true)
  .unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x41", duration=3000, cts=6000).unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x41", duration=3000, cts=-3000).unwrap()
  let out = mux.finish()
  let mut found_ctts = false
  let mut ctts_version = -1
  for i in 0..<(out.length() - 4) {
    if out[i] == b'c' &&
      out[i + 1] == b't' &&
      out[i + 2] == b't' &&
      out[i + 3] == b's' {
      found_ctts = true
      ctts_version = out[i + 4].to_int()
    }
  }
  assert_true(found_ctts, msg="missing ctts")
  assert_eq(ctts_version, 1)
  let movie = av_mov_open(out).unwrap()
  let samples = movie.tracks[0].samples
  assert_eq(samples.length(), 3)
  assert_eq(samples[0].pts, 0L)
  assert_eq(samples[1].pts, 9000L)
  assert_eq(samples[2].pts, 3000L)
  assert_eq(samples[1].dts, 3000L)
  assert_eq(samples[2].dts, 6000L)
}
