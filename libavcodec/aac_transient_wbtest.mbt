///|
/// AAC-LC transient streams from FFmpeg's native and FDK encoders, with
/// PCM reference output from FFmpeg 9.0.2. LGPL-2.1-or-later.
priv struct AacTransientCoverage {
  windows : Array[Int32]
  shapes : Array[Int32]
  grouped : Int32
  tns : Int32
  pns : Int32
  exact : Int32
  samples : Int32
}

///|
fn aac_check_transient(
  encoded : Bytes,
  reference : Bytes,
) -> AacTransientCoverage raise {
  let data = @libavutil.av_base64_decode(encoded, 16384).unwrap()
  let pcm = @libavutil.av_base64_decode(reference, 65536).unwrap()
  let header = ff_adts_header_parse_buf(data).unwrap()
  let config = new_mpeg4_audio_config()
  config.object_type = 2
  config.sampling_index = header.sampling_index
  config.sample_rate = header.sample_rate
  config.chan_config = header.chan_config
  config.channels = 1
  config.frame_length = 1024
  let dec = new_aac_decoder(config, 1)
  let windows = Array::make(4, 0)
  let shapes = Array::make(2, 0)
  let mut tns = 0
  let mut pns = 0
  let mut grouped = 0
  let mut pos = 0
  let mut frames = 0
  let mut max_diff = 0
  let mut exact = 0
  while pos < data.length() {
    let hdr = ff_adts_header_parse_buf(
      data.clamped_view(start=pos, end=pos + av_aac_adts_header_size).to_owned(),
    ).unwrap()
    let end = pos + hdr.frame_length
    assert_true(end <= data.length())
    let payload_start = pos +
      av_aac_adts_header_size +
      (if hdr.crc_absent == 0 { 2 } else { 0 })
    let payload = data.clamped_view(start=payload_start, end~).to_owned()
    let gb = BitReader::new(payload)
    let mut id = gb.read(3).reinterpret_as_int()
    while id == aac_id_filler || id == aac_id_pce {
      if id == aac_id_filler {
        // filler before the first audio element: the SBR-aware FIL reader
        // consumes and ignores the payload just like the C.
        ignore(dec.decode_fill_element(gb, -1, -1))
      } else {
        ignore(aac_decode_pce(gb).unwrap())
      }
      id = gb.read(3).reinterpret_as_int()
    }
    assert_eq(id, aac_id_sce)
    gb.skip(4)
    let ics = aac_decode_ics(gb).unwrap()
    let seq = ics.info.window_sequence
    windows[seq] = windows[seq] + 1
    shapes[ics.info.window_shape] = shapes[ics.info.window_shape] + 1
    tns = tns + ics.tns_present
    for g = 0; g < ics.info.num_window_groups; g = g + 1 {
      if ics.info.window_group_length[g] > 1 {
        grouped = grouped + 1
      }
      for band = 0; band < ics.info.max_sfb; band = band + 1 {
        if ics.sect_cb[g][band] == 13 {
          pns = pns + 1
        }
      }
    }
    let out = dec.decode_frame(payload).unwrap()
    assert_eq(out.length(), 1)
    assert_eq(out[0].samples.length(), 1024)
    for i = 0; i < 1024; i = i + 1 {
      let sample = frames * 1024 + i
      assert_true(sample * 2 + 1 < pcm.length())
      let value = pcm[sample * 2].to_int() | (pcm[sample * 2 + 1].to_int() << 8)
      let want = if value >= 32768 { value - 65536 } else { value }
      let got = aac_s16p(out[0].samples[i])
      let diff = if got > want { got - want } else { want - got }
      if diff > max_diff {
        max_diff = diff
      }
      if diff == 0 {
        exact = exact + 1
      }
    }
    frames = frames + 1
    pos = end
  }
  assert_eq(frames * 2048, pcm.length())
  assert_true(max_diff <= 1)
  { windows, shapes, grouped, tns, pns, exact, samples: frames * 1024, }
}

///|
test "aac: native transient PCM matches FFmpeg across window transitions" {
  let coverage = aac_check_transient(
    aac_transient_native_b64, aac_transient_native_pcm_b64,
  )
  assert_eq(coverage.windows, [1, 2, 9, 1])
  assert_eq(coverage.shapes, [11, 2])
  assert_eq(coverage.grouped, 24)
  assert_eq(coverage.tns, 0)
  assert_eq(coverage.pns, 70)
  assert_true(coverage.exact * 1000 >= coverage.samples * 999)
}

///|
test "aac: FDK transient PCM matches FFmpeg across window transitions" {
  let coverage = aac_check_transient(
    aac_transient_fdk_b64, aac_transient_fdk_pcm_b64,
  )
  assert_eq(coverage.windows, [3, 2, 7, 2])
  assert_eq(coverage.shapes, [9, 5])
  assert_eq(coverage.grouped, 16)
  assert_eq(coverage.tns, 13)
  assert_eq(coverage.pns, 0)
  assert_true(coverage.exact * 1000 >= coverage.samples * 999)
}

///|
test "aac: pulse reconstruction matches FFmpeg including zero, signs and repeated positions" {
  let coverage = aac_check_transient(aac_pulse_b64, aac_pulse_pcm_b64)
  assert_eq(coverage.windows, [6, 0, 0, 0])
  assert_eq(coverage.pns, 1)
  // The pulse path reverses and reapplies the 4/3 power in Double;
  // FFmpeg rounds these intermediate values to float32 (8 one-LSB deltas).
  assert_true(coverage.exact * 1000 >= coverage.samples * 998)
}
