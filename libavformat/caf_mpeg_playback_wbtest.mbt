///|
/// FFmpeg 9.0.2 CAF fixtures. AMR-NB was stream-copied from FATE
/// amrnb/4.75k.amr and MP1 from the Layer I mono decoder fixture.
fn check_caf_legacy_fixture(
  file : Bytes,
  codec : String,
  rate : Int32,
  channels : Int32,
  samples : Int32,
  priming : Int32,
  frame_samples : Int32,
  expected_md5 : String,
) -> Unit raise {
  let demux = av_caf_open(file).unwrap()
  assert_eq(demux.priming, priming)
  assert_eq(demux.format.frames_per_packet, frame_samples)
  assert_eq(demux.packets[0].pts, -priming.to_int64())
  let last = demux.packets[demux.packets.length() - 1]
  assert_eq(last.pts + last.duration.to_int64(), samples.to_int64())
  let audio = decode_audio_file(file)
  assert_eq(audio.codec_id, codec)
  assert_eq(audio.format_name, "caf")
  assert_eq(audio.channels, channels)
  assert_eq(audio.sample_rate, rate)
  assert_eq(
    audio.duration_seconds,
    Some(samples.to_double() / rate.to_double()),
  )
  assert_eq(audio.read_error, "")
  let wave = audio.to_wav_s16()
  let wav = av_wav_open(wave).unwrap()
  assert_eq(wav.data_size, (samples * channels * 2).to_int64())
  assert_eq(caf_md5(wave[wav.data_offset.to_int():].to_owned()), expected_md5)
  if codec == "mp1" || codec == "mp2" || codec == "mp3" {
    let start = demux.data_offset.to_int()
    let raw = file[start:start + demux.data_size.to_int()].to_owned()
    let remuxed = av_caf_mux_mpeg_audio(
      raw,
      priming~,
      valid_frames=samples.to_int64(),
    ).unwrap()
    assert_eq(decode_audio_file(remuxed).samples(), audio.samples())
  }
}

///|
test "CAF amr packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBAv0AAAAAAAHNhbXIAAAAAAAAAAAAAAKAAAAABAAAAAGNoYW4AAAAAAAAADABkAAEAAA",
    b"AAAAAAAGt1a2kAAAAAAAAAHQAAAAxmcm1hc2FtcgAAABFzYW1yRkZNUACB/wABaW5mbwAAAAAAAAAZAAAAAWVuY29kZXIA",
    b"TGF2ZjYzLjEuMTAyAGRhdGEAAAAAAAAAKwAAAAAEPOUwT/K9+V+A+0qGBJZCJn/5hi/Iydbe4gSRKoN87cWuPNmInKBwYW",
    b"t0AAAAAAAAABsAAAAAAAAAAwAAAAAAAAHgAAAAAAAAAAANDQ0=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  // Pin the MoonBit PCM. The FFmpeg comparison allows codec rounding differences.
  check_caf_legacy_fixture(
    file, "amrnb", 8000, 1, 480, 0, 160, "f00a90b65380a1bc8748d3d6a3455c20",
  )
}

///|
test "CAF mp1 packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA30AAAAAAAC5tcDEAAAAAAAAAAAAAAYAAAAABAAAAAGNoYW4AAAAAAAAADABkAAEAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAA2QAAAAA//9oxEMhAAAAAAAA",
    b"AAAAAAAAAAAAc1ULMJOz4ZXxaXIKucWtYc8zg7+hhPEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//9oxEMh",
    b"AAAAAAAAAAAAAAAAAAAAc1VGrWFnGGLMpO74bXx6XAKscWNYU8wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"//9oxEMhAAAAAAAAAAAAAAAAAAAAc1V6Gk8a1zGr2FvGELMJOz4ZXxaXIKsAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    b"AAAAAAAAcGFrdAAAAAAAAAAeAAAAAAAAAAMAAAAAAAAEgAAAAAAAAAAAgiCCIIIg",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_caf_legacy_fixture(
    file, "mp1", 32000, 1, 1152, 0, 384, "cb2824e3d226eedf3a5f767d6aeeda0e",
  )
  // The three MPEG frames each occupy 288 bytes. Use the fixed packet
  // size in desc and remove the now-redundant pakt chunk.
  let table = av_caf_open(file).unwrap()
  let data_end = (table.data_offset + table.data_size).to_int()
  assert_eq(file[data_end:data_end + 4].to_owned(), b"pakt")
  let fixed = file[:data_end].to_owned().to_array()
  fixed[38] = 1
  fixed[39] = 32
  let data = Bytes::from_array(fixed)
  assert_eq(av_caf_open(data).unwrap().format.block_align, 288)
  check_caf_legacy_fixture(
    data, "mp1", 32000, 1, 1152, 0, 384, "cb2824e3d226eedf3a5f767d6aeeda0e",
  )
}

