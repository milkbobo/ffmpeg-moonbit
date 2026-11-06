///|
/// Differential tests against the in-process FFmpeg oracle. These run
/// native-only inside the ffmpeg-moonbit-ffref docker image (the repo
/// checkout mounted at /work); the wasm host build skips this package
/// entirely, so the 1438-test wasm suite is unaffected.
let playback_ogg_file_b64 : Bytes = b"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" +
  "rQsOAAAAFo5fuwEB/A=="

///|
let playback_pcm_wav_b64 : Bytes = b"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"

///|
test "ffref: binds FFmpeg n9.0.2 libavformat" {
  let v = @ffref.ffref_libavformat_major()
  assert_eq(v, 63)
}

///|
/// Walk every MoonBit-demuxed packet against the oracle's view at the
/// container's own tick resolution: pts rescaled to microseconds by the
/// oracle and inverted back (±1 tick of rescale rounding), plus size,
/// keyframe flag and stream index exactly.
fn ffref_check_packets(data : Bytes, label : String) -> Unit raise {
  let oracle = ffref_probe(data)
  let mf = @avf.MediaFile::open(data)
  let streams = mf.streams()
  assert_eq(
    oracle.timebases.length(),
    streams.length(),
    msg="\{label}: stream count",
  )
  let ours : Array[@avf.MediaPacket] = []
  while true {
    let p = match mf.next_packet() {
      Some(v) => v
      None => break
    }
    ours.push(p)
  }
  if ours.length() != oracle.packets.length() {
    println(
      "\{label}: ours \{ours.length()} vs oracle \{oracle.packets.length()}",
    )
    for i = 0; i < ours.length() && i < 30; i = i + 1 {
      println(
        "  ours[\{i}] stream=\{ours[i].stream_index} size=\{ours[i].data.length()} pts=\{ours[i].pts}",
      )
    }
    for i = 0; i < oracle.packets.length() && i < 30; i = i + 1 {
      let o = oracle.packets[i]
      println(
        "  orac[\{i}] stream=\{o.stream_index} size=\{o.size} pts=\{Repr(o.pts_us)}",
      )
    }
  }
  assert_eq(
    ours.length(),
    oracle.packets.length(),
    msg="\{label}: packet count (ours \{ours.length()}, oracle \{oracle.packets.length()})",
  )
  for idx = 0; idx < ours.length(); idx = idx + 1 {
    let p = ours[idx]
    let o = oracle.packets[idx]
    assert_true(
      p.stream_index == o.stream_index,
      msg="\{label}: stream at \{idx}",
    )
    assert_eq(p.data.length(), o.size, msg="\{label}: size at \{idx}")
    assert_eq(p.keyframe, o.keyframe, msg="\{label}: keyframe at \{idx}")
    let (num, den) = oracle.timebases[o.stream_index]
    match o.pts_us {
      Some(us) => {
        // Oracle: us = round(tick * num / den * 1e6). Invert and allow one
        // tick of rounding either way.
        let expect = (us * den.to_int64() + num.to_int64() * 500000L) /
          (num.to_int64() * 1000000L)
        let diff = (p.pts - expect).abs()
        assert_true(
          diff <= 1L,
          msg="\{label}: pts at \{idx}: \{p.pts} vs \{expect}",
        )
      }
      None => fail("\{label}: oracle has no pts at \{idx}")
    }
  }
}

///|
test "ffref: packet oracle matches the MoonBit Ogg demux and pts" {
  let data = @libavutil.av_base64_decode(playback_ogg_file_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "ogg")
}

///|
test "ffref: packet oracle matches the MoonBit WAV packetiser" {
  let data = @libavutil.av_base64_decode(playback_pcm_wav_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "wav")
}

///|
/// Locate the PCM payload of a RIFF/WAVE blob (the `data` chunk body).
fn ffref_wav_pcm(wav : Bytes) -> Bytes raise {
  for i = 0; i + 8 <= wav.length(); i = i + 1 {
    if wav[i] == b'd' &&
      wav[i + 1] == b'a' &&
      wav[i + 2] == b't' &&
      wav[i + 3] == b'a' {
      return wav[i + 8:wav.length()].to_owned()
    }
  }
  fail("no data chunk in wav")
}

///|
test "ffref: decode oracle matches decode_audio_file on Opus" {
  let data = @libavutil.av_base64_decode(playback_ogg_file_b64, 1 << 20).unwrap()
  let oracle = ffref_decode_audio(data)
  assert_eq(oracle.sample_rate, 48000)
  assert_eq(oracle.channels, 2)
  let audio = @avf.decode_audio_file(data)
  assert_eq(audio.sample_rate(), 48000)
  assert_eq(audio.channels(), 2)
  assert_eq(oracle.samples_per_channel, audio.samples()[0].length())
  // Per-sample compare: the oracle converts planar float to packed s16
  // without dither, so our float pipeline may only differ by rounding.
  let ours = ffref_wav_pcm(audio.to_wav_s16())
  assert_eq(ours.length(), oracle.pcm_s16le.length())
  let mut worst = 0
  for i = 0; i < ours.length() / 2; i = i + 1 {
    let a = ours[i * 2].to_int() | (ours[i * 2 + 1].to_int() << 8)
    let a = if a >= 0x8000 { a - 0x10000 } else { a }
    let b = oracle.pcm_s16le[i * 2].to_int() |
      (oracle.pcm_s16le[i * 2 + 1].to_int() << 8)
    let b = if b >= 0x8000 { b - 0x10000 } else { b }
    let d = (a - b).abs()
    if d > worst {
      worst = d
    }
  }
  assert_true(worst <= 1, msg="opus PCM diverged by \{worst}")
}

///|
/// A real H.264+AAC Matroska (the same fixture libavformat's playback
/// tests pin): 32x32, one IDR frame.

///|
let playback_real_mkv_b64 : Bytes = b"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"

///|
test "ffref: video oracle matches VideoDecoder frame YUV on H.264" {
  let data = @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 20).unwrap()
  let oracle = @ffref.ffref_decode_video(data)
  assert_true(oracle.frames().length() > 0)
  // The fixture is High 4:4:4 Predictive: FFmpeg reports yuv444p.
  assert_eq(oracle.chroma_mode(), 2)
  // Our side: open, decode every packet of the first video stream, flush.
  let mf = @avf.MediaFile::open(data)
  let mut video = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if video < 0 && mf.streams()[i].media_type == @avf.MediaType::Video {
      video = i
    }
  }
  assert_true(video >= 0)
  let dec = @avf.VideoDecoder::open(mf.streams()[video])
  assert_eq(dec.width(), oracle.width())
  assert_eq(dec.height(), oracle.height())
  let ours : Array[Bytes] = []
  while true {
    let pkt = match mf.next_packet() {
      Some(p) => p
      None => break
    }
    if pkt.stream_index != video {
      continue
    }
    for f in dec.decode(pkt) {
      ours.push(f.yuv_bytes())
    }
  }
  for f in dec.finish_video() {
    ours.push(f.yuv_bytes())
  }
  assert_eq(ours.length(), oracle.frames().length())
  for i = 0; i < ours.length(); i = i + 1 {
    assert_eq(ours[i], oracle.frames()[i], msg="frame \{i} YUV differs")
  }
}

///|
/// End-to-end video fixtures for the oracle (same bytes as libavformat's
/// playback e2e test): 64x64 yuv420p, 5 frames each.

///|
let e2e_hevc_mkv_b64 : Bytes = b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAAabxFNm3TAv4SxFgiyTbuLU6uEFUmpZlOsgaFN" +
  "u4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIK5E27jFOrhBxTu2tTrIIaQOwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hBzWdeUq17GDD0JATYCM" +
  "TGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQJ7rA5UGSnLr0l+C8bA0am0SJiEB/QAAAAAAAFlSua0nvv4RW54cSrgEAAAAAAAng" +
  "14EBc8WIgRD/AEhJVsmcgQAitZyDdW5kiIEAhpBWX01QRUdIL0lTTy9IRVZDg4EBI+ODhAX14QDgkLCBQLqBQJqBAlWwhFW5gQFV7oEA" +
  "7AEAAAAAAAACAABjokmDAQFgAAAAkAAAAAAAHvAA/P34+AAADwQgAAEAGEABDAH//wFgAAADAJAAAAMAAAMAHpWUCSEAAQAoQgEBAWAA" +
  "AAMAkAAAAwAAAwAeoCCBBZZWVKTC8BaAgAAAAwCAAAAFBCIAAQAGRAHAc8CJJwABCRJOAQX///////////8NLKLeCbUXR9u7VaT+f8L8" +
  "TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltMaW51eF1bR0NDIDE1LjIuMF1bNjQgYml0XSA4Yml0KzEwYml0KzEyYml0" +
  "IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIEluYyAtIGh0dHA6Ly94MjY1" +
  "Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTExMTEwMzkgZnJhbWUtdGhyZWFkcz0xIG5vLXdwcCBuby1wbW9kZSBuby1wbWUgbm8tcHNuciBu" +
  "by1zc2ltIGxvZy1sZXZlbD0tMSBiaXRkZXB0aD04IGlucHV0LWNzcD0xIGZwcz0xMC8xIGlucHV0LXJlcz02NHg2NCBpbnRlcmxhY2U9" +
  "MCB0b3RhbC1mcmFtZXM9MCBsZXZlbC1pZGM9MCBoaWdoLXRpZXI9MSB1aGQtYmQ9MCByZWY9MSBuby1hbGxvdy1ub24tY29uZm9ybWFu" +
  "Y2Ugbm8tcmVwZWF0LWhlYWRlcnMgYW5uZXhiIG5vLWF1ZCBuby1lb2Igbm8tZW9zIG5vLWhyZCBpbmZvIGhhc2g9MCB0ZW1wb3JhbC1s" +
  "YXllcnM9MCBvcGVuLWdvcCBtaW4ta2V5aW50PTEga2V5aW50PTMgZ29wLWxvb2thaGVhZD0wIGJmcmFtZXM9MyBiLWFkYXB0PTAgYi1w" +
  "eXJhbWlkIGJmcmFtZS1iaWFzPTAgcmMtbG9va2FoZWFkPTUgbG9va2FoZWFkLXNsaWNlcz0wIHNjZW5lY3V0PTAgbm8taGlzdC1zY2Vu" +
  "ZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMyIG1pbi1jdS1zaXplPTE2IG5vLXJlY3Qgbm8tYW1wIG1h" +
  "eC10dS1zaXplPTMyIHR1LWludGVyLWRlcHRoPTEgdHUtaW50cmEtZGVwdGg9MSBsaW1pdC10dT0wIHJkb3EtbGV2ZWw9MCBkeW5hbWlj" +
  "LXJkPTAuMDAgbm8tc3NpbS1yZCBuby1zaWduaGlkZSBuby10c2tpcCBuci1pbnRyYT0wIG5yLWludGVyPTAgbm8tY29uc3RyYWluZWQt" +
  "aW50cmEgc3Ryb25nLWludHJhLXNtb290aGluZyBtYXgtbWVyZ2U9MiBsaW1pdC1yZWZzPTAgbm8tbGltaXQtbW9kZXMgbWU9MCBzdWJt" +
  "ZT0wIG1lcmFuZ2U9NTcgdGVtcG9yYWwtbXZwIG5vLWZyYW1lLWR1cCBuby1obWUgbm8td2VpZ2h0cCBuby13ZWlnaHRiIG5vLWFuYWx5" +
  "emUtc3JjLXBpY3MgZGVibG9jaz0wOjAgbm8tc2FvIG5vLXNhby1ub24tZGVibG9jayByZD0yIHNlbGVjdGl2ZS1zYW89MCBlYXJseS1z" +
  "a2lwIHJza2lwIGZhc3QtaW50cmEgbm8tdHNraXAtZmFzdCBuby1jdS1sb3NzbGVzcyBuby1iLWludHJhIG5vLXNwbGl0cmQtc2tpcCBy" +
  "ZHBlbmFsdHk9MCBwc3ktcmQ9Mi4wMCBwc3ktcmRvcT0wLjAwIG5vLXJkLXJlZmluZSBuby1sb3NzbGVzcyBjYnFwb2Zmcz0wIGNycXBv" +
  "ZmZzPTAgcmM9Y3JmIGNyZj0yOC4wIHFjb21wPTAuNjAgcXBzdGVwPTQgc3RhdHMtd3JpdGU9MCBzdGF0cy1yZWFkPTAgaXByYXRpbz0x" +
  "LjQwIHBicmF0aW89MS4zMCBhcS1tb2RlPTEgYXEtc3RyZW5ndGg9MC4wMCBjdXRyZWUgem9uZS1jb3VudD0wIG5vLXN0cmljdC1jYnIg" +
  "cWctc2l6ZT0zMiBuby1yYy1ncmFpbiBxcG1heD02OSBxcG1pbj0wIG5vLWNvbnN0LXZidiBzYXI9MSBvdmVyc2Nhbj0wIHZpZGVvZm9y" +
  "bWF0PTUgcmFuZ2U9MCBjb2xvcnByaW09MiB0cmFuc2Zlcj0yIGNvbG9ybWF0cml4PTIgY2hyb21hbG9jPTAgZGlzcGxheS13aW5kb3c9" +
  "MCBjbGw9MCwwIG1pbi1sdW1hPTAgbWF4LWx1bWE9MjU1IGxvZzItbWF4LXBvYy1sc2I9OCB2dWktdGltaW5nLWluZm8gdnVpLWhyZC1p" +
  "bmZvIHNsaWNlcz0xIG5vLW9wdC1xcC1wcHMgbm8tb3B0LXJlZi1saXN0LWxlbmd0aC1wcHMgbm8tbXVsdGktcGFzcy1vcHQtcnBzIHNj" +
  "ZW5lY3V0LWJpYXM9MC4wNSBuby1vcHQtY3UtZGVsdGEtcXAgbm8tYXEtbW90aW9uIG5vLWhkcjEwIG5vLWhkcjEwLW9wdCBuby1kaGRy" +
  "MTAtb3B0IG5vLWlkci1yZWNvdmVyeS1zZWkgYW5hbHlzaXMtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1zYXZlLXJldXNlLWxldmVsPTAg" +
  "YW5hbHlzaXMtbG9hZC1yZXVzZS1sZXZlbD0wIHNjYWxlLWZhY3Rvcj0wIHJlZmluZS1pbnRyYT0wIHJlZmluZS1pbnRlcj0wIHJlZmlu" +
  "ZS1tdj0xIHJlZmluZS1jdHUtZGlzdG9ydGlvbj0wIG5vLWxpbWl0LXNhbyBjdHUtaW5mbz0wIG5vLWxvd3Bhc3MtZGN0IHJlZmluZS1h" +
  "bmFseXNpcy10eXBlPTAgY29weS1waWM9MSBtYXgtYXVzaXplLWZhY3Rvcj0xLjAgbm8tZHluYW1pYy1yZWZpbmUgbm8tc2luZ2xlLXNl" +
  "aSBuby1oZXZjLWFxIG5vLXN2dCBuby1maWVsZCBxcC1hZGFwdGF0aW9uLXJhbmdlPTEuMDAgc2NlbmVjdXQtYXdhcmUtcXA9MGNvbmZv" +
  "cm1hbmNlLXdpbmRvdy1vZmZzZXRzIHJpZ2h0PTAgYm90dG9tPTAgZGVjb2Rlci1tYXgtcmF0ZT0wIG5vLXZidi1saXZlLW11bHRpLXBh" +
  "c3Mgbm8tbWNzdGYgbm8tc2JyYyBuby1mcmFtZS1yY4ASVMNnQIG/hC3nLxBzc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAy" +
  "c3PWY8CLY8WIgRD/AEhJVslnyKFFo4dFTkNPREVSRIeUTGF2YzYzLjEuMTAyIGxpYngyNjVnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAw" +
  "LjUwMDAwMDAwMAAfQ7Z1Ts+/hGVXBHzngQCjRVuBAACAAAAFUygBrEaYA3XI2tTRsQeaFv4IkyhdOaac+M1HpWbEkWOfScrrCkQD/axw" +
  "uSvqa3SW55B/La08Fli4wVaDAPs8Ef4d+4XkO8a5APJelzGzhEL7tB8Q595uB8QALACWaKkIGb2///rV5Is+J7vZjU/sVL0xZU2FJetu" +
  "WQMB4eoQkv/q2A3hdBi5Dkdbm+gMxIReVKIXuRp84o2Py+91ck+tkJifPXpjJL8JoyFLO3YJHRnrWF7IZMzj73Xuv9S9G1jvAfcl3/Gb" +
  "0p5gjAWzxuhUtdG7g4GimitsXetluBTHXFkb5IVugjErAeWs4kPtXbygcNaPLaQXd+m1WFAjPJZL8c+KwoEqZD00tVy2au8zDIntkAiO" +
  "dXYs2DoW+FBiiuF5d8Dm/I+6e/BWtAnHOQvtLr0GkqELxBUaGkTLVJoRVbqOX2zOH7PSga39Rk0+Orp9Oje3C1hxNUC66+FfRD2wJbmk" +
  "3XCdJ2+tMYpeFatRlk08ITHbLFEvr4SAfM7hkPfh3pmuyVKrOoYX0T4P/Yc+HdOM+1lqjcjbYv6PSj9jq4nRR2Smhexf5Qq5aJ/+rBA4" +
  "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"

