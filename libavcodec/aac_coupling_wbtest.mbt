///|
/// CCE expected PCM is decoded by FFmpeg 9.0.2 from the same synthetic
/// ADTS bytes; see scripts/generate_aac_coupling_vectors.py. LGPL-2.1-or-later.
test "aac CCE: before TNS signed differential gains and grouped short windows" {
  assert_eq(
    aac_check_layout(
      aac_coupling_before_tns_b64,
      aac_coupling_before_tns_pcm_b64,
      [2],
    ),
    10,
  )
}

///|
test "aac CCE: between TNS and IMDCT differential gains" {
  assert_eq(
    aac_check_layout(
      aac_coupling_after_tns_b64,
      aac_coupling_after_tns_pcm_b64,
      [2],
    ),
    10,
  )
}

///|
test "aac CCE: independent coupling retains separate overlap history" {
  assert_eq(
    aac_check_layout(
      aac_coupling_independent_b64,
      aac_coupling_independent_pcm_b64,
      [2],
    ),
    10,
  )
}

///|
test "aac CCE: CPE channel selection and sixteen common gain lists" {
  assert_eq(
    aac_check_layout(
      aac_coupling_stereo_select_b64,
      aac_coupling_stereo_select_pcm_b64,
      [0, 1],
    ),
    10,
  )
}

///|
test "aac CCE: CPE signed gains and zero delta cache" {
  assert_eq(
    aac_check_layout(
      aac_coupling_stereo_signed_b64,
      aac_coupling_stereo_signed_pcm_b64,
      [0, 1],
    ),
    10,
  )
}

///|
test "aac CCE: CPE independent gains and both channel selections" {
  assert_eq(
    aac_check_layout(
      aac_coupling_stereo_independent_b64,
      aac_coupling_stereo_independent_pcm_b64,
      [0, 1],
    ),
    10,
  )
}

///|
test "aac CCE: multiple sources sorted by tag and applied at all three points" {
  assert_eq(
    aac_check_layout(aac_coupling_multiple_b64, aac_coupling_multiple_pcm_b64, [
      0, 1,
    ]),
    10,
  )
}

///|
fn aac_test_silent_cce(bw : BitWriter, tag : UInt32, target : UInt32) -> Unit {
  bw.put(2, 3)
  bw.put(tag, 4)
  bw.put(1, 1) // independent coupling
  bw.put(0, 3) // one target
  bw.put(0, 1) // SCE
  bw.put(target, 4)
  bw.put(1, 1)
  bw.put(0, 3) // sign and scale
  bw.put(100, 8)
  bw.put(0, 11) // long window, max_sfb=0
  bw.put(0, 3) // no tools, no spectral data or explicit first gain
}

///|
test "aac CCE: missing targets and duplicate source tags fail before history updates" {
  let config = new_mpeg4_audio_config()
  config.chan_config = 1
  config.sampling_index = 3
  let dec = new_aac_decoder(config, 1)
  let bw = BitWriter::new()
  aac_test_silent_cce(bw, 9, 1)
  aac_test_zero_sce(bw, 0, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "CCE target is missing from the AAC frame",
  )
  assert_true(dec.coupling_states[9] is None)
  assert_eq(dec.state_keys, [-1])
  let bw = BitWriter::new()
  aac_test_silent_cce(bw, 9, 0)
  aac_test_silent_cce(bw, 9, 0)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "duplicate AAC channel element",
  )
  assert_true(dec.coupling_states[9] is None)
}

///|
test "aac CCE: every truncated frame prefix preserves established source and target history" {
  let data = @libavutil.av_base64_decode(aac_coupling_independent_b64, 16384).unwrap()
  let size = ff_adts_header_parse_buf(data).unwrap().frame_length
  let payload = data.clamped_view(start=7, end=size).to_owned()
  let config = new_mpeg4_audio_config()
  config.sampling_index = 3
  let dec = new_aac_decoder(config, 1)
  ignore(dec.decode_frame(payload).unwrap())
  let source = dec.coupling_states[9].unwrap()
  let source_saved = source.saved.map(x => x)
  let source_shape = source.prev_window_shape
  let source_sequence = source.prev_window_sequence
  let target_saved = dec.channels[0].saved.map(x => x)
  let random = dec.noise.random_state
  for length = 0; length < payload.length(); length = length + 1 {
    assert_true(
      dec.decode_frame(payload.clamped_view(end=length).to_owned()) is Err(_),
    )
    assert_eq(dec.coupling_states[9].unwrap().saved, source_saved)
    assert_eq(source.prev_window_shape, source_shape)
    assert_eq(source.prev_window_sequence, source_sequence)
    assert_eq(dec.channels[0].saved, target_saved)
    assert_eq(dec.noise.random_state, random)
  }
}

///|
test "aac: empty AAC sections consume input and truncated escape chains fail" {
  // FFmpeg decode_band_types permits empty sections but checks the reader
  // after every length increment, so a zero-padded overread must terminate.
  let info = aac_test_ics_info(1)
  let bw = BitWriter::new()
  bw.put(5, 4)
  bw.put(0, 5)
  bw.put(0, 4)
  bw.put(1, 5)
  let gb = BitReader::with_size(bw.finish(), 18)
  assert_eq(aac_decode_section_data(gb, info).unwrap(), [[0]])
  assert_eq(gb.count(), 18)
  let bw = BitWriter::new()
  bw.put(0, 4)
  bw.put(0, 5)
  assert_eq(
    aac_decode_section_data(BitReader::with_size(bw.finish(), 9), info).unwrap_err(),
    "truncated AAC section data",
  )
  let bw = BitWriter::new()
  bw.put(5, 4)
  bw.put(31, 5)
  assert_eq(
    aac_decode_section_data(
      BitReader::with_size(bw.finish(), 9),
      aac_test_ics_info(49),
    ).unwrap_err(),
    "truncated AAC section data",
  )
}

///|
test "aac CCE: PCE declaration changes clear removed histories only on successful frames" {
  let data = @libavutil.av_base64_decode(aac_coupling_independent_b64, 16384).unwrap()
  let size = ff_adts_header_parse_buf(data).unwrap().frame_length
  let config = new_mpeg4_audio_config()
  config.sampling_index = 3
  let dec = new_aac_decoder(config, 1)
  ignore(
    dec.decode_frame(data.clamped_view(start=7, end=size).to_owned()).unwrap(),
  )
  assert_eq(dec.coupling_tags, [9])
  let saved = dec.coupling_states[9].unwrap().saved.map(x => x)
  let pce = aac_test_pce([[0, 0]], [], [], [], raw_block=true)
  let bw = BitWriter::new()
  for byte in pce {
    bw.put(byte.to_uint(), 8)
  }
  aac_test_silent_cce(bw, 9, 0)
  aac_test_zero_sce(bw, 0, false)
  bw.put(7, 3)
  assert_eq(
    dec.decode_frame(bw.finish()).unwrap_err(),
    "coupling element is not declared in AAC PCE",
  )
  assert_eq(dec.coupling_tags, [9])
  assert_eq(dec.coupling_states[9].unwrap().saved, saved)
  let bw = BitWriter::new()
  for byte in pce {
    bw.put(byte.to_uint(), 8)
  }
  aac_test_zero_sce(bw, 0, false)
  bw.put(7, 3)
  ignore(dec.decode_frame(bw.finish()).unwrap())
  assert_eq(dec.coupling_tags, [])
  assert_true(dec.coupling_states[9] is None)
}
