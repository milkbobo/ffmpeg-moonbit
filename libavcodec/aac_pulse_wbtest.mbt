///|
/// Pulse syntax and boundary regressions from aacdec.c decode_pulses;
/// end-to-end PCM references are in aac_transient_realdata_wbtest.mbt.
/// Original FFmpeg code is LGPL-2.1-or-later.
fn aac_pulse_test_header(short : Bool) -> BitWriter {
  let bw = BitWriter::new()
  bw.put(100, 8) // global gain
  bw.put(0, 1) // reserved
  bw.put((if short { 2U } else { 0U }), 2)
  bw.put(0, 1) // sine
  if short {
    bw.put(1, 4) // max_sfb
    bw.put(127, 7) // all eight windows grouped
  } else {
    bw.put(1, 6) // max_sfb
    bw.put(0, 1) // predictor
  }
  bw.put(0, 4) // zero codebook, no scalefactor bits
  bw.put(1, (if short { 3 } else { 5 }))
  bw.put(1, 1) // pulse present
  bw
}

///|
test "aac: pulse syntax preserves all four offsets and amplitudes" {
  let bw = aac_pulse_test_header(false)
  bw.put(3, 2)
  bw.put(1, 6)
  for offset in [0, 31, 0, 3] {
    bw.put(offset.reinterpret_as_uint(), 5)
    bw.put(15, 4)
  }
  bw.put(0, 2) // no TNS / gain control
  bw.put(7, 3) // END
  let gb = BitReader::new(bw.finish())
  let ics = aac_decode_ics(gb).unwrap()
  assert_eq(ics.pulse_present, 1)
  assert_eq(ics.pulse.start_sfb, 1)
  assert_eq(ics.pulse.offsets, [0, 31, 0, 3])
  assert_eq(ics.pulse.amp, [15, 15, 15, 15])
  assert_eq(aac_resolve_pulses(ics.pulse, aac_swb_tables(4).unwrap()).unwrap(), [4, 35, 35, 38])
  assert_eq(gb.read(3), 7U)
}

///|
test "aac: short windows and truncated pulse syntax are rejected" {
  let bw = aac_pulse_test_header(true)
  assert_eq(aac_decode_ics(BitReader::new(bw.finish())).unwrap_err(),
    "pulse data is not allowed in short windows")
  let bw = aac_pulse_test_header(false)
  assert_eq(aac_decode_ics(BitReader::new(bw.finish())).unwrap_err(), "truncated pulse data")
  let bw = aac_pulse_test_header(false)
  bw.put(3, 2) // four pulses promised, none supplied
  bw.put(0, 6)
  assert_eq(aac_decode_ics(BitReader::new(bw.finish())).unwrap_err(), "truncated pulse data")
}

///|
test "aac: pulse positions use each sampling rate's full long SWB table" {
  for rate in [0, 3, 4, 6, 8, 11] {
    let swb = aac_swb_tables(rate).unwrap()
    let last = swb.num_long - 1
    let start = swb.offsets_long[last].reinterpret_as_int()
    let max = swb.offsets_long[swb.num_long].reinterpret_as_int()
    let offsets : Array[Int32] = []
    let mut remaining = max - start - 1
    while remaining > 31 {
      offsets.push(31)
      remaining = remaining - 31
    }
    offsets.push(remaining)
    assert_true(offsets.length() <= 4)
    let pulse : AacPulse = { start_sfb: last, offsets, amp: Array::make(offsets.length(), 1), }
    let positions = aac_resolve_pulses(pulse, swb).unwrap()
    assert_eq(positions[positions.length() - 1], max - 1)
    let pulse : AacPulse = { start_sfb: swb.num_long, offsets: [0], amp: [1], }
    assert_eq(aac_resolve_pulses(pulse, swb).unwrap_err(), "pulse start band out of range")
    // Each encoded offset is at most 31; repeated 31s cross the final band.
    let pulse : AacPulse = { start_sfb: last, offsets: [31, 31, 31, 31], amp: [1, 1, 1, 1], }
    assert_eq(aac_resolve_pulses(pulse, swb).unwrap_err(), "pulse position out of range")
  }
}

///|
test "aac: out of range pulses fail before spectral decode and window state changes" {
  let bw = BitWriter::new()
  bw.put(0, 3) // SCE
  bw.put(0, 4) // tag
  let syntax = aac_pulse_test_header(false)
  syntax.put(0, 2)
  syntax.put(63, 6) // beyond every AAC-LC long SWB table
  syntax.put(0, 9)
  syntax.put(0, 2)
  // Concatenate the syntax bits, omitting BitWriter's byte padding.
  let syntax_bits = 8 + 1 + 2 + 1 + 6 + 1 + 4 + 5 + 1 + 2 + 6 + 9 + 2
  let gb = BitReader::new(syntax.finish())
  for _i = 0; _i < syntax_bits; _i = _i + 1 { bw.put(gb.read1(), 1) }
  bw.put(7, 3)
  let dec = new_aac_decoder(new_mpeg4_audio_config(), 1)
  assert_eq(dec.decode_frame(bw.finish()).unwrap_err(), "pulse start band out of range")
  assert_eq(dec.channels[0].prev_window_shape, 0)
  for v in dec.channels[0].saved { assert_eq(v, 0.0) }
}
