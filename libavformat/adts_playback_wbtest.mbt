///|
/// First two frames of the HE-AACv2 vector in aac_sbr_extra_vectors.
let adts_ps_b64 : Bytes = b"//FcQBciRAFAQoCjVvUgAQAAAAADgAb5IQpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpa" +
  b"WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpa" +
  b"WlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWlpaWl7/8VxAF0JEARKZmD25UaXnRy8GB+upWKP/T+fxcUU/L2EVktbUa0BVoCrQE//yYAkx" +
  b"CJogE4aKgUQab7x/IXrkPthWUOrAJ/a+K5rmuaqqqqqK8raukEhakhOrLYItwUzgIPDb4iBJdGUWvPdDQJTJMxpgjGWwR52HBKMy71e2" +
  b"+y2uSm+qFpB/G4sXDqtXW1QDpPSQ1coZcu9A6L0X70A5h+eknzaTeTkFUKhVyNcLMwM+gUAAAAAABg4="

///|
test "ADTS HE-AACv2 uses stereo output and sample timestamps at the SBR rate" {
  let data = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let track = av_adts_open(data).unwrap()
  assert_eq(track.sample_rate, 22050)
  assert_eq(track.channels, 1)
  let media = MediaFile::open(data)
  assert_eq(media.streams()[0].sample_rate, 44100)
  assert_eq(media.streams()[0].channels, 2)
  assert_eq(media.duration_seconds(), Some(4096.0 / 44100.0))
  let decoder = media.audio_decoder(0)
  for i in 0..<2 {
    let packet = media.next_packet().unwrap()
    let frame = decoder.decode(packet).unwrap()
    assert_eq(frame.pts, Some(i.to_int64() * 2048L))
    assert_eq(frame.nb_samples, 2048)
    assert_eq(frame.sample_rate, 44100)
    assert_eq(frame.samples.length(), 2)
  }
  assert_true(media.next_packet() is None)
  let decoded = decode_audio_file(data)
  assert_eq(decoded.samples[0].length(), 4096)
  assert_eq(decoded.samples[1].length(), 4096)
}

///|
test "ADTS playback rejects channel changes and handles CRC framing" {
  let data = @libavutil.av_base64_decode(adts_ps_b64, 512).unwrap()
  let first = av_adts_open(data).unwrap().frames[0]
  let changed = data.to_array()
  let second = first.size
  changed[second + 3] = (changed[second + 3].to_int() + 0x40).to_byte()
  assert_true(
    adts_open(Bytes::from_array(changed), for_playback=true)
    is Err("adts: changing sample rate or channel configuration"),
  )
  let header = data[:7].to_owned().to_array()
  header[1] = (header[1].to_int() & 0xFE).to_byte()
  // The first header's length is 185 bytes. Adding two bytes involves
  // only the three low frame length bits in the upper part of byte 5.
  assert_eq(first.size, 185)
  header[5] = (header[5].to_int() + 0x40).to_byte()
  let with_crc = Bytes::from_array(header) + b"\x00\x00" + data[7:].to_owned()
  assert_eq(
    decode_audio_file(with_crc).samples,
    decode_audio_file(data).samples,
  )
}
