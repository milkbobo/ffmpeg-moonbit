///|
/// AES-128 encrypted HLS writer test: a real H.264 + AAC MPEG-TS segment is
/// produced by `TsMuxer`, encrypted with `hls_encrypt_aes128`, published with
/// `hls_write_media_playlist` (EXT-X-KEY) and read back through
/// `av_hls_parse` + `HlsSegmentReader` with in-memory key/segment fetch. The
/// decrypted TS decodes to the same FFmpeg references as the plain TS test.

///|
test "hls muxer: AES-128 encrypted segment round-trips through the reader" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let params = fmp4_h264_avcc_params(avcc)
  let source = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let mux = ts_muxer_new(video_stream_type=0x1B, audio_stream_type=0x0F)
  mux.enable_adts(44100, 1).unwrap()
  for i, sample in samples {
    mux.write_video(
      i.to_int64() * 9000L,
      fmp4_h264_annexb(avcc, [params, sample]),
    )
  }
  let mut audio_count = 0
  for packet in source.packets {
    if packet.stream_index == 1 && audio_count < 5 {
      mux.write_audio(audio_count.to_int64() * 2090L, packet.data)
      audio_count = audio_count + 1
    }
  }
  let plain = mux.finish()
  let key = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
  let iv : Bytes = Bytes::make(16, b'\x00')
  let encrypted = hls_encrypt_aes128(key, iv, plain).unwrap()
  assert_eq(encrypted.length(), (plain.length() / 16 + 1) * 16)
  assert_true(encrypted != plain)
  assert_eq(hls_decrypt_aes128(key, iv, encrypted).unwrap(), plain)

  let playlist = hls_write_media_playlist(
    [("seg0.ts", 0.5)],
    media_sequence=0L,
    key_uri=Some("key.bin"),
    key_iv=Some(iv),
  )
  assert_true(
    playlist.contains(
      "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x00000000000000000000000000000000",
    ),
  )
  let parsed = av_hls_parse(playlist).unwrap()
  assert_eq(parsed.keys.length(), 1)
  assert_eq(parsed.keys[0].method_, "AES-128")
  assert_eq(parsed.keys[0].uri, "key.bin")
  assert_eq(parsed.segments.length(), 1)
  assert_eq(parsed.segments[0].key_index, 0)
  let fetch : MediaFetch = (uri, _, _) => {
    if uri == "key.bin" {
      Ok(key)
    } else if uri == "seg0.ts" {
      Ok(encrypted)
    } else {
      Err("unexpected uri \{uri}")
    }
  }
  let reader = hls_segment_reader_new(parsed, fetch).unwrap()
  let data = match reader.next() {
    Ok(Some(v)) => v
    Ok(None) => fail("no HLS segment")
    Err(e) => fail("HLS read failed: \{e}")
  }
  let bytes = data.bytes()
  assert_true(bytes.length() > 0)
  assert_eq(bytes[0].to_int(), 0x47)
  let ts = av_mpegts_open(bytes).unwrap()
  assert_eq(ts.streams.length(), 2)
  let video_pid = ts.streams[0].pid
  let audio_pid = ts.streams[1].pid
  let video : Array[Byte] = []
  let audio_packets : Array[Bytes] = []
  for packet in ts.packets {
    if packet.pid == video_pid {
      for b in packet.payload {
        video.push(b)
      }
    } else if packet.pid == audio_pid {
      audio_packets.push(packet.payload)
    }
  }
  assert_eq(audio_packets.length(), 5)
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(Bytes::from_array(video), false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
  let adec = @libavcodec.new_aac_decoder_from_asc(b"\x12\x08").unwrap()
  let pcm : Array[Double] = []
  for packet in audio_packets {
    let header = @libavcodec.av_aac_adts_header_size
    assert_true(packet.length() > header)
    let out = match adec.decode_frame(packet[header:].to_owned()) {
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
