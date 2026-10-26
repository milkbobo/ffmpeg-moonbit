///|
/// Stereo PCM references decoded by FFmpeg 9.0.2, generated from real
/// native/FDK encoder output and explicit CPE syntax. LGPL-2.1-or-later.
priv struct AacStereoCoverage {
  frames : Int32
  common : Int32
  ms_modes : Array[Int32]
  intensity : Int32
  noise : Int32
  tns : Int32
  short : Int32
}

///|
fn aac_check_stereo(
  encoded : Bytes,
  reference : Bytes,
) -> AacStereoCoverage raise {
  let data = @libavutil.av_base64_decode(encoded, 16384).unwrap()
  let pcm = @libavutil.av_base64_decode(reference, 131072).unwrap()
  let header = ff_adts_header_parse_buf(data).unwrap()
  assert_eq(header.chan_config, 2)
  let config = new_mpeg4_audio_config()
  config.object_type = 2
  config.sampling_index = header.sampling_index
  config.sample_rate = header.sample_rate
  config.chan_config = 2
  config.channels = 2
  config.frame_length = 1024
  let dec = new_aac_decoder(config, 2)
  let probe = new_aac_decoder(config, 2)
  let mut frames = 0
  let mut pos = 0
  let mut common = 0
  let ms_modes = Array::make(3, 0)
  let mut intensity = 0
  let mut noise = 0
  let mut tns = 0
  let mut short = 0
  let mut max_diff = 0
  let mut exact = 0
  while pos < data.length() {
    let hdr = ff_adts_header_parse_buf(
      data.clamped_view(start=pos, end=pos + av_aac_adts_header_size).to_owned(),
    ).unwrap()
    let end = pos + hdr.frame_length
    assert_true(end <= data.length())
    let start = pos +
      av_aac_adts_header_size +
      (if hdr.crc_absent == 0 { 2 } else { 0 })
    let payload = data.clamped_view(start~, end~).to_owned()
    let gb = BitReader::new(payload)
    let mut id = gb.read(3).reinterpret_as_int()
    while id == aac_id_filler || id == aac_id_pce {
      if id == aac_id_filler {
        ignore(probe.decode_fill_element(gb, -1, -1))
      } else {
        ignore(aac_decode_pce(gb).unwrap())
      }
      id = gb.read(3).reinterpret_as_int()
    }
    assert_eq(id, 1)
    gb.skip(4)
    let pair = probe.decode_pair(gb).unwrap()
    if pair.common_window {
      common = common + 1
    }
    ms_modes[pair.ms_present] = ms_modes[pair.ms_present] + 1
    for spectrum in [pair.left, pair.right] {
      let ics = spectrum.ics
      tns = tns + ics.tns_present
      if ics.info.window_sequence == aac_eight_short {
        short = short + 1
      }
      for g = 0; g < ics.info.num_window_groups; g = g + 1 {
        for band = 0; band < ics.info.max_sfb; band = band + 1 {
          let cb = ics.sect_cb[g][band]
          if cb == 14 || cb == 15 {
            intensity = intensity + 1
          }
          if cb == 13 {
            noise = noise + 1
          }
        }
      }
    }
    let out = match dec.decode_frame(payload) {
      Ok(v) => v
      Err(e) => fail("stereo frame \{frames}: \{e}")
    }
    assert_eq(out.length(), 2)
    for ch = 0; ch < 2; ch = ch + 1 {
      assert_eq(out[ch].samples.length(), 1024)
      for i = 0; i < 1024; i = i + 1 {
        let byte = ((frames * 1024 + i) * 2 + ch) * 2
        assert_true(byte + 1 < pcm.length())
        let value = pcm[byte].to_int() | (pcm[byte + 1].to_int() << 8)
        let want = if value >= 32768 { value - 65536 } else { value }
        let got = aac_s16p(out[ch].samples[i])
        let diff = if got > want { got - want } else { want - got }
        if diff > max_diff {
          max_diff = diff
        }
        if diff == 0 {
          exact = exact + 1
        }
      }
    }
    frames = frames + 1
    pos = end
  }
  assert_eq(frames * 4096, pcm.length())
  assert_true(max_diff <= 1)
  assert_true(exact * 1000 >= frames * 2048 * 999)
  { frames, common, ms_modes, intensity, noise, tns, short, }
}

///|
test "aac: native stereo PCM matches FFmpeg" {
  let coverage = aac_check_stereo(
    aac_stereo_native_b64, aac_stereo_native_pcm_b64,
  )
  assert_eq(coverage.frames, 10)
  assert_eq(coverage.common, 10)
  assert_eq(coverage.ms_modes, [0, 0, 10])
  assert_eq(coverage.intensity, 20)
  assert_eq(coverage.noise, 241)
  assert_eq(coverage.tns, 0)
  assert_eq(coverage.short, 2)
}

///|
test "aac: FDK stereo PCM matches FFmpeg" {
  let coverage = aac_check_stereo(aac_stereo_fdk_b64, aac_stereo_fdk_pcm_b64)
  assert_eq(coverage.frames, 11)
  assert_eq(coverage.common, 11)
  assert_eq(coverage.ms_modes, [2, 9, 0])
  assert_eq(coverage.intensity, 86)
  assert_eq(coverage.noise, 0)
  assert_eq(coverage.tns, 18)
  assert_eq(coverage.short, 10)
}