///|
test "CAF mp2 packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAC5tcDIAAAAAAAAAAAAABIAAAAACAAAAAGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAA2QAAAAA//1kBGZEbbRbbJ+g",
    b"AA/DmVICC1Kdk6+FrtV6tW7dlsN2stWrNXsmMncm7tn333333d3d1sWxbFsfNWxbFsWxrX3Y4HJHd3d1sb1G1sfNWxbFsW",
    b"xrUOZE/SHXHRrTUFShPEqY+ia2UBSJXYJ3XlTdQ12WxbFkfNWxdV1WxreCHleEUTdYlwZRSlxeLjFcH/OtbOB3z+G0TckV",
    b"sWxY1sfNb1bXxHlrdxoCM5UTasVsWxbFsfNcdbJLMpTdxoRbLkTYwlsWxbFsfNg9bH6NFTdhYhY9UXW1IWSRlUZXnmp02g",
    b"SJrtRYymeDXT1pSBVqkShQcafH6SNhNRZEUODXSyJKXxukaFusOfZSWpRNBJWidDXRq37RB+W5elsSKYBbpQAA//1kBGZE",
    b"kbSbbSqqqqrmYCS9t9tdttNcs89NMxJpBbCXhjDaYdirU4iNnKEH5alwLzEnuFjJeJtVuY5QZIkaWu5hamU5r3IOjUlkV5",
    b"D0pxZx8GqjPppnySXxemsQ6eEUBbmLFXQdWqKRfDcZHZSVBApwDq4aJFugaMdtoagsFcSuohlNSGj28OvSQUW6xg30YdDk",
    b"QhUYPoaAkAcubg7LbRRfsJkfYKICPdM9sKB4BHFAzuDtj0JF91EScsDkoK5LKuYZgIEHL20O5rhAH3WJVq1dxBwFI6xiRu",
    b"RxfhrA70OGgfcgSe1BUgWtK7iB25cB9ulrDwJ0kCNqhM5azbkpRiaIXRgIgj6moPAW20I2MIpxuM4V1uILBoVukjShwAAA",
    b"//1kBGZDbbJbbJAAAAADnflIfiXPi5PkZvkpPk7PlaflLflq/lbfmLPlrPmLPl7PmbfoHYHX4AjTtWxbFsWxrVsWxbFsa2",
    b"B2B598J1PVsWxbFsa1bFsWxbGtiXxiR7CcdUHgerGsSErGsQnCe1hZGi42ld1rXVa1jWJrViWJdF0azsmD4yHkhnSjPyOG",
    b"aEp6WaKc91Keffeffd3WxbFsWtbGtWxbFrWxrX333333d1sWxbFsWxrVsWxbFsa19999993dbFsWxbFsa1bFsWxbGtffff",
    b"ffd3WxbFsWxbGtWxbFsWxrX333333d1sWxbFsWxrVsWxbFsa19999993dbFsWxbFsa1bFsWxbGtffffffd3WxbFsWxbGtW",
    b"xbFsWxrQcGFrdAAAAAAAAAAeAAAAAAAAAAMAAAAAAAAJMAAAAeEAAAJvgiCCIIIg",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_caf_legacy_fixture(
    file, "mp2", 48000, 2, 2352, 481, 1152, "5f2988a1488aec65819a48c686255b5f",
  )
}

