///|
fn aifc_test_audio(
  tag : String,
  channels : Int32,
  count : Int32,
  bits : Int32,
  payload : Bytes,
) -> Bytes {
  let out = b"FORM".to_array()
  let pad = payload.length() % 2
  aiff_mux_u32be(out, (64 + payload.length() + pad).reinterpret_as_uint())
  out.append(
    b"AIFCFVER\x00\x00\x00\x04\xa2\x80\x51\x40COMM\x00\x00\x00\x18".to_array(),
  )
  aiff_mux_u16be(out, channels)
  aiff_mux_u32be(out, count.reinterpret_as_uint())
  aiff_mux_u16be(out, bits)
  out.append(aiff_mux_ext80(8000))
  aiff_mux_tag(out, tag)
  out.append(b"\x00\x00SSND".to_array())
  aiff_mux_u32be(out, (8 + payload.length()).reinterpret_as_uint())
  out.append(b"\x00\x00\x00\x00\x00\x00\x00\x00".to_array())
  out.append(payload.to_array())
  if pad != 0 {
    out.push(0)
  }
  Bytes::from_array(out)
}

///|
test "AIFF-C raw, in24 and in32 keep sample sign, endianness and channel order" {
  let raw = decode_audio_file(
    aifc_test_audio("raw ", 2, 2, 8, b"\x00\x80\xff\x40"),
  )
  assert_eq(raw.codec_id, "pcm_u8")
  assert_eq(raw.samples, [[-1.0, 127.0 / 128.0], [0.0, -0.5]])
  let wide = decode_audio_file(
    aifc_test_audio("in24", 1, 2, 24, b"\x80\x00\x00\x01\x02\x03"),
  )
  assert_eq(wide.codec_id, "pcm_s24be")
  assert_eq(wide.samples, [[-1.0, 66051.0 / 8388608.0]])
  let wider = decode_audio_file(
    aifc_test_audio("in32", 1, 2, 32, b"\x80\x00\x00\x00\x01\x02\x03\x04"),
  )
  assert_eq(wider.codec_id, "pcm_s32be")
  assert_eq(wider.samples, [[-1.0, 16909060.0 / 2147483648.0]])
}

///|
test "AIFF-C G.726LE keeps codeword boundaries and predictor history across packets" {
  let data = Bytes::makei(4098, i => (71 * i + 11).to_byte())
  let aifc = aifc_test_audio("G726", 1, 7, 16, data)
  let demux = av_aiff_open(aifc).unwrap()
  assert_eq(demux.format.codec, "adpcm_g726le")
  assert_eq(demux.format.bits, 5)
  assert_eq(demux.sample_count, 6556L)
  assert_eq(
    demux.packets.map(packet => (packet.size, packet.pts, packet.duration)),
    [(4095, 0L, 6552), (3, 6552L, 4)],
  )
  let audio = decode_audio_file(aifc)
  let raw = decode_audio_file(data, filename="sample.g726le", g726_bits=5)
  assert_eq(audio.samples, raw.samples)
  assert_eq(audio.duration_seconds, Some(6556.0 / 8000.0))
  assert_true(av_aiff_open(aifc_test_audio("G726", 2, 7, 5, data)) is Err(_))
}
