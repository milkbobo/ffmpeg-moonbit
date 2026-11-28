///|
test "CAF AC-3 carries variable packet sizes, encoder delay and surround layout" {
  let channels = 6
  let frames = 5203
  let mask = 0x60fU
  let wav = wav_muxer_new(44100, channels, 16, channel_mask=mask).unwrap()
  wav.write_samples(Array::make(frames * channels, 0)[:])
  let input = decode_audio_file(wav.finish())
  let encoded = input.to_caf_ac3()
  let track = av_caf_open(encoded).unwrap()
  assert_eq(track.format.block_align, 0)
  assert_eq(track.format.frames_per_packet, 1536)
  assert_eq(track.priming, 256)
  assert_eq(track.sample_count, frames.to_int64())
  assert_eq(track.packets.length(), 4)
  assert_true(track.packets[0].size != track.packets[1].size)
  let decoded = decode_audio_file(encoded)
  assert_eq(decoded.codec_id(), "ac3")
  assert_eq(decoded.sample_rate(), 44100)
  assert_eq(decoded.channels(), channels)
  assert_eq(decoded.samples()[0].length(), frames)

  let without_layout = encoded[:52].to_owned() + encoded[76:].to_owned()
  assert_eq(av_caf_open(without_layout).unwrap().channel_mask, mask)
  let wav = decode_audio_file(without_layout).to_wav_s16()
  assert_eq(av_wav_open(wav).unwrap().format.channel_mask, mask)

  let start = track.data_offset.to_int()
  let raw = encoded[start:start + track.data_size.to_int()].to_owned()
  let remuxed = av_caf_mux_ac3(raw).unwrap()
  let remux = av_caf_open(remuxed).unwrap()
  assert_eq(remux.sample_count, 6144L)
  let new_start = remux.data_offset.to_int()
  assert_eq(remuxed[new_start:new_start + remux.data_size.to_int()], raw)
  assert_true(av_caf_mux_ac3(raw[:raw.length() - 1].to_owned()) is Err(_))
  let corrupt = encoded.to_array()
  corrupt[start] = 0
  assert_true(
    av_caf_open(Bytes::from_array(corrupt))
    is Err("caf: AC-3 frame does not match its packet description"),
  )
}
