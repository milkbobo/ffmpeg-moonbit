///|
/// FFmpeg 9.0.2 AAC-LC LATM from 650 Hz at 32 kHz (-b:a 40k).
let loas_mono_b64 : Bytes = b"VuD3IAASiB/nhuACYwuzGbGZcYlxiYGQABIlauUKIejIWpF1lue/PtMRe1ypkjY95LWQQOauYe6uye4uafq3735L7z3F6zYwMgkoo9ot" +
  b"tYk6rlsM7vJ7LPztg5ZpWkgjWESO8i4hI4iJT3cjOpLGL9d8G7p7q5t2Nt3SW3cxZpzViuXrZsrMOXsVxbCba1u21uNi42LbVNtU22Lj" +
  b"YuNa1WbjYuNi21TbTZ02dNnTWps6bOmzpsZmMSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUSUF8JUUUUUUUUUUUUUUUUUUUU" +
  b"UUUUUUUUUUUUUUUUUUUXAFbg2OsAh05tZLbxZL3TZH3TZLzU//qf9/v1x07r4aq/z//Y/9/jrXV3rVr/7f/2P/b6611xfFzK/1//pf+v" +
  b"xxrrWr1OeA4PwcJRRRFET3x45vKXb38xTI2Qqe4qe+Sg8z5QqHO98vkBzvfL5AB5g+XyOAHud75cz4OPpzj5ccoBw3ztvfLirmuABnjs" +
  b"hD5NWEnMTe+PIwnGDZC+zVfZGA9WzUP5erVqP5fy2agfy/lsqhQ9X8umqFVGv+XjQqFGG0l0kBEp1CpjzzzOd76Pc/0ee+nn9OcN87b3" +
  b"AFbgq9SAi07ZZZlB1x0aHB+A/D/8P/LitdatrrL/6f/h/52BcuCMfJnVmk5pP5JsHtTtb1SemiRpnqT5URfIqDEPl8tdEQ+Xy10EP5/z" +
  b"p6oqkADmAfz89/dr/l40KmBRhtJdIBEE588iU6hJDIRLAcwQsGR5rQKSH6bqocREbl2YrVfyffBQ9D13W6Qf9N/0wfc2yBq1agNWrUBq" +
  b"1agDVq1agDVq1agD+39v7f24AFbgB4KAjEDaOAA="

///|
/// FFmpeg 9.0.2 AAC-LC LATM from 440/660 Hz at 48 kHz (-b:a 96k).
let loas_stereo_b64 : Bytes = b"VuD4IAARkB/njuACYwuzGbGZcYlxiYGQAhKcgAN/gACas9JROuMd60a0lJRJJI8ZIuRIgZSzTn7ZuJZh4u/K9hEEKlkusv5NLeFgry9V" +
  b"ltia1XaZ5fmqpq2UslKoyaMmjJQpQpWhtDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMbNm5adB0ZDijwkXRkTQkFxSmZxLl/d69iSS" +
  b"QscMmomgCQkJGJGJTXWm3jg6vBr/7fwYGBkQMDVKj0wZEtYAAACKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK" +
  b"KKKKKKKKKKKKKKKKKKKKLgBW4Un/o5CmNk4A8A8AwC0LaROyyPlkaWsp4/2/nzxpifHWtX+n/x+vnjWta1ev9f/H79cXxrWr1/f/t+Pa" +
  b"741rV6CyeeeYNYkfVk9VZs5cz9GqPTktnXREQANeu7Y+Gu7Y/l/LXvNh/L+X8rmw/l/L+QH8v5fy13AETZkhrqGAHonltdZ8jk6UIGqD" +
  b"UahAARRREB8ooiAHy+XHjEQA+Xy+XyiIAfL5ceMQAA+Xy+UXyiiBJWfJ8PptTTBIScCQkJCQkJCQkJCQkJCQkJCQmfsld1kr+slf1kuv" +
  b"Tx/nzwcOr1dz/+9/388aoFf/2/+/XF3Qa//vf9/brjrjXH5BFyw2RRfTn8MJZ3O5NaTndZ/JkcztyBjNijWNf0Gs301gZCMQmcg7cJYH" +
  b"XZBKTpcXMRfIN/IPfIc/yhA5xb5COa5yZj1FBqKKKKKKKKKOAFbhHv+OEKZpTwDwPwP/56yXlkfLI0nrcj47/frWuNXrWv/7vj9fbWuN" +
  b"a1q//7f6fr51qatv6v8/68aku5IDHawPf01RvKBgWscdY+WsfLWYD5cfoYD5fL6UAfL5fQwAHy+Xy+lAAHy+Xy+mswA+Xy+X0+msAAfL" +
  b"5fL5QCWS+BXLAwv5P5H8v5H8v5H8v5D+X8v5D+X8v5D+X8v5B/L+X8v5bkwIoEEEEEEEHxuzAAAAAAAAnbI39ZG/rKX3rsl4/r/361qF" +
  b"H9v6f9/bWoD+v6fr51rY3bvv/XjUl3JARdOGdPIe/4wguXABnPoEXiEYwhCEEB2hkMK2w8PDy/t3LwB7j3HuPce/uB7+4Hv7ge/v7gD3" +
  b"9/cAe/v7gD39/f3AA4BW4AmDkKBtIwRg4AA="

