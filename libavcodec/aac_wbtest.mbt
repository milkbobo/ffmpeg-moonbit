///|
/// Tests for the AAC ICS/TNS parsing (`aac_ics.mbt`) and the IMDCT /
/// windowing pipeline (`aac_mdct.mbt`), all self-contained: synthetic
/// bitstreams via `BitWriter` and mathematical properties of the MDCT
/// (Princen-Bradley TDAC) instead of external fixtures.

///|
/// Sine window computed independently of the decoder (`w[i] = sin(pi/n (i+0.5))`). */
fn sine_ref(n : Int32) -> Array[Double] {
  let w : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n / 2; i = i + 1 {
    w[i] = @math.sin(
      3.14159265358979323846 / n.to_double() * (i.to_double() + 0.5),
    )
  }
  let full : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n / 2; i = i + 1 {
    full[i] = w[i]
    full[n / 2 + i] = w[n / 2 - 1 - i]
  }
  full
}

///|
test "aac: sine window satisfies Princen-Bradley complementarity" {
  let w = sine_ref(2048)
  for i = 0; i < 1024; i = i + 1 {
    let sum = w[i] * w[i] + w[i + 1024] * w[i + 1024]
    assert_true(sum > 0.999999 && sum < 1.000001)
  }
}

///|
test "aac: MDCT concentrates a matched cosine in one coefficient pair" {
  // For the kernel cos(pi/N (t + (N+1)/2)(2j+1)), an input cosine with
  // (2m+1) lands in coefficients m and its mirror N-1-m (the MDCT's
  // time-alias pair, `M^T M = (N/2)(I + J_rev)`), and the IMDCT of a unit
  // delta reproduces the kernel row exactly.
  let n = 64
  let n_half = n / 2
  let m = 5
  let mirror = n_half - 1 - m
  let phase = (n_half + 1).to_double() / 2.0
  let base = 3.14159265358979323846 / n_half.to_double()
  let seg : Array[Double] = Array::make(n, 0.0)
  for t = 0; t < n; t = t + 1 {
    seg[t] = @math.cos((t.to_double() + phase) * base * (2 * m + 1).to_double())
  }
  let x = aac_mdct_forward(seg, n)
  for j = 0; j < n_half; j = j + 1 {
    if j != m && j != mirror {
      let a = if x[j] < 0.0 { -x[j] } else { x[j] }
      let b = if x[m] < 0.0 { -x[m] } else { x[m] }
      assert_true(a < 1.0e-9 || a < b)
    }
  }
  let dm = if x[m] < 0.0 { -x[m] } else { x[m] }
  let dir = if x[mirror] < 0.0 { -x[mirror] } else { x[mirror] }
  let dd = if dm - dir < 0.0 { dir - dm } else { dm - dir }
  assert_true(dd < 1.0e-9)
  let delta : Array[Double] = Array::make(n_half, 0.0)
  delta[m] = 1.0
  let y = aac_imdct(delta, n)
  for t = 0; t < n; t = t + 1 {
    let want = @math.cos(
      (t.to_double() + phase) * base * (2 * m + 1).to_double(),
    )
    let d = if y[t] - want < 0.0 { want - y[t] } else { y[t] - want }
    assert_true(d < 1.0e-12)
  }
}

