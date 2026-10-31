///|
/// MPEG-TS muxer tests: the emitted PAT/PMT/PES packets are parsed back by
/// the existing in-memory TS demuxer.

///|
test "ts muxer: PAT/PMT and PES round-trip through the demuxer" {
  let mux = ts_muxer_new()
  mux.write_video(90000L, b"hello")
  mux.write_audio(90090L, b"world")
  let bytes = mux.finish()
  assert_eq(bytes.length() % 188, 0)
  assert_eq(bytes[0], b'\x47')
  assert_eq(bytes[188], b'\x47')
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.packet_size, 188)
  assert_eq(demux.streams.length(), 2)
  assert_eq(demux.streams[0].pid, 0x100)
  assert_eq(demux.streams[0].codec, "h264")
  assert_eq(demux.streams[0].codec_type, "video")
  assert_eq(demux.streams[1].pid, 0x101)
  assert_eq(demux.streams[1].codec, "aac")
  assert_eq(demux.streams[1].codec_type, "audio")
  assert_eq(demux.packets.length(), 2)
  let mut video_ok = false
  let mut audio_ok = false
  for packet in demux.packets {
    if packet.pid == 0x100 {
      assert_eq(packet.payload, b"hello")
      assert_eq(packet.pts, 90000L)
      video_ok = true
    } else if packet.pid == 0x101 {
      assert_eq(packet.payload, b"world")
      assert_eq(packet.pts, 90090L)
      audio_ok = true
    }
  }
  assert_true(video_ok && audio_ok)
  assert_eq(demux.pcrs.length(), 1)
  assert_eq(demux.pcrs[0].pid, 0x100)
  assert_eq(demux.pcrs[0].base, 90000L)
  assert_eq(demux.pcrs[0].ext, 0)
}

///|
test "ts muxer: large payload spans multiple packets with continuity" {
  let mux = ts_muxer_new(video_pid=0x200, audio_pid=0x201)
  let payload : Array[Byte] = []
  for i in 0..<500 {
    payload.push(i.to_byte())
  }
  mux.write_video(0L, Bytes::from_array(payload))
  let bytes = mux.finish()
  assert_eq(bytes.length() % 188, 0)
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.streams[0].pid, 0x200)
  assert_eq(demux.packets.length(), 1)
  assert_eq(demux.packets[0].payload.length(), 500)
  assert_eq(demux.packets[0].payload[499], (499).to_byte())
}

