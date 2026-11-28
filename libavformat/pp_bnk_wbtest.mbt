///|
fn pp_test_bank(music : Bool) -> Bytes {
  let file : Array[Byte] = []
  for word in [7351U, 22050U, 1U, 2U, if music { 2U } else { 0U }] {
    wav_mux_u32(file, word)
  }
  for ch in 0..<2 {
    let size = if ch == 0 || music { 4197 } else { 4210 }
    for
      word in [
        (101 + ch).reinterpret_as_uint(),
        size.reinterpret_as_uint(),
        22050U,
        1U,
        1U,
      ] {
      wav_mux_u32(file, word)
    }
    for i in 0..<size {
      file.push(((i * 73) ^ (i >> 3) ^ (91 * ch)).to_byte())
    }
  }
  Bytes::from_array(file)
}

///|
test "Pro Pinball banks expose independent mono tracks in round-robin order" {
  let data = pp_test_bank(false)
  let file = MediaFile::open(data)
  assert_eq(file.format_name(), "pp_bnk")
  assert_eq(file.streams().length(), 2)
  let outputs = [
    wav_muxer_new(22050, 1, 16).unwrap(),
    wav_muxer_new(22050, 1, 16).unwrap(),
  ]
  let decoders = file.streams().map(info => AudioDecoder::open(info))
  for stream in [0, 1, 0, 1] {
    let packet = file.next_packet().unwrap()
    assert_eq(packet.stream_index, stream)
    assert_eq(packet.pts, if packet.keyframe { 0L } else { 8192L })
    let pcm = decoders[stream].decode(packet).unwrap()
    outputs[stream].write_samples(pcm.samples[0].map(@swr.swr_flt_to_s16)[:])
  }
  assert_true(file.next_packet() is None)
  for
    (stream, hash) in [
      (0, "b1fee68841d6133cff0e3106b3e56343"),
      (1, "459b94331bffa6bd83e39f38d4a40077"),
    ] {
    let pcm = outputs[stream].finish()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
  }
}

///|
test "Pro Pinball music banks decode paired tracks as stereo" {
  let data = pp_test_bank(true)
  let file = MediaFile::open(data)
  assert_eq(file.streams().length(), 1)
  assert_eq(file.next_packet().unwrap().data.length(), 8192)
  assert_eq(file.next_packet().unwrap().pts, 8192L)
  let audio = decode_audio_file(data)
  assert_eq(audio.channels(), 2)
  assert_eq(audio.samples()[0].length(), 8394)
  let pcm = audio.to_wav_s16()
  let wav = av_wav_open(pcm).unwrap()
  assert_eq(
    telephony_md5(pcm[wav.data_offset.to_int():].to_owned()),
    "8c4573d0f695d9dcf76571411937b64a",
  )
  assert_true(
    pp_bnk_open(data[:data.length() - 1].to_owned())
    is Err("pp_bnk: truncated track audio"),
  )
}
