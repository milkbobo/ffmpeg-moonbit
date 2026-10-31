///|
/// HLS fMP4 media playlist with B-frame segments: `EXT-X-MAP` plus trun
/// composition offsets survive the HLS segment reader and decode in the
/// source presentation order.

///|
test "hls: B-frame fMP4 segments keep composition offsets" {
  let src = @libavutil.av_base64_decode(mp4_bframes_src_b64, 100000).unwrap()
  let movie = av_mov_open(src).unwrap()
  let track = movie.tracks[0]
  let avcc = track.extradata.unwrap()
  let timescale = track.timescale.reinterpret_as_int()
  let init = fmp4_h264_init_segment(track.width, track.height, timescale, avcc).unwrap()
  let src_payloads : Array[Bytes] = []
  let first : Array[Fmp4Sample] = []
  let second : Array[Fmp4Sample] = []
  let mut seg_duration = 0L
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
    if i < 4 {
      first.push(s)
      seg_duration = seg_duration + sample.duration.to_int64()
    } else {
      second.push(s)
    }
  }
  let media1 = fmp4_media_segment(1, 1, 0L, first).unwrap()
  let media2 = fmp4_media_segment(1, 2, seg_duration, second).unwrap()
  let files : Map[String, Bytes] = Map([])
  files["init.mp4"] = init
  files["seg-1.m4s"] = media1
  files["seg-2.m4s"] = media2
  let playlist_text = hls_write_media_playlist(
    [
      ("seg-1.m4s", seg_duration.to_double() / 10240.0),
      ("seg-2.m4s", seg_duration.to_double() / 10240.0),
    ],
    target_duration=1,
    map_uri=Some("init.mp4"),
  )
  let playlist = av_hls_parse(playlist_text).unwrap()
  let fetch : MediaFetch = (uri, offset, length) => {
    let data = match files.get(uri) {
      Some(bytes) => bytes
      None => return Err("unexpected uri \{uri}")
    }
    let start = offset.to_int()
    let end = if length < 0L { data.length() } else { start + length.to_int() }
    if start < 0 || end > data.length() || start > end {
      return Err("bad range")
    }
    Ok(data[start:end].to_owned())
  }
  let reader = hls_segment_reader_new(playlist, fetch).unwrap()
  let payloads : Array[Bytes] = []
  let pts_seq : Array[Int64] = []
  let dts_seq : Array[Int64] = []
  for _ in 0..<2 {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => fail("missing HLS segment")
      Err(e) => fail("segment read failed: \{e}")
    }
    let bytes = segment.bytes()
    let seg_movie = av_mov_open(bytes).unwrap()
    for sample in seg_movie.tracks[0].samples {
      let start = sample.offset.to_int()
      let end = start + sample.size.reinterpret_as_int()
      payloads.push(bytes[start:end].to_owned())
      pts_seq.push(sample.pts)
      dts_seq.push(sample.dts)
    }
  }
  assert_eq(payloads.length(), track.samples.length())
  let src_base = track.samples[0].dts
  let out_base = dts_seq[0]
  for i in 0..<payloads.length() {
    let a = track.samples[i]
    assert_eq(payloads[i], src_payloads[i], msg="payload \{i}")
    assert_eq(pts_seq[i] - dts_seq[i], a.pts - a.dts, msg="cts \{i}")
    assert_eq(dts_seq[i] - out_base, a.dts - src_base, msg="dts \{i}")
  }
  let src_md5 = mp4_bframes_decode(avcc, src_payloads)
  let out_md5 = mp4_bframes_decode(avcc, payloads)
  assert_eq(out_md5.length(), src_md5.length())
  for i in 0..<src_md5.length() {
    assert_eq(out_md5[i], src_md5[i], msg="frame \{i}")
  }
}