///|
let e2e_vp9_webm_b64 : Bytes = b"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"

///|
let e2e_av1_mkv_b64 : Bytes = b"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"

///|
fn ffref_e2e_diff(b64 : Bytes, name : String) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 1 << 20).unwrap()
  let oracle = @ffref.ffref_decode_video(data)
  assert_eq(oracle.frames().length(), 5, msg="\{name}: oracle frames")
  assert_eq(oracle.chroma_mode(), 0, msg="\{name}: chroma")
  let mf = @avf.MediaFile::open(data)
  let mut video = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if video < 0 && mf.streams()[i].media_type == @avf.MediaType::Video {
      video = i
    }
  }
  assert_true(video >= 0, msg="\{name}: video stream")
  let dec = @avf.VideoDecoder::open(mf.streams()[video])
  assert_eq(dec.width(), oracle.width(), msg="\{name}: width")
  assert_eq(dec.height(), oracle.height(), msg="\{name}: height")
  let ours : Array[Bytes] = []
  while true {
    let pkt = match mf.next_packet() {
      Some(p) => p
      None => break
    }
    if pkt.stream_index != video {
      continue
    }
    for f in dec.decode(pkt) {
      ours.push(f.yuv_bytes())
    }
  }
  for f in dec.finish_video() {
    ours.push(f.yuv_bytes())
  }
  assert_eq(ours.length(), oracle.frames().length(), msg="\{name}: frames")
  for i = 0; i < ours.length(); i = i + 1 {
    assert_eq(ours[i], oracle.frames()[i], msg="\{name}: frame \{i} YUV")
  }
}

///|
test "ffref: HEVC real stream matches the oracle byte-for-byte" {
  ffref_e2e_diff(e2e_hevc_mkv_b64, "hevc")
}

///|
test "ffref: VP9 real stream matches the oracle byte-for-byte" {
  ffref_e2e_diff(e2e_vp9_webm_b64, "vp9")
}

///|
test "ffref: AV1 real stream matches the oracle byte-for-byte" {
  ffref_e2e_diff(e2e_av1_mkv_b64, "av1")
}

// ffref-fixture-section

