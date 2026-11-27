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