///|
/// HEVC access units (first 3 of 10), split on AUD NAL units, from:
/// `ffmpeg -f lavfi -i testsrc2=size=64x48:rate=10 -t 1 -c:v libx265
///   -x265-params aud=1:bframes=0:keyint=5 -f hevc hevc_aud.265`
/// (docker linuxserver/ffmpeg:9.0.2).  64x48 at 10 fps, so PTS steps of
/// 9000 in the 90 kHz timebase.
let ts_hevc_au_b64 : Array[Bytes] = [
  b"AAAAAUYBEAAAAAFAAQwB//8BYAAAAwCQAAADAAADAB6SgJAAAAABQgEBAWAAAAMAkAAAAwAAAwAeoCCDFlkq5MrwFoCAAAADAIAAAAUEAAAAAUQBwXPQiQAAAU4BBf//////////8yyi3gm1F0fbu1Wk/n/C/E54MjY1IChidWlsZCAyMTYpIC0gNC4yKzEtZTQ0NDc0NDpbTGludXhdW0dDQyAxNS4yLjBdWzY0IGJpdF0gOGJpdCsxMGJpdCsxMmJpdCAtIEguMjY1L0hFVkMgY29kZWMgLSBDb3B5cmlnaHQgMjAxMy0yMDE4IChjKSBNdWx0aWNvcmV3YXJlLCBJbmMgLSBodHRwOi8veDI2NS5vcmcgLSBvcHRpb25zOiBjcHVpZD0xMTExMDM5IGZyYW1lLXRocmVhZHM9MSBuby13cHAgbm8tcG1vZGUgbm8tcG1lIG5vLXBzbnIgbm8tc3NpbSBsb2ctbGV2ZWw9MCBiaXRkZXB0aD04IGlucHV0LWNzcD0xIGZwcz0xMC8xIGlucHV0LXJlcz02NHg0OCBpbnRlcmxhY2U9MCB0b3RhbC1mcmFtZXM9MCBsZXZlbC1pZGM9MCBoaWdoLXRpZXI9MSB1aGQtYmQ9MCByZWY9MyBuby1hbGxvdy1ub24tY29uZm9ybWFuY2UgcmVwZWF0LWhlYWRlcnMgYW5uZXhiIGF1ZCBuby1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1sYXllcnM9MCBvcGVuLWdvcCBtaW4ta2V5aW50PTEga2V5aW50PTUgZ29wLWxvb2thaGVhZD0wIGJmcmFtZXM9MCBiLWFkYXB0PTIgbm8tYi1weXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTIwIGxvb2thaGVhZC1zbGljZXM9MCBzY2VuZWN1dD00MCBuby1oaXN0LXNjZW5lY3V0IHJhZGw9MCBuby1zcGxpY2Ugbm8taW50cmEtcmVmcmVzaCBjdHU9MzIgbWluLWN1LXNpemU9OCBuby1yZWN0IG5vLWFtcCBtYXgtdHUtc2l6ZT0zMiB0dS1pbnRlci1kZXB0aD0xIHR1LWludHJhLWRlcHRoPTEgbGltaXQtdHU9MCByZG9xLWxldmVsPTAgZHluYW1pYy1yZD0wLjAwIG5vLXNzaW0tcmQgc2lnbmhpZGUgbm8tdHNraXAgbnItaW50cmE9MCBuci1pbnRlcj0wIG5vLWNvbnN0cmFpbmVkLWludHJhIHN0cm9uZy1pbnRyYS1zbW9vdGhpbmcgbWF4LW1lcmdlPTMgbGltaXQtcmVmcz0xIG5vLWxpbWl0LW1vZGVzIG1lPTEgc3VibWU9MiBtZXJhbmdlPTU3IHRlbXBvcmFsLW12cCBuby1mcmFtZS1kdXAgbm8taG1lIHdlaWdodHAgbm8td2VpZ2h0YiBuby1hbmFseXplLXNyYy1waWNzIGRlYmxvY2s9MDowIHNhbyBuby1zYW8tbm9uLWRlYmxvY2sgcmQ9MyBzZWxlY3RpdmUtc2FvPTQgZWFybHktc2tpcCByc2tpcCBuby1mYXN0LWludHJhIG5vLXRza2lwLWZhc3Qgbm8tY3UtbG9zc2xlc3MgYi1pbnRyYSBuby1zcGxpdHJkLXNraXAgcmRwZW5hbHR5PTAgcHN5LXJkPTIuMDAgcHN5LXJkb3E9MC4wMCBuby1yZC1yZWZpbmUgbm8tbG9zc2xlc3MgY2JxcG9mZnM9MCBjcnFwb2Zmcz0wIHJjPWNyZiBjcmY9MjguMCBxY29tcD0wLjYwIHFwc3RlcD00IHN0YXRzLXdyaXRlPTAgc3RhdHMtcmVhZD0wIGlwcmF0aW89MS40MCBhcS1tb2RlPTIgYXEtc3RyZW5ndGg9MS4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIgcWctc2l6ZT0zMiBuby1yYy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9ybWF0PTUgcmFuZ2U9MCBjb2xvcnByaW09MiB0cmFuc2Zlcj0yIGNvbG9ybWF0cml4PTIgY2hyb21hbG9jPTAgZGlzcGxheS13aW5kb3c9MCBjbGw9MCwwIG1pbi1sdW1hPTAgbWF4LWx1bWE9MjU1IGxvZzItbWF4LXBvYy1sc2I9OCB2dWktdGltaW5nLWluZm8gdnVpLWhyZC1pbmZvIHNsaWNlcz0xIG5vLW9wdC1xcC1wcHMgbm8tb3B0LXJlZi1saXN0LWxlbmd0aC1wcHMgbm8tbXVsdGktcGFzcy1vcHQtcnBzIHNjZW5lY3V0LWJpYXM9MC4wNSBuby1vcHQtY3UtZGVsdGEtcXAgbm8tYXEtbW90aW9uIG5vLWhkcjEwIG5vLWhkcjEwLW9wdCBuby1kaGRyMTAtb3B0IG5vLWlkci1yZWNvdmVyeS1zZWkgYW5hbHlzaXMtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1zYXZlLXJldXNlLWxldmVsPTAgYW5hbHlzaXMtbG9hZC1yZXVzZS1sZXZlbD0wIHNjYWxlLWZhY3Rvcj0wIHJlZmluZS1pbnRyYT0wIHJlZmluZS1pbnRlcj0wIHJlZmluZS1tdj0xIHJlZmluZS1jdHUtZGlzdG9ydGlvbj0wIG5vLWxpbWl0LXNhbyBjdHUtaW5mbz0wIG5vLWxvd3Bhc3MtZGN0IHJlZmluZS1hbmFseXNpcy10eXBlPTAgY29weS1waWM9MSBtYXgtYXVzaXplLWZhY3Rvcj0xLjAgbm8tZHluYW1pYy1yZWZpbmUgbm8tc2luZ2xlLXNlaSBuby1oZXZjLWFxIG5vLXN2dCBuby1maWVsZCBxcC1hZGFwdGF0aW9uLXJhbmdlPTEuMDAgc2NlbmVjdXQtYXdhcmUtcXA9MGNvbmZvcm1hbmNlLXdpbmRvdy1vZmZzZXRzIHJpZ2h0PTAgYm90dG9tPTAgZGVjb2Rlci1tYXgtcmF0ZT0wIG5vLXZidi1saXZlLW11bHRpLXBhc3Mgbm8tbWNzdGYgbm8tc2JyYyBuby1mcmFtZS1yY4AAAAEoAa8RgEPUsWKm/peACGfs1mBi6Ns//FVwGcC4+MZrgX6qG+XxO+nKkZowJKZdM6inx37NR8ozBMxYQ2UHHXe+QWlWqhbzPJKn5xh5NnwHZcyMnkf//9Bjv5mPHu9/afl9K1+ayuEShB3ChoVkvYkg9trw4E/6kHcwZpEb0HJySAvUTKd/yiLlOOXFtrFbHx1fdygOV4UmCKIXefQs9eL2vZNB/zXCDKZhIlD+fuujPvCyf5h9v8OVKap714Tgab2gPr4mTN4pwIavIsPMpFxTc6FDvJ8p1PK8BtgIPG9we42Dj9GJstx3Ew1YAkMW28rAKioS9nmSns9qM3F3uvnjAIPUgF/U35e8hZCbnHWw4bNQjgQ9pxv284wrImfHjOnc9xK++nmkeyy5CNtu06gUDZhScjPIatJ8qvzrUiDh9RNwl7HFcnXUTdrQv6uemKINe+TwBm3ym3HQKxFinsFxLcnRgpVKXCreLnF9Lyc4yhOLRQjdoeRJX80gNSxO0TksOOhOn5Sej5d4yzbOKtnYWUcpEp3rdVWpJleWgsJ2Zad+h/RZqP4wxotazxCpLPAcFNuUj3CVGXd7Wq+0TrzmxEEkCi8D5SI5YbvkN09XfMFUXKaQz+jow0ED0dG7dyga2Ch8VBX+8VgS2I59B6kZOd999XB5GmfzJnBX50hGZ1FFZHY4kAWK1uTf2VaxAyIMqb4S6a/LOjxl/ic+Nomat+kniDYdbk/Z4L7paH6VfUpardd7z3gKzG9zJ92zYg2YktrqUYswqTV+Zv6VsnoyM58MflPDu2eIYWFXXBKxJBA2tCXPbXJ1fGXdUjPZ7QG1mVdyWNRbzodpWwGEXmvEWRrQ5Qu8AoKptq/yITTpwuYDyDWSF4zg4e0CZXIVUSaNJtOdx8CV7+/Dc8c5jSQf6Ffmg0NbXBsj2oO4n80qPdnQSrxZWwxXdNxyGroZ29PzM0wLe+x66LlF/FkRw/zUs3pGQLmHxc47eucOz2c+Jd8ImbQlKrG/e4R3gFT+YteyPtPVlWPqNrmD3FfVh1Fn+jfTOKk/OkpVFMFJtClw7vltIwqum7U7UG5umHcbV5S0YKQJ8wazhfxaKFe2UgltjirEwqf/",
  b"AAAAAUYBMAAAAQIB0Al+EMYjFv1LGVUW0+ZsLAoqFVdZczx9uHePRT/p0AJCvamNI+1dV5wIWbxaTEknneNMyUw=",
  b"AAAAAUYBMAAAAQIB0BH/1EMGIaNJ1CWn3I4X/ijUPk2Q6q+wRgk9maXAPYX8ajXSTe880sB0kkIBx+19kT2JFbrAsieJ+DnYUMg=",
]