///|
let ffref_mp3_file_b64 : Bytes = b"//uQZAAAAmsLzp1gYAAAAA0goAABFmVFGBnqAAAAADSDAAAACmtt2MISzaANv00DAY1MNRggDB3ba21933/jcvtiEAAAABAMDwfB" +
  b"98oCBzE4P8EHTnT7uX85y/nOn3cuD4Pg+HwQDFQDB/Jggcy/gh0mLOU0YyPFhgZBDGP7aAYLwChk4oXG58XKYNIWhzjDAEIHJ3tB" +
  b"6EgJJiFhQGEuE8EBFQsHAJVwM5HA4TsyP4G4hgYU0BnTCKPgZlAAYJAxQkDED1U/hYkAECAwIQNlBuFf/BtUP2DFQWhCkQ1bqq/h" +
  b"kUY4QWEFhyRQIoFrv1deQ4XMLmIaMyOaUhzhzttD2v8okVIqXiLEWMSdLpkXmt1f/tl5ZdCQNCVwNrf+362QL////rVgDALAFUwD" +
  b"ABVMDUA+TAHANYwGUEsM7VckzLqBuEw44JFMGyBNTAxQP4wOUDeMD5AvDASQEB5pG7tnTPR/Rre/KcORUfaJAix3DYeaOyrgCmLK" +
  b"KP1ElrtZQfao+LaBdJVqhW5DWGyJN1pi2l7W36ToivJueWlUmAAgApgG//uSZD4P87EVQw98QAAAAA0g4AABDsBVDA/sZsgAADSA" +
  b"AAAEABoYDWA8mBrAhRhAoaiZsEzlmaYhqZhBwJQffgm9xJtzwbbsmfnJdB35RT2Ef5n8KCimnyMgNz98q+Ds99/ihtet9pNeuvQp" +
  b"/L/r1PEYvu/9Zay+d7f2+nXGX9ZzT96ZN+Nenqr2+2NP/pX3vt3vC6pwDAPQEQwEQBfMBhAnjArAT8waEPwMsoe6jK3Q9owXwERN" +
  b"VPjHCc2FQOArTUisODnVl1n38r0v8Lf+EVQGIvDO3U27Xnkd6DmkABMYvHCqB6LltlGzCUMZF9AteLIVgg5c81gSWrYoTJr4Zc5C" +
  b"bk2A+oCLuVVIgwEwETA2A4MHcI0xLh2jgr64N/gdwxNQnzhGQzxGMzPzMngxYWWvLA5Dr029O+10USXEFdLrmOLh0vzgtvP2emMv" +
  b"W5vnNqqW35a6VvUeT9XuRRIuOzCqTEFNRTQuMKqqqqqqqqqqqqqqqqqqqqqqqqqqqgAAADC3KqmPEpkZwZsymz6hgggViY5yqsmO" +
  b"DBUJgdoFoBqE4P/7kmSGiPOKIkML+xmwAAANIAAAAQtoVxUvbEaAAAA0gAAABGPGAbpSB0cwGvIBhUiRq/d1VttT99BBNz1TQ4Cw" +
  b"ZFwpa8WDLSGKLKtjFibzxXI44+xIXXll+1zro171om9fb7K7yrHi5gIIBCYFgBNGCjgnphLQUUYrSPjnGXdsJxLI+iYr4FvHRMAm" +
  b"qrDmlSzGkcxmW5gmEgJIS2cO3DiBrJyxJjZmWAUnFVT2vq7CQRlGEdhFU1acWt1GmpjHXgUOJx9VKnpKMuzKxA5Y3araJSCTKW9K" +
  b"tm3iuQJ0qVY9ZKvjJhNiKOCK+kyvT555XRSyBOHzce3zjUOT4gjkLVvwxk6iUjQpZgWucoy3VpxRSVqEMXxDe1O0ba85J5SSIVVM" +
  b"QU1FNC4wVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUwIsCgMCUA2zAxQVgwUgKbMLzH+jTxvco0z8fQMKsC" +
  b"STS6wM0Es3KoDj1JNgGEDFJJFtpb9QRMnPnyOm3zGy6ko4azxd1B8ra2a2/S7s5TEHd+a0P/+5Jk0QjzQxZE43+gkAAADSAAAAEX" +
  b"Aaz+D/UmyAAANIAAAAS1p8vJYqikEuddxrXHxo3/345mUUm6Mv8bsh8n9eEupFpqH7f+k9QmzHatjOYjCdTqPaF/stGPtbD1hjvT" +
  b"qx7vPvtqLii9xMRoYYCQAKGBcgSJgpwJYYTOE3mLBDuBx7fGYcYAO/GLJhZJ0c/RqgxBpCtpopNxlYYRhGCaEhlb+Q2DmSZGFXt2" +
  b"sMuqs8pLywEQVjEHu/W1FFYzM5BDJMRNtNGmPzRa5JYowoTx7oYSlCnXsOL1FdKI0Ic/SSWo5b62FRIWdNRwQlcYcVZPDNNPcbGI" +
  b"jm17Xhy0UC2YSagyRSSOJH/19Mg6bx0LSRMVDl1diYTLBTeQTywkn1wqTEFNRTQuMKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqAACoyNEkkwC4A5MAzAVDARgJEwH8EmME4DqzIl3MkyFwOXMEZBAjVSTSjDuNT7/jlmhYLAxl" +
  b"+dWo593p7Z/3e78bWRjTvup+E0SI//uSZOkP9O1pwIP8MbIAAA0gAAABFlGu/g/0xsAAADSAAAAEwtSnh6h4xty7Ft03w3dL/kML" +
  b"K4KN7u151DkR5u1jVPxp/zPo+qzp1l7XQWM9Uikda/4fyn35yVFXya9qgwF8ANMDeAmjBiQUcws4KmMZnIFzpjvaU6JEgrMZ0DEj" +
  b"vGPTX1xzUBqjTG1TL85zCgGi26wjW38QL1T8gvE65kKteaK8UcQqDWxpRnU5UbjOToRJ+hkt3wLrumlCKcplFzTVOQQJyBAft6DE" +
  b"DGGtx6l9RXpxXEqKElZJIGijE7SXQyQU14KyTp5T4nGlUjS8Ovkm3wKoUmDbl9LbrcJNdlEhlBI7c3sr3uM9JqSriVLF5KyKxzHR" +
  b"1hLJJ5FcqSyRVUxBTUU0LjBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUZAAMBzAijAdgMEwJkE2ME" +
  b"ACWzCUxz4z7zgoM9PHGjCEAhkyusjNQlNonY4FATVhHBxGT5AkHr5zDx21/WIU6VlosjA6C8xAlejxxQnVNJ+//7kmTkiPQ8I0PT" +
  b"+kmiAAANIAAAARf1sPwP9SbIAAA0gAAABBWi4gSjWrS4tL0qHS3fIWohbn1iKU6uESIqj5xs8c8cn1X44gp1vpkuxvoqOQtzEb9y" +
  b"dVDDYkdJcqnMHXVzv3VMjzW1TGQlD2zVg+ihepBSCAJQwKsBlMEuA5jCLQekxPwXkOCHtDjfvhfQxQUJDOQGsNGlYM6VFM1owMgi" +
  b"uMFQPSEcuGI3bllvPV7G/y7nnJcnS7LzxBwdddB/Agz3KOINruSKMQLXNpY/N9nKFHNDlo6s4ti8xmnx6yrrE0Von7iJZDKjGQZm" +
  b"GPJWcfDos94TyeQL6p0pPMWzwySSc/rZJl511txkw5jzV/XpGClXQFT7WIIgpeE3rTTIJBVMQU1FNC4wVVVVVVVVVVVVVVVVVVVV" +
  b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUwHACLMBxAwjAkATswPEJkMIuHXTO4eQMznoc5MHtCJDAQAL0wHMAWA2sbQODvADV5" +
  b"AAUIob8NErIKuzL2WfWUKF30TczUW7d9Ig0w6zS6XUH/+5Jk5wn09mnBE/xBogAADSAAAAEVsakAr/THiAAANIAAAAQLxZNHiPwJ" +
  b"rD1BcBhVRunMGoxM4TcGSFvGczSOyG2k+HTfs+ZHmtJPRQxmRyQrWG4DGYjAHp2pmcc3cGF8vcEUM79FZFkBvITAX5gZQDUYLGB8" +
  b"mFDBCBi44y2csxg3nJYjN5i5wT4YUuDxmChgx5oAvhnXRpkeZ5gwCSGbKHDjFSX2MK/KHL8cqWG72srWeGOeOVPB+XaRhpo2SmT2" +
  b"R+Ei16k5UnbDsZjysM5UDSaA8xbELRhTqndys3KpjBWmUOm2rCcaSt4XvbKLMjTd5suuQWY5TPNOKKsgOc6Cg9kvhezFH0UlrEZP" +
  b"nLbIa2ciY7P1vG8giUosrC58Fut1TEFNRTQuMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVUwG8CKMBsAxTAi" +
  b"QT4wOAJvMILHeDN/ucwzZsdUMHICMTFLIM9Ac22YjhjhNZDsIIyfLrRXM1pNxv+/6DPuc7PtWOZtLacKK1+9y/9e/zoTzvmu27ZU" +
  b"//uSZOeP9MNrwQP1GnIAAA0gAAABFqWy/g/0ycAAADSAAAAEbjQ/i+7zVu/qLqcaLt75pWWa+73371X//RzOvHo7GyLqG1A6Wp39" +
  b"n9r8ulkqdqZu6OPl/FfYebmc8tDc29PSM2mnDNByghBAGaYGiAumC0AcxhR4PeYu0L6HML2tRylQwcYu6EwnTDtGnjHGeq/mbVLG" +
  b"QRpGCoKo2MrdiGydXqvZTY2H0/deL93UoEZO67QfLbY81po0qWUSTJlMLMJWibhkZ6w/oFotKIpPmiLnfG7lkIIPhhKaJorq/tFA" +
  b"4w0u1aCpzJk1a2h3FUNytZfH2aZl5RerHumwpfcwl8S7MtjkGYzyctig34xKU4tPaZk6bsfT3wIfaAUbKTNqtkxBTUU0LjCqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqMBsAiTAaQMYwH4FDMDRCdjB5h5EzRPqFMy0HbzBoQjwwY1QyDG4CucRZxrUbBhJU" +
  b"k8tHhq7rv7w/urfzuabewMODH4VzdVGum0pm3DCjAnWUtD65UoUDFtHaQP/7kmTpifTTakED/DGyAAANIAAAARbxqv6v9SbIAAA0" +
  b"gAAABETbw83JyERAb5o7MaEGXXT96pzz+mHpsebcDtc1U4ynAc0YUsYKKIG+WhM9RAoP+9R6tB5QTiMgeQwIEAKMD2AXjBpwPUwv" +
  b"gIQMbDGVzr5sC06tcZ3MbCCljvuFzWVyzQxvjO2/zI09zBYHi965G5xAgWTJzsWzPWaQgNO4NajRQSaAfYx1l0FnDsYRYXs0qyUV" +
  b"m1I6cWnkrbxM6ofYSUQqNEKJ8l2UbTMutLqzbTak1pddlSGNJn5F0k4GnymhV8JxQFEDSN1ujamqM1yq9ulaq5VQmkS+zcmZzOv6" +
  b"uEjShEgVabnDGJZkEE0c2JM1J6UIYszROtONp7qTTc5MQU1FNC4wqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqMBrAijAYgMkwHcFG" +
  b"MC+CfzBwR6YzBzssMvFHhDBeAkchcAtEDcpMOKL81sMQ4nKhe6Q2waPtELI8BqXIh5sHGW0HGNwR5y2+uvQpid3NVY9HhrTAIQ54" +
  b"eyaMxGpmii5XSgL/+5Jk7I/0omjBA/wZ4gAADSAAAAEYcbL8D/UmwAAANIAAAARktPLemTObnqcjHGDLTjsrkwpSLu7DOJlBiXyh" +
  b"E7JDYjfx/JoiENJWbNCUUjFRiEwsjAngCMwSUBfMHqBADDbwi0x8oauPKJypDxThtYx8cLRPaJYNkoONJ4DM/N2MlEiMHQnCgALT" +
  b"cCGxWMTIJuSXccMLApK8QtVTD1C5I9hdBSOhl/UtA5FiSczJpyNCbOMpbPabWKniukSuNsEh9dUQQerOrhBQq3EoUmSsnGl4azIi" +
  b"JF5MplvqAEcXt9iZtWLaqRZeKiRCw0TvREpmK9waWTJMaOa4hmafqa6NHnZnFOxRKTaJSRFrCZ9mD0OuNpmFTRCpTYTiiLN8+WmO" +
  b"TEFNRTQuMKowGgCJMBdAyDAagUkwK0KEMGYHuzLG+8EysoebMFNCUDBLpNIgM3QQTi6qNdioOJqZzyyfCJ6uaiRiwE7q1R8jho0R" +
  b"K660csdMX3FmI/bFCxCqvcpEssWOV7KWVimiZaqb5qSYx9w6SqdTNmFPLK31VLa/PWhi3pyd//uSZPAP9JppwQP8GbIAAA0gAAAB" +
  b"GXmw+g/1JsgAADSAAAAE4wkb20K7KkwP6Q2IsQ6sh4XeGdJui7viFpoZRs33pUqRZgYIB0YKsAsGEdghZh+wSQZHyN8n0LaVp8V4" +
  b"5aZHcGFGHyhT5g4oS2afSkaF/+ZOqiYOBcFQHVUZHADkR+UWZnGVX+02VVyK3NX8sqXKatS9oH21XIS6a5IyhkfVbE0dI3JtJB4b" +
  b"XmrXKo10ZCOH5B6iVCUJicjJiKIuq81FAwrZIMLS2YwKVVEAsS0J0RslpKTWrDWRYlInREjSxtQgZSDMC0pQLIFBQco4xZETSNJg" +
  b"uuUcJMVH5NTDUECwXIlm5498eymjYcjPaa1KaTa7Y+eKipCdI+wy5aCNukxBTUU0LjCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqjAZQIgwFgDLMBjBTDAmgoswW8fMMoQ8RDJxR6wwSAJZMTPI0wEjdo0ONJk10JQ4pJwvnJrbngmmfM3h08KVTMS3QfkF" +
  b"Y4l+83E2AlSuxNmZVRx+KKisUR4VPv/7kmT7j/TTa8ED/EGwAAANIAAAARtlsvgP9SnAAAA0gAAABCpM0oRQhRjJkMyM++FI38IF" +
  b"gRUZAX4es8ZxZKcTMILJGwRoaSmTpDU3fMYiU3diG6hsYKmgoLXLIGDIgYEoAZmCEgFZg2gFcYYeDImN5CaR2kMkYdgMJ/GNzhFp" +
  b"3w+Rqc5BnC45llihjEfxgaD6CBkb6Q2TiV7UYQW3TCwtH0y+Nto6DwRxpNTpRQE9QtdJaMFM3VXtGKMoEEoSR6RP7ZFUXRFGpKE5" +
  b"ySaWQnKDRjTSiUW0oLug0uiJO5qyZNZMilNPKQpr9SpyTxVdKTz+KyYjTTaNFNV6HaYuDDGVSCCVICTYYSVGGoKzW3NxVgW3H62g" +
  b"RqsXES2ikt2KVWowSACcMBMAGjBDQnswx0M/MU7JqTGI+XszcIXVMNJBfzBwwSMwLEEJMCRAzzA0wOAwLMAKMA2AEAEAAKQp7/7e" +
  b"3e26LDkGdX+co0pHc35j4eprz/1ez7dzdn/u7Q0tXxoxp/eG7lO+M2NGPmm36zsz4zSQZLc2u9606/87kWd75ez/+5Jk7A/0rWrB" +
  b"A/wZsgAADSAAAAEYHbD8D/UmyAAANIAAAARr8uv7XdFt89fyWlTdc4djd837lZR+/9pN7zj4z+47UkjOAAIgQAUKAAAAYFISpj5X" +
  b"EmGOCmZPyTJlvEcmfS3scyoxI4Bod4Ie5EJGbZaRRhridBgRsOGBkCIYIwCRh+gCmFkA/WAEUAbBYGdkSDQrbBb4BgIBBa6Bi8eg" +
  b"DD4DFQZ1QvuFj4pAdgGAw0AKFgBguA0HPiijDE6BtguwMRCMDAIgAFD4XBgHCnbUMmJ/Iospl4G2wBIEC18G5gN4QbrUns0nCIFM" +
  b"3K5omIqN0VAW4PiF+ISa+9ZfSNCcTd2THaLKGNGNHAO8XMOSOj/3N1IGidSKZuouDuIqOSQwg5BiAkoWCXtr/62Z1IUz6DLsaSqQ" +
  b"ElCLmxFSaKRPlQipSKaZVb////u7f///y8TRmTlMQU1FNC4wVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
  b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV//uSZP+ABRdrwQV8wAIAAA0goAABIaIRGTnqgAAAADSDAAAAVVVVVVVV" +
  b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV" +
  b"VVVVVVVVVVVVVVVVVVVVVVVVVVVVVQBMOyOnoPnyPTYOCkDA5kEZrmZsGJlyCFyAkwQcxAcHBWQGDGGTJAFJAgFoG8WJfG6EdDBW" +
  b"xuhqSWvE8opTlQ5XM13sVuOYnSpblczRqvVay3YVbFw+3BYX1vWuoTErosJ9G3WtdZrXWLeC9t6117Qn2gaPBpQKuiUFhKdUDRYO" +
  b"1AzrBUeGuRxE7KnRK75YOcFVnc7xEkxBTUU0LjCqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qv/7kmSLj/StMkGPaeAAAAANIOAAAQAAAaQAAAAgAAA0gAAABKqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq" +
  b"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="

