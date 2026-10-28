///|
/// DASH SegmentBase single-file playback: an ffmpeg `-global_sidx 1` MP4 is
/// addressed by `indexRange`/`Initialization range`; the reader parses the
/// global sidx and fetches both subsegment ranges. The reassembled H.264
/// access units must decode to FFmpeg's framemd5 references.

///|
let dash_sb_mp4_b64 = b"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"

///|
let dash_sb_mpd =
  #|<?xml version="1.0" encoding="UTF-8"?>
  #|<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static"
  #|     profiles="urn:mpeg:dash:profile:isoff-live:2011"
  #|     mediaPresentationDuration="PT1.0S" minBufferTime="PT1.0S">
  #|  <Period id="0" start="PT0.0S">
  #|    <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.64000a">
  #|      <Representation id="0" bandwidth="33400" width="64" height="48">
  #|        <BaseURL>out-stream0.mp4</BaseURL>
  #|        <SegmentBase indexRange="817-880">
  #|          <Initialization range="0-816" />
  #|        </SegmentBase>
  #|      </Representation>
  #|    </AdaptationSet>
  #|  </Period>
  #|</MPD>

///|
let dash_sb_refs : Array[String] = [
  "0d0e1e41b85c93d65be60889a5b97e22", "055afc97c18ce5c2f1fe514ebc2451b9", "1661b8de48987f0eeb9002be26cf5cfc",
  "e28f55d2f9d07f2e7e624c9253df5d0f", "b038a9efdd9699bfe9643ef732ab7b5a", "c81a0c594dfbd67faef49c5352629a9c",
  "d3281188452cf16d674c74ae935d35b1", "d234153be74001956628ff01154d5a37", "9902479439a1f69efd3420a34449181c",
  "fda391f56f4f7014f807dd23a07a0dea",
]

///|
test "dash: SegmentBase indexRange single-file playback" {
  let mpd = av_dash_parse(dash_sb_mpd).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.index_range, "817-880")
  assert_eq(rep.initialization, "out-stream0.mp4")
  assert_eq(rep.initialization_range, "0-816")
  assert_eq(rep.segments.length(), 0)
  let file = @libavutil.av_base64_decode(dash_sb_mp4_b64, 100000).unwrap()
  let fetch : MediaFetch = (uri, offset, length) => {
    if uri != "out-stream0.mp4" {
      return Err("unexpected uri \{uri}")
    }
    let start = offset.to_int()
    let end = if length < 0L { file.length() } else { start + length.to_int() }
    if start < 0 || end > file.length() || start > end {
      return Err("bad range")
    }
    Ok(file[start:end].to_owned())
  }
  let reader = dash_segment_reader_new(rep, fetch)
  let mut avcc : Bytes = b""
  let payload : Array[Byte] = []
  let mut total_samples = 0
  let mut segments = 0
  while true {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => break
      Err(e) => fail("segment read failed: \{e}")
    }
    segments = segments + 1
    let movie = match av_mov_open(segment.bytes()) {
      Ok(v) => v
      Err(e) => fail("fMP4 open failed: \{e}")
    }
    let track = movie.tracks[0]
    avcc = track.extradata.unwrap()
    total_samples = total_samples + track.samples.length()
    let bytes = segment.bytes()
    for sample in track.samples {
      let start = sample.offset.to_int()
      let end = start + sample.size.reinterpret_as_int()
      for b in bytes[start:end] {
        payload.push(b)
      }
    }
  }
  assert_eq(segments, 2)
  assert_eq(total_samples, 10)
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 10)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), dash_sb_refs[i], msg=i.to_string())
  }
}
