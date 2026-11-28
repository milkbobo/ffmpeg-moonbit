///|
test "Nintendo AST planar PCM matches FFmpeg with a short last block" {
  let samples = Array::makei(5203 * 4, i => {
    (317 * (i / 4) + 11717 * (i % 4) + 289) % 65536 - 32768
  })
  let wav = wav_muxer_new(32000, 4, 16, channel_mask=0x107U).unwrap()
  wav.write_samples(samples[:])
  let input = decode_audio_file(wav.finish())
  let encoded = input.to_ast()
  assert_eq(caf_md5(encoded), "d7f4c6d2b6643f5417dbb035a9750aca")
  let track = ast_open(encoded).unwrap()
  assert_eq(track.frames[5].pts, 5120L)
  assert_eq(track.frames[5].duration, 83)
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.format_name(), "ast")
  assert_eq(decoded.samples(), input.samples())
  assert_eq(
    av_wav_open(decoded.to_wav_s16()).unwrap().format.channel_mask,
    0x107U,
  )
  assert_true(
    ast_open(encoded[:encoded.length() - 1].to_owned())
    is Err("ast: truncated stream"),
  )
}

///|
test "Nintendo AST AFC stores channel planes and keeps predictor history across blocks" {
  let channels = 2
  let out = b"STRM".to_array()
  aiff_mux_u32be(out, (64 + 72 * channels).reinterpret_as_uint())
  aiff_mux_u16be(out, 0)
  aiff_mux_u16be(out, 16)
  aiff_mux_u16be(out, channels)
  aiff_mux_u16be(out, 0)
  aiff_mux_u32be(out, 32000U)
  aiff_mux_u32be(out, 128U)
  for _ in 0..<40 {
    out.push(0)
  }
  for blocks in [3, 5] {
    wav_mux_tag(out, "BLCK")
    aiff_mux_u32be(out, (9 * blocks).reinterpret_as_uint())
    for _ in 0..<24 {
      out.push(0)
    }
    for ch in 0..<channels {
      for block in 0..<blocks {
        let shift = (blocks + ch + block) % 16
        let index = (3 * blocks + 7 * ch + block) % 16
        out.push(((shift << 4) | index).to_byte())
        for i in 0..<8 {
          out.push((157 * i + 67 * block + 41 * ch + 19 * blocks).to_byte())
        }
      }
    }
  }
  let encoded = Bytes::from_array(out)
  let track = ast_open(encoded).unwrap()
  assert_eq(track.frames.map(p => (p.pts, p.duration)), [(0L, 48), (48L, 80)])
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.codec_id(), "adpcm_afc")
  let wav = decoded.to_wav_s16()
  let demux = av_wav_open(wav).unwrap()
  let start = demux.data_offset.to_int()
  assert_eq(
    caf_md5(wav[start:start + demux.data_size.to_int()].to_owned()),
    "52f0a9fb0b139bf526bf281a679024e1",
  )
}
