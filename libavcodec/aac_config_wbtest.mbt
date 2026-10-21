///|
/// AAC-LC GASpecificConfig grammar from FFmpeg 9.0.2 aac/aacdec.c.
/// Real ASC-only PCE packet/PCM references live in libavformat's AAC ASC
/// MP4 integration tests. LGPL-2.1-or-later.
fn aac_test_asc_header(
  aot : Int32,
  rate : Int32,
  channels : Int32,
  flags : Int32,
) -> BitWriter {
  let bw = BitWriter::new()
  bw.put(aot.reinterpret_as_uint(), 5)
  bw.put(rate.reinterpret_as_uint(), 4)
  bw.put(channels.reinterpret_as_uint(), 4)
  bw.put(flags.reinterpret_as_uint(), 3)
  bw
}

///|
/// A PCE starts at bit 16 normally, or bit 30 with coreCoderDelay. Its
/// alignment must use ASC bit zero in both cases, rather than its tag.
fn aac_test_asc_pce(core_delay : Bool, extension : Bool) -> Bytes {
  let bw = BitWriter::new()
  bw.put(2, 5)
  bw.put(3, 4)
  bw.put(0, 4)
  bw.put(0, 1)
  bw.put(if core_delay { 1U } else { 0U }, 1)
  if core_delay {
    bw.put(0x1234, 14)
  }
  bw.put(if extension { 1U } else { 0U }, 1)
  bw.put(5, 4) // PCE tag
  bw.put(1, 2)
  bw.put(3, 4)
  bw.put(2, 4) // front SCE7 + CPE3
  bw.put(0, 4) // side
  bw.put(1, 4) // back CPE9
  bw.put(1, 2) // LFE2
  bw.put(0, 7) // assoc / cc
  bw.put(0, 3) // mixdown flags
  bw.put(0, 1)
  bw.put(7, 4)
  bw.put(1, 1)
  bw.put(3, 4)
  bw.put(1, 1)
  bw.put(9, 4)
  bw.put(2, 4)
  let before_align = 16 + (if core_delay { 14 } else { 0 }) + 34 + 19
  bw.put(0, (0 - before_align) & 7)
  bw.put(0, 8) // zero-length comment
  if extension {
    bw.put(0, 1)
  } // extensionFlag3
  bw.finish()
}

///|
test "aac ASC: indexed configurations initialize decoder capacity and output order" {
  let counts = [1, 2, 3, 4, 5, 6, 8]
  for config = 1; config <= 7; config = config + 1 {
    let data = aac_test_asc_header(2, 3, config, 0).finish()
    let parsed = aac_parse_audio_specific_config(data).unwrap()
    assert_eq(parsed.config.channels, counts[config - 1])
    assert_eq(parsed.config.sample_rate, 48000)
    assert_eq(parsed.bits_consumed, 16)
    let dec = new_aac_decoder_from_asc(data).unwrap()
    assert_eq(dec.channels.length(), counts[config - 1])
    assert_eq(
      dec.layout.map(channel => channel.position),
      aac_default_layout(config).unwrap().map(channel => channel.position),
    )
    assert_eq(dec.state_keys, Array::make(counts[config - 1], -1))
  }
}

///|
test "aac ASC: PCE alignment includes core coder delay and optional extensionFlag3" {
  for core_delay in [false, true] {
    for extension in [false, true] {
      let data = aac_test_asc_pce(core_delay, extension)
      let parsed = aac_parse_audio_specific_config(data).unwrap()
      assert_eq(parsed.config.chan_config, 0)
      assert_eq(parsed.config.channels, 6)
      assert_eq(parsed.layout.map(channel => channel.position), [
        0, 1, 2, 3, 4, 5,
      ])
      assert_eq(parsed.layout.map(channel => channel.element_tag), [
        3, 3, 7, 2, 9, 9,
      ])
      assert_eq(
        parsed.bits_consumed,
        (if core_delay { 96 } else { 80 }) + (if extension { 1 } else { 0 }),
      )
      let dec = new_aac_decoder_from_asc(data).unwrap()
      assert_eq(dec.channels.length(), 6)
      assert_eq(dec.layout.map(channel => channel.element_tag), [
        3, 3, 7, 2, 9, 9,
      ])
    }
  }
}

