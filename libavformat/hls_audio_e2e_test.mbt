///|
/// AAC encoder -> TS muxer -> HLS byte-range fetch -> demux -> PCM.
/// Compare with direct AAC access-unit decoding so dropped or duplicated
/// units, fetch offsets and URI query corruption affect the result.
test "HLS shared TS resource decodes every AAC access unit" {
  let encoder = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(48000, 1, 64000),
  ).unwrap()
  let mux = @libavformat.ts_muxer_new(video=false)
  let direct = @libavcodec.new_aac_decoder_from_asc(b"\x11\x88").unwrap()
  let expected : Array[Double] = []
  for frame in 0..<3 {
    let samples = Array::makei(1024, i => {
      0.2 * @math.sin((frame * 1024 + i).to_double() * 0.0575958653158129)
    })
    let packet = encoder.encode_frame([samples]).unwrap().unwrap()
    let decoded = direct.decode_frame(packet[7:].to_owned()).unwrap()
    for sample in decoded[0].samples {
      expected.push(sample)
    }
    mux.write_audio(frame.to_int64() * 1920L, packet)
  }
  let ts = mux.finish()
  let length = ts.length()
  let playlist = @libavformat.av_hls_parse(
    "#EXTM3U\n#EXT-X-BYTERANGE:\{length}@7\n#EXTINF:0.064,\nshared.ts?next=https://cdn.test/a/../b\n#EXT-X-ENDLIST",
    base_uri="https://example.test/list.m3u8?token=a/b",
  ).unwrap()
  let calls = Ref(0)
  let reader = @libavformat.hls_segment_reader_new(playlist, (uri, offset, size) => {
    calls.val += 1
    if uri != "https://example.test/shared.ts?next=https://cdn.test/a/../b" ||
      offset != 7L ||
      size != length.to_int64() {
      return Err("unexpected HLS resource request")
    }
    Ok(ts)
  }).unwrap()
  let segment = reader.next().unwrap().unwrap()
  let actual = @libavformat.decode_audio_file(segment.bytes())
  assert_eq(actual.codec_id, "aac")
  assert_eq(actual.sample_rate, 48000)
  assert_eq(actual.channels, 1)
  assert_eq(actual.samples[0].length(), 3072)
  assert_eq(actual.samples[0], expected)
  assert_eq(calls.val, 1)
  assert_true(reader.next().unwrap() is None)
}
