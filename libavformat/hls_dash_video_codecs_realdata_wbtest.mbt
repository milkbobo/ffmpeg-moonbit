///|
/// HLS and DASH end-to-end coverage for the fMP4 video writers beyond H.264:
/// HEVC/AV1/VP9 init + media segments are referenced by an HLS media playlist
/// (`EXT-X-MAP`) and a SegmentTemplate MPD, fetched through the existing
/// readers, demuxed by `av_mov_open` and decoded to the same frame MD5s as the
/// plain fMP4 tests.

///|
fn hls_dash_fetch(resources : Map[String, Bytes]) -> MediaFetch {
  (uri, offset, length) => {
    let data = match resources.get(uri) {
      Some(v) => v
      None => return Err("unexpected uri " + uri)
    }
    if offset < 0L || offset > data.length().to_int64() {
      return Err("bad range")
    }
    let end = if length < 0L {
      data.length().to_int64()
    } else {
      if offset + length > data.length().to_int64() {
        return Err("range past end")
      }
      offset + length
    }
    Ok(data[offset.to_int():end.to_int()].to_owned())
  }
}

///|
fn hls_dash_payload(bytes : Bytes, track : Mp4Track) -> Array[Byte] {
  let out : Array[Byte] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in bytes[start:end] {
      out.push(b)
    }
  }
  out
}

///|
fn hls_dash_md5(data : Bytes) -> String {
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
test "hls/dash: HEVC fMP4 segment template decodes" {
  let hvcc = @libavutil.av_base64_decode(mkv_hevc_hvcc_b64, 1024).unwrap()
  let packets = mkv_hevc_au_packets(
    @libavutil.av_base64_decode(mkv_hevc_stream_b64, 1000000).unwrap(),
  )
  let samples : Array[Fmp4Sample] = []
  for i, packet in packets {
    samples.push(fmp4_sample(packet, 3000, i == 0))
  }
  let init = fmp4_hevc_init_segment(64, 64, 90000, hvcc).unwrap()
  let media = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let playlist = hls_write_media_playlist(
    [("seg-1.m4s", 0.1)],
    version=6,
    map_uri=Some("init.mp4"),
  )
  let pl = av_hls_parse(playlist).unwrap()
  let reader = hls_segment_reader_new(
    pl,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  ).unwrap()
  let seg = reader.next().unwrap().unwrap()
  let bytes = seg.bytes()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks[0].codec, "hvc1")
  assert_eq(movie.tracks[0].samples.length(), 5)
  let frames = @libavcodec.ff_hevc_decode_frames_ex(
    Bytes::from_array(hls_dash_payload(bytes, movie.tracks[0])),
    true,
    4,
    true,
  ).unwrap()
  let sorted = frames.copy()
  sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  for i = 0; i < mkv_hevc_refs.length(); i = i + 1 {
    assert_eq(mkv_hevc_md5(sorted[i].yuvp(8)), mkv_hevc_refs[i])
  }
  let mpd = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "hvc1.1.6.L93.B0",
        "v1",
        200000L,
        90000L,
        15000L,
        "init.mp4",
        "seg-$Number$.m4s",
        width=64,
        height=64,
      ),
    ],
    media_duration_seconds=0.5,
  )
  let parsed = av_dash_parse(mpd).unwrap()
  let rep = parsed.periods[0].adaptation_sets[0].representations[0]
  let dr = dash_segment_reader_new(
    rep,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  )
  let dseg = dr.next().unwrap().unwrap()
  let dbytes = dseg.bytes()
  let dmovie = av_mov_open(dbytes).unwrap()
  assert_eq(dmovie.tracks[0].samples.length(), 5)
}

