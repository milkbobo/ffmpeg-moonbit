///|
fn film_test_file(
  packets : Array[(Bool, Bytes)],
  channels : Int32,
  bits : Int32,
  compression : Int32,
  legacy~ : Bool = false,
) -> Bytes {
  let fdsc = if legacy { 20 } else { 32 }
  let stab = 16 + 16 * packets.length()
  let out : Array[Byte] = []
  wav_mux_tag(out, "FILM")
  aiff_mux_u32be(out, (16 + fdsc + stab).reinterpret_as_uint())
  aiff_mux_u32be(out, if legacy { 0U } else { 0x312e3039U })
  aiff_mux_u32be(out, 0U)
  wav_mux_tag(out, "FDSC")
  aiff_mux_u32be(out, fdsc.reinterpret_as_uint())
  wav_mux_tag(out, "raw ")
  aiff_mux_u32be(out, 1U)
  aiff_mux_u32be(out, 1U)
  if !legacy {
    out.push(24)
    out.push(channels.to_byte())
    out.push(bits.to_byte())
    out.push(compression.to_byte())
    aiff_mux_u16be(out, 22050)
    for _ in 0..<6 {
      out.push(0)
    }
  }
  wav_mux_tag(out, "STAB")
  aiff_mux_u32be(out, stab.reinterpret_as_uint())
  aiff_mux_u32be(out, 15U)
  aiff_mux_u32be(out, packets.length().reinterpret_as_uint())
  let mut offset = 0
  for (audio, packet) in packets {
    aiff_mux_u32be(out, offset.reinterpret_as_uint())
    aiff_mux_u32be(out, packet.length().reinterpret_as_uint())
    aiff_mux_u32be(out, if audio { 0xffffffffU } else { 0U })
    aiff_mux_u32be(out, 1U)
    offset += packet.length()
  }
  for (_, packet) in packets {
    for byte in packet {
      out.push(byte)
    }
  }
  Bytes::from_array(out)
}

///|
test "FILM audio skips video records and preserves planar PCM channels" {
  let packets = [
    (true, b"\x00\x01\x00\x02\xff\xff\xff\xfe"),
    (false, b"\x80\x00\x00"),
    (true, b"\x00\x03\x00\x04\xff\xfd\xff\xfc"),
  ]
  let film = film_test_file(packets, 2, 16, 0)
  let track = film_audio_open(film).unwrap()
  assert_eq(track.codec, "pcm_s16be_planar")
  assert_eq(track.frames[1].pts, 2L)
  assert_eq(track.frames[1].pos - track.frames[0].pos, 11L)
  assert_eq(decode_audio_file(film).samples(), [
    [1.0, 2.0, 3.0, 4.0].map(x => x / 32768.0),
    [-1.0, -2.0, -3.0, -4.0].map(x => x / 32768.0),
  ])
  let legacy = film_test_file([(true, b"\x80\x00\x7f")], 1, 8, 0, legacy=true)
  assert_eq(decode_audio_file(legacy).samples(), [[-1.0, 0.0, 127.0 / 128.0]])
}

///|
test "FILM reassembles ADX header and blocks split across records" {
  let wav = wav_muxer_new(22050, 2, 16).unwrap()
  let samples = Array::makei(133 * 2, i => i * 12289 % 65536 - 32768)
  wav.write_samples(samples[:])
  let adx = decode_audio_file(wav.finish()).to_adx()
  let film = film_test_file(
    [
      (true, adx[:19].to_owned()),
      (false, b"\x80\x00\x00"),
      (true, adx[19:55].to_owned()),
      (true, adx[55:].to_owned()),
    ],
    2,
    4,
    2,
  )
  let audio = decode_audio_file(film)
  assert_eq(audio.format_name, "film_cpk")
  assert_eq(audio.codec_id, "adpcm_adx")
  assert_eq(audio.samples(), decode_audio_file(adx).samples())
}
