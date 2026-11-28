///|
test "WAV and Wave64 FLAC index full frames and normalize STREAMINFO" {
  let pcm = Array::makei(170, i => 0x571221 - i * 321)
  let flac = @libavcodec.flac_encode(pcm, 2, 48000, 24, block_size=32).unwrap()
  let frames : Array[Byte] = []
  for frame in flac.frames {
    frames.append(frame.to_array())
  }
  let expected_size = frames.length()
  for wave64 in [false, true] {
    let fmt : Array[Byte] = []
    let extra = if wave64 {
      b"fLaC\x80\x00\x00\x22" + flac.streaminfo
    } else {
      flac.streaminfo
    }
    wav_mux_u16(fmt, 0xF1AC)
    wav_mux_u16(fmt, 2)
    wav_mux_u32(fmt, 48000U)
    wav_mux_u32(fmt, 16000U)
    wav_mux_u16(fmt, 4)
    wav_mux_u16(fmt, 16)
    wav_mux_u16(fmt, extra.length())
    fmt.append(extra.to_array())
    let file : Array[Byte] = []
    if wave64 {
      let fmt_size = w64_align8(24L + fmt.length().to_int64())
      let data_size = w64_align8(24L + expected_size.to_int64())
      file.append(w64_guid_riff.to_array())
      w64_le64(file, 40L + fmt_size + data_size)
      file.append(w64_guid_wave.to_array())
      file.append(w64_guid_fmt.to_array())
      w64_le64(file, fmt_size)
      file.append(fmt)
      while file.length() % 8 != 0 {
        file.push(0)
      }
      file.append(w64_guid_data.to_array())
      w64_le64(file, data_size)
      file.append(frames)
      while file.length() % 8 != 0 {
        file.push(0)
      }
    } else {
      file.append(b"RIFF".to_array())
      wav_mux_u32(
        file,
        (20 + fmt.length() + expected_size + expected_size % 2).reinterpret_as_uint(),
      )
      file.append(b"WAVEfmt ".to_array())
      wav_mux_u32(file, fmt.length().reinterpret_as_uint())
      file.append(fmt)
      file.append(b"data".to_array())
      wav_mux_u32(file, expected_size.reinterpret_as_uint())
      file.append(frames)
      if expected_size % 2 != 0 {
        file.push(0)
      }
    }
    let data = Bytes::from_array(file)
    let demux = if wave64 {
      av_w64_open(data).unwrap()
    } else {
      av_wav_open(data).unwrap()
    }
    assert_eq(demux.format.codec, "flac")
    assert_eq(demux.format.bits_per_sample, 24)
    assert_eq(demux.format.extradata, flac.streaminfo)
    assert_eq(demux.data_size, expected_size.to_int64())
    assert_eq(demux.sample_count, 85L)
    let media = MediaFile::open(data)
    for i in 0..<flac.frames.length() {
      let packet = media.next_packet().unwrap()
      assert_eq(packet.data, flac.frames[i])
      assert_eq(packet.pts, i.to_int64() * 32L)
    }
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(data)
    assert_eq(audio.samples, decode_audio_file(flac.file()).samples)
    let end = (demux.data_offset + demux.data_size).to_int() - 1
    file[end] = (file[end].to_int() ^ 1).to_byte()
    let corrupt = Bytes::from_array(file)
    let err = if wave64 { av_w64_open(corrupt) } else { av_wav_open(corrupt) }
    assert_true(err is Err("flac: frame CRC mismatch"))
  }
}

///|
test "WAV and Wave64 FLAC export preserve PCM and the explicit speaker mask" {
  let channels = 6
  let frames = 4101
  let mask = 0x3fU
  let wav = wav_muxer_new(48000, channels, 32, channel_mask=mask).unwrap()
  wav.write_samples(
    Array::makei(frames * channels, i => (i.to_uint64() * 2654435761UL).to_int())[:],
  )
  let audio = decode_audio_file(wav.finish())
  for wave64 in [false, true] {
    let file = audio.to_wav_flac(bits=32, wave64~)
    let track = if wave64 {
      av_w64_open(file).unwrap()
    } else {
      av_wav_open(file).unwrap()
    }
    assert_eq(track.format.format_tag, 0xf1ac)
    assert_eq(track.format.bits_per_sample, 32)
    assert_eq(track.format.channel_mask, mask)
    assert_eq(track.packets.map(p => (p.pts, p.duration)), [
      (0L, 4096),
      (4096L, 5),
    ])
    assert_eq(track.sample_count, 4101L)
    let decoded = decode_audio_file(file)
    assert_eq(decoded.channel_mask, mask)
    assert_eq(decoded.samples(), audio.samples())
  }
}

///|
test "WAV FLAC remux preserves native STREAMINFO and coded frames" {
  let flac = @libavcodec.flac_encode(
    Array::makei(170, i => i * 27 - 1500),
    1,
    44100,
    16,
    block_size=32,
  ).unwrap()
  let raw = flac.file()
  let file = av_wav_mux_flac(raw).unwrap()
  let demux = av_wav_open(file).unwrap()
  let start = demux.data_offset.to_int()
  assert_eq(file[start:start + demux.data_size.to_int()], raw[42:])
  assert_eq(demux.format.extradata, flac.streaminfo)
  assert_eq(demux.sample_count, 170L)
  assert_true(av_wav_mux_flac(raw, channel_mask=3U) is Err(_))
  assert_true(av_wav_mux_flac(raw[:raw.length() - 1].to_owned()) is Err(_))
}
