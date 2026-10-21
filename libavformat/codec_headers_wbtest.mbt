///|
/// Tests for the Opus packet, AV1 OBU/sequence-header and VP9 frame-header
/// slices. The packets come from the small real WebM files embedded in
/// `webm_codec_parameters_wbtest.mbt` (same white-box test package), so the
/// expected values are ffprobe's: Opus 48 kHz / 20 ms packets, VP9 64x48
/// keyframe, AV1 Main 64x48 yuv420p.

///|
test "opus: real WebM packets are 20 ms" {
  let bytes = @libavutil.av_base64_decode(webm_opus_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_true(mkv.packets.length() >= 3)
  let p = @libavcodec.opus_parse_packet(mkv.packets[0].data).unwrap()
  assert_eq(p.frame_duration, 960)
  assert_eq(p.frame_count, 1)
  assert_eq(p.total_samples, 960)
  assert_eq(p.code, 0)
  assert_true(!p.stereo)
  assert_eq(p.mode, "hybrid")
  assert_eq(p.frame_sizes.length(), 1)
  assert_eq(p.frame_sizes[0], mkv.packets[0].data.length() - 1)
}

///|
test "opus: packet codes 0..3 and lacing" {
  let payload = Bytes::make(10, b'\x00')
  let code0 = @libavcodec.opus_parse_packet(b"\x80").unwrap()
  assert_eq(code0.frame_count, 1)
  assert_eq(code0.frame_duration, 120)
  assert_eq(code0.frame_sizes[0], 0)
  let pkt : Array[Byte] = [b'\x81']
  pkt.append(payload.to_array())
  let code1 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt[:])).unwrap()
  assert_eq(code1.frame_count, 2)
  assert_eq(code1.frame_sizes, [5, 5])
  let pkt2 : Array[Byte] = [b'\x82', b'\x03']
  pkt2.append(payload.to_array())
  let code2 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt2[:])).unwrap()
  assert_eq(code2.frame_count, 2)
  assert_eq(code2.frame_sizes, [3, 7])
  // Code 3 CBR: two equal frames.
  let pkt3 : Array[Byte] = [b'\x83', b'\x02']
  pkt3.append(payload.to_array())
  let code3 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt3[:])).unwrap()
  assert_eq(code3.frame_count, 2)
  assert_eq(code3.frame_sizes, [5, 5])
  // Code 3 VBR: count byte 0x82, first frame length 3, rest 10.
  let pkt4 : Array[Byte] = [b'\x83', b'\x82', b'\x03']
  pkt4.append(payload.to_array())
  let code3v = @libavcodec.opus_parse_packet(Bytes::from_array(pkt4[:])).unwrap()
  assert_true(code3v.vbr)
  assert_eq(code3v.frame_sizes, [3, 7])
  // 60 ms config (3) with three frames exceeds the 120 ms packet limit.
  let long : Bytes = b"\x1b\x03"
  match @libavcodec.opus_parse_packet(long) {
    Ok(_) => fail("expected duration error")
    Err(e) => assert_true(e.contains("120"))
  }
}

///|
test "vp9: real WebM keyframe header" {
  let bytes = @libavutil.av_base64_decode(webm_vp9_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let key = mkv.packets[0]
  assert_true(key.is_keyframe)
  let h = @libavcodec.vp9_parse_frame_header(key.data).unwrap()
  assert_true(h.keyframe)
  assert_false(h.show_existing_frame)
  assert_true(h.show_frame)
  assert_eq(h.profile, 0)
  assert_eq(h.width, 64)
  assert_eq(h.height, 48)
  assert_eq(h.bit_depth, 8)
  assert_eq(h.color_space, 0) // unspecified
  assert_true(h.chroma_subsampling_x)
  assert_true(h.chroma_subsampling_y)
  assert_eq(h.refresh_frame_flags, 0xFF)
}

///|
test "av1: av1C and OBU sequence header" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let av1c = mkv.tracks[0].codec_priv.unwrap()
  let s = @libavcodec.av1_parse_sequence_header(av1c).unwrap()
  assert_eq(s.profile, 0)
  assert_eq(s.level, 0)
  assert_eq(s.bitdepth, 8)
  assert_false(s.monochrome)
  assert_true(s.chroma_subsampling_x)
  assert_true(s.chroma_subsampling_y)
  // The keyframe packet starts with a temporal delimiter and sequence header.
  let packet = mkv.packets[0].data
  let from_obu = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_eq(from_obu.profile, 0)
  assert_eq(from_obu.bitdepth, 8)
  assert_eq(from_obu.width, 64)
  assert_eq(from_obu.height, 48)
  assert_eq(from_obu.chroma_subsampling_x, true)
}

///|
test "av1: rejects malformed OBU input" {
  match @libavcodec.av1_parse_sequence_header(b"\xff\xff") {
    Ok(_) => fail("expected OBU error")
    Err(e) => assert_true(e.contains("av1"))
  }
}

///|
test "vp9: rejects bad frame marker and sync code" {
  match @libavcodec.vp9_parse_frame_header(b"\x00\x00\x00") {
    Ok(_) => fail("expected marker error")
    Err(e) => assert_true(e.contains("marker"))
  }
  // marker 10, profile 0, show_existing 0, keyframe 1, show_frame 1,
  // error_resilient 0, then a wrong 24-bit sync code.
  let bad : Bytes = b"\x82\x00\x00\x00"
  match @libavcodec.vp9_parse_frame_header(bad) {
    Ok(_) => fail("expected sync error")
    Err(e) => assert_true(e.contains("sync"))
  }
}

///|
test "av1: keyframe frame header matches trace_headers" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let packet = mkv.packets[0].data
  let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_true(seq.enable_order_hint)
  assert_eq(seq.order_hint_bits, 7)
  assert_eq(seq.seq_force_screen_content_tools, 2)
  let fh = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
  assert_false(fh.show_existing_frame)
  assert_eq(fh.frame_type, @libavcodec.av1_frame_key)
  assert_true(fh.show_frame)
  assert_true(fh.error_resilient_mode) // KEY+show_frame infers resilient
  assert_false(fh.disable_cdf_update)
  assert_true(fh.allow_screen_content_tools)
  assert_false(fh.force_integer_mv)
  assert_false(fh.frame_size_override_flag)
  assert_eq(fh.order_hint, 0)
  assert_eq(fh.width, 64)
  assert_eq(fh.height, 48)
  assert_eq(fh.render_width, 64)
  assert_eq(fh.render_height, 48)
  assert_false(fh.use_superres)
  assert_false(fh.allow_intrabc)
}
