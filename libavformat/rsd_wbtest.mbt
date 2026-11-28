///|
test "RSD RADP, XADP and PCM audio match FFmpeg" {
  for
    (version, tag, channels, offset, block, count, hash) in [
      ("3", "RADP", 1, 2048, 20, 96, "ed65d0ea4e664c5c08934a7d3929b78d"),
      ("3", "RADP", 2, 2048, 40, 96, "7c880d44b6655b2f463380305d75203a"),
      ("2", "XADP", 2, 128, 72, 195, "bd9d2979d5033dec74df28c9e7626c53"),
      ("4", "PCM ", 1, 2048, 16, 24, "a4f86d0d02220e9aae071eec0c128d38"),
      ("6", "PCMB", 2, 64, 32, 24, "570afd304add6a66f4a710b2775a9ce9"),
    ] {
    let file : Array[Byte] = []
    wav_mux_tag(file, "RSD" + version + tag)
    for word in [channels, 16, 22050, 0, offset] {
      wav_mux_u32(file, word.reinterpret_as_uint())
    }
    for _ in 28..<offset {
      file.push(0)
    }
    let payload = Array::makei(3 * block, i => ((i * 73) ^ (i >> 3)).to_byte())
    if tag == "RADP" || tag == "XADP" {
      for b in 0..<3 {
        for ch in 0..<channels {
          let p = b * block + ch * 4
          let predictor = 10000 - 9700 * ch - 3100 * b
          let step = 12 + 13 * ch + 7 * b
          let (first, second) = if tag == "RADP" {
            (step, predictor)
          } else {
            (predictor, step)
          }
          payload[p] = first.to_byte()
          payload[p + 1] = (first >> 8).to_byte()
          payload[p + 2] = second.to_byte()
          payload[p + 3] = (second >> 8).to_byte()
        }
      }
    }
    file.append(payload)
    let data = Bytes::from_array(file)
    let track = rsd_open(data).unwrap()
    assert_eq(track.frames[0].pos, offset.to_int64())
    assert_eq(track.total_samples, count.to_int64())
    let audio = decode_audio_file(data)
    assert_eq(audio.format_name, "rsd")
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), count)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
    assert_true(
      rsd_open(data[:data.length() - 1].to_owned())
      is Err("rsd: incomplete audio block"),
    )
  }
}

///|
test "RSD DSP handles both coefficient byte orders and stereo WADP word interleaving" {
  for
    (tag, channels, start, blocks, hash) in [
      ("WADP", 1, 2048, 130, "f85aaaa891ce248298652e7d5611af46"),
      ("WADP", 2, 2048, 4, "16b3b5fa45cfb7f5b9a6f5b579dbeddf"),
      ("GADP", 1, 64, 130, "f85aaaa891ce248298652e7d5611af46"),
    ] {
    let file : Array[Byte] = []
    wav_mux_tag(file, "RSD3" + tag)
    for word in [channels, 16, 22050, 0, start] {
      wav_mux_u32(file, word.reinterpret_as_uint())
    }
    for _ in 28..<start {
      file.push(0)
    }
    for ch in 0..<channels {
      let base = if tag == "GADP" { 28 } else { 420 + 40 * ch }
      for i in 0..<16 {
        let coeff = if i % 2 == 0 {
          1200 + 65 * i + 79 * ch
        } else {
          -250 - 13 * i - 31 * ch
        }
        let offset = base + i * 2
        if tag == "GADP" {
          file[offset] = coeff.to_byte()
          file[offset + 1] = (coeff >> 8).to_byte()
        } else {
          file[offset] = (coeff >> 8).to_byte()
          file[offset + 1] = coeff.to_byte()
        }
      }
    }
    let payload = Array::makei(blocks * channels * 8, i => {
      ((i * 73) ^ (i >> 3)).to_byte()
    })
    for block in 0..<blocks {
      for ch in 0..<channels {
        payload[block * 8 * channels + 2 * ch] = (16 * ((block + ch) % 8) +
        (3 * block + ch) % 12).to_byte()
      }
    }
    file.append(payload)
    let data = Bytes::from_array(file)
    let track = rsd_open(data).unwrap()
    assert_eq(track.frames[0].pos, start.to_int64())
    assert_eq(track.frames[1].pts, if channels == 1 { 1792L } else { 14L })
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), blocks * 14)
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
  }
}

///|
test "RSD VAG preserves PlayStation predictor history and silent blocks" {
  for
    (channels, hash) in [
      (1, "8655e0c4acee235986a77a02fb823298"),
      (2, "c4686c42436aa8721cde45a4427c59d6"),
    ] {
    let file : Array[Byte] = []
    wav_mux_tag(file, "RSD4VAG ")
    for word in [channels, 16, 22050] {
      wav_mux_u32(file, word.reinterpret_as_uint())
    }
    for _ in 20..<2048 {
      file.push(0)
    }
    let payload = Array::makei(5 * 16 * channels, i => {
      ((i * 73) ^ (i >> 3)).to_byte()
    })
    for block in 0..<5 {
      for ch in 0..<channels {
        let start = (block * channels + ch) * 16
        payload[start] = (16 * ((block + ch) % 5) + (3 * block + ch) % 16).to_byte()
        payload[start + 1] = if block == 2 && ch == 0 { 7 } else { 0 }
      }
    }
    file.append(payload)
    let data = Bytes::from_array(file)
    let track = rsd_open(data).unwrap()
    assert_eq(track.codec, "adpcm_psx")
    assert_eq(track.frames.length(), 5)
    assert_eq(track.frames[1].pts, 28L)
    let audio = decode_audio_file(data)
    assert_eq(audio.channels(), channels)
    assert_eq(audio.samples()[0].length(), 140)
    for i in 56..<84 {
      assert_eq(audio.samples()[0][i], 0.0)
    }
    let pcm = audio.to_wav_s16()
    let wav = av_wav_open(pcm).unwrap()
    assert_eq(telephony_md5(pcm[wav.data_offset.to_int():].to_owned()), hash)
  }
}