///|
test "aac ASC: truncated GA flags core delay PCE and extensionFlag3 return errors" {
  assert_eq(
    aac_parse_audio_specific_config(b"\x11").unwrap_err(),
    "truncated AAC GASpecificConfig",
  )
  assert_eq(
    aac_parse_audio_specific_config(b"\x11\x92").unwrap_err(),
    "truncated AAC core coder delay",
  )
  assert_eq(
    aac_parse_audio_specific_config(b"\x11\x91").unwrap_err(),
    "truncated AAC extensionFlag3",
  )
  let data = aac_test_asc_pce(false, false)
  for length = 0; length < data.length(); length = length + 1 {
    match
      aac_parse_audio_specific_config(data.clamped_view(end=length).to_owned()) {
      Err(_) => ()
      Ok(_) => fail("truncated ASC accepted at byte \{length}")
    }
  }
}

///|
test "aac ASC: unsupported profiles rates and 960 frame initialization" {
  assert_eq(
    new_aac_decoder_from_asc(aac_test_asc_header(1, 3, 2, 0).finish()).unwrap_err(),
    "only AAC-LC AudioSpecificConfig is supported",
  )
  assert_eq(
    new_aac_decoder_from_asc(aac_test_asc_header(2, 13, 2, 0).finish()).unwrap_err(),
    "invalid AAC sampling rate index",
  )
  let bw = BitWriter::new()
  bw.put(2, 5)
  bw.put(15, 4)
  bw.put(48000, 24)
  bw.put(2, 4)
  bw.put(0, 3)
  assert_eq(
    new_aac_decoder_from_asc(bw.finish()).unwrap_err(),
    "invalid AAC sampling rate index",
  )
  assert_eq(
    new_aac_decoder_from_asc(aac_test_asc_header(2, 3, 8, 0).finish()).unwrap_err(),
    "unsupported AAC channel configuration",
  )
  let data = aac_test_asc_header(2, 3, 2, 4).finish()
  assert_eq(
    aac_parse_audio_specific_config(data).unwrap().config.frame_length,
    960,
  )
  let decoder = new_aac_decoder_from_asc(data).unwrap()
  assert_eq(decoder.swb.offsets_long[decoder.swb.num_long], 960U)
  assert_eq(decoder.swb.offsets_short[decoder.swb.num_short], 120U)
}

///|
test "aac ASC: active explicit or implicit SBR PS is rejected while disabled SBR is accepted" {
  for aot in [5, 29] {
    let bw = BitWriter::new()
    bw.put(aot.reinterpret_as_uint(), 5)
    bw.put(6, 4) // 24 kHz core
    bw.put(1, 4)
    bw.put(3, 4) // 48 kHz extension
    bw.put(2, 5)
    bw.put(0, 3)
    assert_eq(
      new_aac_decoder_from_asc(bw.finish()).unwrap_err(),
      "SBR/PS AudioSpecificConfig is not supported",
    )
  }
  for extension_rate in [3, 0] {
    let bw = aac_test_asc_header(2, 3, 2, 0)
    bw.put(0x2b7, 11)
    bw.put(5, 5)
    bw.put(1, 1)
    bw.put(extension_rate.reinterpret_as_uint(), 4)
    assert_eq(
      new_aac_decoder_from_asc(bw.finish()).unwrap_err(),
      "SBR/PS AudioSpecificConfig is not supported",
    )
  }
  let parsed = aac_parse_audio_specific_config(b"\x11\x90\x56\xe5\x00").unwrap()
  assert_eq(parsed.config.sbr, 0)
  assert_eq(parsed.config.channels, 2)
  assert_eq(parsed.bits_consumed, 16)
}

///|
test "aac ASC: PCE errors propagate from parser to decoder initialization" {
  let duplicate = b"\x11\x80" + aac_test_pce([[0, 0], [0, 0]], [], [], [])
  assert_eq(
    new_aac_decoder_from_asc(duplicate).unwrap_err(),
    "duplicate PCE channel element",
  )
  let height = b"\x11\x80" +
    aac_test_pce([[0, 0]], [], [], [], comment=b"\xac\x00\x00")
  assert_eq(new_aac_decoder_from_asc(height).unwrap().layout[0].position, 2)
}
