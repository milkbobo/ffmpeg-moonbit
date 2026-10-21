///|
/// AAC layout/PCE boundary cases derived from FFmpeg 9.0.2 decode_pce,
/// ff_aac_channel_layout_map and ff_aac_channel_map. LGPL-2.1-or-later.
fn aac_test_pce(
  front : Array[Array[Int32]],
  side : Array[Array[Int32]],
  back : Array[Array[Int32]],
  lfe : Array[Int32],
  comment~ : Bytes = b"",
  cc~ : Int32 = 0,
  raw_block~ : Bool = false,
) -> Bytes {
  let bw = BitWriter::new()
  if raw_block {
    bw.put(5, 3)
  }
  bw.put(5, 4) // PCE instance tag (the three-bit element id is not included)
  bw.put(1, 2)
  bw.put(3, 4)
  bw.put(front.length().reinterpret_as_uint(), 4)
  bw.put(side.length().reinterpret_as_uint(), 4)
  bw.put(back.length().reinterpret_as_uint(), 4)
  bw.put(lfe.length().reinterpret_as_uint(), 2)
  bw.put(0, 3)
  bw.put(cc.reinterpret_as_uint(), 4)
  bw.put(0, 3) // no mixdown fields
  for group in [front, side, back] {
    for entry in group {
      bw.put(entry[0].reinterpret_as_uint(), 1)
      bw.put(entry[1].reinterpret_as_uint(), 4)
    }
  }
  for tag in lfe {
    bw.put(tag.reinterpret_as_uint(), 4)
  }
  for _i = 0; _i < cc; _i = _i + 1 {
    bw.put(0, 5)
  }
  let count = (if raw_block { 3 } else { 0 }) +
    4 +
    6 +
    21 +
    3 +
    5 * (front.length() + side.length() + back.length() + cc) +
    4 * lfe.length()
  bw.put(0, (0 - count) & 7)
  bw.put(comment.length().reinterpret_as_uint(), 8)
  for byte in comment {
    bw.put(byte.to_uint(), 8)
  }
  bw.finish()
}

///|
test "aac: indexed layouts 1 through 7 match FFmpeg channel maps" {
  let positions = [
    [2],
    [0, 1],
    [0, 1, 2],
    [0, 1, 2, 8],
    [0, 1, 2, 4, 5],
    [0, 1, 2, 3, 4, 5],
    [0, 1, 2, 3, 4, 5, 9, 10],
  ]
  for config = 1; config <= 7; config = config + 1 {
    let layout = aac_default_layout(config).unwrap()
    assert_eq(layout.map(channel => channel.position), positions[config - 1])
  }
  let layout = aac_default_layout(7).unwrap()
  assert_eq(layout[4].element_tag, 2) // BL/BR from CPE2, SL/SR from CPE1
  assert_eq(layout[6].element_tag, 1)
  for config in [-1, 8, 9, 10, 15] {
    assert_eq(
      aac_default_layout(config).unwrap_err(),
      "unsupported AAC channel configuration",
    )
  }
}

///|
test "aac: PCE front side back LFE channels use AVChannel order and exact tags" {
  let data = aac_test_pce(
    [[0, 7], [1, 2]],
    [[1, 9]],
    [[1, 4]],
    [3],
    comment=b"comment",
  )
  let gb = BitReader::new(data)
  let layout = aac_decode_pce(gb).unwrap()
  assert_eq(layout.map(channel => channel.position), [0, 1, 2, 3, 4, 5, 9, 10])
  assert_eq(layout.map(channel => channel.element_tag), [2, 2, 7, 3, 4, 4, 9, 9])
  assert_eq(gb.bits_left(), 0)
}

///|
test "aac: PCE duplicate tags unsupported arrangements and extensions are rejected" {
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([[0, 0], [0, 0]], [], [], []))).unwrap_err(),
    "duplicate PCE channel element",
  )
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([[1, 0], [0, 0]], [], [], []))).unwrap_err(),
    "unsupported PCE channel arrangement",
  )
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([], [[0, 0]], [], []))).unwrap_err(),
    "unsupported PCE channel arrangement",
  )
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([], [], [], []))).unwrap_err(),
    "PCE has no audio channels",
  )
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([[0, 0]], [], [], [], cc=1)))
    .unwrap()
    .length(),
    1,
  )
  assert_eq(
    aac_decode_pce(BitReader::new(aac_test_pce([[0, 0]], [], [], [], cc=2))).unwrap_err(),
    "duplicate PCE coupling element",
  )
  assert_eq(
    aac_decode_pce(
      BitReader::new(
        aac_test_pce([[0, 0]], [], [], [], comment=b"\xac\x00\x00"),
      ),
    ).unwrap()[0].position,
    2,
  )
}