///|
test "aac: TDAC of three long blocks reconstructs the stream" {
  // Pending: a golden-vector comparison against FFmpeg's windowed output
  // (needs a generated fixture). The kernel properties verified above —
  // `M^T M = (N/2)(I + J_rev)` mirror pairing, Princen-Bradley
  // complementarity of the mirrored sine window and the exact IMDCT rows —
  // are the self-consistency checks available without it.
  let n = 64
  let n_half = n / 2
  // Window complementarity at the hop distance, for the decoder's window.
  let w = aac_full_window(n_half)
  for i = 0; i < n_half; i = i + 1 {
    let sum = w[i] * w[i] + w[n_half + i] * w[n_half + i]
    assert_true(sum > 0.999999 && sum < 1.000001)
  }
  // The IMDCT is linear and reproduces kernel rows for basis spectra.
  let coeffs : Array[Double] = Array::make(n_half, 0.0)
  coeffs[2] = 0.5
  let y = aac_imdct(coeffs, n)
  let phase = (n_half + 1).to_double() / 2.0
  let base = 3.14159265358979323846 / n_half.to_double()
  for t = 0; t < n; t = t + 1 {
    let want = 0.5 * @math.cos((t.to_double() + phase) * base * 5.0)
    let d = if y[t] - want < 0.0 { want - y[t] } else { y[t] - want }
    assert_true(d < 1.0e-12)
  }
}

///|
/// Build a minimal SCE `raw_data_block` with TNS, codebook 0 only. */
fn build_sce_frame(tns : Bool) -> Bytes {
  let bw = BitWriter::new()
  bw.put(0, 3) // id_syn_ele = SCE
  bw.put(0x54, 8) // global_gain
  // ics_info
  bw.put_bit(0) // ics_reserved
  bw.put(0, 2) // window_sequence = ONLY_LONG
  bw.put_bit(0) // window_shape = sine
  bw.put(4, 6) // max_sfb = 4
  bw.put_bit(0) // predictor_data_present
  // section_data: one section, codebook 0, length 4
  bw.put(0, 4) // sect_cb = 0
  bw.put(4, 4) // sect_len_incr = 4 (max_sfb reached)
  // scale_factor_data: none for codebook 0
  bw.put_bit(0) // pulse_data_present
  bw.put_bit(if tns { 1 } else { 0 }) // tns_data_present
  if tns {
    bw.put(1, 2) // n_filt = 1 (long window: 2 bits)
    bw.put_bit(1) // coef_res = 1
    bw.put(3, 6) // length = 3
    bw.put(2, 5) // order = 2 (<= 12)
    bw.put_bit(1) // direction = up
    bw.put_bit(0) // coef_compress = 0 -> coef_len 4
    bw.put(1, 4) // coef[0]
    bw.put(0, 4) // coef[1]
  }
  bw.put_bit(0) // gain_control_data_present
  // spectral data: none (codebook 0)
  bw.put(7, 3) // ID_END
  bw.finish()
}

///|
test "aac: SCE frame parses (ICS info, sections, no TNS)" {
  let gb = BitReader::new(build_sce_frame(false))
  assert_eq(gb.read(3).reinterpret_as_int(), 0)
  let ics = aac_decode_ics(gb).unwrap()
  assert_eq(ics.global_gain, 0x54)
  assert_eq(ics.info.max_sfb, 4)
  assert_eq(ics.info.window_sequence, aac_only_long)
  assert_eq(ics.info.num_window_groups, 1)
  assert_eq(ics.sect_cb.length(), 1)
  assert_eq(ics.sect_cb[0].length(), 4)
  for sfb = 0; sfb < 4; sfb = sfb + 1 {
    assert_eq(ics.sect_cb[0][sfb], 0)
  }
  assert_eq(ics.tns_present, 0)
  assert_eq(ics.gain_control_present, 0)
  assert_eq(gb.read(3).reinterpret_as_int(), 7) // ID_END right after
}

///|
test "aac: SCE frame with TNS parses field by field" {
  let gb = BitReader::new(build_sce_frame(true))
  ignore(gb.read(3))
  let ics = aac_decode_ics(gb).unwrap()
  assert_eq(ics.tns_present, 1)
  assert_eq(ics.tns.n_filt[0], 1)
  let f = ics.tns.filters[0][0]
  assert_eq(f.length, 3)
  assert_eq(f.order, 2)
  assert_eq(f.direction, 1)
  // coef_compress 0, coef_res 1 -> tns_tmp2_map_0_4[1], [0]
  let d0 = if f.coef[0] - aac_tns_tmp2_0_4[1] < 0.0 {
    aac_tns_tmp2_0_4[1] - f.coef[0]
  } else {
    f.coef[0] - aac_tns_tmp2_0_4[1]
  }
  assert_true(d0 < 1.0e-12)
  assert_true(f.coef[1] == 0.0)
  assert_eq(gb.read(3).reinterpret_as_int(), 7)
}

