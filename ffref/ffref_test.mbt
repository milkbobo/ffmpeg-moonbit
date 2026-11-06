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
  assert_eq(oracle.timebases.length(), streams.length(), msg="\{label}: stream count")
  let ours : Array[@avf.MediaPacket] = []
  while true {
    let p = match mf.next_packet() {
      Some(v) => v
      None => break
    }
    ours.push(p)
  }
  assert_eq(ours.length(), oracle.packets.length(), msg="\{label}: packet count")
  for idx = 0; idx < ours.length(); idx = idx + 1 {
    let p = ours[idx]
    let o = oracle.packets[idx]
    assert_true(p.stream_index == o.stream_index, msg="\{label}: stream at \{idx}")
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
        assert_true(diff <= 1L, msg="\{label}: pts at \{idx}: \{p.pts} vs \{expect}")
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