///|
test "CAF mp3 packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAC5tcDMAAAAAAAAAAAAABIAAAAACAAAAAGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAAwQAAAAA//tURAAAAOMA3O0E",
    b"IA4gYAs8oYQBBXRXUhmjgACsBnO/GiQCSTQAbkuAAAAw8PH2uHh78OABhn5h5/wAAR/h4fowAAEq/wATlxOsHAQOFwfcUB",
    b"AEAHB96TnAYf7vB9+7pcJYb9/dAIIdzycsb5OWNpnQRfImT6JnegWgN8Fo8Nvxsab+OiIK/BURHv1zeEiAiKAKAIAUCgYA",
    b"AAAABsgBJmUzRKpycLJrToBeKEvOnssJXfDpX+HSqgYwAAFJAAAA//tURAQDESMKUXdwwAonAWl47rABBJAtOpXDACCaha",
    b"bquDAG/+5yl0VqoSW9UVMKC0xJNTWYcMMgKLxF+dIgJOIABAAf+8dqyJ6AYAk1guAxhCJxjOLJ8yMwGG4wNBoIBp+l4h9V",
    b"bEGQAAaP/OV22yoioyA4AGBQqYjBZjr5k7uMEh8BCtdcSigIjaYoAMAAX//Covl+WvrTL4AwHGBjafSZBi4GGDgUlxYpwN",
    b"Agj////pr9/d3X6VAeqz9SlGh8//tUZAaAAUUU1oZk4AApYhs9yAgABhibWhkDgAB3iKqDFFAABr/Q3G/fg7JfmOOfsQb6",
    b"S4H/IFCn9KS//o//TJQAAAMBgMBgMBgAAABOzqyHuEVwkuGSg+h2o2vgYv+LJwA75cD/5T/pIqR3kPDZvBu4Pm8VAFeI4P",
    b"hv+JI6NfxwamEjv/GxU5TTf/zSgSBo9+sKgEJHf6gMPC5GHhfBJ8AiHnlAbxcSf8RK8EQF8sJiv5UVSn+3ZUxBTUU0LjBV",
    b"//tUZAQP8AAAaQcAAAgAAA0g4AABAAABpAAAACAAADSAAAAEVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVcGFrdAAAAAAAAAAgAAAAAAAAAA",
    b"QAAAAAAAAJMAAABFEAAAR/gUCBQIFAgUA=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_caf_legacy_fixture(
    file, "mp3", 48000, 2, 2352, 1105, 1152, "7a4a9b7055a2a26ac6a9d2d032c3ae7f",
  )
  let wave_tag = file.to_array()
  wave_tag[28] = b'm'
  wave_tag[29] = b's'
  wave_tag[30] = 0
  wave_tag[31] = b'U'
  check_caf_legacy_fixture(
    Bytes::from_array(wave_tag),
    "mp3",
    48000,
    2,
    2352,
    1105,
    1152,
    "7a4a9b7055a2a26ac6a9d2d032c3ae7f",
  )
}

///|
test "CAF mp3-low packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA13AAAAAAAC5tcDMAAAAAAAAAAAAAAkAAAAACAAAAAGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAAlwAAAAA//NUZAAGeD1eb6GI",
    b"AAcwasY5RRAAoCnQMOA7u7u7uSIiIiI7u8CAAAAAYGBg+D4fdBB2D/KBjwfB8EAQBAEHf//SJwf3f//wQSbeAuSAHOc53P",
    b"6EJn6CAcAAAA4AAx38pyAP8p71JIcXhyh2+IyCS+pUI7Bpg+iW//NURBIGHFlUAMboAAyIovJZgsACsRTNEM4iyQ0y52pm",
    b"7R/92j/5bKa1NTfBUJA1+JToNcDAUBN3agUDAYCXyhvAgL9wSt7JoqOG4AFos+itLpTN7e+h7F/+mCoK/ETw1+Inhr+W9j",
    b"+dvDi1BCkB0BQQnAdMHgCI//NURBIGWGVaAMFQAA0g0qgBgqAAoHTVn86+HzkTcn//L4HB/8aBHfwQKBj/qMw+X//PrzhT",
    b"/5/AzlEGoYDLhTAMhgBaoJjwMcCIAW8XxphcGmgRf/y+5uH/y4E/wQKBj/lDM+X//PrzhRWSNxb3JJFBQXwkFBQV//NURA",
    b"0F2AF3HOCMAYwQcsrZwxAAjEFBTeBQUFBQr+BQSC//IoKCu8FBQV3/iCkn/+IUN//8KCWVTAty2/8ZmZVVS+NVUKAgICAg",
    b"IEDQNA0ewaBoGTuoSgq7EoKgrxKCp3lQaPcsHUxBTUU0LjBVVVVVVVVVVVVV//NUZBEAAAGkAAAAAAAAA0gAAAAAVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVcGFrdAAAAAAAAAAdAAAAAAAAAAUAAAAAAAAG2AAABFEAAAAXeHh4eHg=",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  check_caf_legacy_fixture(
    file, "mp3", 24000, 2, 1752, 1105, 576, "de3cfa8b328f04fa736040d6c30ee30c",
  )
}