///|
/// MP3 frames (first 4 of 13) from:
/// `ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100 -t 0.3
///   -c:a libmp3lame -b:a 64k -write_xing 0 out.mp3`
/// (docker linuxserver/ffmpeg:9.0.2).  MPEG-1 Layer III 44.1 kHz 64 kbit/s,
/// 1152 samples per frame.
let ts_mp3_frame_b64 : Array[Bytes] = [
  b"//tQxAAACixDLlWUgAGBFWYjOtAAB6rDjjOF02TxocEIHFgfXh8YHEYEHonlsy5aD6g7E2vw+GBQFAQDAoJEDE5o0aNsH3iAEAQxOD/BB050+c5fznL+7p93Lg+D4Ph8EAxKAMH9IAEIAAEEABhqOhh7cQgAQxTkZGgxtMo1uIUAgcb7B0p2czA4omYlhMYRhIt7r9bBHQHT4DlEmC1fhah2jCiW/47hhhLiRHr/5ImReLxiXf/y6ZF4vIl0u/xEFQVER7/gqgAAAAR5bze6Ww==",
  b"//tSxASCCHAhLf3RACF/iuFRz9RIWUspMAAFHAAEIGG4O8mrRhmLAXmDgGgEBjAMAgEBTOu/Zc6lWZp1+qhKOHvyrf+tdv9X6v3pxvv//vABBgUEmOiAZ/R5viZGEoh5ZnszrGZ4SHmmEuAqgHFXCBo9QgaARwGgX6BksigKAQWWRQvmiCfb8vKV+6jqBnXuSnW6YvTl3o69Rotq9yvtRb+437p0wZQt7rTt8xf1oTUAkAIqYxHBjgomU0MaUipgtIbkZOQ2RGTDhrxgpQHaaOY=",
  b"//tSxBCCCdwjDs5/YkFCBGHlv+xIRiw+amhG2SpohCJAT8y7i2I5VrhSgl/9f0d4g/v6P362Oazko9t+tdWx+/93NAQkqCgYAMpKTXGI7/dMHMCyjMHVcoy9ILMMHVA+T0KQ2Z2NbaTWMAzAuQ3fynwB9NerL6MuL07iFf1o7bG/8ZT/7acsbsYmM7yOpOUR6brhygDQilRkxeZaiGgO5vPoYJYGKmQfsKpkAgYGYIiBpGyXmVJHGZnf8G7LIGwNZ7E26X36PIflHq3JnXI9Pd8=",
  b"//tSxB6CCdAjEM3/QkEsBGIZv+xI77R99kgcR8m0ZQXtS1f5bQJhIg0oQBmRDhqKedNbGDNhKplbCS2ZUuEsmDPAaB2sWaqymkLRo9SZKTp0RukzBDVlBf0aP9X0VlHfL3ySUI9w29X2fz/XWydVv/6aAFBBjsiGPjKZZUxpymmC+iDhlIkBsZP+IDGCrAkZoKcZQMm0oxw06asSiQc6sus9eddsCzdgo7vf+xleH9ik/ivKSFuj7ldWr+7orRr6P02gEChnJSbozHz9JhEwXYY=",
]