///|
test "hls/dash: AV1 fMP4 segment template decodes" {
  let av1c = @libavutil.av_base64_decode(mp4_av1_real_av1c_b64, 256).unwrap()
  let frames : Array[Bytes] = []
  for f in mp4_av1_real_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  let samples : Array[Fmp4Sample] = []
  for i, frame in frames {
    samples.push(fmp4_sample(frame, 9000, i == 0))
  }
  let init = fmp4_av1_init_segment(64, 48, 90000, av1c).unwrap()
  let media = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let playlist = hls_write_media_playlist(
    [("seg-1.m4s", 0.5)],
    version=6,
    map_uri=Some("init.mp4"),
  )
  let pl = av_hls_parse(playlist).unwrap()
  let reader = hls_segment_reader_new(
    pl,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  ).unwrap()
  let seg = reader.next().unwrap().unwrap()
  let bytes = seg.bytes()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks[0].codec, "av01")
  assert_eq(movie.tracks[0].samples.length(), 5)
  let dec = @libavcodec.Av1Decoder::new()
  let mut n = 0
  for sample in movie.tracks[0].samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = bytes[start:end].to_owned()
    assert_eq(packet, frames[n])
    let picture = dec.decode_packet(packet).unwrap().unwrap()
    assert_eq(hls_dash_md5(picture.packed()), mp4_av1_real_refs[n])
    n = n + 1
  }
  let mpd = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "av01.0.04M.08",
        "v1",
        200000L,
        90000L,
        45000L,
        "init.mp4",
        "seg-$Number$.m4s",
        width=64,
        height=48,
      ),
    ],
    media_duration_seconds=0.5,
  )
  let parsed = av_dash_parse(mpd).unwrap()
  let rep = parsed.periods[0].adaptation_sets[0].representations[0]
  let dr = dash_segment_reader_new(
    rep,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  )
  let dseg = dr.next().unwrap().unwrap()
  let dbytes = dseg.bytes()
  let dmovie = av_mov_open(dbytes).unwrap()
  assert_eq(dmovie.tracks[0].samples.length(), 5)
}

///|
test "hls/dash: VP9 fMP4 segment template decodes" {
  let frames : Array[Bytes] = []
  for f in webm_av_vp9_frames_b64 {
    frames.push(@libavutil.av_base64_decode(f, 4096).unwrap())
  }
  let vpcc : Bytes = b"\x01\x00\x00\x00\x00\x00\x82\x02\x02\x02\x00\x00"
  let samples : Array[Fmp4Sample] = []
  for i, frame in frames {
    samples.push(fmp4_sample(frame, 9000, i == 0))
  }
  let init = fmp4_vp9_init_segment(64, 48, 90000, vpcc).unwrap()
  let media = fmp4_media_segment(1, 1, 0L, samples).unwrap()
  let playlist = hls_write_media_playlist(
    [("seg-1.m4s", 0.5)],
    version=6,
    map_uri=Some("init.mp4"),
  )
  let pl = av_hls_parse(playlist).unwrap()
  let reader = hls_segment_reader_new(
    pl,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  ).unwrap()
  let seg = reader.next().unwrap().unwrap()
  let bytes = seg.bytes()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks[0].codec, "vp09")
  assert_eq(movie.tracks[0].samples.length(), 5)
  let dec = @libavcodec.vp9_decoder_new()
  let mut n = 0
  for sample in movie.tracks[0].samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = bytes[start:end].to_owned()
    assert_eq(packet, frames[n])
    assert_eq(dec.decode_packet(packet).unwrap().length(), 1)
    assert_eq(hls_dash_md5(dec.frame_bytes()), webm_av_vp9_refs[n])
    n = n + 1
  }
  let mpd = dash_write_segment_template_mpd(
    [
      DashAdaptation::new(
        "video",
        "video/mp4",
        "vp09.00.10.08",
        "v1",
        200000L,
        90000L,
        45000L,
        "init.mp4",
        "seg-$Number$.m4s",
        width=64,
        height=48,
      ),
    ],
    media_duration_seconds=0.5,
  )
  let parsed = av_dash_parse(mpd).unwrap()
  let rep = parsed.periods[0].adaptation_sets[0].representations[0]
  let dr = dash_segment_reader_new(
    rep,
    hls_dash_fetch({ "init.mp4": init, "seg-1.m4s": media }),
  )
  let dseg = dr.next().unwrap().unwrap()
  let dbytes = dseg.bytes()
  let dmovie = av_mov_open(dbytes).unwrap()
  assert_eq(dmovie.tracks[0].samples.length(), 5)
}
