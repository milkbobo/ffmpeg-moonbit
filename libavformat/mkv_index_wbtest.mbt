///|
/// MKV single-track writers emit SeekHead/Cues for their video keyframes.

///|
fn mkv_index_cluster_rel(bytes : Bytes, segment_start : Int64) -> Int32 {
  for i in 0..<(bytes.length() - 4) {
    if bytes[i].to_int() == 0x1F &&
      bytes[i + 1].to_int() == 0x43 &&
      bytes[i + 2].to_int() == 0xB6 &&
      bytes[i + 3].to_int() == 0x75 {
      return i - segment_start.to_int()
    }
  }
  -1
}

///|
test "mkv H.264: SeekHead/Cues track keyframes" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let mux = mkv_h264_muxer_new(64, 48, avcc).unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x01\x65", duration=100, keyframe=true)
  .unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x41", duration=100).unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x01\x41", duration=100, keyframe=true)
  .unwrap()
  let bytes = mux.finish()
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 2)
  assert_eq(cues.cues[0].time, 0L)
  assert_eq(cues.cues[1].time, 200L)
  assert_eq(cues.cues[0].track, 1L)
  assert_eq(
    cues.cues[0].cluster_position,
    mkv_index_cluster_rel(bytes, cues.segment_data_start).to_int64(),
  )
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  assert_eq(mkv.packets.length(), 3)
}

///|
test "mkv HEVC: SeekHead/Cues track keyframes" {
  let hvcc = @libavutil.av_base64_decode(mp4_hevc_hvcc_b64, 1024).unwrap()
  let mux = mkv_hevc_muxer_new(64, 48, hvcc).unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x01\x26\x01", duration=100, keyframe=true)
  .unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x02\x01", duration=100).unwrap()
  let bytes = mux.finish()
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 1)
  assert_eq(cues.cues[0].time, 0L)
  assert_eq(
    cues.cues[0].cluster_position,
    mkv_index_cluster_rel(bytes, cues.segment_data_start).to_int64(),
  )
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  assert_eq(mkv.packets.length(), 2)
}

///|
test "mkv H.264: explicit PTS encodes B-frame reorder" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let mux = mkv_h264_muxer_new(64, 48, avcc).unwrap()
  mux
  .write_packet(b"\x00\x00\x00\x01\x65", duration=100, keyframe=true, pts_ms=0L)
  .unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x41", duration=100, pts_ms=200L).unwrap()
  mux.write_packet(b"\x00\x00\x00\x01\x41", duration=100, pts_ms=100L).unwrap()
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.packets.length(), 3)
  let expected : Array[Int64] = [0L, 200L, 100L]
  for i in 0..<3 {
    assert_eq(mkv.packets[i].pts, expected[i], msg="pts \{i}")
  }
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 1)
  assert_eq(cues.cues[0].time, 0L)
}

///|
test "mkv A/V: Cues survive tag insertion" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(
    64,
    48,
    avcc,
    44100,
    channels=1,
    audio_private=b"\x12\x08",
  ).unwrap()
  mux.write_video(b"V0", 0L, 200, keyframe=true).unwrap()
  mux.write_audio(b"A0", 0L, 100).unwrap()
  mux.write_video(b"V1", 200L, 200, keyframe=true).unwrap()
  mux.write_audio(b"A1", 100L, 100).unwrap()
  let bytes = mux.finish()
  let cues = av_matroska_parse_cues(bytes).unwrap()
  assert_eq(cues.cues.length(), 2)
  assert_eq(cues.cues[0].time, 0L)
  assert_eq(cues.cues[1].time, 200L)
  let tagged = mkv_add_tags(bytes, [("title", "indexed")]).unwrap()
  let cues2 = av_matroska_parse_cues(tagged).unwrap()
  assert_eq(cues2.cues.length(), 2)
  assert_eq(cues2.cues[1].time, 200L)
  assert_true(
    cues2.cues[0].cluster_position > cues.cues[0].cluster_position,
    msg="tags must shift the cluster forward",
  )
  let mkv = av_matroska_open(tagged).unwrap()
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.packets.length(), 4)
}

///|
test "mkv A/V: video blocks keep decode order with reordered PTS" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(
    64,
    48,
    avcc,
    44100,
    channels=1,
    audio_private=b"\x12\x08",
  ).unwrap()
  mux.write_video(b"V0", 0L, 100, keyframe=true).unwrap()
  mux.write_video(b"V1", 200L, 100).unwrap()
  mux.write_video(b"V2", 100L, 100).unwrap()
  mux.write_audio(b"A0", 0L, 100).unwrap()
  mux.write_audio(b"A1", 100L, 100).unwrap()
  let mkv = av_matroska_open(mux.finish()).unwrap()
  let video_pts : Array[Int64] = []
  for packet in mkv.packets {
    if packet.stream_index == 0 {
      video_pts.push(packet.pts)
    }
  }
  assert_eq(video_pts.length(), 3)
  assert_eq(video_pts[0], 0L)
  assert_eq(video_pts[1], 200L)
  assert_eq(video_pts[2], 100L)
}