///|
test "ts muxer: HEVC and MP3 stream types round-trip" {
  let video : Array[Bytes] = []
  for b in ts_hevc_au_b64 {
    video.push(@libavutil.av_base64_decode(b, 4096).unwrap())
  }
  let audio : Array[Bytes] = []
  for b in ts_mp3_frame_b64 {
    audio.push(@libavutil.av_base64_decode(b, 512).unwrap())
  }
  assert_eq(video.length(), 3)
  assert_eq(video[0].length(), 3228)
  assert_eq(audio.length(), 4)
  let mux = ts_muxer_new(video_stream_type=0x24, audio_stream_type=0x03)
  for i, au in video {
    mux.write_video(i.to_int64() * 9000L, au)
  }
  // 1152 samples per frame at 44100 Hz in the 90 kHz timebase.
  let audio_pts = [0L, 2351L, 4702L, 7053L]
  for j, fr in audio {
    mux.write_audio(audio_pts[j], fr)
  }
  let bytes = mux.finish()
  assert_eq(bytes.length() % 188, 0)
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.streams.length(), 2)
  assert_eq(demux.streams[0].pid, 0x100)
  assert_eq(demux.streams[0].codec, "hevc")
  assert_eq(demux.streams[0].codec_type, "video")
  assert_eq(demux.streams[1].pid, 0x101)
  assert_eq(demux.streams[1].codec, "mp3")
  assert_eq(demux.streams[1].codec_type, "audio")
  assert_eq(demux.packets.length(), 7)
  let mut vi = 0
  let mut ai = 0
  for packet in demux.packets {
    if packet.pid == 0x100 {
      assert_eq(packet.payload, video[vi])
      assert_eq(packet.pts, vi.to_int64() * 9000L)
      vi = vi + 1
    } else if packet.pid == 0x101 {
      assert_eq(packet.payload, audio[ai])
      assert_eq(packet.pts, audio_pts[ai])
      ai = ai + 1
    }
  }
  assert_eq(vi, 3)
  assert_eq(ai, 4)
  // One PCR per video PES.
  assert_eq(demux.pcrs.length(), 3)
  assert_eq(demux.pcrs[0].pid, 0x100)
  assert_eq(demux.pcrs[0].base, 0L)
}

