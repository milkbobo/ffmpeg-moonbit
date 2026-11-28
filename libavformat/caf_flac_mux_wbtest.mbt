///|
test "CAF FLAC export retains every PCM bit and the short final packet" {
  for (bits, channels, mask) in [(16, 1, 0U), (24, 6, 0x3fU), (32, 2, 0U)] {
    let wav = wav_muxer_new(32000, channels, bits, channel_mask=mask).unwrap()
    let frames = 5203
    let samples = Array::makei(frames * channels, i => {
      let word = (i.to_uint64() * 2654435761UL + 0x80000000UL).to_int()
      word >> (32 - bits)
    })
    wav.write_samples(samples[:])
    let input = decode_audio_file(wav.finish())
    let encoded = input.to_caf_flac(bits~)
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.format.bits, bits)
    assert_eq(track.packets.length(), 2)
    assert_eq(track.packets[0].duration, 4096)
    assert_eq(track.packets[1].pts, 4096L)
    assert_eq(track.packets[1].duration, 1107)
    assert_eq(track.sample_count, 5203L)
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.samples(), input.samples())
    if mask != 0U {
      assert_eq(track.channel_mask, mask)
      assert_eq(decoded.channel_mask, mask)
    }
  }
}

///|
test "CAF FLAC remux retains coded frames and validates CRC and packet timing" {
  let flac = @libavcodec.flac_encode(
    Array::makei(8300, i => i % 528 - 264),
    2,
    44100,
    16,
  ).unwrap()
  let encoded = av_caf_mux_flac(flac.file()).unwrap()
  let track = av_caf_open(encoded).unwrap()
  assert_eq(track.extradata, flac.streaminfo)
  assert_eq(track.packets.length(), flac.frames.length())
  for i, packet in track.packets {
    let start = packet.pos.to_int()
    assert_eq(encoded[start:start + packet.size], flac.frames[i])
  }
  let broken = encoded.to_array()
  let last_duration_byte = track.data_offset.to_int() - 17
  broken[last_duration_byte] = broken[last_duration_byte] ^ 1
  assert_true(
    av_caf_open(Bytes::from_array(broken))
    is Err("caf: FLAC frame does not match its packet description"),
  )
  let broken = encoded.to_array()
  let crc = track.data_offset.to_int() + track.packets[0].size - 1
  broken[crc] = broken[crc] ^ 1
  assert_true(
    av_caf_open(Bytes::from_array(broken)) is Err("flac: frame CRC mismatch"),
  )
}
