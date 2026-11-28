///|
test "CAF aac export keeps its source rate and trims AAC priming and padding" {
  for (channels, rate, count) in [(1, 44100, 1024), (2, 48000, 5203)] {
    let wav = wav_muxer_new(rate, channels, 16).unwrap()
    wav.write_samples(
      Array::makei(count * channels, i => (i % 73 - 36) * 400)[:],
    )
    let encoded = decode_audio_file(wav.finish()).to_caf_aac()
    let track = av_caf_open(encoded).unwrap()
    assert_eq(track.format.frames_per_packet, 1024)
    assert_eq(track.priming, 1024)
    assert_eq(track.packets[0].pts, -1024L)
    assert_eq(track.sample_count, count.to_int64())
    let last = track.packets[track.packets.length() - 1]
    assert_eq(last.pts + last.duration.to_int64(), count.to_int64())
    let decoded = decode_audio_file(encoded)
    assert_eq(decoded.codec_id(), "aac")
    assert_eq(decoded.channels(), channels)
    assert_eq(decoded.sample_rate(), rate)
    for plane in decoded.samples() {
      assert_eq(plane.length(), count)
    }
    let packets = track.packets.map(packet => {
      let start = packet.pos.to_int()
      encoded[start:start + packet.size].to_owned()
    })
    assert_eq(
      av_caf_mux_aac(
        track.extradata,
        packets,
        priming=1024,
        valid_frames=count.to_int64(),
      ).unwrap(),
      encoded,
    )
  }
}

///|
test "CAF aac packet timing follows the 960-sample AudioSpecificConfig" {
  let asc = b"\x11\x8c"
  let encoded = av_caf_mux_aac(asc, [b"\xe0"]).unwrap()
  let track = av_caf_open(encoded).unwrap()
  assert_eq(track.extradata, asc)
  assert_eq(track.format.frames_per_packet, 960)
  assert_eq(track.sample_count, 960L)
  let broken = encoded.to_array()
  broken[43] = broken[43] + 1 // desc.mFramesPerPacket
  assert_true(
    av_caf_open(Bytes::from_array(broken))
    is Err("caf: AAC packet duration does not match AudioSpecificConfig"),
  )
}