///|
let ffref_av_ts_b64 : Bytes = b"R0AREABC8CUAAcEAAP8B/wAB/IAUSBIBBkZGbXBlZwlTZXJ2aWNlMDF3fEPK////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//////////////////////////////////////////////////9HQAAQAACwDQABwQAAAAHwACqxBLL/////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/0dQABAAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////R0EAMAdQAAB/IX4AAAAB4AAAgIAFIQAH6LUAAAABCfAAAAAB" +
  b"Z0LACtolsBEAAAMAAQAAAwAUDxImoAAAAAFozg/IAAABBgX//z/cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IC0gSC4y" +
  b"NjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRt" +
  b"bCBHAQARLSBvcHRpb25zOiBjYWJhYz0wIHJlZj0xIGRlYmxvY2s9MDowOjAgYW5hbHlzZT0wOjAgbWU9ZGlhIHN1Ym1lPTAgcHN5" +
  b"PTEgcHN5X3JkPTEuMDA6MC4wMCBtaXhlZF9yZWY9MCBtZV9yYW5nZT0xNiBjaHJvbWFfbWU9MSB0cmVsbGlzPTAgOHg4ZGN0PTAg" +
  b"Y3FtPTAgZGVhZHpvbmU9MjEsMTEgZmFzdF9wc2tpcD0xIGNocm9tYUcBABJfcXBfb2Zmc2V0PTAgdGhyZWFkcz0xIGxvb2thaGVh" +
  b"ZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBj" +
  b"b25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTQga2V5aW50X21pbj0xIHNjZW5lY3V0PTAgaW50" +
  b"cmFfRwEAE3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3Rl" +
  b"cD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAABZYiEOgxgAIaAQDyw3rypgC0gyFtUJ8ACmyImN+hkdwAHQZRHMSaalwryquBM0Sfq" +
  b"C6ab+zAe/wbh78IAAEAAADAFSw9gAAoAHNMBRsDo+eAyAABALAAEAcBHAQAUD7n4RAAEAEAAQGQAEBAACAkBAHyACZM8yAKBf+f2" +
  b"sgA4uVwDg99QgQVgsIKwABZOHUREYUSB9xaF+0ULFcH8vw9F8g8IAAVAAEARgQAAqAAIAjAYwA4GEADyITQIyRIJim4EYD9f+DgA" +
  b"CACABwC5YCQFblD4hy/pxiYWnNIbu0GBGZkaG3Q6M+ABgpmu1KHgd8Ua/t4YIQAAgACBKamMkDJoN77vhQABAWAAEBkAAQ6wgABA" +
  b"IA4AkkcBABVa81AAo0SgGBDKtRlpsAUDTthAgrBYQVjcEDIDoN4egsYdxsDDPqkwhQCZjcwgABUAAQBGBAACoAAgCMBZwAcYMIHp" +
  b"8jqHQvThElwynH4APBEAC6keaIJPK+r3+QAAIAgAAgDAZcKgD7gB0QBOAEAKy8WDxcBMHuUgnXWij2X+JAA3Cx4lmhaagnK38JAA" +
  b"LWgGBkdgQAgACBQoABIQAAgolAAEDhCqWUaWAOXqDTGAcGL1yxGchUCARwEANg8A//////////////////8llfy2WqlgCmHMoegy" +
  b"ZyInv+xMCchnMJCgWXP+CzgAIACAqQZZIG4W70mDpKtm3V/AB7CDNQPVIGHzfq8DwABACYBgB1wcIDYgONt3gDHYGmsUBxNCcAG4" +
  b"edDcBQmOUAd+7QkAA3IAHA+GwIAAQAQABAlCAJBAJmKVuWpM8XiQqldAFACM9+y1N4bmUYDN8qebkfEYzMRSPkAOhoA/RBBZVyVj" +
  b"oWfCB61HQAARAACwDQABwQAAAAHwACqxBLL/////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////0dQABEAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////R0EAN40QAACQtX4A////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"//8AAAHgAACAgAUhAAkvBQAAAAEJ8AAAAAFBmiBifBHF00qVeCOK22phMoBHQAASAACwDQABwQAAAAHwACqxBLL/////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////0dQABIAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9EuZv/////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////R0EAOGgQAACiSX4A////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////wAAAeAAAICABSEACXVVAAAAAQnwAAAAAUGaQMnwxFAweTIGaljDQbQYuk9KF3FWP8V64h0fx4YigwdNkDXcsnTzQbVL+AiA" +
  b"3UcUZc/ox0BHQAATAACwDQABwQAAAAHwACqxBLL/////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////////////0dQABMAArAXAAHBAADhAPAAG+EA8AAP4QHwAC9E" +
  b"uZv/////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////////R0EAOWUQAACz3X4A////////////////////////////////////////////////////////////////////////" +
  b"/////////////////////////////////////////////////////wAAAeAAAICABSEACbulAAAAAQnwAAAAAUGaYSfDEUDDCmAp" +
  b"UtoJP4myvl5RCpvDT8u1xDo/3hiKAMP0wF3lt0LOIWTDQJeYQ2um5inXLsCT0FBHQQEwAUAAAAHAC0+AgAUhAAfYYf/xUEAjv/zc" +
  b"AExhdmM2My4xLjEwMgACMKtc6QxCDq1Nzm+JrpuDRUXUpknb2SIAEoSCKYRJySK2EmQiMZJIMS7ZWdsqQ3Ayeb2Fn4bB5lFx7Tly" +
  b"3Hk11FMIhWSSIjIaSbGIyREiQ8exCQ2EWBJFJ/F/DfYfavsP071n4rsHuLrnjLiO4tu6O0bqrEdDcw9ddk83bN2NsnSWwcxapxbj" +
  b"O9cd3rad6xOOxkcBARHYrjZtBxVxsVhuU7ap21TtarM9Sz2g2K42Kw3Kw2qdtUa/PsdStqVs+v0bTRtWa00a/PsdCtoVVCqlK5Su" +
  b"UrlK7V4asdWOrRq0YaMNEk0k1U1U0k0lD0SUSTSTVTVTVTSUSUSUSUVTVTVTVTSUSURRRRRRRRf/8VBAI7/8AWaY2TbrNROLcJqS" +
  b"txUj/T/vri2Fxerrv19dBer1/XoTV2T+t8L41cqQYr0YePLcimsQ49gpMwRHXZMkRwEBEphk+bSeiqsQP2ZbjY54HuT7YY5I7x0a" +
  b"1VOnapT/xv1a7d/5OiQYGu5BISDAzuEhIMDAzu4SErBgYGd3CQk4DDmXdwk40DMg153fIJCcl5Bz5K/t6JdandiRdATwe3uuD5tQ" +
  b"OAlYpI8L9TmWOuKaq19TtzSzbbhZMlKaVSZrpdpJpJscMa62dpJpGxwprdnaSZ2xrZ3Z2dpGdnbHBnZ3Z2dnZ2dGdnZ50Kyoi+nO" +
  b"8QAIEHb71kzQiXRHAQET+dM8Tem79ArosaLXRYxM6KUSUSUT8p0SEhMyUJS3UuDTXP/xUEAWv/wBFvYs9JYpF1RGQT1vv8v188an" +
  b"FXmt3dXuRHnJJET7ytK42IDxjTukcR7hxHmF28i/CObvLFvqsquQdl2nqvGcTGrU1mxWKsUcqPFazrVqZJOGZNscZmB68MMMHBsc" +
  b"ccWQHrwwwcT/Hw2n394T/Hw2n39yHx8GT7+4Vj79s1LlbtjsORzMwK9FONvtw4tRokcBARSc3P0NNPHr+OpHpZj5VtuXjXSd5jV3" +
  b"Vi/hBWmqhNvA//FQQBR//ADoNi0syAsTQsHRMLWK9Z//Z+38/+X3XDv2y8uSJT9pUqrzW5mqmQT1IL+kFWVTN3HOLKFC8PAL10fv" +
  b"j6cPp7ePDjqoqmkpdHSpBQGlmVJDEAc2r8XSDA7VI2gkJckzdjfOTAuFlFrJoJsudWUYUF0lSShA0ac6CwFYtZber63WEBFTckIW" +
  b"vI1S5Ij6SZKnDOWTRwEBFS0E9MKdmNKzsR//8VBAG9/8AOY2LPBWTAWPoUPoSDpX6fHf/8Xr/9PPz+NcbpM6xLBUftTFMyKihTtz" +
  b"IUUcuZBmbwk6WKhGh4ii8e8tW/KscGGVpbKXdE1zQdt5XveTCzmUOVdL7f4IAkRxdgQjvR80SuBohBRCyVGtOA2CPXYgrBYQTBTF" +
  b"9k8WUEhgaTXaiugXnG2ZuV7tdFiW+CMBCAOGjlmx35Y31NXrh/4TarPh/p8H6HNP+/dHAQEWPytBE4Xs5dVh988nBQ+FWt9OJyJj" +
  b"jGt6YwonyqEPRQI9vvFrVFZXH2OKu8+VGfTw//FQQBzf/ADgNi0shVociaEiPzOf/7Pr/8/bXfxS08+tuN8GLwSlCBKB2r68srTp" +
  b"cRWcE35aV0zWh6io4XE/XFJN9vhq8KppJpJq5pJnoqh2eaRmsGea76cPDM1JVpzOVY4XHvmhMXEViW+HH401NzmdTDozpnCqra/X" +
  b"GKG6apM/LK77/HGMO0cBARc5VUoajG0Mc/OvU87Hweg/+O5eBLnQFtLvc8yws46P0xgzL4RKkRlu45YIHNe2yvYCPISYHZDCVlfX" +
  b"PFhMIU7KxZJmjLq61qVmFkDv0kuEozYAGZ6udjJ7ZwfrCjv8//FQQBY//ADcNizs9EaFBaFA6EQ6FA6V/Wb//te//z/N1xnVtVzW" +
  b"sVDJeQOVUYtUBT28WTNAjZ0635PXzUe6CK7O/s77Ls7rLTIyWLLqRXK8QWrBGQgkMAUaRwEBGPoYi5CzC0AhGEqxlwOCWkvGUeOA" +
  b"LYditQL9Awtt03JnkxaVXu5Gbslrph336+b65ilbetwhdHWkm4gt8lwWXYsosQ6jhPr89Gqn+yOfUUip09a9Sfq9j//xUEAS3/wA" +
  b"6DYs1GZMBQeiYOiYWsfbz7//2vn/5/fzd62qNMl71t+uMulKlSUUGYswpksWio8xqM+j4gu+wPNGY5rHNY5qqUyTVs1xwmkZ8ZGJ" +
  b"nZ2el2Ca1tTL3YMt7oRHAQEZYghubxAk/1TQGILWS1cj235D7ENUIe6GHnI6EnwxBx6lYGtJx5XEa13zQ1zBRU9tcqFgpvz/8VBA" +
  b"G//8AOY2LPRUNQYPoWEhNCwdCgdCwdK53n/97v/3/04r425uziqiZb/wxJGxUwD7gW1hbVGXJSCfBUSNVtUBcfGY+sK1GPsFbfFa" +
  b"he46Jq1IILhlDwPXxTDTFfy5CGCMoihehENwYHhRMAMTphfRUSmSF0uBkR6LeSyEQEbylkcBARolkPlnvnplACEo4qWD8YsE5YDo" +
  b"0AQO8ld79ShaNNsBIJ4N/uAwK+Hmr03nTK/ignIkrfPynFfHqoI+36ECmk35cLYR6qN85pZaE76wsBdLGSkjNYgCM0amMCvcuP/x" +
  b"UEAZf/wA5DYs7OUyL0hB0L+3tv/+9P+/83NXW+LM1O+G9d8YuqRSAUZBxrxsKMwsQk2Mp2Bj8S3qcO7r7uvux7scMe7GumukTdnZ" +
  b"6XSu+RpWhpKVUq+jAYGNRwEBG+TPMBlETVXnVwq2EXtzvd95OrMaVUzEV1ZZ0vfppkiFAPnpfkQYM+zsUYo4wWKXHJJg63Xeu9BH" +
  b"S/6jw4y2KmphceIMowrNvG8q4+cSaJdCtzsqPs8OPCZk1E0DvRbwLQVBpDNbNdBiNMX8QZZxwP/xUEAV//wA5DYs7TQehYJh0SB0" +
  b"aB0r85f/9n9v/x/mOt8ZOHK6kVMH/rdSVUqUqCmcKXL1y8Xeqf9XvpfwpSvT6/Ts4UenZw1HAQEcEqCj0Ogo8PDpLDzrM84oJjT3" +
  b"ELOiHCChGUDUx0aSZ4O9CC2DFa7cGY2KVgBhRmqCDM2cBp1vbPJVaH36Uvp2Os6MI0jgl3M7TA/BJkias6PlbVhDS1FNOV8mdH0y" +
  b"TotiHlXS4VC///FQQBof/ADgNizstysbQsXSEHSP4v1//Zn/8EviZF0kvK1l7vICkxQ2VB3F26iQqSE2cvfHSSgNl2Q9+7z+7dr3" +
  b"e7z9e7HdrrprvrOtazkOs0cBAR21nUkrZ74QvpYo1orexzmcdzWycn3fJzuUJvK5jWMu45gna0JDVTpWkasLmV1Eh65UqYEtCsiZ" +
  b"qVlaY7v7iShRiDgmoNSiQZiQFI0GU3grr3A5VaGjC96L6FRHustuGrVmDElXOc3R6TETlOh3BZjNLEKuYVMjCeX8k2pK9vD/8VBA" +
  b"G5/8AN42LSykMokKQ9Cg9CQ9C/Tmf/h+3/4/reSSuDGszisurVQQJUVkofUvqK0snjpeo3SRRwEBHgklg00tSIvf0axs/dGrRqmk" +
  b"mkmqmfF2dgxFHaRlpBnQ2BLfE0NA7cxdtqdBS/J8KP++7Dr9evdxo+0jbRWblVMZnGb8Tela3sc0kl/AzPooZrjUEO0iMgOzNznE" +
  b"7pBVmPggNEBCfcynSLsS1lOTSEr8Ui1bI0SQQL2en5NdwvPvogjQChttF681jlbr0Azx2Y6c6DzRsR5qACEg5g+15u/WLv/xUEAU" +
  b"v/wA4jYs7KVaB0KD0Kh1L9NHAQE/KAD////////////////////////////////////////////////////b5//i7/6/5ldTvzNb" +
  b"9dOOUqVdQFVLqAoJtpZmyjuEMpuhEmRCIALNWh8/l89t1m/bbflZbeRkFZpSRO731raxUiFfXmGSi4tc77Mb/Z2JQCoic4vNq3dr" +
  b"Gatq71IT1YnUrlmbzmFs5eG9Vve0KcLtTbU29hvlFJQ4zaOxRC6ROy1Jlhk+FSqy6kd/YXcr4EdBATABQAAAAcADMYCABSEACbzz" +
  b"//FQQBmf/ADqNizwZmQFB6Fh6FA6Eg6FA6V4nz//az/3/xpqOeCbvWQvY/NZVLrKvcqCmaaWWp0uoHQi3lQY1e1wFYuNrcapnYuN" +
  b"NnVJTLU0qa06OElLsUzmMw0iBTPHEgMkG+AdDYqSktPrlqETe92GxTNp7aXAHuURpKIeUTgIUioxUJWlKsNigPrb1ZdfWiOyndAL" +
  b"nKr4jMYG2Ds78LyfTJFluJmzRwEBEQ2oyTCxi8A8ClwiakpkJzEF5iVfq65vlLe9D946N0TzejZd4P/xUEAVv/wA6jYtLNQ+iQWh" +
  b"Qend17//2c/2/381xjhp263Wm6kPykrJUBQMToE6Q+a6Ufn9TEVtBBIngjXnl49+eVkLAkaVIlq0C5lfROgzqBMhdHAGA4aiJjA2" +
  b"OZ0+dRibJifaZHuS/5oQc3k7Rmrfd8OtpKvQNHWWgr5iHAGWNXTNDnG1eoUOy6IPLkLMNPjvSbtHAQEShjjxA8xxHq4mqmSIoNSD" +
  b"OlEooseOh71EnP/xUEAWn/wBCFYttGYqC15B0KBZzP/21/10vqM0kxSXs+lrSSLqT8ZoEFqIIL4J+bg4CZVk49AnbxLn5bx4SmCF" +
  b"+mQlxSE+SQhuIJLdgfSL96fncJMQiYgkxA/b7Pms2cadwdqdUyiMcSed9X6vxvK49ywsmcbRtGIjHA8nJz8+3Nnrn4+Pj0lGLsss" +
  b"soQ1zzzlUSjLLLKdDszzzlYjD0cBARMPbgAABUYfCOyPederlDxUol8NQ4D/8VBAHh/8ATKZstNRtmrCZGr2pjrD11+Jri8vU1//" +
  b"a4/XzrQH9O/rjq3RqakEAoEt9VmGv6yC/D8OOuMTTP/nbktSY4QopjhBigp4YY4QZGKCmOGLkYAfy/kD+X8v5Afy/l/ID+X8vWID" +
  b"+X8vV6wpWiEfmfneZJmLaSmCOIWVlVAO9r2vGx0El6d1SwxyZL/MxNhno1smSjC//fn+beeVM5lpRwEBNF4A////////////////" +
  b"////////////////////////////////////////////////////////////////////////////////////////////////////" +
  b"////////JEQdZy/3lstMlCCIOw1kOzdnZ2Z2Iw+Nn9cMvK7OzsYAABNnnXlP1XRt8P+B+L8cA/mH5/rP0GDC6rslSkJWp1wqGJX9" +
  b"y0yk7sBxmLj/8VBAAZ/8ARiBtHA="