///|
/// RIFF header of the same stereo stream remuxed by FFmpeg with -c:a copy.
let loas_wav_header_b64 : Bytes = b"UklGRsoDAABXQVZFZm10IBQAAAACFgIAgLsAAAAAAAAEABAAAgARkGZhY3QEAAAAABAAAExJU1QaAAAASU5GT0lTRlQNAAAATGF2ZjYzLjEuMTAyAABkYXRhdAMAAA=="

///|
test "bare LOAS playback yields sample timestamps and FFmpeg PCM" {
  let data = @libavutil.av_base64_decode(loas_mono_b64, 1024).unwrap()
  let media = MediaFile::open(data)
  assert_eq(media.format_name(), "loas")
  let stream = media.streams()[0]
  assert_eq(stream.codec_id, "aac_latm")
  assert_eq(stream.sample_rate, 32000)
  assert_eq(stream.channels, 1)
  assert_eq(media.duration_seconds(), Some(0.128))
  let decoder = media.audio_decoder(0)
  for i in 0..<4 {
    let packet = media.next_packet().unwrap()
    assert_eq(packet.pts, i.to_int64() * 1024L)
    let frame = decoder.decode(packet).unwrap()
    assert_eq(frame.pts, Some(packet.pts))
    assert_eq(frame.nb_samples, 1024)
  }
  assert_true(media.next_packet() is None)

  // A clip with a single configuration-bearing LOAS frame is auto-detected.
  assert_eq(decode_audio_file(data[:250].to_owned()).samples[0].length(), 1024)

  let audio = decode_audio_file(data)
  let wav = audio.to_wav_s16()
  let wave = av_wav_open(wav).unwrap()
  assert_eq(wave.data_size, 8192L)
  assert_eq(
    caf_md5(wav[wave.data_offset.to_int():].to_owned()),
    "3b53fdcb0829a95feba5623f52e3518f",
  )
}

///|
test "WAV 0x1602 reads LATM access units and decodes the same stereo PCM as LOAS" {
  let es = @libavutil.av_base64_decode(loas_stereo_b64, 1024).unwrap()
  let header = @libavutil.av_base64_decode(loas_wav_header_b64, 128).unwrap()
  let data = header + es
  let wav = av_wav_open(data).unwrap()
  assert_eq(wav.format.format_tag, 0x1602)
  assert_eq(wav.data_size, es.length().to_int64())
  let audio = decode_audio_file(data)
  assert_eq(audio.format_name, "wav")
  assert_eq(audio.codec_id, "aac_latm")
  assert_eq(audio.sample_rate, 48000)
  assert_eq(audio.channels, 2)
  assert_eq(audio.samples[0].length(), 4096)
  assert_eq(audio.samples[1].length(), 4096)
  assert_eq(audio.samples, decode_audio_file(es).samples)
}

///|
test "LOAS rejects truncated framing and unsupported mux or decoder changes" {
  let mono = @libavutil.av_base64_decode(loas_mono_b64, 1024).unwrap()
  let stereo = @libavutil.av_base64_decode(loas_stereo_b64, 1024).unwrap()
  assert_true(
    @libavcodec.latm_parse_stream(mono[:mono.length() - 1].to_owned())
    is Err("latm: truncated LOAS frame"),
  )
  assert_true(
    @libavcodec.latm_parse_stream(mono + stereo)
    is Err("latm: changing AudioSpecificConfig is not supported"),
  )
  let changed = mono.to_array()
  changed[3] = b'\x00'
  assert_true(
    @libavcodec.latm_parse_stream(Bytes::from_array(changed))
    is Err("latm: asynchronous stream framing is not supported"),
  )
  changed[3] = b'\x21'
  assert_true(
    @libavcodec.latm_parse_stream(Bytes::from_array(changed))
    is Err("latm: multiple subframes are not supported"),
  )
}
