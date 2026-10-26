///|
/// White-box tests for `itut35.mbt`. Expected values are derived from the
/// C sources (`itut35.c`, `atsc_a53.c`, `dynamic_hdr_vivid.c`,
/// `aom_film_grain.c`); bit layouts follow T/UWA 005.1-2022 and the AV1
/// film grain spec syntax used by `ff_aom_parse_film_grain_sets`.

///|
test "itut35: parse_buffer dispatch table" {
  // US / ATSC / GA94 closed captions
  let cc : Array[Byte] = [
    0xB5, 0x00, 0x31, 71, 65, 57, 52, 0x03, 0x41, 0x00, 0xCC, 0xCC, 0xCC, 0xFF,
  ]
  let itut : ItutT35 = {
    country_code: 0,
    provider_code: 0,
    provider_oriented_code: 0,
    payload: b"",
  }
  assert_eq(itut_t35_parse_buffer(itut, Bytes::from_array(cc[:])), Ok(1))
  assert_eq(itut.country_code, 0xB5)
  assert_eq(itut.provider_code, 0x31)
  assert_eq(itut.provider_oriented_code, 0x47413934)
  // The payload starts right after the GA94 tag: the GA94 container header
  // (type code 0x03, cc flags 0x41, reserved) stays part of it; only
  // parse_a53_cc strips it.
  assert_eq(itut.payload, b"\x03\x41\x00\xCC\xCC\xCC\xFF")
  // US / ATSC / DTG1 active format: active_format_flag must be set
  let afd_ok : Array[Byte] = [0xB5, 0x00, 0x31, 68, 84, 71, 49, 0x40, 0x0B]
  assert_eq(itut_t35_parse_buffer(itut, Bytes::from_array(afd_ok[:])), Ok(1))
  assert_eq(itut.payload, b"\x0B")
  let afd_off : Array[Byte] = [0xB5, 0x00, 0x31, 68, 84, 71, 49, 0x00, 0x0B]
  assert_eq(itut_t35_parse_buffer(itut, Bytes::from_array(afd_off[:])), Ok(0))
  // US / ATSC unknown identifier
  assert_eq(
    itut_t35_parse_buffer(
      itut, b"\xB5\x00\x31\x58\x58\x58\x58\x00\x00\x00\x00\x00",
    ),
    Ok(0),
  )
  // US / AOM 0x0001
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x58\x90\x01\x81\x40"), Ok(1))
  assert_eq(itut.provider_code, 0x5890)
  assert_eq(itut.provider_oriented_code, 1)
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x58\x90\x02\x81\x40"), Ok(0))
  // US / Samsung: oriented code 1, application identifier 4
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3C\x00\x01\x04\x81\x40"),
    Ok(1),
  )
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3C\x00\x01\x05\x81\x40"),
    Ok(0),
  )
  // US / Dolby 0x800
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3B\x00\x00\x08\x00\x81"),
    Ok(1),
  )
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3B\x00\x00\x08\x01\x81"),
    Ok(0),
  )
  // US / SMPTE 2094-40 app 5: oriented code 1
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x00\x90\x00\x01\x81\x40"), Ok(1))
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x00\x90\x00\x02\x81\x40"), Ok(0))
  // US unknown provider
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x12\x34\x81\x40"), Ok(0))
  // UK / V-Nova: second octet skipped, provider 0x5000
  assert_eq(itut_t35_parse_buffer(itut, b"\xB4\x01\x50\x00\x81\x40"), Ok(1))
  assert_eq(itut.payload, b"\x81\x40")
  assert_eq(itut_t35_parse_buffer(itut, b"\xB4\x01\x50\x01\x81\x40"), Ok(0))
  // CN / HDR Vivid: provider 4, oriented code 5
  assert_eq(itut_t35_parse_buffer(itut, b"\x26\x00\x04\x00\x05\x81\x40"), Ok(1))
  assert_eq(itut_t35_parse_buffer(itut, b"\x26\x00\x04\x00\x06\x81\x40"), Ok(0))
  assert_eq(itut_t35_parse_buffer(itut, b"\x26\x00\x05\x00\x05\x81\x40"), Ok(0))
  // unknown country
  assert_eq(itut_t35_parse_buffer(itut, b"\x01\x81\x40"), Ok(0))
  // 0xFF country code: the extension byte is consumed, but the C keeps
  // country_code == 0xFF, which no provider dispatch matches -> ignored.
  // A truncated extension byte is invalid.
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xFF\x07\x00\x31\x00\x01\x04\x81\x40"),
    Ok(0),
  )
  // truncations
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x00\x31"), Err("EINVAL"))
  // GA94 has no extra length check beyond the oriented code: a 1-byte
  // payload is accepted here (parse_a53_cc then rejects it with EINVAL).
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x31\x47\x41\x39\x34\x03"),
    Ok(1),
  )
  assert_eq(itut_t35_parse_buffer(itut, b"\xB4\x01\x50"), Err("EINVAL"))
  assert_eq(itut_t35_parse_buffer(itut, b"\xFF"), Err("EINVAL"))
  // recognized provider but empty payload
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x58\x90\x01"), Err("EINVAL"))
}