///|
let ffref_mjpeg_mkv_b64 : Bytes = b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAASyRFNm3TAv4QlmSdKTbuLU6uEFUmpZlOs" +
  b"gaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIBU027jFOrhBxTu2tTrIISYuwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hGA+d1Uq" +
  b"17GDD0JATYCMTGF2ZjYzLjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQPixPrYqp8jLy66whgPKW5kSJiECPQAAAAAAAFlSua9+/hBJh" +
  b"SSOuAQAAAAAAAFDXgQFzxYh60BQf+R+zZpyBACK1nIN1bmSIgQCGh1ZfTUpQRUeDgQEj44OEC+vCAOCQsIEguoEgmoECVbCEVbmB" +
  b"AlXugQDsAQAAAAAAAAIAABJUw2dAf7+Ep6K6hHNzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjMuMS4xMDJzc9RjwItjxYh60BQf" +
  b"+R+zZmfIn0Wjh0VOQ09ERVJEh5JMYXZjNjMuMS4xMDIgbWpwZWdnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAxLjAwMDAwMDAwMAAf" +
  b"Q7Z1UIS/hMLkEjrngQCjQ0qBAACA/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAoKCwoLDQ0NDQ0N" +
  b"EA8QEBAQEBAQEBAQEBISEhUVFRISEhAQEhIUFBUVFxcXFRUVFRcXGRkZHh4cHCMjJCsrM//EAHwAAQADAQEAAAAAAAAAAAAAAAcG" +
  b"BAMIBQEAAQUBAAAAAAAAAAAAAAAABwECAwQFBhAAAgIBAwIFAwUBAAAAAAAAAQIDEQQSBQAhBiITg0PCUTFBIzORcVJhEQACAgIB" +
  b"BAIDAQAAAAAAAAABAgMRBAUSACEiMRMGUTIUQf/AABEIACAAIAMBIgACEQADEQD/2gAMAwEAAhEDEQA/AIB2ltU2cZnIZIAyK0td" +
  b"GZQSY0JFFwGUn/IIJ+4v1N33PPgMRhyp4NWvUIZHiBrTV6GF1Zq7PFTasCDb+3tmWFa87HGTIxC6nknSORixVVurCKTZCKoJNcGd" +
  b"79j1PjzsPruvxJZflkgjldr7yKHoUwoBgQP1HS42XJmRbiKYIw1qYKYh4jnF/TI0kxDe7kPENVeKgfnpo3bbcDHEQhxMeHXr1eVE" +
  b"kRatNWUCnpZ/nm/aW/QZUr4s7JFkyDVEnUCZY7LeXd+JQQSl2RbDoDVre/Y9T4855ys+fa83AzMdtMsEjSL1YBq0WjaGViji1dQR" +
  b"qUkcDf13Oy5E+OSeWRW9h3Z+9t3HImj4j1+Om4mLFlS7uWUM7YDYD4vk3GE5EbRzcVviBItchXcqD/nT3gZEWT29sTxNqUYaRE0R" +
  b"44USKQeIA+GRGW/sasWOCO9+x6nx5Mu2+6MBInjZMgUFUtoTSNX56SFqFdaF/wDOX87fsbBmBliyPHdAKl+H+5B9elXwhaDe56Zn" +
  b"80eqeWj+wmUGvI3xKXQvqLNhn0y7J8aJthHshjFZFIiCLitwJAPIyWxANVxsX76nG9+x6nx5zjuePLlz4WPCuuWaQxRrYXU7siqL" +
  b"YhRZIFkgfXij3HsOU0qS+ZjqrMT4mcVVff8ATr882wO1twzYCFbHiKVqWR2vrdfto4/H15garSa/GxTPjbaPMKjuiQsovv48i5F+" +
  b"XVvQz47ttI8yZMGXYHEX45O7RtjoXoeudqbNVxFX7HX/2aNDRYEAyID/2P/gABBKRklGAAECAAABAAEAAP/+AA9MYXZjNjMuMS4x" +
  b"MDIA/9sAQwAICgoLCgsNDQ0NDQ0QDxAQEBAQEBAQEBAQEhISFRUVEhISEBASEhQUFRUXFxcVFRUVFxcZGRkeHhwcIyMkKysz/8QA" +
  b"eAABAAMBAQAAAAAAAAAAAAAABwYFAwgEAQACAwEAAAAAAAAAAAAAAAAHBgIBBQQQAAICAQMCBwEBAQEAAAAAAAECAxEEEgUAIQZR" +
  b"EyKDQzHCQVKRMxEAAQQCAgIDAQEBAAAAAAAAAQIDBBESBQAhIjETBlEUMkH/wAARCAAgACADASIAAhEAAxEA/9oADAMBAAIRAxEA" +
  b"PwCAdpbVNnGZyGSAMitLXRmUEmNCRRcBlJ/yCCfsXabvuefAYjDlTwateoQyPEDWmr0MLqzV2eKm1YEG39vbMsK152OMmRiF1PJO" +
  b"kcjFiqrdWEUmyEVQSa4M738Hufnjh9d18R135XGG3VqvtxIXQpQoBQIH+Ry40tyY1uGnghQ1qIKIhxGbX9LinHiFe7cOIVVeKQP3" +
  b"jRu224GOIhDiY8OvXq8qJIi1aasoFPSz/wB5v2lv0GVK+LOyRZMg1RJ1AmWOy3l3fqUEEpdkWw6A16t7+D3PzznnKz59rzcDMx20" +
  b"ywSNIvVgGrRaNoZWKOLV1BGpSRwN/XZ0txHxuPuuJV7C1qX3auxkTR8R6/ORiRWpTu7ddClqgKgLi+SsWTIbU29im8QHE1kK7KQf" +
  b"+ce8DIiye3tieJtSjDSImiPXCiRSD1AH0yIy39GrFjgjvfwe5+eTvZO7dufHaDy8pSNALFI9Iu+vSUtQrrS3zXK37G26QedFkest" +
  b"WlU/leMg8elXwifXN5OEv+ZOrWqifL5kg12bxKbry5yTG5WnGyXHjqntbIRilxJDQQIqsCQDkXLUQDVY2L98nO9/B7n55zjuePLl" +
  b"z4WPCuuWaQxRrYXU7siqLYhRZIFkgePEje+3MxMlJ2lxgjavt3sVX3cdf3x5YYna+4bhEdLY8RQDUsjtfW6/80cfzx4ua7SwIcUv" +
  b"xNq3PKR2lDKkCzfWRWRflzW0bkRR2iJcluE7sDET8S+1NqjoK6HrO0mzVY2L9jn/2aNDTIEBkID/2P/gABBKRklGAAECAAABAAEA" +
  b"AP/+AA9MYXZjNjMuMS4xMDIA/9sAQwAICgoLCgsNDQ0NDQ0QDxAQEBAQEBAQEBAQEhISFRUVEhISEBASEhQUFRUXFxcVFRUVFxcZ" +
  b"GRkeHhwcIyMkKysz/8QAfAABAAMBAQEAAAAAAAAAAAAABwYFCAMCBAEAAgMBAAAAAAAAAAAAAAAABwYCAQUEEAACAgEDAQkAAwEA" +
  b"AAAAAAABAgMRBBIFACEGIkExUcJDgxORUnFTEQABBAEDBAMBAQEAAAAAAAABAgMEERIFIQAxEyIGFFEVQTIl/8AAEQgAIAAgAwEi" +
  b"AAIRAAMRAP/aAAwDAQACEQMRAD8AgHZLaps4zOQyQBkVpa6MygkxoSKLgMpP9QQT5i7Td9zz4DEYcqeDVr1CGR4ga01ehhdWauzx" +
  b"U2rAg2/s9sywrX7Y4yZGIXU8k6RyMWKqt1YRSbIRVBJrgzvfwfZ7eOHrunxHXe64w26tV7uJC6FKFAKBA/yOXGluTGtYaeCFDTUQ" +
  b"URDiM2vkuKceIV1tw4hVV4pA++NG7bbgY4iEOJjw69er8okiLVpqygU9LP8APO/ZLfoMqV8WdkiyZBqiTqBMsdlvzu+8oIJS7Ith" +
  b"0Br6t7+D7PbzPOVnz7Xm4GZjtplgkaRerANWi0bQysUcWrqCNSkjgb9dnS3Edtx91xKuoWtS97VuMiaPiOn1yMSK1Kd1t10KWqAq" +
  b"AuL5KxZMhtTb2KbxAcTWQrcpB/nHvAyIsns9sTxNqUYaRE0R34USKQd4A92RGW/I1YscEd7+D7PbxB27thtuTjfgseUhQrqZ0j0j" +
  b"V492VmoV17t+nPGXvuNt40TRZFyB60qnh/sg6dfC+Eb1jWpqpXx/zFgi9+8m633xxuqVzgkpmaT+mpiIua1qQilLoUGwgRV4EpBy" +
  b"LlqIBqsdr68ne9/B9nt5nHc8eXLnwseFdcs0hijWwup3ZFUWxCiyQLJA9eIW49mc3FyhPJLi6HuqeSxRHncQHj68uMPsxuGf31aC" +
  b"LQV1LI7avM/80dfD14sQtGgwYxfhamjUsRultlTYBN7ZFShflze0ZUL/AKiZUxuI9qBiJ7Kxam1RkFdDcZ2k2arGxfUc/9mjQ0uB" +
  b"AliA/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAoKCwoLDQ0NDQ0NEA8QEBAQEBAQEBAQEBISEhUV" +
  b"FRISEhAQEhIUFBUVFxcXFRUVFRcXGRkZHh4cHCMjJCsrM//EAHcAAQADAQEAAAAAAAAAAAAAAAcIBgQFAwEBAQEBAQAAAAAAAAAA" +
  b"AAAABgcBBQIQAAICAQMCBgMBAQAAAAAAAAECAxEEEgUAIQYTIlGDQ8IxQVIzkREAAgEEAgIDAQEBAAAAAAAAAQIDBBESBTEAISIU" +
  b"BhNRMkH/wAARCAAgACADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCgdpbVNnGZyGSAMitLXRmUEmNCRRcBlJ/kEE/kX1N33PPgMRhy" +
  b"p4NWvUIZHiBrTV6GF1Zq7PFTasCDb+3tmWFa8bHGTIxC6nknSORixVVurCKTZCKoJNcGd7+D3Prxh9d19JLL+skEcrtfzIoewsws" +
  b"AwIH+R3aarkrItxFMEYa1KFKQ4jOL5MjSTENzeQ4hrW9VA/vWjdttwMcRCHEx4devV4USRFq01ZQKeln/vPftLfoMqV8WdkiyZBq" +
  b"iTqBMsdlvDu/MoIJS7Ith0BrVvfwe59eR5ys+fa83AzMdtMsEjSL1YBq0WjaGViji1dQRqUkcjf12uq5E/OSeWRW5Duz+bt5GRNj" +
  b"6jj+d80lLFVS7uWUM7UDUD0vs2MJqI2jmxW+IEi2yFvJUH/nXvAyIsnt7YnibUow0iJojzwokUg8wB8siMt/g1YscEd7+D3PrxDg" +
  b"7x23cIRFHHlIUChmkSPSNV9fJK7UK69L9BzPuG94+FF4UsWRqkDVSpXSvWQdPQi+Ur6ruat6n47a5kIvzKt7e3nHG/B7zZvnattm" +
  b"YqJ6qHZClKzBhGqClfAlQcjJdmANrY+L89v29/B7n15HHc8eXLnwseFdcs0hijWwup3ZFUWxCiyQLJA9eIM/bGbt8/jTS4umQkjS" +
  b"8nSq/OqJR+/Xnd27tnPzJBKGgj8Mgssjtq63X+aOv6/rhGl1FFr6czUGxTaY8iOJowCb+MizC/txz1LqfgKu0WoroqabYGkX8HHv" +
  b"G1Mhew8++Sm5tbC4vyO//9mjQ0aBAyCA/9j/4AAQSkZJRgABAgAAAQABAAD//gAPTGF2YzYzLjEuMTAyAP/bAEMACAoKCwoLDQ0N" +
  b"DQ0NEA8QEBAQEBAQEBAQEBISEhUVFRISEhAQEhIUFBUVFxcXFRUVFRcXGRkZHh4cHCMjJCsrM//EAHoAAQADAQEAAAAAAAAAAAAA" +
  b"AAcGBAgDBQEBAQEBAQAAAAAAAAAAAAAABgcBBQIQAAICAQMCBQUAAwEAAAAAAAECAxEEEgUAISIGE4NDwjFSUWFBkTKCFhEAAgEE" +
  b"AQQDAQEAAAAAAAAAAQIDBBESBTEAISITFAZRMkH/wAARCAAgACADASIAAhEAAxEA/9oADAMBAAIRAxEAPwCAeEtqmzjM5DJAGRWl" +
  b"rozKCTGhIouAyk/aCCfqL9Td9zz4DEYcqeDVr1CGR4ga01ehhdWauzxU2rAg2/w9sywrXnY4yZGIXU8k6RyMWKqt1YRSbIRVBJrg" +
  b"zvfsep8eMPruvpJZfbJBHK7X7yKHsLMLAMCB/I62mq5KyLcRTBGGtShSkOIzi+TI0kxDc3kOIa1vFQP3po3bbcDHEQhxMeHXr1eV" +
  b"EkRatNWUCnpZ/wA87+Et+gypXxZ2SLJkGqJOoEyx2W8u77lBBKXZFsOgNWt79j1PjzPOVnz7Xm4GZjtplgkaRerANWi0bQysUcWr" +
  b"qCNSkjkb+u11XInrknlkVuQ7s/e7dxkTY+I4/OvNJSxVUu7llDO1A1A9L5NjCaiNo5sVviBItshbuVB/zp7wMiLJ8PbE8TalGGkR" +
  b"NEd8KJFIO4A9siMt/Q1YscEd79j1PjxCHjHbd0GmKPKj0aAzSpGAL/vZK5oV16X+uUt43iDHgELxzhnuu1K7f+/30q+U76nt6qWo" +
  b"9D0LRMO9jKpa3l3xxB4PXKY1+tfZlKGSeDZfFKz5BFRaV8CVBuXuxANrY3F+ekTe/Y9T48zjuePLlz4WPCuuWaQxRrYXU7siqLYh" +
  b"RZIFkgfniF/5nN2o6p5cUhyxGh5OnUfXVEv5HJDs3hzOnm864Ywlakdzr6k1/ojL/Pu4Jp9VSa2H26+vXbBefXE0YHPbIswv5cdK" +
  b"taNfGm0E1fFDPsDSD47A5xtTIXxHfzyU3NrYXF+R1//ZHFO7a+K/hItKeMy7j7OBALeK94EB8YIB2PCBCbuQs4HIt4v3gQHxggHY" +
  b"8IIDVruRs4IBkLeL94EB8YIB2PCCBp67kbOCAli3i/eBAfGCAdjwggntu5GzggMgt4v3gQHxggHY8IINOw=="