///|
/// The SDT section is byte-identical to ffmpeg 9.0.2 mpegtsenc for the same
/// service metadata (`-metadata service_name=TestSvc
/// -metadata service_provider=TestProv`), and the demuxer reads it back.
test "ts muxer: SDT service descriptor matches mpegtsenc and round-trips" {
  let mux = ts_muxer_new(service_name="TestSvc", service_provider="TestProv")
  mux.write_video(90000L, b"hello")
  let bytes = mux.finish()
  assert_eq(bytes[0], b'\x47')
  assert_eq(
    (bytes[1].to_int() & 0x1F) * 256 + bytes[2].to_int(),
    0x11,
    msg="SDT is the first table packet",
  )
  let start = 5 // TS header + PSI pointer field
  let sec_len = ((bytes[start + 1].to_int() & 0x0F) << 8) |
    bytes[start + 2].to_int()
  assert_eq(sec_len, 37)
  let expected : Array[Byte] = [
    b'\x42', b'\xf0', b'\x25', b'\x00', b'\x01', b'\xc1', b'\x00', b'\x00', b'\xff',
    b'\x01', b'\xff', b'\x00', b'\x01', b'\xfc', b'\x80', b'\x14', b'\x48', b'\x12',
    b'\x01', b'\x08', b'\x54', b'\x65', b'\x73', b'\x74', b'\x50', b'\x72', b'\x6f',
    b'\x76', b'\x07', b'\x54', b'\x65', b'\x73', b'\x74', b'\x53', b'\x76', b'\x63',
    b'\xfc', b'\xab', b'\xed', b'\xd5',
  ]
  for i in 0..<expected.length() {
    assert_eq(bytes[start + i], expected[i], msg="SDT byte " + i.to_string())
  }
  let demux = av_mpegts_open(bytes).unwrap()
  assert_eq(demux.programs.length(), 1)
  assert_eq(demux.programs[0].service_name, "TestSvc")
  assert_eq(demux.programs[0].service_provider, "TestProv")
  assert_eq(demux.programs[0].service_type, 1)
  // Defaults mirror mpegtsenc: Service01 / FFmpeg.
  let plain = ts_muxer_new()
  plain.write_video(0L, b"x")
  let defaults = av_mpegts_open(plain.finish()).unwrap()
  assert_eq(defaults.programs[0].service_name, "Service01")
  assert_eq(defaults.programs[0].service_provider, "FFmpeg")
}
