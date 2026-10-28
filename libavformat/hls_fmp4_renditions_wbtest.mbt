///|
/// HLS fMP4 with a separate audio rendition: `EXT-X-MAP` initialization
/// sections in both media playlists, an `EXT-X-MEDIA` audio group in the
/// master playlist, and full read-back through `HlsSegmentReader` (init +
/// media), MOV demux and H.264/AAC decode against the same FFmpeg references
/// as the other container tests.

///|
test "hls: fMP4 video playlist and audio rendition decode round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let vsamples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    vsamples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let vinit = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let vmedia = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(vsamples[0], 9000, true),
    fmp4_sample(vsamples[1], 9000, false),
    fmp4_sample(vsamples[2], 9000, false),
    fmp4_sample(vsamples[3], 9000, false),
    fmp4_sample(vsamples[4], 9000, false),
  ]).unwrap()
  let source = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let packets : Array[Bytes] = []
  for packet in source.packets {
    if packet.stream_index == 1 && packets.length() < 5 {
      packets.push(packet.data)
    }
  }
  let ainit = fmp4_aac_init_segment(44100, 1).unwrap()
  let asamples : Array[Fmp4Sample] = []
  for packet in packets {
    asamples.push(fmp4_sample(packet, 1024, true))
  }
  let amedia = fmp4_media_segment(1, 1, 0L, asamples).unwrap()
  let vplaylist = hls_write_media_playlist(
    [("video-1.m4s", 0.5)],
    version=6,
    map_uri=Some("video-init.mp4"),
  )
  let aplaylist = hls_write_media_playlist(
    [("audio-1.m4s", 0.5)],
    version=6,
    map_uri=Some("audio-init.mp4"),
  )
  let master = hls_write_master_playlist(
    [
      HlsMasterVariant::new(
        "video.m3u8",
        800000,
        64,
        48,
        "avc1.42c00a,mp4a.40.2",
        audio_group="aud",
      ),
    ],
    renditions=[
      HlsMasterRendition::new(
        "AUDIO",
        "aud",
        "English",
        "audio.m3u8",
        language="en",
        is_default=true,
        channels="1",
      ),
    ],
    version=6,
  )
  let master_pl = av_hls_parse(master).unwrap()
  assert_eq(master_pl.renditions.length(), 1)
  assert_eq(master_pl.renditions[0].uri, "audio.m3u8")

  let fetch : MediaFetch = (uri, _, _) => {
    if uri == "video-init.mp4" {
      Ok(vinit)
    } else if uri == "video-1.m4s" {
      Ok(vmedia)
    } else if uri == "audio-init.mp4" {
      Ok(ainit)
    } else if uri == "audio-1.m4s" {
      Ok(amedia)
    } else {
      Err("unexpected uri \{uri}")
    }
  }
  let vpl = av_hls_parse(vplaylist).unwrap()
  assert_eq(vpl.maps.length(), 1)
  assert_eq(vpl.maps[0].uri, "video-init.mp4")
  let vreader = hls_segment_reader_new(vpl, fetch).unwrap()
  let vseg = match vreader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no video segment")
    Err(e) => fail("video read failed: \{e}")
  }
  let vbytes = vseg.bytes()
  let vmovie = av_mov_open(vbytes).unwrap()
  assert_eq(vmovie.tracks.length(), 1)
  let vtrack = vmovie.tracks[0]
  assert_eq(vtrack.codec, "avc1")
  assert_eq(vtrack.samples.length(), 5)
  let payload : Array[Byte] = []
  for sample in vtrack.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in vbytes[start:end] {
      payload.push(b)
    }
  }
  let vb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let vdec = @libavcodec.new_h264_decoder()
  let frames = match vdec.decode_annexb(vb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }

  let apl = av_hls_parse(aplaylist).unwrap()
  assert_eq(apl.maps.length(), 1)
  assert_eq(apl.maps[0].uri, "audio-init.mp4")
  let areader = hls_segment_reader_new(apl, fetch).unwrap()
  let aseg = match areader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no audio segment")
    Err(e) => fail("audio read failed: \{e}")
  }
  let abytes = aseg.bytes()
  let amovie = av_mov_open(abytes).unwrap()
  assert_eq(amovie.tracks.length(), 1)
  let atrack = amovie.tracks[0]
  assert_eq(atrack.codec, "mp4a")
  assert_eq(atrack.samples.length(), 5)
  let adec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  let pcm : Array[Double] = []
  for sample in atrack.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let out = match adec.decode_frame(abytes[start:end].to_owned()) {
      Ok(v) => v
      Err(e) => fail("AAC decode failed: \{e}")
    }
    for element in out {
      for v in element.samples {
        pcm.push(v)
      }
    }
  }
  assert_eq(pcm.length(), 5120)
}
