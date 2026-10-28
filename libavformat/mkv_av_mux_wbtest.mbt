///|
/// MKV H.264+AAC muxer tests: both tracks are parsed back by
/// `av_matroska_open`.

///|
let mkv_av_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mkv muxer: H.264 + AAC tracks interleave by timestamp" {
  let avcc = @libavutil.av_base64_decode(mkv_av_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(64, 48, avcc, 48000, channels=2).unwrap()
  mux.write_video(b"V0", 0L, 33, keyframe=true).unwrap()
  mux.write_video(b"V1", 33L, 33).unwrap()
  mux.write_audio(b"A0", 0L, 21).unwrap()
  mux.write_audio(b"A1", 21L, 21).unwrap()
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_false(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(mkv.tracks[0].codec_priv.unwrap(), avcc)
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_AAC")
  assert_eq(mkv.tracks[1].codec_priv.unwrap().length(), 2)
  assert_eq(mkv.packets.length(), 4)
  let pts : Array[Int64] = [0L, 0L, 21L, 33L]
  let streams : Array[Int32] = [0, 1, 1, 0]
  let payloads : Array[Bytes] = [b"V0", b"A0", b"A1", b"V1"]
  for i in 0..<4 {
    assert_eq(mkv.packets[i].pts, pts[i])
    assert_eq(mkv.packets[i].stream_index, streams[i])
    assert_eq(mkv.packets[i].data, payloads[i])
  }
}

///|
test "mkv muxer: invalid A/V packets are rejected" {
  let avcc = @libavutil.av_base64_decode(mkv_av_avcc_b64, 1024).unwrap()
  let mux = mkv_av_muxer_new(64, 48, avcc, 48000).unwrap()
  match mux.write_audio(Bytes::new(0), 0L, 21) {
    Ok(_) => fail("empty audio packet must fail")
    Err(_) => ()
  }
}

///|
test "mkv muxer: real H.264 + AAC tracks decode round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let src = av_matroska_open(
    @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap(),
  ).unwrap()
  let asc = src.tracks[1].codec_priv.unwrap()
  let src_audio : Array[Bytes] = []
  for p in src.packets {
    if p.stream_index == 1 {
      src_audio.push(p.data)
    }
  }
  assert_eq(src_audio.length(), 45)
  let mux = mkv_av_muxer_new(64, 48, avcc, 44100, channels=1).unwrap()
  for i, sample in samples {
    mux.write_video(sample, i.to_int64() * 100L, 100, keyframe=i == 0).unwrap()
  }
  for i, packet in src_audio {
    mux.write_audio(packet, i.to_int64() * 23L, 23).unwrap()
  }
  let bytes = mux.finish()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(mkv.tracks[0].codec_priv.unwrap(), avcc)
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_AAC")
  assert_eq(mkv.tracks[1].codec_priv.unwrap(), b"\x12\x08")
  assert_eq(mkv.packets.length(), 50)
  let video_packets : Array[Bytes] = []
  let audio_packets : Array[Bytes] = []
  for p in mkv.packets {
    if p.stream_index == 0 {
      video_packets.push(p.data)
    } else {
      audio_packets.push(p.data)
    }
  }
  assert_eq(video_packets.length(), 5)
  assert_eq(audio_packets.length(), 45)
  for i, packet in audio_packets {
    assert_eq(packet, src_audio[i])
  }
  let payload : Array[Byte] = []
  for packet in video_packets {
    for b in packet {
      payload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
  let adec = @libavcodec.new_aac_decoder_from_asc(asc).unwrap()
  for i, packet in audio_packets {
    match adec.decode_frame(packet) {
      Ok(_) => ()
      Err(e) => fail("aac frame \{i}: \{e}")
    }
  }
}