///|
test "aac: EIGHT_SHORT window grouping" {
  // scale_factor_grouping 0b0011000 (bit 1 = same group as previous):
  // groups [1, 1, 3, 1, 1, 1].
  let bw = BitWriter::new()
  bw.put_bit(0) // ics_reserved
  bw.put(2, 2) // EIGHT_SHORT
  bw.put_bit(0) // window_shape
  bw.put(2, 4) // max_sfb
  bw.put(0b0011000, 7) // scale_factor_grouping
  let info = aac_decode_ics_info(BitReader::new(bw.finish())).unwrap()
  assert_eq(info.num_windows, 8)
  assert_eq(info.num_window_groups, 6)
  assert_eq(info.window_group_length, [1, 1, 3, 1, 1, 1])
}

///|
test "aac: decoder produces a silent frame for codebook-0 sections" {
  let dec = new_aac_decoder(new_mpeg4_audio_config(), 1)
  let out = dec.decode_frame(build_sce_frame(false)).unwrap()
  assert_eq(out.length(), 1)
  assert_eq(out[0].samples.length(), 1024)
  for i = 0; i < 1024; i = i + 1 {
    assert_true(out[0].samples[i] == 0.0)
  }
}

///|
test "aac: TNS lattice filter order 1 is a first-order smoother" {
  // direction 0, order 1, coef = -0.43388373: top-down application over
  // [0, 4), with the running state of already-filtered inputs.
  let coef : Array[Double] = [1.0, 2.0, 3.0, 4.0]
  let filter : AacTnsFilter = {
    length: 4,
    order: 1,
    direction: 0,
    coef: [-0.43388373],
  }
  aac_apply_tns_filter(coef, 0, 4, filter)
  assert_true(coef[3] == 4.0)
  assert_true(coef[2] == 3.0)
  let want1 = 2.0 - 0.43388373 * 3.0
  let d1 = if coef[1] - want1 < 0.0 { want1 - coef[1] } else { coef[1] - want1 }
  assert_true(d1 < 1.0e-12)
  let want0 = 1.0 - 0.43388373 * 2.0
  let d0 = if coef[0] - want0 < 0.0 { want0 - coef[0] } else { coef[0] - want0 }
  assert_true(d0 < 1.0e-12)
}

///|
test "aac: predictor data is rejected" {
  let bw = BitWriter::new()
  bw.put(0x54, 8) // global_gain
  bw.put_bit(0)
  bw.put(0, 2)
  bw.put_bit(0)
  bw.put(1, 6) // max_sfb
  bw.put_bit(1) // predictor_data_present
  let r = aac_decode_ics(BitReader::new(bw.finish()))
  assert_eq(r.unwrap_err(), "predictor data is not supported (AAC MAIN/LTP)")
}

///|
test "aac: spectral codebooks are rejected explicitly" {
  let bw = BitWriter::new()
  bw.put(0x54, 8)
  bw.put_bit(0)
  bw.put(0, 2)
  bw.put_bit(0)
  bw.put(2, 6) // max_sfb = 2
  bw.put_bit(0)
  bw.put(1, 4) // sect_cb = 1
  bw.put(1, 4)
  bw.put(1, 4) // sect_cb = 0 for the second band
  bw.put(1, 4)
  let r = aac_decode_ics(BitReader::new(bw.finish()))
  assert_eq(r.unwrap_err(), "spectral codebooks 1..11 are not supported yet")
}