///|
test "itut35: parse_a53_cc" {
  // user_data_type_code != 3 -> ignore
  assert_eq(parse_a53_cc(None, b"\x00\x41\x00\xCC\xCC\xCC\xFF"), Ok((0, None)))
  // process_cc_data_flag clear -> ignore
  assert_eq(parse_a53_cc(None, b"\x03\x01\x00\xCC\xCC\xCC\xFF"), Ok((0, None)))
  // cc_count == 0 -> ignore
  assert_eq(parse_a53_cc(None, b"\x03\x40\x00\xFF"), Ok((0, None)))
  // valid: one triple
  assert_eq(
    parse_a53_cc(None, b"\x03\x41\x00\x11\x22\x33\xFF"),
    Ok((1, Some(b"\x11\x22\x33"))),
  )
  // two fields merge (av_buffer_realloc append)
  assert_eq(
    parse_a53_cc(Some(b"\x11\x22\x33"), b"\x03\x41\x00\xAA\xBB\xCC\xFF"),
    Ok((1, Some(b"\x11\x22\x33\xAA\xBB\xCC"))),
  )
  // cc_count * 3 >= size - 3 (marker byte required)
  assert_eq(parse_a53_cc(None, b"\x03\x41\x00\x11\x22\x33"), Err("EINVAL"))
  assert_eq(parse_a53_cc(None, b"\x03\x42\x00\x11\x22"), Err("EINVAL"))
  assert_eq(parse_a53_cc(None, b"\x03"), Err("EINVAL"))
}

///|
test "itut35: HDR Vivid payload parse" {
  // system_start_code 0x01, one window: min/avg/var/max maxrgb =
  // 0x111/0x222/0x333/0x444 over 4095, no tone mapping, no saturation.
  let payload = b"\x01\x11\x12\x22\x33\x34\x44\x00"
  let s = new_hdr_vivid()
  assert_eq(parse_hdr_vivid(s, payload), Ok(0))
  assert_eq(s.system_start_code, 1)
  assert_eq(s.num_windows, 1)
  assert_eq(s.params[0].minimum_maxrgb.num, 0x111)
  assert_eq(s.params[0].minimum_maxrgb.den, 4095)
  assert_eq(s.params[0].average_maxrgb.num, 0x222)
  assert_eq(s.params[0].variance_maxrgb.num, 0x333)
  assert_eq(s.params[0].maximum_maxrgb.num, 0x444)
  assert_eq(s.params[0].tone_mapping_mode_flag, 0)
  assert_eq(s.params[0].color_saturation_mapping_flag, 0)
  // unknown system_start_code: nothing parsed
  let s2 = new_hdr_vivid()
  assert_eq(parse_hdr_vivid(s2, b"\x00\x00"), Ok(0))
  assert_eq(s2.num_windows, 0)
  // truncated maxrgb stats
  let s3 = new_hdr_vivid()
  assert_eq(parse_hdr_vivid(s3, b"\x01\x11\x12"), Err("EINVAL"))
}

