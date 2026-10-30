///|
/// fMP4 B-frame segments: composition offsets from real x264 B-frame
/// samples are written into the `trun` version/CTS fields, survive a
/// split-segment round-trip through `av_mov_open`, and decode intact.

///|
test "fmp4: H.264 B-frame composition offsets survive split segments" {
  let src = @libavutil.av_base64_decode(mp4_bframes_src_b64, 100000).unwrap()
  let movie = av_mov_open(src).unwrap()
  let track = movie.tracks[0]
  let avcc = track.extradata.unwrap()
  let timescale = track.timescale.reinterpret_as_int()
  let init = fmp4_h264_init_segment(track.width, track.height, timescale, avcc).unwrap()
  let samples : Array[Fmp4Sample] = []
  let first : Array[Fmp4Sample] = []
  let second : Array[Fmp4Sample] = []
  let src_payloads : Array[Bytes] = []
  let mut base2 = 0L
  for i, sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let payload = src[start:end].to_owned()
    src_payloads.push(payload)
    let s = fmp4_sample(
      payload,
      sample.duration.reinterpret_as_int(),
      sample.keyframe,
      cts=(sample.pts - sample.dts).to_int(),
    )
    samples.push(s)
    if i < 3 {
      first.push(s)
      base2 = base2 + sample.duration.to_int64()
    } else {
      second.push(s)
    }
  }
  assert_true(samples.length() == 8)
  let seg1 = fmp4_media_segment(1, 1, 0L, first).unwrap()
  let seg2 = fmp4_media_segment(1, 2, base2, second).unwrap()
  let file : Array[Byte] = []
  for part in [init, seg1, seg2] {
    for b in part {
      file.push(b)
    }
  }
  let file_bytes = Bytes::from_array(file)
  let remux = av_mov_open(file_bytes).unwrap()
  let rt = remux.tracks[0]
  assert_eq(rt.samples.length(), track.samples.length())
  let src_base = track.samples[0].dts
  let out_base = rt.samples[0].dts
  for i in 0..<track.samples.length() {
    let a = track.samples[i]
    let b = rt.samples[i]
    assert_eq(b.pts - b.dts, a.pts - a.dts, msg="cts \{i}")
    assert_eq(b.dts - out_base, a.dts - src_base, msg="dts \{i}")
    assert_eq(b.keyframe, a.keyframe, msg="key \{i}")
  }
  let out_payloads : Array[Bytes] = []
  for sample in rt.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    out_payloads.push(file_bytes[start:end].to_owned())
  }
  let src_md5 = mp4_bframes_decode(avcc, src_payloads)
  let out_md5 = mp4_bframes_decode(avcc, out_payloads)
  assert_eq(out_md5.length(), src_md5.length())
  for i in 0..<src_md5.length() {
    assert_eq(out_md5[i], src_md5[i], msg="frame \{i}")
  }
}
