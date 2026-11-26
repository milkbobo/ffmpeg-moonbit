///|
/// FFmpeg 9.0.2 muxed 997 Hz tones into FLV. The AAC fixture includes
/// a video stream. MP3 PCM was generated with FFmpeg's fixed decoder.
fn check_flv_fixture(
  file : Bytes,
  codec : String,
  rate : Int32,
  count : Int32,
  md5 : String,
) -> Unit raise {
  let audio = decode_audio_file(file)
  assert_eq(audio.format_name, "flv")
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.sample_rate, rate)
  assert_eq(audio.channels, 1)
  assert_eq(audio.read_error, "")
  let wave = audio.to_wav_s16()
  let wav = av_wav_open(wave).unwrap()
  assert_eq(wav.data_size, (count * 2).to_int64())
  assert_eq(caf_md5(wave[wav.data_offset.to_int():].to_owned()), md5)
}

///|
/// Rewrite legacy tags as the equivalent single-track Enhanced FLV tags.
fn flv_test_extended(
  file : Bytes,
  fourcc : Bytes,
  legacy_prefix : Int32,
) -> Bytes {
  let header_end = flv_header_end(file).unwrap() + 4
  let out = file[:header_end].to_owned().to_array()
  let mut pos = header_end
  while pos < file.length() {
    let size = flv_u24be(file, pos + 1)
    let body = pos + 11
    let end = body + size
    if file[pos] == 8 {
      let kind = if legacy_prefix == 2 { file[body + 1].to_int() } else { 1 }
      let size = size - legacy_prefix + 5
      out.append([
        8,
        (size >> 16).to_byte(),
        (size >> 8).to_byte(),
        size.to_byte(),
      ])
      out.append(file[pos + 4:body].to_owned().to_array())
      out.push((0x90 | kind).to_byte())
      out.append(fourcc.to_array())
      out.append(file[body + legacy_prefix:end].to_owned().to_array())
      let previous_size = size + 11
      for byte in 0..<4 {
        out.push((previous_size >> (8 * (3 - byte))).to_byte())
      }
    } else {
      out.append(file[pos:end + 4].to_owned().to_array())
    }
    pos = end + 4
  }
  Bytes::from_array(out)
}

///|
test "FLV aac matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQUAAAAJAAAAABIAASQAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAANAAhkdXJhdGlvbgA/sCDEm6XjVAAFd2lkdGgAQD",
    b"AAAAAAAAAABmhlaWdodABAMAAAAAAAAAANdmlkZW9kYXRhcmF0ZQBAaGoAAAAAAAAJZnJhbWVyYXRlAEA5AAAAAAAAAAx2",
    b"aWRlb2NvZGVjaWQAQAAAAAAAAAAADWF1ZGlvZGF0YXJhdGUAQD9AAAAAAAAAD2F1ZGlvc2FtcGxlcmF0ZQBA5YiAAAAAAA",
    b"APYXVkaW9zYW1wbGVzaXplAEAwAAAAAAAAAAZzdGVyZW8BAAAMYXVkaW9jb2RlY2lkAEAkAAAAAAAAAAdlbmNvZGVyAgAM",
    b"TGF2ZjYzLjEuMTAyAAhmaWxlc2l6ZQBAhYAAAAAAAAAACQAAAS8IAAAHAAAAAAAAAK8AEghW5QAAAAASCAAAjQAAAAAAAA",
    b"CvAdwATGF2YzYzLjEuMTAyAAJYZVKsUIQhC0JB1Kte+9Ruc1r4VXGXW51h8SZxvWayDVtJwV551yFMtGJZKWzWOkVTzTZq",
    b"+si9b5AB7xvTR64sF6Do6bQ3VbSmtMlMlIvovyb+GPhjwvwvwvwvovhKBgZFQoUKFChQodhQRIjdVVVVVVVVVVU0000003",
    b"AAAACYCAAAkQAAFwAAAACvAQEeMpmFlzz9qqqrF+Sa1eL421nXPGcbvIFfd3eTDyO7u7u7u7u74eTtkAA9/f39/f39/f39",
    b"/cgMnx8fHx8fHx8fBgA77+/v7+/v7+8IAAP8fHx8fHx8D4+AAn3Dvv7+/uXv7kAB8ZPj4+Pj4+B8GAGf39/f39/f39wAAB",
    b"8fHx8fHx8GAAAA9/f39/f3hAA4AAAAnAkAAA8AABcAAAAAEgAAhAAICBEmICAgIf/+AAAAGg==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "aac", 44100, 2048, "904cdf57d5669566eb981bae044aecc9",
  )
  check_flv_fixture(
    flv_test_extended(file, b"mp4a", 2),
    "aac",
    44100,
    2048,
    "904cdf57d5669566eb981bae044aecc9",
  )
  let media = MediaFile::open(file)
  assert_eq(media.streams().length(), 1)
  assert_eq(media.stream_timebase(0), Some((1000.0, 0.0)))
  let packets = av_flv_audio_open(file).unwrap().packets
  assert_eq(packets.map(p => (p.pts, p.size)), [(0L, 139), (23L, 143)])
  assert_true(
    av_flv_audio_open(file[:file.length() - 1].to_owned())
    is Err("flv: truncated tag payload"),
  )
}