///|
let ffref_rgb_png_b64 : Bytes = b"iVBORw0KGgoAAAANSUhEUgAAACgAAAAcCAIAAACcd2qBAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAQUlEQVR4nGNkYGBgAyN2JJIO" +
  b"XBaGAQKjFo9aPGrx8LD4FxsIfaFv0TUyg3rU4lGLh6HFA1GCjNCgHrV41OJhZTEAaB0JKZArHLwAAAAASUVORK5CYII="

///|
let ffref_rgba_png_b64 : Bytes = b"iVBORw0KGgoAAAANSUhEUgAAACgAAAAcCAYAAAATFf3WAAAACXBIWXMAAAABAAAAAQBPJcTWAAAAYklEQVR4nO3VMQrAIBQE0Q0E" +
  b"vf9dU6XKNxKwnyIr7ENRrAYLPVRajTG71NfV4eyUuQRSCaQSSCWQegPvNudVz/f4VvSt6/6nsz1u0FkCqQRSCaRmoPFLvckNGksg" +
  b"lUAqgdQDhusKIlpnOPAAAAAASUVORK5CYII="

///|
let ffref_aac_m4a_b64 : Bytes = b"AAAAHGZ0eXBNNEEgAAACAE00QSBpc29taXNvMgAAAAhmcmVlAAAK+21kYXTcAExhdmM2My4xLjEwMgACMKtc6QxCDq1Nzm+JrpuD" +
  b"RUXUpknb2SIAEoSCKYRJySK2EmQiMZJIMS7ZWdsqQ3Ayeb2Fn4bB5lFx7Tly3Hk11FMIhWSSIjIaSbGIyREiQ8exCQ2EWBJFJ/F/" +
  b"DfYfavsP071n4rsHuLrnjLiO4tu6O0bqrEdDcw9ddk83bN2NsnSWwcxapxbjO9cd3rad6xOOxtiuNm0HFXGxWG5TtqnbVO1qsz1L" +
  b"PaDYrjYrDcrDap21Rr8+x1K2pWz6/RtNG1ZrTRr8+x0K2hVUKqUrlK5SuUrtXhqx1Y6tGrRhow0STSTVTVTSTSUPRJRJNJNVNVNV" +
  b"NJRJRJRJRVNVNVNVNJRJRFFFFFFFFwFmmNk26zUTi3CakrcVI/0/764thcXq679fXQXq9f16E1dk/rfC+NXKkGK9GHjy3IprEOPY" +
  b"KTMER12TJJhk+bSeiqsQP2ZbjY54HuT7YY5I7x0a1VOnapT/xv1a7d/5OiQYGu5BISDAzuEhIMDAzu4SErBgYGd3CQk4DDmXdwk4" +
  b"0DMg153fIJCcl5Bz5K/t6JdandiRdATwe3uuD5tQOAlYpI8L9TmWOuKaq19TtzSzbbhZMlKaVSZrpdpJpJscMa62dpJpGxwprdna" +
  b"SZ2xrZ3Z2dpGdnbHBnZ3Z2dnZ2dGdnZ50Kyoi+nO8QAIEHb71kzQiXT50zxN6bv0CuixotdFjEzopRJRJRPynRISEzJQlLdS4NNc" +
  b"ARb2LPSWKRdURkE9b7/L9fPGpxV5rd3V7kR5ySRE+8rSuNiA8Y07pHEe4cR5hdvIvwjm7yxb6rKrkHZdp6rxnExq1NZsVirFHKjx" +
  b"Ws61amSThmTbHGZgevDDDBwbHHHFkB68MMHE/x8Np9/eE/x8Np9/ch8fBk+/uFY+/bNS5W7Y7DkczMCvRTjb7cOLUaKc3P0NNPHr" +
  b"+OpHpZj5VtuXjXSd5jV3Vi/hBWmqhNvAAOg2LSzICxNCwdEwtYr1n/9n7fz/5fdcO/bLy5IlP2lSqvNbmaqZBPUgv6QVZVM3cc4s" +
  b"oULw8AvXR++Ppw+nt48OOqiqaSl0dKkFAaWZUkMQBzavxdIMDtUjaCQlyTN2N85MC4WUWsmgmy51ZRhQXSVJKEDRpzoLAVi1lt6v" +
  b"rdYQEVNyQha8jVLkiPpJkqcM5ZMtBPTCnZjSs7EfAOY2LPBWTAWPoUPoSDpX6fHf/8Xr/9PPz+NcbpM6xLBUftTFMyKihTtzIUUc" +
  b"uZBmbwk6WKhGh4ii8e8tW/KscGGVpbKXdE1zQdt5XveTCzmUOVdL7f4IAkRxdgQjvR80SuBohBRCyVGtOA2CPXYgrBYQTBTF9k8W" +
  b"UEhgaTXaiugXnG2ZuV7tdFiW+CMBCAOGjlmx35Y31NXrh/4TarPh/p8H6HNP+/c/K0EThezl1WH3zycFD4Va304nImOMa3pjCifK" +
  b"oQ9FAj2+8WtUVlcfY4q7z5UZ9PAA4DYtLIVaHImhIj8zn/+z6//P2138UtPPrbjfBi8EpQgSgdq+vLK06XEVnBN+WldM1oeoqOFx" +
  b"P1xSTfb4avCqaSaSauaSZ6KodnmkZrBnmu+nDwzNSVaczlWOFx75oTFxFYlvhx+NNTc5nUw6M6Zwqq2v1xihumqTPyyu+/xxjDs5" +
  b"VUoajG0Mc/OvU87Hweg/+O5eBLnQFtLvc8yws46P0xgzL4RKkRlu45YIHNe2yvYCPISYHZDCVlfXPFhMIU7KxZJmjLq61qVmFkDv" +
  b"0kuEozYAGZ6udjJ7ZwfrCjv8ANw2LOz0RoUFoUDoRDoUDpX9Zv/+17//P83XGdW1XNaxUMl5A5VRi1QFPbxZM0CNnTrfk9fNR7oI" +
  b"rs7+zvsuzustMjJYsupFcrxBasEZCCQwBRr6GIuQswtAIRhKsZcDglpLxlHjgC2HYrUC/QMLbdNyZ5MWlV7uRm7Ja6Yd9+vm+uYp" +
  b"W3rcIXR1pJuILfJcFl2LKLEOo4T6/PRqp/sjn1FIqdPWvUn6vY8A6DYs1GZMBQeiYOiYWsfbz7//2vn/5/fzd62qNMl71t+uMulK" +
  b"lSUUGYswpksWio8xqM+j4gu+wPNGY5rHNY5qqUyTVs1xwmkZ8ZGJnZ2el2Ca1tTL3YMt7oRiCG5vECT/VNAYgtZLVyPbfkPsQ1Qh" +
  b"7oYecjoSfDEHHqVga0nHlcRrXfNDXMFFT21yoWCm/ADmNiz0VDUGD6FhITQsHQoHQsHSud5//e7/9/9OK+Nubs4qomW/8MSRsVMA" +
  b"+4FtYW1RlyUgnwVEjVbVAXHxmPrCtRj7BW3xWoXuOiatSCC4ZQ8D18Uw0xX8uQhgjKIoXoRDcGB4UTADE6YX0VEpkhdLgZEei3ks" +
  b"hEBG8pYlkPlnvnplACEo4qWD8YsE5YDo0AQO8ld79ShaNNsBIJ4N/uAwK+Hmr03nTK/ignIkrfPynFfHqoI+36ECmk35cLYR6qN8" +
  b"5pZaE76wsBdLGSkjNYgCM0amMCvcuADkNizs5TIvSEHQv7e2//70/7/zc1db4szU74b13xi6pFIBRkHGvGwozCxCTYynYGPxLepw" +
  b"7uvu6+7Huxwx7sa6a6RN2dnpdK75GlaGkpVSr6MBgY3kzzAZRE1V51cKthF7c73feTqzGlVMxFdWWdL36aZIhQD56X5EGDPs7FGK" +
  b"OMFilxySYOt13rvQR0v+o8OMtipqYXHiDKMKzbxvKuPnEmiXQrc7Kj7PDjwmZNRNA70W8C0FQaQzWzXQYjTF/EGWccAA5DYs7TQe" +
  b"hYJh0SB0aB0r85f/9n9v/x/mOt8ZOHK6kVMH/rdSVUqUqCmcKXL1y8Xeqf9XvpfwpSvT6/Ts4UenZw0SoKPQ6Cjw8OksPOszzigm" +
  b"NPcQs6IcIKEZQNTHRpJng70ILYMVrtwZjYpWAGFGaoIMzZwGnW9s8lVoffpS+nY6zowjSOCXcztMD8EmSJqzo+VtWENLUU05XyZ0" +
  b"fTJOi2IeVdLhUL8A4DYs7LcrG0LF0hB0j+L9f/2Z//BL4mRdJLytZe7yApMUNlQdxduokKkhNnL3x0koDZdkPfu8/u3a93u8/Xux" +
  b"3a66a76zrWs5DrO1nUkrZ74QvpYo1orexzmcdzWycn3fJzuUJvK5jWMu45gna0JDVTpWkasLmV1Eh65UqYEtCsiZqVlaY7v7iShR" +
  b"iDgmoNSiQZiQFI0GU3grr3A5VaGjC96L6FRHustuGrVmDElXOc3R6TETlOh3BZjNLEKuYVMjCeX8k2pK9vAA9DYtcFRREFxm//w/" +
  b"T/9epXWUyc+atlkolEq9yrqlD5W1g0QH/z+kef6y3Ws51FLBppLuDgHb+rMy4lIMb80bj1hhu66PP3GXYUZ0SfQlpEvkNoQpSkeQ" +
  b"/KNGeQDI+c+AGFgbsbqNJePoyN2Y9EDoyM2DZtTATNe8Iv3T+jqcIO0H4Q+HgssBpXGc3e8xRX6S8eyatFF1aZ4X93FGzRXP0i39" +
  b"ejN2c62IYCPzmxylJpidNbnS7PHOteiy9VLq5bislCt/HaNQKuABLDYtdGYhF1SIap/Tn/rczrnRV1km5JHlIkiT6giDjHXXu/pH" +
  b"uVSgzsK3UtyNoi2SRx4KKdBfX/LOotm5S756Q2/vXHWWie7Be7jiq7UG8JTRr1fsF61U1gmajj247rMqpnptWeSau+Foka1ejc9y" +
  b"yztbudyLmao5++Lmno+j0WUZMVFykr0wTdlRXjyW7VREqyUqLlJDJit2UlemS3cUV7CYrVREq0xW7KSvTFbsqK8eSlTKIlW4AAAD" +
  b"Mm1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAArEQAADOuAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAA" +
  b"AAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJddHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAA" +
  b"ADOuAAAAAAAAAAAAAAABAQAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAc" +
  b"ZWxzdAAAAAAAAAABAAAzrgAABAAAAQAAAAAB1W1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAArEQAADeuVcQAAAAAAC1oZGxyAAAA" +
  b"AAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAYBtaW5mAAAAEHNtaGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYA" +
  b"AAAAAAAAAQAAAAx1cmwgAAAAAQAAAURzdGJsAAAAanN0c2QAAAAAAAAAAQAAAFptcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAA" +
  b"rEQAAAAAADZlc2RzAAAAAAOAgIAlAAEABICAgBdAFQAAAAABDwAAAQ8ABYCAgAUSCFblAAaAgIABAgAAACBzdHRzAAAAAAAAAAIA" +
  b"AAANAAAEAAAAAAEAAAOuAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAOAAAAAQAAAExzdHN6AAAAAAAAAAAAAAAOAAABFgAAARYAAACu" +
  b"AAAAnAAAANcAAADfAAAAqgAAAI8AAADYAAAAxAAAAKgAAADJAAAAyQAAALgAAAAUc3RjbwAAAAAAAAABAAAALAAAABpzZ3BkAQAA" +
  b"AHJvbGwAAAACAAAAAf//AAAAHHNiZ3AAAAAAcm9sbAAAAAEAAAAOAAAAAQAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAA" +
  b"AAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI="