///|
test "aac: every truncated PCE prefix is rejected without overreading" {
  let data = aac_test_pce(
    [[0, 0], [1, 0]],
    [],
    [[1, 1]],
    [0],
    comment=b"PCE test",
  )
  for length = 0; length < data.length() * 8; length = length + 1 {
    let gb = BitReader::with_size(data, length)
    assert_eq(
      aac_decode_pce(gb).unwrap_err(),
      "program_config_element overruns the frame",
    )
  }
}

///|
fn aac_test_zero_sce(bw : BitWriter, tag : Int32, noise : Bool) -> Unit {
  bw.put(0, 3)
  bw.put(tag.reinterpret_as_uint(), 4)
  bw.put(100, 8)
  bw.put(0, 1)
  bw.put(0, 2)
  bw.put(1, 1) // KBD to detect premature window history updates
  bw.put(if noise { 1U } else { 0U }, 6)
  bw.put(0, 1)
  if noise {
    bw.put(13, 4)
    bw.put(1, 5)
    bw.put(256, 9)
  }
  bw.put(0, 3)
}

///|
test "aac: missing duplicate and undeclared elements fail without committing channel state" {
  let config = new_mpeg4_audio_config()
  config.chan_config = 3
  config.channels = 3
  let dec = new_aac_decoder(config, 3)
  let bw = BitWriter::new()
  aac_test_zero_sce(bw, 0, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "AAC frame does not contain every declared channel",
  )
  let bw = BitWriter::new()
  aac_test_zero_sce(bw, 0, false)
  aac_test_zero_sce(bw, 0, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "duplicate AAC channel element",
  )
  let bw = BitWriter::new()
  aac_test_zero_sce(bw, 1, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "channel element is not declared in AAC layout",
  )
  for state in dec.channels {
    assert_eq(state.prev_window_shape, 0)
    for sample in state.saved {
      assert_eq(sample, 0.0)
    }
  }
  assert_eq(dec.state_keys, [-1, -1, -1])
  assert_eq(config.chan_config, 3)
  assert_eq(config.channels, 3)
}

///|
test "aac: failed noise frames restore the PNS generator as well as window history" {
  let config = new_mpeg4_audio_config()
  config.chan_config = 1
  config.sampling_index = 3
  let dec = new_aac_decoder(config, 1)
  let random = dec.noise.random_state
  let bw = BitWriter::new()
  aac_test_zero_sce(bw, 0, true)
  bw.put(2, 3) // truncated coupling after the noise samples were generated
  assert_eq(dec.decode_frame(bw.finish()).unwrap_err(), "truncated CCE header")
  assert_eq(dec.noise.random_state, random)
  assert_eq(dec.channels[0].prev_window_shape, 0)
  assert_eq(dec.state_keys, [-1])
}

///|
test "aac: unsuccessful PCE frames preserve the previous committed layout" {
  let config = new_mpeg4_audio_config()
  config.chan_config = 1
  config.channels = 1
  let dec = new_aac_decoder(config, 1)
  let pce = aac_test_pce([[0, 0], [0, 1]], [], [], [], raw_block=true)
  assert_eq(
    dec.decode_frame(pce + b"\xe0").unwrap_err(),
    "missing channel element",
  )
  assert_eq(
    dec.decode_frame(pce + pce + b"\xe0").unwrap_err(),
    "multiple PCEs are not supported",
  )
  let bw = BitWriter::new()
  for byte in pce {
    bw.put(byte.to_uint(), 8)
  }
  aac_test_zero_sce(bw, 0, false)
  aac_test_zero_sce(bw, 1, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "insufficient AAC channel states",
  )
  assert_eq(dec.layout.map(channel => channel.position), [2])
  assert_eq(config.chan_config, 1)
  assert_eq(config.channels, 1)
  assert_eq(dec.state_keys, [-1])
  assert_eq(dec.channels[0].prev_window_shape, 0)
}

///|
test "aac: indexed stereo admits dual mono and retains separate histories" {
  let config = new_mpeg4_audio_config()
  config.chan_config = 2
  let dec = new_aac_decoder(config, 2)
  let bw = BitWriter::new()
  aac_test_zero_sce(bw, 0, false)
  aac_test_zero_sce(bw, 1, false)
  bw.put(7, 3)
  let out = dec.decode_frame(bw.finish()).unwrap()
  assert_eq(out.length(), 2)
  assert_eq(dec.layout.map(channel => channel.position), [0, 1])
  assert_eq(dec.state_keys, [0, 2])
}

///|
test "aac: truncated and extended DSE lengths are bounded" {
  assert_eq(
    aac_skip_data_element(BitReader::new(b"\x00")).unwrap_err(),
    "data_stream_element overruns the frame",
  )
  let bw = BitWriter::new()
  bw.put(1, 1)
  bw.put(255, 8)
  bw.put(2, 8) // 257 bytes promised; only three bytes of padding follow
  bw.put(0, 24)
  assert_eq(
    aac_skip_data_element(BitReader::new(bw.finish())).unwrap_err(),
    "data_stream_element overruns the frame",
  )
}
