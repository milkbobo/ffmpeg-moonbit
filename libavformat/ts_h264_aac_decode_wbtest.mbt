///|
/// H.264 + AAC MPEG-TS writer test: real x264 access units (avcC parameters
/// prepended) and AAC frames are muxed with ADTS framing, demuxed back and
/// decoded. Video MD5s match the FFmpeg references in `fmp4_h264_refs`; AAC
/// PCM matches the ADTS reference within one LSB.

///|
test "ts muxer: H.264/AAC output decodes to FFmpeg references" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  let params = fmp4_h264_avcc_params(avcc)
  let mkv_data = @libavutil.av_base64_decode(mkv_av_b64, 1000000).unwrap()
  let source = av_matroska_open(mkv_data).unwrap()
  let mux = ts_muxer_new(video_stream_type=0x1B, audio_stream_type=0x0F)
  mux.enable_adts(44100, 1).unwrap()
  for i, sample in samples {
    let au = fmp4_h264_annexb(avcc, [params, sample])
    mux.write_video(i.to_int64() * 9000L, au)
  }
  let mut audio_count = 0
  for packet in source.packets {
    if packet.stream_index == 1 && audio_count < 5 {
      mux.write_audio(audio_count.to_int64() * 2090L, packet.data)
      audio_count = audio_count + 1
    }
  }
  assert_eq(audio_count, 5)
  let bytes = mux.finish()
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.streams.length(), 2)
  let video_pid = demux.streams[0].pid
  let audio_pid = demux.streams[1].pid
  let video : Array[Byte] = []
  let audio_packets : Array[Bytes] = []
  for packet in demux.packets {
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
  let reference = @libavutil.av_base64_decode(adts_ref_pcm_b64, 16384).unwrap()
  let mut max_diff = 0
  for i = 0; i < 5120; i = i + 1 {
    let v = pcm[i] * 32768.0
    let q = if v >= 32767.5 {
      32767
    } else if v <= -32768.5 {
      -32768
    } else {
      v.round().to_int()
    }
    let start = 2 * i
    let want = reference[start].to_int() | (reference[start + 1].to_int() << 8)
    let want = if want >= 32768 { want - 65536 } else { want }
    let diff = if q > want { q - want } else { want - q }
    if diff > max_diff {
      max_diff = diff
    }
  }
  assert_true(max_diff <= 1, msg="TS AAC max diff \{max_diff}")
}