///|
test "aac: independent CPE windows and channel histories match FFmpeg" {
  let coverage = aac_check_stereo(
    aac_stereo_independent_b64, aac_stereo_independent_pcm_b64,
  )
  assert_eq(coverage.frames, 5)
  assert_eq(coverage.common, 0)
  assert_eq(coverage.ms_modes, [5, 0, 0])
  assert_eq(coverage.intensity, 0)
  assert_eq(coverage.noise, 0)
  assert_eq(coverage.tns, 0)
  assert_eq(coverage.short, 2)
}

///|
test "aac: every mid-side mode and intensity polarity match FFmpeg" {
  let coverage = aac_check_stereo(
    aac_stereo_joint_b64, aac_stereo_joint_pcm_b64,
  )
  assert_eq(coverage.frames, 9)
  assert_eq(coverage.common, 9)
  assert_eq(coverage.ms_modes, [3, 2, 4])
  assert_eq(coverage.intensity, 4)
  assert_eq(coverage.noise, 2)
  assert_eq(coverage.tns, 0)
}

///|
test "aac: mid-side masks use window groups and leave coefficient bits untouched" {
  let bw = BitWriter::new()
  bw.put(0, 1)
  bw.put(2, 2)
  bw.put(0, 1)
  bw.put(3, 4)
  bw.put(0b0101111, 7) // group lengths 1, 2, 5
  let info = aac_decode_ics_info(BitReader::new(bw.finish())).unwrap()
  assert_eq(info.window_group_length, [1, 2, 5])
  let bw = BitWriter::new()
  bw.put(0b101010101, 9)
  bw.put(0x2d, 6)
  let gb = BitReader::new(bw.finish())
  assert_eq(aac_decode_ms_mask(gb, info, 1).unwrap(), [
    [true, false, true],
    [false, true, false],
    [true, false, true],
  ])
  assert_eq(gb.count(), 9)
  assert_eq(gb.read(6), 0x2dU)
  for mode in [0, 2] {
    let gb = BitReader::new(b"\xff\xff")
    let mask = aac_decode_ms_mask(gb, info, mode).unwrap()
    for row in mask {
      for bit in row {
        assert_eq(bit, mode == 2)
      }
    }
    assert_eq(gb.count(), 0)
  }
  let gb = BitReader::with_size(b"\xff\xff", 8)
  assert_eq(
    aac_decode_ms_mask(gb, info, 1).unwrap_err(),
    "truncated mid-side mask",
  )
  assert_eq(gb.count(), 0)
  assert_eq(
    aac_decode_ms_mask(gb, info, 3).unwrap_err(),
    "ms_present = 3 is reserved",
  )
}

///|
/// Minimal silent pair with KBD current windows. A failed tail must not
/// change either previous window shape or either overlap buffer.
fn aac_test_silent_pair(
  tail : Int32,
  mode~ : Int32 = 0,
  bands~ : Int32 = 0,
) -> Bytes {
  let bw = BitWriter::new()
  bw.put(1, 3)
  bw.put(0, 4)
  bw.put(1, 1)
  bw.put(0, 1)
  bw.put(0, 2)
  bw.put(1, 1)
  bw.put(bands.reinterpret_as_uint(), 6)
  bw.put(0, 1)
  bw.put(mode.reinterpret_as_uint(), 2)
  for _ch = 0; _ch < 2; _ch = _ch + 1 {
    bw.put(100, 8)
    bw.put(0, 3) // no tools; max_sfb = 0 has no section/scalefactor bits
  }
  bw.put(tail.reinterpret_as_uint(), 3)
  bw.finish()
}

///|
test "aac: invalid CPE modes, geometry and channel capacity return errors" {
  let dec = new_aac_decoder(new_mpeg4_audio_config(), 2)
  assert_eq(
    dec.decode_frame(aac_test_silent_pair(7, mode=3)).unwrap_err(),
    "ms_present = 3 is reserved",
  )
  assert_eq(
    dec.decode_frame(aac_test_silent_pair(7, bands=63)).unwrap_err(),
    "max_sfb exceeds the scalefactor band count",
  )
  let mono = new_aac_decoder(new_mpeg4_audio_config(), 1)
  assert_eq(
    mono.decode_frame(aac_test_silent_pair(7)).unwrap_err(),
    "insufficient AAC channel states",
  )
  let empty = new_aac_decoder(new_mpeg4_audio_config(), 0)
  assert_eq(
    empty.decode_frame(build_sce_frame(false)).unwrap_err(),
    "insufficient AAC channel states",
  )
  assert_eq(dec.decode_frame(b"").unwrap_err(), "missing channel element")
}

///|
test "aac: malformed CPE tails leave both channel window histories unchanged" {
  let dec = new_aac_decoder(new_mpeg4_audio_config(), 2)
  assert_eq(
    dec.decode_frame(aac_test_silent_pair(2)).unwrap_err(),
    "missing element instance tag",
  )
  assert_eq(
    dec.decode_frame(aac_test_silent_pair(0)).unwrap_err(),
    "AAC channel layout is required for multiple elements",
  )
  for state in dec.channels {
    assert_eq(state.prev_window_shape, 0)
    for sample in state.saved {
      assert_eq(sample, 0.0)
    }
  }
  let out = dec.decode_frame(aac_test_silent_pair(7)).unwrap()
  assert_eq(out.length(), 2)
  for ch = 0; ch < 2; ch = ch + 1 {
    assert_eq(dec.channels[ch].prev_window_shape, 1)
    for sample in out[ch].samples {
      assert_eq(sample, 0.0)
    }
  }
}
