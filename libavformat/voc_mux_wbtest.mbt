///|
test "VOC PCM and G.711 exports match FFmpeg with continuation blocks" {
  let samples = Array::makei(5203 * 2, i => {
    let n = i / 2
    let value = if i % 2 == 0 { 19 * n + 37 } else { 73 * n + 11 }
    (value % 256 - 128) * 256
  })
  let wav = wav_muxer_new(32000, 2, 16).unwrap()
  wav.write_samples(samples[:])
  let audio = decode_audio_file(wav.finish())
  for
    (codec, hash) in [
      ("pcm_s16le", "87c268c94505d23a8d4e1a5a5f2c847c"),
      ("pcm_u8", "6c381f053cbbb8416e7002bbada1ba82"),
      ("pcm_alaw", "9915e7725fdfc6d83ae4f039a01fc8c3"),
      ("pcm_mulaw", "56d55cfeab69574e930c6ed11fa42b1b"),
    ] {
    let encoded = audio.to_voc(codec~)
    assert_eq(caf_md5(encoded), hash, msg=codec)
    let track = av_voc_open(encoded).unwrap()
    assert_true(track.frames.map(packet => packet.pts).contains(1024L))
    assert_eq(track.total_samples, 5203L)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.sample_rate(), 32000)
    assert_eq(decoded.codec_id(), codec)
  }
}

///|
test "VOC unsigned 8-bit uses an explicit rate when the legacy clock differs" {
  let wav = wav_muxer_new(44100, 1, 16).unwrap()
  wav.write_samples([-32768, -256, 0, 32512][:])
  let input = decode_audio_file(wav.finish())
  let encoded = input.to_voc(codec="pcm_u8")
  assert_eq(encoded[26], 9)
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.sample_rate(), 44100)
  assert_eq(decoded.samples(), input.samples())
}

///|
test "VOC Creative Technology ADPCM keeps predictor state across blocks" {
  for
    (channels, pcm_hash) in [
      (1, "8eed057633002a169bb818dfb69ed986"),
      (2, "17b78ceec03154efb908f0a845886f56"),
    ] {
    let out = voc_magic.to_array()
    out.append([26, 0, 20, 1, 31, 17, 9, 197, 11, 0])
    wav_mux_u32(out, 22050U)
    out.push(4)
    out.push(channels.to_byte())
    wav_mux_u16(out, 0x0200)
    wav_mux_u32(out, 0U)
    for i in 0..<5007 {
      if i == 3001 {
        out.append([2, 214, 7, 0])
      }
      out.push((i * 157 + 123).to_byte())
    }
    out.push(0)
    let encoded = Bytes::from_array(out)
    let track = av_voc_open(encoded).unwrap()
    assert_eq(track.frames[1].pts, (4096 / channels).to_int64())
    assert_eq(track.frames[2].pts, (6002 / channels).to_int64())
    assert_eq(track.total_samples, (10014 / channels).to_int64())
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.codec_id(), "adpcm_ct")
    let wav = decoded.to_wav_s16()
    let demux = av_wav_open(wav).unwrap()
    let start = demux.data_offset.to_int()
    assert_eq(
      caf_md5(wav[start:start + demux.data_size.to_int()].to_owned()),
      pcm_hash,
    )
  }
}