///|
/// Minimal HDR Vivid payload with one tone mapping param (base + three
/// spline) and saturation mapping, hand-packed bit by bit.
test "itut35: HDR Vivid tone mapping parse" {
  let bits : Array[Int32] = []
  let put = fn(bits : Array[Int32], v : Int32, n : Int32) -> Unit {
    for i = n - 1; i >= 0; i = i - 1 {
      bits.push((v >> i) & 1)
    }
  }
  put(bits, 0x01, 8)
  // window: four 12-bit maxrgb values
  put(bits, 100, 12)
  put(bits, 200, 12)
  put(bits, 300, 12)
  put(bits, 400, 12)
  put(bits, 1, 1)
  // tone_mapping_mode_flag
  put(bits, 0, 1)
  // tone_mapping_param_num - 1
  // tm param 0
  put(bits, 3000, 12)
  // targeted_system_display_maximum_luminance
  put(bits, 1, 1)
  // base_enable_flag
  put(bits, 12345, 14)
  // base_param_m_p
  put(bits, 5, 6)
  // base_param_m_m
  put(bits, 1000, 10)
  // base_param_m_a
  put(bits, 1001, 10)
  // base_param_m_b
  put(bits, 9, 6)
  // base_param_m_n
  put(bits, 1, 2)
  // base_param_k1
  put(bits, 2, 2)
  // base_param_k2
  put(bits, 3, 4)
  // base_param_k3
  put(bits, 5, 3)
  // base_param_Delta_enable_mode
  put(bits, 100, 7)
  // base_param_Delta
  put(bits, 1, 1)
  // three_Spline_enable_flag
  put(bits, 0, 1)
  // three_Spline_num - 1
  // three spline 0: th_mode 1 (no th_enable_mb), th_enable, deltas, strength
  put(bits, 1, 2)
  put(bits, 3000, 12)
  put(bits, 500, 10)
  put(bits, 501, 10)
  put(bits, 200, 8)
  // color_saturation_mapping_flag
  put(bits, 1, 1)
  put(bits, 3, 3)
  // color_saturation_num
  put(bits, 128, 8)
  // gain 0 (128/128 = 1.0)
  put(bits, 100, 8)
  // gain 1
  let payload = bits_pack_be(bits)
  let s = new_hdr_vivid()
  assert_eq(parse_hdr_vivid(s, payload), Ok(0))
  let tm = s.params[0].tm_params[0]
  assert_eq(s.params[0].tone_mapping_param_num, 1)
  assert_eq(tm.targeted_system_display_maximum_luminance.num, 3000)
  assert_eq(tm.base_param_m_p.num, 12345)
  assert_eq(tm.base_param_m_p.den, 16383)
  assert_eq(tm.base_param_m_m.num, 5)
  assert_eq(tm.base_param_m_a.num, 1000)
  assert_eq(tm.base_param_m_b.num, 1001)
  assert_eq(tm.base_param_m_n.num, 9)
  assert_eq(tm.base_param_k1, 1)
  assert_eq(tm.base_param_k2, 2)
  assert_eq(tm.base_param_k3, 3)
  assert_eq(tm.base_param_Delta_enable_mode, 5)
  assert_eq(tm.base_param_Delta.num, 100)
  assert_eq(tm.three_Spline_num, 1)
  let sp = tm.three_spline[0]
  assert_eq(sp.th_mode, 1)
  assert_eq(sp.th_enable.num, 3000)
  assert_eq(sp.th_enable.den, 4095)
  assert_eq(sp.th_delta1.num, 500)
  assert_eq(sp.th_delta2.num, 501)
  assert_eq(sp.enable_strength.num, 200)
  assert_eq(s.params[0].color_saturation_num, 3)
  assert_eq(s.params[0].color_saturation_gain[0].num, 128)
  assert_eq(s.params[0].color_saturation_gain[1].num, 100)
  assert_eq(s.params[0].color_saturation_gain[2].num, 0)
}

///|
/// Pack an Array of bit values (0/1, MSB first) into bytes.
fn bits_pack_be(bits : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < bits.length(); i = i + 8 {
    let mut b = 0
    for j = 0; j < 8; j = j + 1 {
      if i + j < bits.length() && bits[i + j] != 0 {
        b = b | (1 << (7 - j))
      }
    }
    out.push(b.to_byte())
  }
  Bytes::from_array(out[:])
}

///|
/// One AOM film grain set, hand-packed following
/// `ff_aom_parse_film_grain_sets`: AV1 type, seed 0x1234, update_grain,
/// 160x120 (apply units 2^2), luma only, no scaling prediction, no y
/// points, scaling shift code 0, ar_coeff_lag 0, ar_coeff_shift code 1,
/// grain scale shift 0, no overlap, no limit.
fn aom_fgs_minimal_bits() -> Array[Int32] {
  let bits : Array[Int32] = []
  let put = fn(bits : Array[Int32], v : Int32, n : Int32) -> Unit {
    for i = n - 1; i >= 0; i = i - 1 {
      bits.push((v >> i) & 1)
    }
  }
  put(bits, 1, 1)
  // enable
  put(bits, 0, 4)
  // reserved
  put(bits, 0, 3)
  // num_sets - 1
  put(bits, 0, 1)
  // payload_4byte = 0
  put(bits, 10, 8)
  // payload_size (bytes), covers the 12-bit set header + set body
  put(bits, 0, 3)
  // set_idx
  // set payload (63 bits, padded to 64 by the parser's skip)
  put(bits, 1, 1)
  // grain type = AV1
  put(bits, 0x1234, 16)
  // seed
  put(bits, 1, 1)
  // update_grain
  put(bits, 2, 4)
  // apply_units_log2
  put(bits, 40, 12)
  // width field
  put(bits, 30, 12)
  // height field
  put(bits, 1, 1)
  // luma_only
  put(bits, 0, 1)
  // video_signal_characteristics_flag
  put(bits, 0, 1)
  // predict_scaling
  put(bits, 0, 4)
  // num_y_points
  put(bits, 0, 2)
  // scaling_shift code
  put(bits, 0, 2)
  // ar_coeff_lag
  put(bits, 1, 2)
  // ar_coeff_shift code
  put(bits, 0, 2)
  // grain_scale_shift
  put(bits, 0, 1)
  // overlap_flag
  put(bits, 0, 1)
  // limit_output_range
  bits
}

