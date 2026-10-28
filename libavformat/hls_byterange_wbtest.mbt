///|
/// HLS `EXT-X-BYTERANGE`: one single-file TS resource is described by three
/// byte-range segments (the last two omit `@offset`, so the parser continues
/// after the previous range). The reader fetches each slice and the AAC
/// packets still decode.

///|
test "hls: byte-range media playlist over one TS file" {
  let source = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let packets : Array[Bytes] = []
  for packet in source.packets {
    if packet.stream_index == 1 && packets.length() < 5 {
      packets.push(packet.data)
    }
  }
  assert_eq(packets.length(), 5)
  let segments : Array[Bytes] = []
  let mut idx = 0
  let mut pts = 0L
  for count in [2, 2, 1] {
    let mux = ts_muxer_new(video=false, audio=true)
    mux.enable_adts(44100, 1).unwrap()
    for _ in 0..<count {
      mux.write_audio(pts, packets[idx])
      idx = idx + 1
      pts = pts + 2090L
    }
    segments.push(mux.finish())
  }
  let media : Array[Byte] = []
  for seg in segments {
    for b in seg {
      media.push(b)
    }
  }
  let media_bytes = Bytes::from_array(media)
  let r1 = HlsByteRange::new(segments[0].length().to_int64(), offset=0L)
  let r2 = HlsByteRange::new(segments[1].length().to_int64())
  let r3 = HlsByteRange::new(segments[2].length().to_int64())
  let text = hls_write_media_playlist_byterange(
    [
      HlsMediaSegmentSpec::new("media.ts", 0.0464, byterange=Some(r1)),
      HlsMediaSegmentSpec::new("media.ts", 0.0464, byterange=Some(r2)),
      HlsMediaSegmentSpec::new("media.ts", 0.0464, byterange=Some(r3)),
    ],
    version=3,
  )
  assert_true(text.contains("#EXT-X-VERSION:4"))
  assert_true(text.contains("#EXT-X-BYTERANGE:\{segments[0].length()}@0"))
  assert_true(text.contains("#EXT-X-BYTERANGE:\{segments[1].length()}\n"))
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.segments.length(), 3)
  let b1 = playlist.segments[0].byterange.unwrap()
  let b2 = playlist.segments[1].byterange.unwrap()
  let b3 = playlist.segments[2].byterange.unwrap()
  assert_eq(b1.offset, 0L)
  assert_eq(b2.offset, segments[0].length().to_int64())
  assert_eq(b3.offset, (segments[0].length() + segments[1].length()).to_int64())
  assert_eq(b3.offset + b3.length, media_bytes.length().to_int64())
  let fetch : MediaFetch = (uri, offset, length) => {
    if uri != "media.ts" {
      return Err("unexpected uri \{uri}")
    }
    let start = offset.to_int()
    let end = if length < 0L {
      media_bytes.length()
    } else {
      start + length.to_int()
    }
    if start < 0 || end > media_bytes.length() || start > end {
      return Err("bad range")
    }
    Ok(media_bytes[start:end].to_owned())
  }
  let reader = hls_segment_reader_new(playlist, fetch).unwrap()
  let adec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  let mut total_packets = 0
  let mut total_samples = 0
  for _ in 0..<3 {
    let segment = match reader.next() {
      Ok(Some(v)) => v
      Ok(None) => fail("missing segment")
      Err(e) => fail("segment read failed: \{e}")
    }
    let demux = match av_mpegts_open(segment.bytes()) {
      Ok(v) => v
      Err(e) => fail("TS open failed: \{e}")
    }
    assert_eq(demux.streams.length(), 1)
    let pid = demux.streams[0].pid
    for packet in demux.packets {
      if packet.pid == pid {
        total_packets = total_packets + 1
        let header = @libavcodec.av_aac_adts_header_size
        let out = match adec.decode_frame(packet.payload[header:].to_owned()) {
          Ok(v) => v
          Err(e) => fail("AAC decode failed: \{e}")
        }
        for element in out {
          total_samples = total_samples + element.samples.length()
        }
      }
    }
  }
  assert_eq(total_packets, 5)
  assert_eq(total_samples, 5120)
}

///|
test "hls: EXT-X-MAP byte range attribute" {
  let text = hls_write_media_playlist_byterange(
    [
      HlsMediaSegmentSpec::new(
        "media.mp4",
        1.0,
        byterange=Some(HlsByteRange::new(100L, offset=200L)),
      ),
    ],
    map_uri=Some("init.mp4"),
    map_byterange=Some(HlsByteRange::new(720L, offset=0L)),
  )
  assert_true(text.contains("#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"720@0\""))
  let playlist = av_hls_parse(text).unwrap()
  assert_eq(playlist.maps[0].byterange.unwrap().length, 720L)
  assert_eq(playlist.segments[0].byterange.unwrap().offset, 200L)
}
