///|
test "MPEG-TS ADTS joins split headers and reports HE-AACv2 presentation parameters" {
  let source = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let base = av_adts_open(source).unwrap()
  let split = base.frames[0].size + 2
  let es = source + source[base.frames[0].size:].to_owned()
  let mux = ts_muxer_new(video=false)
  mux.write_audio(90000L, es[:2].to_owned())
  mux.write_audio(92000L, es[2:split].to_owned())
  mux.write_audio(96000L, es[split:].to_owned())
  let ts = mux.finish()
  let media = MediaFile::open(ts)
  let info = media.streams()[0]
  assert_eq(info.codec_id, "aac")
  assert_eq(info.sample_rate, 44100)
  assert_eq(info.channels, 2)
  let f0 = media.next_packet().unwrap()
  let f1 = media.next_packet().unwrap()
  let f2 = media.next_packet().unwrap()
  assert_eq((f0.pts, f1.pts, f2.pts), (90000L, 92000L, 96000L))
  assert_eq(f0.data + f1.data + f2.data, es)
  assert_true(media.next_packet() is None)
  let audio = decode_audio_file(ts)
  assert_eq(audio.sample_rate, 44100)
  assert_eq(audio.channels, 2)
  assert_eq(audio.samples[0].length(), 6144)
  assert_eq(audio.samples, decode_audio_file(es).samples)
}