///|
test "FLV mp3 matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/r752yLQ5WAANYXVkaW9kYX",
    b"RhcmF0ZQBAN3AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDViIAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEAAAxhdWRpb2NvZGVjaWQAQAAAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAEB/cAAAAA",
    b"AAAAAJAAAAywgAAE8AAAAAAAAAKv/zMMQADkCCmB9MeAB63bgC973ve970pSlKUpS7a9e/hwIAEBNxcy5qN+D4fiAMcHz/",
    b"BCU9/R7+g5iAH9YEOaA/0cEAfB9YiJSL8REo2gAAAFoIAABQAAAaAAAAACr/8zLECA6ItqQBicgA/4hAUdFX7tNKGr2RJ7",
    b"mlH/7ARz/Q8/TOZJj/0NLS6wnrNX5YKgqCYMswMQF4FaBv8WSqFBqrzM9jSJHDiSWmkgESAAAAWwgAAE8AADQAAAAAKv/z",
    b"MMQPCvCdqAvGGALSIBRY4BAQEgwEKoUCFMVBURHfJT0tR/8OrO//okxBTUU0LjCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
    b"qqqqqqqgAAAFo=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "mp3", 22050, 1728, "fb504f516a2021dd91c0cc36e9b123d5",
  )
  let packets = av_flv_audio_open(file).unwrap().packets
  let first = packets[0]
  let second = packets[1]
  let tag_start = first.pos - 12
  // Merge the first two MP3 frames into one tag and replace its trailer.
  let merged = file[:first.pos + first.size].to_owned().to_array()
  let size = 1 + first.size + second.size
  merged[tag_start + 3] = size.to_byte()
  merged.append(file[second.pos:second.pos + second.size].to_owned().to_array())
  merged.append([0, 0, 0, (11 + size).to_byte()])
  merged.append(file[second.pos + second.size + 4:].to_owned().to_array())
  let grouped = Bytes::from_array(merged)
  assert_eq(
    av_flv_audio_open(grouped).unwrap().packets.map(p => (p.pts, p.size)),
    [(0L, 78), (26L, 79), (52L, 78)],
  )
  check_flv_fixture(
    grouped, "mp3", 22050, 1728, "fb504f516a2021dd91c0cc36e9b123d5",
  )
  check_flv_fixture(
    flv_test_extended(grouped, b".mp3", 1),
    "mp3",
    22050,
    1728,
    "fb504f516a2021dd91c0cc36e9b123d5",
  )
}

///|
test "FLV alaw matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/iJN0vGp++gANYXVkaW9kYX",
    b"RhcmF0ZQBAT0AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEC/QAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEAAAxhdWRpb2NvZGVjaWQAQBwAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAEB1wAAAAA",
    b"AAAAAJAAAAywgAAFEAAAAAAAAAcvGQhZPRExoSUZOaktIQGhJckJqS2RAaEluQmp3FEBodRpGancARGh1NkZqdzxEaHEiW",
    b"mpzKFhocdZaanPcWGhx2l5qc8RcaH3CXmp/zFxofAAAAXAgAABEAAAoAAAAAcn2Ump/8FBoff5Sanv8VGhwAAAAc",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "pcm_alaw", 8000, 96, "ba47497f7318f1961ec014aef64d457f",
  )
}

///|
test "FLV mulaw matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/iJN0vGp++gANYXVkaW9kYX",
    b"RhcmF0ZQBAT0AAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEC/QAAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEAAAxhdWRpb2NvZGVjaWQAQCAAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAEB1wAAAAA",
    b"AAAAAJAAAAywgAAFEAAAAAAAAAgta5r7j3OC83drivt/A5Lzdtua+36zkvN2m5r7bmOS82ZLqvtuI6LzZfuq+23jovNV27",
    b"r7XcOy81Wruvtdk7LzVYvK+11zwvNFa8r7TVPC80AAAAXAgAABEAAAoAAAAAglO9r7TSPS80Ub2ws9E+LzUAAAAc",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "pcm_mulaw", 8000, 96, "5932f1d8e0ed5ce4baf39d31eeb081bd",
  )
}