///|
let ffref_fmp4_seg_b64 : Bytes = b"AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAuBtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAKxEAAAAAAABAAABAAAAAAAA" +
  b"AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAB43Ry" +
  b"YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA" +
  b"AAAAAAAAAEAAAAAAAAAAAAAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAAAAAAQAAAEAAAAAAVttZGlhAAAAIG1kaGQAAAAA" +
  b"AAAAAAAAAAAAAKxEAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAAc291bgAAAAAAAAAAAAAAAFNvdW5kSGFuZGxlcgAAAAEGbWluZgAA" +
  b"ABBzbWhkAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADKc3RibAAAAH5zdHNkAAAAAAAAAAEA" +
  b"AABubXA0YQAAAAAAAAABAAAAAAAAAAAAAQAQAAAAAKxEAAAAAAA2ZXNkcwAAAAADgICAJQABAASAgIAXQBUAAAAAAPoAAAD6AAWA" +
  b"gIAFEghW5QAGgICAAQIAAAAUYnRydAAAAAAAAPoAAAD6AAAAABBzdHRzAAAAAAAAAAAAAAAQc3RzYwAAAAAAAAAAAAAAFHN0c3oA" +
  b"AAAAAAAAAAAAAAAAAAAQc3RjbwAAAAAAAAAAAAAAKG12ZXgAAAAgdHJleAAAAAAAAAABAAAAAQAAAAAAAAAAAAAAAAAAAGF1ZHRh" +
  b"AAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAA" +
  b"AABMYXZmNjMuMS4xMDIAAAAYc3R5cG1zZGgAAAAAbXNkaG1zaXgAAAA0c2lkeAEAAAAAAAABAACsRAAAAAAAAAAAAAAAAAAAAAAA" +
  b"AAABAAAK2wAAMACAAAAAAAAAmG1vb2YAAAAQbWZoZAAAAAAAAAABAAAAgHRyYWYAAAAcdGZoZAACADgAAAABAAAEAAAAARYCAAAA" +
  b"AAAAFHRmZHQBAAAAAAAAAAAAAAAAAABIdHJ1bgAAAgEAAAANAAAAoAAAARYAAAEWAAAArgAAAJwAAADXAAAA3wAAAKoAAACPAAAA" +
  b"2AAAAMQAAACoAAAAyQAAAMkAAApDbWRhdNwATGF2YzYzLjEuMTAyAAIwq1zpDEIOrU3Ob4mum4NFRdSmSdvZIgAShIIphEnJIrYS" +
  b"ZCIxkkgxLtlZ2ypDcDJ5vYWfhsHmUXHtOXLceTXUUwiFZJIiMhpJsYjJESJDx7EJDYRYEkUn8X8N9h9q+w/TvWfiuwe4uueMuI7i" +
  b"27o7RuqsR0NzD112Tzds3Y2ydJbBzFqnFuM71x3etp3rE47G2K42bQcVcbFYblO2qdtU7WqzPUs9oNiuNisNysNqnbVGvz7HUral" +
  b"bPr9G00bVmtNGvz7HQraFVQqpSuUrlK5Su1eGrHVjq0atGGjDRJNJNVNVNJNJQ9ElEk0k1U1U1U0lElElElFU1U1U1U0lElEUUUU" +
  b"UUUXAWaY2TbrNROLcJqStxUj/T/vri2Fxerrv19dBer1/XoTV2T+t8L41cqQYr0YePLcimsQ49gpMwRHXZMkmGT5tJ6KqxA/ZluN" +
  b"jnge5PthjkjvHRrVU6dqlP/G/Vrt3/k6JBga7kEhIMDO4SEgwMDO7hISsGBgZ3cJCTgMOZd3CTjQMyDXnd8gkJyXkHPkr+3ol1qd" +
  b"2JF0BPB7e64Pm1A4CVikjwv1OZY64pqrX1O3NLNtuFkyUppVJmul2kmkmxwxrrZ2kmkbHCmt2dpJnbGtndnZ2kZ2dscGdndnZ2dn" +
  b"Z0Z2dnnQrKiL6c7xAAgQdvvWTNCJdPnTPE3pu/QK6LGi10WMTOilElElE/KdEhITMlCUt1Lg01wBFvYs9JYpF1RGQT1vv8v188an" +
  b"FXmt3dXuRHnJJET7ytK42IDxjTukcR7hxHmF28i/CObvLFvqsquQdl2nqvGcTGrU1mxWKsUcqPFazrVqZJOGZNscZmB68MMMHBsc" +
  b"ccWQHrwwwcT/Hw2n394T/Hw2n39yHx8GT7+4Vj79s1LlbtjsORzMwK9FONvtw4tRopzc/Q008ev46kelmPlW25eNdJ3mNXdWL+EF" +
  b"aaqE28AA6DYtLMgLE0LB0TC1ivWf/2ft/P/l91w79svLkiU/aVKq81uZqpkE9SC/pBVlUzdxziyhQvDwC9dH74+nD6e3jw46qKpp" +
  b"KXR0qQUBpZlSQxAHNq/F0gwO1SNoJCXJM3Y3zkwLhZRayaCbLnVlGFBdJUkoQNGnOgsBWLWW3q+t1hARU3JCFryNUuSI+kmSpwzl" +
  b"ky0E9MKdmNKzsR8A5jYs8FZMBY+hQ+hIOlfp8d//xev/08/P41xukzrEsFR+1MUzIqKFO3MhRRy5kGZvCTpYqEaHiKLx7y1b8qxw" +
  b"YZWlspd0TXNB23le95MLOZQ5V0vt/ggCRHF2BCO9HzRK4GiEFELJUa04DYI9diCsFhBMFMX2TxZQSGBpNdqK6BecbZm5Xu10WJb4" +
  b"IwEIA4aOWbHfljfU1euH/hNqs+H+nwfoc0/79z8rQROF7OXVYffPJwUPhVrfTiciY4xremMKJ8qhD0UCPb7xa1RWVx9jirvPlRn0" +
  b"8ADgNi0shVociaEiPzOf/7Pr/8/bXfxS08+tuN8GLwSlCBKB2r68srTpcRWcE35aV0zWh6io4XE/XFJN9vhq8KppJpJq5pJnoqh2" +
  b"eaRmsGea76cPDM1JVpzOVY4XHvmhMXEViW+HH401NzmdTDozpnCqra/XGKG6apM/LK77/HGMOzlVShqMbQxz869TzsfB6D/47l4E" +
  b"udAW0u9zzLCzjo/TGDMvhEqRGW7jlggc17bK9gI8hJgdkMJWV9c8WEwhTsrFkmaMurrWpWYWQO/SS4SjNgAZnq52MntnB+sKO/wA" +
  b"3DYs7PRGhQWhQOhEOhQOlf1m//7Xv/8/zdcZ1bVc1rFQyXkDlVGLVAU9vFkzQI2dOt+T181Hugiuzv7O+y7O6y0yMliy6kVyvEFq" +
  b"wRkIJDAFGvoYi5CzC0AhGEqxlwOCWkvGUeOALYditQL9Awtt03JnkxaVXu5Gbslrph336+b65ilbetwhdHWkm4gt8lwWXYsosQ6j" +
  b"hPr89Gqn+yOfUUip09a9Sfq9jwDoNizUZkwFB6Jg6Jhax9vPv//a+f/n9/N3rao0yXvW364y6UqVJRQZizCmSxaKjzGoz6PiC77A" +
  b"80Zjmsc1jmqpTJNWzXHCaRnxkYmdnZ6XYJrW1Mvdgy3uhGIIbm8QJP9U0BiC1ktXI9t+Q+xDVCHuhh5yOhJ8MQcepWBrSceVxGtd" +
  b"80NcwUVPbXKhYKb8AOY2LPRUNQYPoWEhNCwdCgdCwdK53n/97v/3/04r425uziqiZb/wxJGxUwD7gW1hbVGXJSCfBUSNVtUBcfGY" +
  b"+sK1GPsFbfFahe46Jq1IILhlDwPXxTDTFfy5CGCMoihehENwYHhRMAMTphfRUSmSF0uBkR6LeSyEQEbyliWQ+We+emUAISjipYPx" +
  b"iwTlgOjQBA7yV3v1KFo02wEgng3+4DAr4eavTedMr+KCciSt8/KcV8eqgj7foQKaTflwthHqo3zmlloTvrCwF0sZKSM1iAIzRqYw" +
  b"K9y4AOQ2LOzlMi9IQdC/t7b//vT/v/NzV1vizNTvhvXfGLqkUgFGQca8bCjMLEJNjKdgY/Et6nDu6+7r7se7HDHuxrprpE3Z2el0" +
  b"rvkaVoaSlVKvowGBjeTPMBlETVXnVwq2EXtzvd95OrMaVUzEV1ZZ0vfppkiFAPnpfkQYM+zsUYo4wWKXHJJg63Xeu9BHS/6jw4y2" +
  b"KmphceIMowrNvG8q4+cSaJdCtzsqPs8OPCZk1E0DvRbwLQVBpDNbNdBiNMX8QZZxwADkNiztNB6FgmHRIHRoHSvzl//2f2//H+Y6" +
  b"3xk4crqRUwf+t1JVSpSoKZwpcvXLxd6p/1e+l/ClK9Pr9OzhR6dnDRKgo9DoKPDw6Sw86zPOKCY09xCzohwgoRlA1MdGkmeDvQgt" +
  b"gxWu3BmNilYAYUZqggzNnAadb2zyVWh9+lL6djrOjCNI4JdzO0wPwSZImrOj5W1YQ0tRTTlfJnR9Mk6LYh5V0uFQvwDgNizstysb" +
  b"QsXSEHSP4v1//Zn/8EviZF0kvK1l7vICkxQ2VB3F26iQqSE2cvfHSSgNl2Q9+7z+7dr3e7z9e7HdrrprvrOtazkOs7WdSStnvhC+" +
  b"lijWit7HOZx3NbJyfd8nO5Qm8rmNYy7jmCdrQkNVOlaRqwuZXUSHrlSpgS0KyJmpWVpju/uJKFGIOCag1KJBmJAUjQZTeCuvcDlV" +
  b"oaML3ovoVEe6y24atWYMSVc5zdHpMROU6HcFmM0sQq5hUyMJ5fyTakr28AD0Ni1wVFEQXGb//D9P/16ldZTJz5q2WSiUSr3KuqUP" +
  b"lbWDRAf/P6R5/rLdaznUUsGmku4OAdv6szLiUgxvzRuPWGG7ro8/cZdhRnRJ9CWkS+Q2hClKR5D8o0Z5AMj5z4AYWBuxuo0l4+jI" +
  b"3Zj0QOjIzYNm1MBM17wi/dP6Opwg7QfhD4eCywGlcZzd7zFFfpLx7Jq0UXVpnhf3cUbNFc/SLf16M3ZzrYhgI/ObHKUmmJ01udLs" +
  b"8c616LL1UurluKyUK38do1Aq4A=="

// ---- §328 audio decode: MP3 (mp3fixed) + AAC (TS / MP4) -------------------

///|
/// Read the i-th interleaved s16 sample out of a packed little-endian blob.
fn ffref_rd_s16(b : Bytes, i : Int32) -> Int32 {
  let v = b[i * 2].to_int() | (b[i * 2 + 1].to_int() << 8)
  if v >= 0x8000 {
    v - 0x10000
  } else {
    v
  }
}

///|
test "ffref: MP3 decode matches the mp3fixed oracle byte-for-byte" {
  let data = @libavutil.av_base64_decode(ffref_mp3_file_b64, 1 << 20).unwrap()
  let oracle = @ffref.ffref_decode_audio(data)
  assert_eq(oracle.sample_rate, 44100, msg="mp3: sample rate")
  assert_eq(oracle.channels, 2, msg="mp3: channels")
  let ours = @libavcodec.decode_mp3_stream(data).unwrap()
  assert_eq(
    ours.samples.length() / oracle.channels,
    oracle.samples_per_channel,
    msg="mp3: sample count",
  )
  let pcm = ours.pcm_bytes()
  assert_eq(pcm.length(), oracle.pcm_s16le.length(), msg="mp3: pcm length")
  let mut worst = 0
  for i = 0; i < pcm.length() / 2; i = i + 1 {
    let d = (ffref_rd_s16(pcm, i) - ffref_rd_s16(oracle.pcm_s16le, i)).abs()
    if d > worst {
      worst = d
    }
  }
  // Both sides are the fixed-point decoder (USE_FLOATS=0), so this must be
  // exact, not just close.
  assert_true(worst == 0, msg="mp3: max sample diff \{worst}")
}

///|
/// Compare the facade `decode_audio_file` pipeline against the oracle on a
/// container: same PCM length, per-sample |diff| <= 1 (float-tail rounding).
fn ffref_audio_diff(
  data : Bytes,
  label : String,
  rate : Int32,
  ch : Int32,
) -> Unit raise {
  let oracle = @ffref.ffref_decode_audio(data)
  assert_eq(oracle.sample_rate, rate, msg="\{label}: sample rate")
  assert_eq(oracle.channels, ch, msg="\{label}: channels")
  let audio = @avf.decode_audio_file(data)
  let ours = ffref_wav_pcm(audio.to_wav_s16())
  assert_eq(
    ours.length(),
    oracle.pcm_s16le.length(),
    msg="\{label}: pcm length (ours \{ours.length()}, oracle \{oracle.pcm_s16le.length()})",
  )
  let mut worst = 0
  for i = 0; i < ours.length() / 2; i = i + 1 {
    let d = (ffref_rd_s16(ours, i) - ffref_rd_s16(oracle.pcm_s16le, i)).abs()
    if d > worst {
      worst = d
    }
  }
  assert_true(worst <= 1, msg="\{label}: max sample diff \{worst}")
}

///|
test "ffref: TS AAC decode matches decode_audio_file within 1 LSB" {
  let data = @libavutil.av_base64_decode(ffref_av_ts_b64, 1 << 20).unwrap()
  ffref_audio_diff(data, "ts-aac", 44100, 1)
}

///|
test "ffref: MP4 AAC decode matches decode_audio_file within 1 LSB" {
  let data = @libavutil.av_base64_decode(ffref_aac_m4a_b64, 1 << 20).unwrap()
  ffref_audio_diff(data, "m4a-aac", 44100, 1)
}

///|
test "ffref: fMP4 AAC decode matches decode_audio_file within 1 LSB" {
  let data = @libavutil.av_base64_decode(ffref_fmp4_seg_b64, 1 << 20).unwrap()
  ffref_audio_diff(data, "fmp4-aac", 44100, 1)
}

// ---- §329 container packet differential: TS / MKV / WebM / MP4 / fMP4 ------

///|
test "ffref: packet oracle matches the MoonBit MPEG-TS demux" {
  let data = @libavutil.av_base64_decode(ffref_av_ts_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "ts")
}

///|
test "ffref: packet oracle matches the MoonBit Matroska demux" {
  let data = @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "mkv")
}

///|
test "ffref: packet oracle matches the MoonBit WebM demux" {
  let data = @libavutil.av_base64_decode(e2e_vp9_webm_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "webm")
}

///|
test "ffref: packet oracle matches the MoonBit MP4 demux" {
  let data = @libavutil.av_base64_decode(ffref_aac_m4a_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "mp4")
}

///|
test "ffref: packet oracle matches the MoonBit fMP4 segment demux" {
  // A DASH/HLS-style media segment: ftyp+moov (init) followed by
  // styp+moof+mdat (the first DASH chunk), which both demuxers open as one
  // fragmented MP4 file.
  let data = @libavutil.av_base64_decode(ffref_fmp4_seg_b64, 1 << 20).unwrap()
  ffref_check_packets(data, "fmp4")
}

// ---- §330 image codecs: MJPEG + PNG ---------------------------------------