///|
test "CAF ac3 packet timing and PCM" {
  let encoded = bcat([
    b"Y2FmZgABAABkZXNjAAAAAAAAACBA53AAAAAAAGFjLTMAAAAAAAAAAAAABgAAAAACAAAAAGNoYW4AAAAAAAAADABlAAIAAA",
    b"AAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAAwQAAAAAC3ewWgxAQ+EG8AET",
    b"klFh+QEM/Sw+fOz9wygOJ8Zf10iRJAFdUaMvmyuMNoCXUJuJeNXgm8aBUKRtRvBaL5f9wsLjaUh6m518qc3M6erGXZKHdb",
    b"CaL24Am82yCbXbOJsNtMkr3VySjdaJJN90ii33yIP7eHWSpuB3sIGLhfBXFjwPmnkoPhTgUZK9s21J+vspKL6/V1aanXNy",
    b"goWHhnJkISUpjWgpO1qvDf/pAGiff5dhvnz58fzAGh2P5Ihv30N8Ad5/YAfl8MYY5UnP4WTx5BvtjiD/Cf/vbKiw2Oarc4",
    b"4a4yEBCRIhT58+hvnz58+fPnwHT+BAL/yS//kCf+EngBkIBTY/vIPX9EJNDUSbtUYyq3eMMABngyf9BvxGenlxjjiCwvlk",
    b"+mOIP8SB+/M2K1ZQrIzfLqzDgAeyDeAPq545w1QrtztQN1GeRj+8g9fYQMxNUppVKzMH6swwAHR+9gP9qMHXz2d80Zxoj/",
    b"sqY4g/xoO8A0EqdmauPMoCFKErC3e0TQxAQ+EG8AEICEhjShJm6p+/faABfPnt8cABfPnuuZf0ihQpAHgAABgABfcQ/ibH",
    b"d1P/vn+AA7vGAAAf4A98CMv60yKIGsYD0BuwyEJQXRVMyH4VXrwwPAAH+AH/4PvZHkIFLP5APwAB3eMAABAX/EP8GoKmfs",
    b"DzFPYQDdhkPz8/iQkJGwqG+fgeAAP+AP+PPaNXCPKYwOFAYIDu8YAAB/gD3gIy3ry8noaAhfwG7DIZmZm/6Pob6DPt+UA+",
    b"PwEPZSqU/7itYyZUDRaonGkwK8K+BCeS4puCSRDnHRL0anca1Avbx1E3bY060ZAa8do6Q5G52ExfDu+UTngOf20jmeeste",
    b"/0SG/Lx2BERCLS6lrG9vkB+HaZg/Z8+r4gsQzhkR+AZNJYli3lj3Ek0MaxS4IeZyVOK/MOYtU9RNRsN7OKOKOZOYPMZnkg",
    b"SbJoG6p/UmQKO0FXQhvLBKrIL4jVQpiUI6mgyEBAQQgICCf4+fPv+dXx/zq+ANawAFK+cGFrdAAAAAAAAAAcAAAAAAAAAA",
    b"IAAAAAAAAJMAAAAQAAAAHQgwCDAA==",
  ])
  let file = @libavutil.av_base64_decode(encoded, 2048).unwrap()
  // Pin the MoonBit PCM. The FFmpeg comparison allows codec rounding differences.
  check_caf_legacy_fixture(
    file, "ac3", 48000, 2, 2352, 256, 1536, "587885ad0b92ccd80e943bfacfcb31dd",
  )
}