///|
test "FLV s16 matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/iJN0vGp++gANYXVkaW9kYX",
    b"RhcmF0ZQBAhYiAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDliIAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQDAAAAAAAAAABnN0",
    b"ZXJlbwEAAAxhdWRpb2NvZGVjaWQAQAgAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAECUOAAAAA",
    b"AAAAAJAAAAywgABCMAAAAAAAAAPgAAQwJ7BJwGmwhuCgoMaQ2DDlEP0Q//D9sPZA+fDo4NNwyhCtUI2ga9BIcCRAAA/sb7",
    b"ofme98b1IvS88prxw/A68ALwHfCK8EbxTvKd8y318/bp+AL7Nv14/70B+QMhBigIBgqwCx4NSA4oD7oP/A/qD4cP1A7UDY",
    b"0MBQtECVQHPgUMA8sAhv5I/B/6E/gv9n/0CvPY8e7wUvAI8A/wafAT8QrySvPL9IX2cPiD+rH88f43AXUDogWyB5sJUgvO",
    b"DAkO+w6gD/QP9g+lDwQPFg7fDGYLsQnLB70FkQNSAQ7/zfyd+on4nPbf9FvzGPIe8XDwEvAG8E3w5fDK8fnya/QZ9vr3BP",
    b"ou/Gr+rwDxAiMFOwctCfAKewzGDckOgA/nD/0Pvw8xD1QOLg3DCxwKQAg6BhUE2QGU/1L9HfsC+Qv3QfWv813yUfGR8CDw",
    b"AvA18LrwjvGs8hD0sfWG94f5qvvk/SgAbAKiBMEGvQiMCiUMfw2TDl0P1w//D9UPWQ+ODnkNHQyDCrMItgaXBF8CGwDY/Z",
    b"/7ffl896f1CPSm8onxt/Az8AHwIvCU8FbxZPK380r1FfcN+Sn7Xv2g/+UBIARFBksIJQrLCzQNWg41D8EP/Q/mD30PxA6/",
    b"DXQM6AojCTAHFwXlAqMAXv4i/Pn58PcQ9mP08vLF8eHwS/AG8BPwcvAi8R7yYvPn9Kb2lPio+tn8Gf9fAZ0DyAXVB7sJbg",
    b"vmDBwOCQ+oD/cP8w+dD/YOAw7HDEkLkQmoB5cFagMqAeX+pvx4+mb4e/bC9EPzBfIP8WbwDvAJ8FXw8vDd8RHzh/Q59h34",
    b"KvpV/JP+1wAYA0kFXwdOCQ0LlAzaDdgOig/sD/sPuA8kD0IOFg2oC/wJHggVBu0DsQFs/yr99/re+Or2JPWW80jyQfGH8B",
    b"zwA/A88MfwoPHD8iv0z/Wp96350fsM/lAAkwLJBOUG3giqCj8MlA2kDmgP3A//D88PTg9+DmMNAwxlCpEIkgZwBDcC8/+w",
    b"/Xn7WPla94j17fOQ8njxq/At8AHwJ/Cf8GbxefLR82n1Nvcx+U/7hv3J/w0CRwRqBm0IRArmC0sNaw5BD8gP/g/iD3MPtQ",
    b"6rDVoMygoCCQwH8QS9AnsANv77+9T5zffw9Uj02/Kz8dTwQ/AE8BfwfPAx8TPye/ME9cb2uPjP+gD9Qf+GAcQD7gX5B9oJ",
    b"igv+DC8OFg+wD/kP8A+UD+gO7w2vDCwLcQmEB3IFQgMCAb3+fvxR+kP4W/al9Crz8fEB8V7wC/AL8F3wAPHw8Snzo/RZ9k",
    b"D4T/p8/Lr+AAFAA28FggdvCSsLrQzuDecOkw/vD/kPsQ8XDzAO/wyMC90J+wfwBcYDiQFE/wP90fq6+Mj2BvV98zTyMvF9",
    b"8BfwBPBD8NPwsvHa8kb07vXL99L5AAAELg==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "pcm_s16le", 44100, 529, "036923b0c53f38ef6f93d8755d7350fd",
  )
}

///|
test "FLV u8 matches FFmpeg PCM" {
  let encoded = bcat([
    b"RkxWAQQAAAAJAAAAABIAAMAAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/iJN0vGp++gANYXVkaW9kYX",
    b"RhcmF0ZQBAVYiAAAAAAAAPYXVkaW9zYW1wbGVyYXRlAEDFiIAAAAAAAA9hdWRpb3NhbXBsZXNpemUAQCAAAAAAAAAABnN0",
    b"ZXJlbwEAAAxhdWRpb2NvZGVjaWQAAAAAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDIACGZpbGVzaXplAEB4AAAAAA",
    b"AAAAAJAAAAywgAAHUAAAAAAAAABIGIjo+MhHt0cHF2f4iOj4yFfHRwcXZ+h46PjIV8dHBwdn6HjY+Nhn11cHB1fYaNj42G",
    b"fXVwcHV9ho2PjYd+dnBwdHyFjI+Oh352cXB0fIWMj46If3ZxcHR7hIyPjoh/d3Fwc3uEi4+OiYB3cXBzeoOLj46JAAAAgA",
    b"gAABEAAAsAAAAABIF4cXBzeoOLj4+JgXhyb3IAAAAc",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_flv_fixture(
    file, "pcm_u8", 11025, 132, "a3b6469b0f883459cd1696066f786336",
  )
}
