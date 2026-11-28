///|
test "Amiga SVX exports planar PCM and keeps an odd mono sample count" {
  for channels in [1, 2] {
    let wav = wav_muxer_new(22050, channels, 16).unwrap()
    wav.write_samples(
      if channels == 1 {
        [-32768, 0, 32512][:]
      } else {
        [-32768, 512, 0, -512, 32512, -1024][:]
      },
    )
    let input = decode_audio_file(wav.finish())
    for bits in [8, 16] {
      let written = input.to_svx(bits~)
      let size = 3 * channels * (bits / 8)
      let track = av_svx_open(written).unwrap()
      assert_eq(track.frames[0].size, size)
      assert_eq(track.total_samples, 3L)
      assert_eq(
        written.length() - track.frames[0].pos.to_int() - size,
        size % 2,
      )
      let decoded = decode_audio_file(written)
      assert_eq(decoded.sample_rate(), 22050)
      assert_eq(decoded.samples(), input.samples())
      if bits == 8 && channels == 2 {
        let body = track.frames[0].pos.to_int()
        assert_eq(written[body:], b"\x80\x00\x7f\x02\xfe\xfc")
        let corrupt = written.to_array()
        corrupt[body - 1] = 5
        assert_true(
          av_svx_open(Bytes::from_array(corrupt))
          is Err("svx: unequal channel planes"),
        )
      }
    }
  }
}

///|
test "16SV accepts a 14-byte VHDR without compression fields" {
  let data = b"FORM\x00\x00\x00\x24" +
    b"16SVVHDR\x00\x00\x00\x0e\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x1f\x40" +
    b"BODY\x00\x00\x00\x02\x80\x00"
  let audio = decode_audio_file(data)
  assert_eq(audio.sample_rate(), 8000)
  assert_eq(audio.samples(), [[-1.0]])
}

///|
test "NSP reads both rate headers and excludes NOTE and trailing bytes from PCM" {
  for (header, tag, channels) in [("HEDR", "SD_A", 1), ("HDR8", "SDAB", 2)] {
    let out = b"FORMDS16\x00\x00\x00\x00".to_array()
    wav_mux_tag(out, header)
    wav_mux_u32(out, 32U)
    for _ in 0..<20 {
      out.push(0)
    }
    wav_mux_u32(out, 32000U)
    for _ in 0..<8 {
      out.push(0)
    }
    out.append(b"NOTE\x03\x00\x00\x00ab\x00\x00".to_array())
    wav_mux_tag(out, tag)
    wav_mux_u32(out, 4U)
    out.append([0, 128, 255, 127, 0, 0])
    let audio = decode_audio_file(Bytes::from_array(out))
    assert_eq(audio.format_name(), "nsp")
    assert_eq(audio.sample_rate(), 32000)
    assert_eq(audio.channels(), channels)
    let pcm = if channels == 1 {
      [[-1.0, 32767.0 / 32768.0]]
    } else {
      [[-1.0], [32767.0 / 32768.0]]
    }
    assert_eq(audio.samples(), pcm)
  }
}
