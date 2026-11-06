///|
/// Differential tests against the in-process FFmpeg oracle. These run
/// native-only inside the ffmpeg-moonbit-ffref docker image (the repo
/// checkout mounted at /work); the wasm host build skips this package
/// entirely, so the 1438-test wasm suite is unaffected.

let playback_ogg_file_b64 : Bytes = b"T2dnUwACAAAAAAAAAAAN8K0LAAAAADJMpZEBE09wdXNIZWFkAQJ4AIC7AAAAAABPZ2dTAAAAAAAAAAAAAA3wrQsBAAAAxzMUKQEjT3B1" +
  "c1RhZ3MTAAAAbW9vbmJpdC1mZm1wZWctb3B1cwAAAABPZ2dTAAA4BAAAAAAAAA3wrQsCAAAA15PR8QHx/GVAOb6hEtUQTmI+3mLqCRzT" +
  "woqTPWozVsXOPHKuAiclKKuUSoDsSWv/QfKSqSzd+KKw0pgwLIOvB/kIfIomVZ5Ef+nDx+SIN2Gs286KgQkBjJA9BKkpvT5axTMQ7fLs" +
  "HRndER77/Rf05KkouX0NEdmB3Cw517pcuBTnSfd7aA5b+isGkxvWTjs4PIcF6VIpTMrF9u9Sr48tkT1exoWTryuEmA9tVBdYEa4/22ga" +
  "dKJny+mXHyf3GrDCjtkJKrkbK7wl0T8KPyh9thk5gvTvfq6vjscEUS0Q8GZBVlIhJEFq5QXu+aixYja9ImFdbP2N9U9nZ1MAAPgHAAAA" +
  "AAAADfCtCwMAAABHo7GwAfH8d+GXQ14/tXxs80k4UYMwiJdL3G3P7VPRGSk/VKDjz3GA1+P6TyZ0TpdNyUVniOcaalXUQrcHn+DhNTLb" +
  "QIxIUa5ny1kRGXxVYd/SVuxx76SZa+4vCNAUPPt5UpqsALmhqDr849WDe0FdaZdKkol8SV+Oc9TgZanvdr/3aa0VQn9PgRuAcVY3pd4i" +
  "Vky4eN7S5aM+qwmNvNqtEAFe5szkAQ16XQs8+BAZuRINlcQTz8pl0TKvNT+bQgMhNK+Y6OeBMuXYqPjAJfmNEjUSreDByqxYeUHcTCHm" +
  "WQVRLwV/wG6emC0k0tEIrRGhWS207xwbT2dnUwAAuAsAAAAAAAAN8K0LBAAAAH92OjYB8fwKPhIIvJxOfEehHKfo01A7UxDbz5CVm4yW" +
  "+WYpKluZbkqbO4dbSXaoRhvRsY00Q5BeahQhFNdXS3R02wxWjDQcvQpXqgiEcNaCljbWUmIm07lz5tw/xPCsg3S++9EFFf10Q+q6Ftxf" +
  "mSwlisDYPHwl6frRKdknSk4LD8LUrNLv0+YG9SS05LXL5Gxw2s/Bw35X69iC48ppUJ6ANYoumCbS/WI8f+akWWRvv285IzanKx2qzqPX" +
  "591ENO43inwUJHnZ7r0aw4zrWUBcH0oo1pDVLCAEly5vWZOLddZaEvyXJNe/r240T6+vISxqvc2YyDBPZ2dTAAB4DwAAAAAAAA3wrQsF" +
  "AAAA/yzD9gHx/HfgzKCbf/TSr4sOkQEMA0I+gEHM1B7876dSqWpdiqzhQBvDC1ZViOnpawrKADxh68MOhPL776jq5UoDz19Bo4xkT8IA" +
  "TqL4FzlJG+n9jMf1JchNYC9mn3ndSSPj7zLc0av4DwDYo0QcbolVCBvokGwvicnKMC5vZFT1Gw1cOtco/84hrOIqRyAD0bXrfGdbhyr+" +
  "Y/YTSFbxUPDZ0nQUVBgFpEyR2ZAzvK/tyqxutlW39bqaLXeniaGSxdwrYbUL8D+HwskkKVwFhslbatmolcqu/PFB3E+QRLFvVfgkcNKv" +
  "YTc2QtOMgEsQoGEtfh6d/U9nZ1MAADgTAAAAAAAADfCtCwYAAACU6Y+2AfH8Cj4RSgOLt4dk12XpMflnORJVaU7BCs33eO2nuELhy/GC" +
  "zG4BUTRS+evSd6N4MogNaIAUxschdkcX52cgGrfn9cpI6qoj/nZVbEYfCEKTkcYf78jmHNw08koB2jSuVjAZYKAEmLOx/dgEjZsTe/YY" +
  "J0hIHA9SZbfoLlVl7yh5k0hRrwE31ImUjW/jM713RrJrZ48+YvI4OciRhyQEwsTL8dfgCJVHrWEM8cIgDLlIYRbztstLdWazl/ZhFSDL" +
  "uvbekUIGTLYSF5A+mWilEU+WE0loImvbEb7zy/CMsnrpKhJZVNXGFpTlw+FopHRlRLj4T2dnUwAA+BYAAAAAAAAN8K0LBwAAACPeqRUB" +
  "8fwA1D2w/1rY8X4IEBUL4KDBa3x2KLQKGih1bGXuegtPWFbMaClddsrRujDiu+U/Hqzmkg1C+LMM9Zu8d0uWbwmg+uD8LYiRVYVDTNWp" +
  "2stq7oAf1C2xVFPFeajWiwLi/Rl6QLz3bl/Lhn51pQ1NKX80mUwauZgphT++vY8YO5k+eIoMWpujo+rch/UJzPEde/X+hozKkrGEpQRc" +
  "zkpWF6gTBH9PLe/tOWKWk6FO3ns4AbpgGzfW4BtPfmEVrtMC6PBvNqAlQMinyF0/j45cwmvEds74MKrQ9Merr28skfM6uSHM1QhIGiND" +
  "GiVSj75MkUxPZ2dTAAC4GgAAAAAAAA3wrQsIAAAAQLBVNAHx/Hfhl282pGgGZL/4rW57DwSntMSargpXAa3TVnIhPKvVPj3v6DhPMUR0" +
  "oAWWEAzVF+NpW28y2riGnKp5UXwwyRxswi1fJzVly/Y1xVAq8Ha/KvUJNauZ5aZ4oYy9fHiU7h9tRsY15D4fcDm0Fpb4hW0fNNaYWCE+" +
  "E2TdwFiH8H7atPavVdTNNXwLpOG6WIodO7Jn9A1ZI2TiZX1ditvbddkj0lKDOfA/TPynKODNpiISB5GYWK8qd7LLaMpcqGK/Mr55QSSC" +
  "iXAWNF8MqyWOcHuzyiQ2pt28rIgCrLwV/zJs7Zi1hY02RaN9Y2UZfx6dNk9nZ1MAAHgeAAAAAAAADfCtCwkAAAArF9oUAfH8BEXHCi43" +
  "xYfehau/QDqVHqgB8sBO7nyZo8IDvqZgq61IXLWGZiddUYlOB1FgMDe1W5M5Bx3ikoyxjudmZlb1+8S0savcvObPcTXQjboC1RQ4wXOS" +
  "N3AkWMwpsXZe2ZlcbUX0xounekPkYI3ALMvFNuU1269Ysgc+XmXYd6brUdVrM8odOu6OUPXZ28uEX0ayaKvcZ08Zqo2FEjaVOsDPgTLl" +
  "aj1DWX1r4qWwbLZd8sr0e/I0luHy+TUnecfDZZFVeGdN3i8kK2zBXWY686hmE6YLcly5vWZOK69uQdsijNEujfQ6kDJVgv+sh2RrUK3B" +
  "T2dnUwAAOCIAAAAAAAAN8K0LCgAAADy5AU0B8fwCHC/hJuzKiqmn6qqTy8f3Yf0j9QET7RorbGyTU3/kDeIq8dxVWUu+SylUIXwZQ6tn" +
  "uR6xctjL8EJmrzkXvL/O+S3ttlhC5+7FERt9slbckCRmXnrP81YwTGvE0vXwYO5HSugCtrB03IDHWUGdAQajn+ur/O/G3n0K5m/r+oFf" +
  "ZyPzx1V+lWa7dxZ+k8/o1k1sGt1h3j9CQBhUe5rj+Q8VW/UjH+qnumWYrihsuUCk+QJiiBtc+5xWAWEV/E2qX0OoH2IlYyynQCcGzMrF" +
  "nUKJjXKSXLmxnNCLr27B/+kqG4jsvheMdu6cmSGRf/NQoIFPZ2dTAAD4JQAAAAAAAA3wrQsLAAAAlvUkdAHx/AJ/PqdWULFYLRJc8AlN" +
  "kh/SEKDjtvzk/HYXqO3WCMPhFAXCiLTNofksp2zbQ9owZB9yQbuJ0EmawSOVcaMGeLef0lWdk4awfn7Ga3OKiCEC6wrF71pnT46XKOSM" +
  "sRHt5jQ6w4uKs0/PPlgHNiuPnrctgI2QnWFBu3sZJGZdelY4/EtXl8BcfN6Ut58Xfs5JBWSJkMsTsGlQUZNpie0R/BWO6N+tRhXchhJL" +
  "Yy50QYZHD9NkCVL1svaYRU4UL8I8hP73anmsssuc54OOimBlYTqb/yXLmxvvPLr2yxVCYrbii29KiQGL86uG1WFuYlwwVk9nZ1MAALgp" +
  "AAAAAAAADfCtCwwAAAB0H3PqAfH8ANQ9sb4bRLPEvtYsJu3nKUthWO6/d7KtCBNHYwxohx2NshpPjM4+tuksmcQPUMzqiKzLwvHwlV+W" +
  "T8zsv1VKy519hSRnoR7PoS1GozSCUYDHSlV/Jp/0DsuW6FDlxZQDoiOY2+1mq6r5jeJU2Mrtj0/ZGhFmeF+SA8OEnMAt27ADBD2BrZ6t" +
  "eTA5W9ct0aya8w+uBan3Hp+F5U5PIkpILnylz8ZmOmXGs9JojLlKhguvd6klPlicCkNhFVFEbxQmDz/laGkyK2ImkqcqjyLYTpsjyXLm" +
  "w9Merr28skbRZWSHU3RnKNjfMBySEwMnQJFMT2dnUwAAeC0AAAAAAAAN8K0LDQAAANiRfc4B8fwCfzehfvPagP+3DP7VE8wPmCcpEgjQ" +
  "lpO6GSYJop6w5ilI2kSJjpxvDVyKF4iNQgMicVuuyMYN9icYyRWUTuQpJG9aTGP4I3fbFIr4/KarKnO5ngYN0qMTgBXZcfrRdip5/iDc" +
  "QVImMfmTUfQVMqebcHGQ1LMsNcUFe034OyvlabrrrO6ZOWEeyTxc3YmdRrJpSG25nSGBBiDvcMZj0q9yXo8mAmn5+I7k9aVsuW/ijT9q" +
  "GpX0ETVVkYRWHGbyHBMJbKEsONs+snfUazZGzRhOiWLJcubDVSkuvbde2z+uyXIDRNFBRP2sVLFOiu8sspNPZ2dTAAA4MQAAAAAAAA3w" +
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