///|
test "ffref: MJPEG frames match av_mjpeg_decode byte-for-byte" {
  let data = @libavutil.av_base64_decode(ffref_mjpeg_mkv_b64, 1 << 20).unwrap()
  let oracle = @ffref.ffref_decode_video(data)
  assert_true(oracle.frames().length() > 0, msg="mjpeg: oracle frames")
  // ffmpeg's mjpeg decoder reports yuvj420p for this fixture.
  assert_eq(oracle.chroma_mode(), 0, msg="mjpeg: chroma kind")
  let mf = @avf.MediaFile::open(data)
  let mut video = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if video < 0 && mf.streams()[i].media_type == @avf.MediaType::Video {
      video = i
    }
  }
  assert_true(video >= 0, msg="mjpeg: video stream")
  let ours : Array[Bytes] = []
  while true {
    let pkt = match mf.next_packet() {
      Some(p) => p
      None => break
    }
    if pkt.stream_index != video {
      continue
    }
    let img = @libavcodec.av_mjpeg_decode(pkt.data).unwrap()
    // Planes are already cropped to the visible geometry; pack Y, Cb, Cr.
    let out : Array[Byte] = []
    for plane in img.planes {
      for b_ in plane {
        out.push(b_)
      }
    }
    ours.push(Bytes::from_array(out))
  }
  assert_eq(
    ours.length(),
    oracle.frames().length(),
    msg="mjpeg: frames (ours \{ours.length()}, oracle \{oracle.frames().length()})",
  )
  for i = 0; i < ours.length(); i = i + 1 {
    assert_eq(ours[i], oracle.frames()[i], msg="mjpeg: frame \{i} YUV")
  }
}

///|
/// Diff one PNG fixture: the oracle decodes the raw .png through png_pipe
/// into a packed rgb24/rgba frame, which must equal av_png_decode pixels.
fn ffref_png_diff(b64 : Bytes, label : String, kind : Int32) -> Unit raise {
  let data = @libavutil.av_base64_decode(b64, 1 << 20).unwrap()
  let oracle = @ffref.ffref_decode_video(data)
  assert_eq(oracle.frames().length(), 1, msg="\{label}: frames")
  assert_eq(oracle.chroma_mode(), kind, msg="\{label}: kind")
  let img = @libavcodec.av_png_decode(data).unwrap()
  assert_eq(img.width, oracle.width(), msg="\{label}: width")
  assert_eq(img.height, oracle.height(), msg="\{label}: height")
  assert_eq(
    img.pixels.length(),
    oracle.frames()[0].length(),
    msg="\{label}: pixel length",
  )
  assert_eq(img.pixels, oracle.frames()[0], msg="\{label}: pixels")
}

///|
test "ffref: PNG rgb24 matches av_png_decode byte-for-byte" {
  ffref_png_diff(ffref_rgb_png_b64, "png-rgb24", 3)
}

///|
test "ffref: PNG rgba matches av_png_decode byte-for-byte" {
  ffref_png_diff(ffref_rgba_png_b64, "png-rgba", 4)
}

// ---- §331 audio encode oracle: libshine / aac / native opus -----------------

///|
/// Deterministic sine PCM (interleaved s16) shared by the encoder
/// differentials; channel 1 runs at 1.5x the frequency of channel 0.
/// Returns the sample array and the packed little-endian bytes (what the
/// oracle receives) from one source of truth.
fn ffref_sine_pcm(
  samples : Int32,
  channels : Int32,
  freq : Int32,
  rate : Int32,
) -> (Array[Int32], Bytes) {
  let arr : Array[Int32] = []
  let out : Array[Byte] = []
  for i = 0; i < samples; i = i + 1 {
    for c = 0; c < channels; c = c + 1 {
      let f = if c == 0 { freq.to_double() } else { freq.to_double() * 1.5 }
      let t = i.to_double() / rate.to_double()
      let v = @math.sin(t * f * 6.283185307179586) * 10000.0
      let s = v.round().to_int()
      let s = if s > 32767 { 32767 } else if s < -32768 { -32768 } else { s }
      arr.push(s)
      out.push((s & 0xFF).to_byte())
      out.push(((s >> 8) & 0xFF).to_byte())
    }
  }
  (arr, Bytes::from_array(out))
}

///|
/// First byte index at which two equal-length blobs differ, or None.
fn ffref_first_diff(a : Bytes, b : Bytes) -> Int32? {
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return Some(i)
    }
  }
  None
}

///|
/// Assert our packet sequence equals the oracle's, byte for byte.
fn ffref_expect_packets(
  ours : Array[Bytes],
  oracle : @ffref.FFRefEncode,
  label : String,
) -> Unit raise {
  assert_eq(
    ours.length(),
    oracle.packets().length(),
    msg="\{label}: packet count (ours \{ours.length()}, oracle \{oracle.packets().length()})",
  )
  for i = 0; i < ours.length(); i = i + 1 {
    assert_eq(
      ours[i].length(),
      oracle.packets()[i].length(),
      msg="\{label}: packet \{i} size (ours \{ours[i].length()}, oracle \{oracle.packets()[i].length()})",
    )
    assert_eq(
      ours[i],
      oracle.packets()[i],
      msg="\{label}: packet \{i} bytes (first diff at \{Repr(ffref_first_diff(ours[i], oracle.packets()[i]))})",
    )
  }
}

///|
fn ffref_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b_ in part {
      out.push(b_)
    }
  }
  Bytes::from_array(out)
}

///|
test "ffref: shine MP3 encoder matches libshine byte-for-byte" {
  let rate = 44100
  let channels = 2
  let frames = 8 // 8 x 1152 samples per channel
  let (arr, pcm) = ffref_sine_pcm(1152 * frames, channels, 440, rate)
  let oracle = @ffref.ffref_encode_audio(
    pcm,
    "libshine",
    sample_rate=rate,
    channels~,
    bitrate=128000,
  )
  let enc = @libavcodec.mp3_encoder_new(
    @libavcodec.mp3_encode_config(44100, 2, 128000),
  ).unwrap()
  let ours : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    let input : Array[Int32] = []
    for j = 0; j < 1152 * channels; j = j + 1 {
      input.push(arr[i * 1152 * channels + j])
    }
    ours.push(enc.encode_frame(input).unwrap())
  }
  // libshine hands out whole MP3 frames while the MoonBit encoder returns
  // shine's raw 32-bit-aligned output chunks, so the boundaries differ by
  // design: the concatenated bitstream is what must match.
  assert_eq(
    ffref_concat(ours),
    ffref_concat(oracle.packets()),
    msg="mp3-enc: bitstream",
  )
}

///|
/// Best-lag SNR (dB) of channel 0 of a decoded interleaved s16le blob
/// against the encoder input (interleaved), measured over the middle of
/// the signal; the lag search covers the encoder + decoder delay.
fn ffref_snr_db(input : Array[Int32], decoded : Bytes, ch : Int32) -> Double {
  let n_in = input.length() / ch
  let n_out = decoded.length() / 2 / ch
  let mut best = -1000.0
  for lag = 0; lag <= 2048; lag = lag + 1 {
    let mut sig = 0.0
    let mut err = 0.0
    for i = 1024; i < n_in - 1024 && i + lag < n_out; i = i + 1 {
      let x = input[i * ch].to_double()
      let y = ffref_rd_s16(decoded, (i + lag) * ch).to_double()
      sig = sig + x * x
      err = err + (x - y) * (x - y)
    }
    if sig > 0.0 && err > 0.0 {
      let snr = 10.0 * @math.log10(sig / err)
      if snr > best {
        best = snr
      }
    }
  }
  best
}

///|
/// Max |diff| between two interleaved s16le blobs of equal length.
fn ffref_max_diff(a : Bytes, b : Bytes) -> Int32 {
  let mut worst = 0
  for i = 0; i < a.length() / 2; i = i + 1 {
    let d = (ffref_rd_s16(a, i) - ffref_rd_s16(b, i)).abs()
    if d > worst {
      worst = d
    }
  }
  worst
}

///|
/// The AAC and Opus encoder ports are byte-exact against their *patched*
/// C reference harnesses (deterministic libm, direct MDCT; see
/// PORTING_HISTORY §276/§304-§309), not against the stock FFmpeg encoders:
/// the oracle shows different frames from the very first one. What holds
/// against the real FFmpeg is interop and quality, checked here: the real
/// decoder accepts our streams, the MoonBit decoder agrees with it on them,
/// and the SNR stays close to the native encoder's at the same bit rate.
test "ffref: AAC encoder streams decode in real FFmpeg at native-level SNR" {
  let rate = 44100
  let channels = 2
  let frames = 12 // 12 x 1024 samples per channel
  let (arr, pcm) = ffref_sine_pcm(1024 * frames, channels, 440, rate)
  // Ours: the default encoder configuration; `encode_frame` already emits
  // complete ADTS frames, so their concatenation is the stream.
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(44100, 2, 128000),
  ).unwrap()
  let adts : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    let planes : Array[Array[Double]] = []
    for c = 0; c < channels; c = c + 1 {
      let plane : Array[Double] = []
      for j = 0; j < 1024; j = j + 1 {
        plane.push(arr[(i * 1024 + j) * channels + c].to_double() / 32768.0)
      }
      planes.push(plane)
    }
    adts.push(enc.encode_frame(planes).unwrap())
  }
  let dec_ours = @ffref.ffref_decode_audio(ffref_concat(adts))
  assert_eq(dec_ours.channels, 2, msg="aac-enc: channels")
  assert_eq(
    dec_ours.samples_per_channel,
    frames * 1024,
    msg="aac-enc: real decoder sample count",
  )
  // Decoder parity: the MoonBit AAC decoder on the same raw frames, through
  // the swresample float->s16 rounding, must agree with the real decoder.
  let dec = @libavcodec.new_aac_decoder_from_asc(@avf.ts_adts_to_asc(2, 4, 2)).unwrap()
  let mine : Array[Byte] = []
  for frame in adts {
    // The encoder writes protection_absent=1: a 7-byte header.
    let out = dec.decode_frame(frame[7:].to_owned()).unwrap()
    for i = 0; i < out[0].samples.length(); i = i + 1 {
      for c = 0; c < out.length(); c = c + 1 {
        let v = @swr.swr_flt_to_s16(out[c].samples[i])
        mine.push((v & 0xFF).to_byte())
        mine.push(((v >> 8) & 0xFF).to_byte())
      }
    }
  }
  let mine = Bytes::from_array(mine)
  assert_eq(
    mine.length(),
    dec_ours.pcm_s16le.length(),
    msg="aac-enc: parity length",
  )
  let worst = ffref_max_diff(mine, dec_ours.pcm_s16le)
  assert_true(worst <= 1, msg="aac-enc: decoder parity diff \{worst}")
  // Quality against the native encoder at the same bit rate.
  let native = @ffref.ffref_encode_audio(
    pcm,
    "aac",
    sample_rate=rate,
    channels~,
    bitrate=128000,
  )
  let nmux = @avf.adts_muxer_new(44100, 2).unwrap()
  for p in native.packets() {
    nmux.write_frame(p).unwrap()
  }
  let dec_native = @ffref.ffref_decode_audio(nmux.finish())
  let snr_ours = ffref_snr_db(arr, dec_ours.pcm_s16le, 2)
  let snr_native = ffref_snr_db(arr, dec_native.pcm_s16le, 2)
  // Measured 67.7 dB vs the native encoder's 31.5 dB. Before the §331
  // `coef2minsf` floor the default path saturated the tonal peak and this
  // was 3.4 dB.
  assert_true(snr_ours >= 60.0, msg="aac-enc: SNR \{snr_ours}")
  assert_true(
    snr_ours >= snr_native,
    msg="aac-enc: SNR \{snr_ours} vs native \{snr_native}",
  )
}

///|
test "ffref: Opus encoder streams decode in real FFmpeg at native-level SNR" {
  let rate = 48000
  let channels = 2
  let frames = 10 // 10 x 960 samples per channel
  let (arr, pcm) = ffref_sine_pcm(960 * frames, channels, 440, rate)
  let enc = @libavcodec.opus_encoder_new(
    @libavcodec.opus_encode_config(2, 64000),
  ).unwrap()
  let ours : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    let planes : Array[Array[Float]] = []
    for c = 0; c < channels; c = c + 1 {
      let plane : Array[Float] = []
      for j = 0; j < 960; j = j + 1 {
        plane.push(Float::from_int(arr[(i * 960 + j) * channels + c]) / 32768.0)
      }
      planes.push(plane)
    }
    match enc.encode(planes).unwrap() {
      Some(b) => ours.push(b)
      None => ()
    }
  }
  for b in enc.flush().unwrap() {
    ours.push(b)
  }
  let mux = @avf.ogg_opus_muxer_new(channels=2, pre_skip=120).unwrap()
  for b in ours {
    mux.write_packet(b).unwrap()
  }
  let ours_ogg = mux.finish()
  // The real decoder accepts the stream, and the MoonBit Opus decoder (via
  // the playback facade, pre-skip trimmed) agrees with it within 1 LSB.
  ffref_audio_diff(ours_ogg, "opus-enc", 48000, 2)
  // Quality against the native encoder (same packets-in-Ogg path).
  let native = @ffref.ffref_encode_audio(
    pcm,
    "opus",
    sample_rate=rate,
    channels~,
    bitrate=64000,
  )
  let nmux = @avf.ogg_opus_muxer_new(channels=2, pre_skip=120).unwrap()
  for b in native.packets() {
    nmux.write_packet(b).unwrap()
  }
  let dec_ours = @ffref.ffref_decode_audio(ours_ogg)
  let dec_native = @ffref.ffref_decode_audio(nmux.finish())
  let snr_ours = ffref_snr_db(arr, dec_ours.pcm_s16le, 2)
  let snr_native = ffref_snr_db(arr, dec_native.pcm_s16le, 2)
  // Measured 20.2 dB vs the native encoder's 18.8 dB on this tone.
  assert_true(snr_ours >= 18.0, msg="opus-enc: SNR \{snr_ours}")
  assert_true(
    snr_ours >= snr_native - 1.0,
    msg="opus-enc: SNR \{snr_ours} vs native \{snr_native}",
  )
}
