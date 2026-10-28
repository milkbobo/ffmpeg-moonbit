///|
/// H.264 + AAC MP4 muxer tests: both tracks are parsed back by `av_mov_open`.

///|
let mp4_av_avcc_b64 : Bytes = b"AWQAHv/hABdnZAAerLII9gIgAAADACAAAAMBQeLFyQEABmjrw8siwP34+AA="

///|
test "mp4 muxer: H.264 + AAC tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(mp4_av_avcc_b64, 1024).unwrap()
  let mux = mp4_av_muxer_new(64, 48, avcc, 48000, 2).unwrap()
  mux.write_video(b"\x00\x00\x01\x02", duration=3000, keyframe=true).unwrap()
  mux.write_video(b"\x00\x00\x01\x03", duration=3000).unwrap()
  mux.write_audio(b"\xAA\x01").unwrap()
  mux.write_audio(b"\xAA\x02").unwrap()
  mux.write_audio(b"\xAA\x03").unwrap()
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  let video = movie.tracks[0]
  let audio = movie.tracks[1]
  assert_eq(video.codec, "avc1")
  assert_eq(video.width, 64)
  assert_eq(video.height, 48)
  assert_eq(video.samples.length(), 2)
  assert_eq(audio.codec, "mp4a")
  assert_eq(audio.sample_rate, 48000U)
  assert_eq(audio.channels, 2U)
  assert_eq(audio.samples.length(), 3)
  let vpayloads : Array[Bytes] = [b"\x00\x00\x01\x02", b"\x00\x00\x01\x03"]
  for i in 0..<2 {
    let s = video.samples[i]
    assert_eq(s.dts, (i * 3000).to_int64())
    assert_eq(s.duration, 3000U)
    assert_eq(s.keyframe, i == 0)
    let start = s.offset.to_int()
    assert_eq(
      bytes[start:start + s.size.reinterpret_as_int()].to_owned(),
      vpayloads[i],
    )
  }
  let apayloads : Array[Bytes] = [b"\xAA\x01", b"\xAA\x02", b"\xAA\x03"]
  for i in 0..<3 {
    let s = audio.samples[i]
    assert_eq(s.dts, (i * 1024).to_int64())
    assert_eq(s.duration, 1024U)
    let start = s.offset.to_int()
    assert_eq(
      bytes[start:start + s.size.reinterpret_as_int()].to_owned(),
      apayloads[i],
    )
  }
}

///|
test "mp4 muxer: invalid A/V parameters are rejected" {
  let avcc = @libavutil.av_base64_decode(mp4_av_avcc_b64, 1024).unwrap()
  match mp4_av_muxer_new(64, 48, avcc, 12345, 2) {
    Ok(_) => fail("unsupported sample rate must fail")
    Err(_) => ()
  }
  let mux = mp4_av_muxer_new(64, 48, avcc, 48000, 2).unwrap()
  match mux.write_video(Bytes::new(0), duration=3000) {
    Ok(_) => fail("empty video packet must fail")
    Err(_) => ()
  }
}

///|
test "mp4 muxer: real H.264 + AAC tracks decode round-trip" {
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
  // The source MKV carries AAC-LC 44.1 kHz mono (ASC 0x12 0x08 plus trailing
  // sync-extension bytes); the MP4 writer re-signals it as plain LC.
  assert_eq(asc[0], b'\x12')
  assert_eq(asc[1], b'\x08')
  let audio_packets : Array[Bytes] = []
  for p in src.packets {
    if p.stream_index == 1 {
      audio_packets.push(p.data)
    }
  }
  assert_eq(audio_packets.length(), 45)
  let mux = mp4_av_muxer_new(64, 48, avcc, 44100, 1).unwrap()
  for i, sample in samples {
    mux.write_video(sample, duration=9000, keyframe=i == 0).unwrap()
  }
  for packet in audio_packets {
    mux.write_audio(packet).unwrap()
  }
  let bytes = mux.finish()
  let movie = av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  let video = movie.tracks[0]
  assert_eq(video.codec, "avc1")
  assert_eq(video.extradata.unwrap(), avcc)
  assert_eq(video.samples.length(), 5)
  let vpayload : Array[Byte] = []
  for sample in video.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in bytes[start:end] {
      vpayload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(vpayload),
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
  let audio = movie.tracks[1]
  assert_eq(audio.codec, "mp4a")
  assert_eq(audio.sample_rate, 44100U)
  assert_eq(audio.channels, 1U)
  assert_eq(audio.samples.length(), 45)
  // The audio track is byte-transparent: FFmpeg decodes this MP4's audio
  // exactly like the same AUs wrapped in ADTS (the source MKV additionally
  // trims one priming frame via CodecDelay, which MP4 does not model here).
  let adec = @libavcodec.new_aac_decoder_from_asc(asc).unwrap()
  for i, sample in audio.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let packet = bytes[start:end].to_owned()
    assert_eq(packet, audio_packets[i])
    match adec.decode_frame(packet) {
      Ok(_) => ()
      Err(e) => fail("aac frame \{i}: \{e}")
    }
  }
}

///|
test "mp4 muxer: audio priming is signalled without touching video" {
  let avcc = @libavutil.av_base64_decode(mp4_av_avcc_b64, 1024).unwrap()
  let mux = mp4_av_muxer_new(64, 48, avcc, 44100, 1, aac_priming=1024).unwrap()
  mux
  .write_video(b"\x00\x00\x00\x02\x65\x88", duration=9000, keyframe=true)
  .unwrap()
  for _ in 0..<3 {
    mux.write_audio(b"\xAA\x01").unwrap()
  }
  let movie = av_mov_open(mux.finish()).unwrap()
  assert_eq(movie.tracks.length(), 2)
  assert_eq(movie.tracks[0].skip_samples, 0)
  assert_eq(movie.tracks[0].samples.length(), 1)
  assert_eq(movie.tracks[1].skip_samples, 1024)
  assert_eq(movie.tracks[1].samples.length(), 3)
  match mp4_av_muxer_new(64, 48, avcc, 44100, 1, aac_priming=-1) {
    Ok(_) => fail("negative priming must fail")
    Err(_) => ()
  }
}
