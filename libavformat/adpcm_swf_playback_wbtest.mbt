///|
/// The 2-, 3- and 5-bit fixtures use hand-packed codes. The 4-bit
/// fixture uses the start of a packet from FFmpeg's encoder.
fn check_swf_adpcm_fixture(
  file : Bytes,
  container : String,
  channels : Int32,
  count : Int32,
  md5 : String,
) -> Unit raise {
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, container)
  assert_eq(audio.codec_id, "adpcm_swf")
  assert_eq(audio.sample_rate, 22050)
  assert_eq(audio.channels, channels)
  assert_eq(audio.read_error, "")
  let wave = audio.to_wav_s16()
  let demux = av_wav_open(wave).unwrap()
  assert_eq(demux.data_size, (count * channels * 2).to_int64())
  assert_eq(caf_md5(wave[demux.data_offset.to_int():].to_owned()), md5)
}

///|
test "Flash ADPCM two-bit in flv matches FFmpeg" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAAAgABAoAAAAAAAAAGh1MPm2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtss",
    b"cYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxht",
    b"sscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxx",
    b"htsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2y",
    b"xxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG",
    b"2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLH",
    b"GG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbb",
    b"LHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscY",
    b"bbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtss",
    b"cYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxht",
    b"sscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxx",
    b"htsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2y",
    b"xxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG",
    b"2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLH",
    b"GG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxhtsscYbbLHGG2yxxorQ+bbLH",
    b"AAAAQV",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_swf_adpcm_fixture(
    file, "flv", 1, 4111, "460dd9eb34d276e1ecebb3624a074f66",
  )
}

///|
test "Flash ADPCM three-bit in flv matches FFmpeg" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAAAgAAA8AAAAAAAAAGl1MPqvV4vD4dDmcxmKwAAAAGg==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_swf_adpcm_fixture(
    file, "flv", 1, 30, "622bd9efb757eaeee15d33b331bad569",
  )
}

///|
test "Flash ADPCM four-bit in wav matches FFmpeg" {
  let encoded = bcat([
    b"UklGRjgAAABXQVZFZm10IBIAAABGUwIAIlYAAAV6AAARAAQAAABkYXRhEQAAAIAAABmaAf39/f39/f3+PqMiAA==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_swf_adpcm_fixture(
    file, "wav", 2, 12, "4491efab9d3e9dd69941888d62f48dc2",
  )
  let demux = av_wav_open(file).unwrap()
  assert_eq(demux.format.block_align, 17)
  assert_eq(demux.sample_count, 12L)
  assert_eq(demux.packets[0].duration, 12)
  let start = demux.data_offset.to_int()
  let payload = file[start:start + 17].to_owned()
  let pair = file[:start + 17].to_owned().to_array()
  pair.append(payload.to_array())
  pair[4] = (pair.length() - 8).to_byte()
  pair[42] = 34
  let repeated = Bytes::from_array(pair)
  let demux = av_wav_open(repeated).unwrap()
  assert_eq(demux.packets.map(p => (p.pts, p.duration)), [(0L, 12), (12L, 12)])
  let expected = decode_audio_file(file).samples
  let decoded = decode_audio_file(repeated).samples
  for c in 0..<2 {
    assert_eq(decoded[c][:12].to_owned(), expected[c])
    assert_eq(decoded[c][12:].to_owned(), expected[c])
  }
}

///|
test "Flash ADPCM five-bit in flv matches FFmpeg" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAAAgAABwAAAAAAAAAG91MPorQ3b7Sz4qYU3g41W7oJWIvwZ3KjXoUMgAAACc=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_swf_adpcm_fixture(
    file, "flv", 2, 18, "2f4240771061023615631dd0454f4593",
  )
}

///|
test "Flash ADPCM requires a complete predictor header" {
  let seed = b"\x80\x00\x00"
  assert_eq(@libavcodec.swf_adpcm_samples(seed[:], 1).unwrap(), 1)
  assert_eq(@libavcodec.decode_swf_adpcm(seed, 1).unwrap(), [0])
  assert_true(
    @libavcodec.decode_swf_adpcm(seed, 2)
    is Err("adpcm_swf: invalid packet size"),
  )
}