///|
test "itut35: AOM film grain sets" {
  let s = new_aom_fgs1_params()
  assert_eq(
    parse_aom_film_grain_sets(s, bits_pack_be(aom_fgs_minimal_bits())),
    Ok(0),
  )
  assert_eq(s.enable, 1)
  let set = s.sets[0].unwrap()
  assert_eq(set.grain_type, 1)
  assert_eq(set.seed, 0x1234)
  assert_eq(set.width, 160)
  assert_eq(set.height, 120)
  assert_eq(set.subsampling_x, 0)
  assert_eq(set.subsampling_y, 0)
  assert_eq(set.bit_depth_luma, 0)
  assert_eq(set.color_primaries, 2)
  assert_eq(set.num_y_points, 0)
  assert_eq(set.scaling_shift, 8)
  assert_eq(set.ar_coeff_shift, 7)
  assert_eq(set.overlap_flag, 0)
  for i = 1; i < 8; i = i + 1 {
    assert_true(s.sets[i] is None)
  }
  // enable = 0: nothing stored
  let s2 = new_aom_fgs1_params()
  assert_eq(parse_aom_film_grain_sets(s2, b"\x00\x00"), Ok(0))
  assert_eq(s2.enable, 0)
  // predict_scaling without a transmitted reference set: EINVAL + uninit
  let bits = aom_fgs_minimal_bits()
  // predict_scaling is bit 52 (0-based) of the set payload: message header
  // is 8 + 12 bits, then 1+16+1+4+12+12+1+1 = 48 set bits -> flip bit 68
  bits[68] = 1
  let s3 = new_aom_fgs1_params()
  assert_eq(parse_aom_film_grain_sets(s3, bits_pack_be(bits)), Err("EINVAL"))
  assert_eq(s3.enable, 0)
}

///|
test "itut35: parse_payload fills the T.35 meta slots" {
  let meta = new_itut_t35_meta()
  let itut : ItutT35 = {
    country_code: 0,
    provider_code: 0,
    provider_oriented_code: 0,
    payload: b"",
  }
  // GA94 captions
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x31GA94\x03\x41\x00\x11\x22\x33\xFF"),
    Ok(1),
  )
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_eq(meta.a53_cc, Some(b"\x11\x22\x33"))
  // DTG1 AFD
  assert_eq(itut_t35_parse_buffer(itut, b"\xB5\x00\x31DTG1\x40\x4A"), Ok(1))
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_eq(meta.afd, Some(0xA))
  // LCEVC
  assert_eq(itut_t35_parse_buffer(itut, b"\xB4\x01\x50\x00\x81\x40\x00"), Ok(1))
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_eq(meta.lcevc, Some(b"\x81\x40\x00"))
  // Dolby is acknowledged but ignored (no DOVIContext in the H.264 path)
  assert_eq(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3B\x00\x00\x08\x00\x81"),
    Ok(1),
  )
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_true(meta.hdr_vivid is None)
  // HDR Vivid
  assert_eq(
    itut_t35_parse_buffer(
      itut, b"\x26\x00\x04\x00\x05\x01\x11\x12\x22\x33\x34\x44\x00",
    ),
    Ok(1),
  )
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_true(meta.hdr_vivid is Some(_))
  assert_eq(meta.hdr_vivid.unwrap().system_start_code, 1)
  // malformed HDR Vivid payload propagates the error
  ignore(itut_t35_parse_buffer(itut, b"\x26\x00\x04\x00\x05\x01\x11").unwrap())
  assert_eq(itut_t35_parse_payload(meta, itut), Err("EINVAL"))
  // Samsung / SMPTE payloads are kept raw (see itut35.mbt header)
  ignore(
    itut_t35_parse_buffer(itut, b"\xB5\x00\x3C\x00\x01\x04\x81\x40").unwrap(),
  )
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_eq(meta.hdr_plus, Some(b"\x81\x40"))
  ignore(itut_t35_parse_buffer(itut, b"\xB5\x00\x90\x00\x01\x81\x40").unwrap())
  assert_eq(itut_t35_parse_payload(meta, itut), Ok(0))
  assert_eq(meta.hdr_smpte2094_app5, Some(b"\x81\x40"))
  // unref clears everything
  itut_t35_unref(meta)
  assert_true(meta.a53_cc is None)
  assert_true(meta.afd is None)
  assert_true(meta.lcevc is None)
  assert_true(meta.hdr_vivid is None)
  assert_true(meta.hdr_plus is None)
  assert_true(meta.hdr_smpte2094_app5 is None)
  assert_eq(meta.aom_film_grain.enable, 0)
}
