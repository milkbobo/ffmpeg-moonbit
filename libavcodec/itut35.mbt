///|
/// ITU-T T.35 "user data registered" SEI payload parsing.
///
/// Ported from `libavcodec/itut35.c` (`ff_itut_t35_parse_buffer` and the
/// payload dispatch of `ff_itut_t35_parse_payload_to_struct`),
/// `libavcodec/atsc_a53.c` (`ff_parse_a53_cc`), `libavcodec/dynamic_hdr_vivid.c`
/// (`ff_parse_itu_t_t35_to_dynamic_hdr_vivid`) and the AOM film grain
/// payload parser of `libavcodec/aom_film_grain.c`
/// (`ff_aom_parse_film_grain_sets` / `ff_aom_uninit_film_grain_params`).
///
/// Copyright (c) 2025 Rewtdchar & FFmpeg authors
///
/// This file is part of a port of FFmpeg and is LGPL-2.1-or-later; see the C
/// sources for the full license header.
///
/// Implementation deviations from the C:
/// - Samsung HDR10+ (`av_dynamic_hdr_plus_from_t35`, libavutil) and
///   SMPTE ST 2094-40 application 5 (`av_dynamic_hdr_smpte2094_app5_from_t35`)
///   payloads are kept as raw bytes; their struct-level parsers are a
///   follow-up slice.
/// - Dolby Vision (provider 0x003B / oriented code 0x800) is ignored exactly
///   like the C: the H.264 SEI path passes no `DOVIContext`
///   (`decode_registered_user_data` uses `FFITUTT35Aux aux = { NULL }`), so
///   `ff_itut_t35_parse_payload_to_struct` returns 0 before parsing.
/// - `FF_ITUT_T35_FLAG_COUNTRY_CODE` is not ported; every caller in the H.264
///   path passes flags 0.

///|
/// `ITU_T_T35_COUNTRY_CODE_*` from `itut35.h`. */
pub let itut_t35_country_code_cn : Int32 = 0x26

///|
pub let itut_t35_country_code_uk : Int32 = 0xB4

///|
pub let itut_t35_country_code_us : Int32 = 0xB5

///|
/// `ITU_T_T35_PROVIDER_CODE_*` from `itut35.h`. */
pub let itut_t35_provider_code_hdr_vivid : Int32 = 0x0004

///|
pub let itut_t35_provider_code_vnova : Int32 = 0x5000

///|
pub let itut_t35_provider_code_atsc : Int32 = 0x0031

///|
pub let itut_t35_provider_code_dolby : Int32 = 0x003B

///|
pub let itut_t35_provider_code_aom : Int32 = 0x5890

///|
pub let itut_t35_provider_code_samsung : Int32 = 0x003C

///|
pub let itut_t35_provider_code_smpte : Int32 = 0x0090

///|
/// `MKBETAG('D', 'T', 'G', '1')`: ATSC active format description. */
let itut_t35_atsc_afd_tag : Int32 = 0x44544731

///|
/// `MKBETAG('G', 'A', '9', '4')`: ATSC closed captions. */
let itut_t35_atsc_cc_tag : Int32 = 0x47413934

///|
/// `FFITUTT35` (the accepted country/provider identification plus the
/// payload after the identification bytes). */
pub struct ItutT35 {
  mut country_code : Int32
  mut provider_code : Int32
  mut provider_oriented_code : Int32
  mut payload : Bytes
}

///|
/// `ff_itut_t35_parse_buffer` with `flags == 0`: read the country code from
/// the buffer, dispatch the provider codes and, when a supported combination
/// is found, leave the remaining bytes as `payload`. Returns `Ok(1)` when
/// recognized, `Ok(0)` for a known-but-unsupported combination (the caller
/// must ignore it) and `Err("EINVAL")` on truncated data. */
pub fn itut_t35_parse_buffer(
  itut_t35 : ItutT35,
  buf : Bytes,
) -> Result[Int32, String] {
  let gb = sei_cur_new(buf)
  let mut provider_code : Int32 = 0
  let mut provider_oriented_code = 0
  let country_code = gb.get()
  if country_code == 0xFF {
    if gb.left() < 1 {
      return Err("EINVAL")
    }
    // itu_t_t35_country_code_extension_byte
    gb.skip(1)
  }
  if country_code == itut_t35_country_code_us {
    if gb.left() < 2 {
      return Err("EINVAL")
    }
    provider_code = gb.get_be16()
    if provider_code == itut_t35_provider_code_atsc {
      if gb.left() < 4 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get_be32().reinterpret_as_int()
      if provider_oriented_code == itut_t35_atsc_afd_tag {
        if gb.left() < 2 {
          return Err("EINVAL")
        }
        if (gb.get() & 0x40) == 0 {
          // active_format_flag
          return Ok(0) // ignore
        }
      } else if provider_oriented_code == itut_t35_atsc_cc_tag {
        ()
      } else {
        // ignore unsupported identifiers
        return Ok(0)
      }
    } else if provider_code == itut_t35_provider_code_aom {
      if gb.left() < 1 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get()
      if provider_oriented_code != 0x0001 {
        return Ok(0) // ignore
      }
    } else if provider_code == itut_t35_provider_code_samsung {
      if gb.left() < 3 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get_be16()
      let application_identifier = gb.get()
      if provider_oriented_code != 1 || application_identifier != 4 {
        return Ok(0) // ignore
      }
    } else if provider_code == itut_t35_provider_code_dolby {
      if gb.left() < 4 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get_be32().reinterpret_as_int()
      if provider_oriented_code != 0x800 {
        return Ok(0) // ignore
      }
    } else if provider_code == itut_t35_provider_code_smpte {
      if gb.left() < 2 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get_be16()
      if provider_oriented_code != 1 {
        return Ok(0) // ignore
      }
    } else {
      // ignore unsupported provider codes
      return Ok(0)
    }
  } else if country_code == itut_t35_country_code_uk {
    if gb.left() < 3 {
      return Err("EINVAL")
    }
    // t35_uk_country_code_second_octet
    gb.skip(1)
    provider_code = gb.get_be16()
    if provider_code != itut_t35_provider_code_vnova {
      // ignore unsupported provider codes
      return Ok(0)
    }
  } else if country_code == itut_t35_country_code_cn {
    if gb.left() < 2 {
      return Err("EINVAL")
    }
    provider_code = gb.get_be16()
    if provider_code == itut_t35_provider_code_hdr_vivid {
      if gb.left() < 2 {
        return Err("EINVAL")
      }
      provider_oriented_code = gb.get_be16()
      if provider_oriented_code != 0x0005 {
        return Ok(0) // ignore
      }
    } else {
      // ignore unsupported provider codes
      return Ok(0)
    }
  } else {
    // ignore unsupported country codes
    return Ok(0)
  }
  if gb.left() == 0 {
    return Err("EINVAL")
  }
  itut_t35.payload = gb.get_buffer(gb.left())
  itut_t35.country_code = country_code
  itut_t35.provider_code = provider_code
  itut_t35.provider_oriented_code = provider_oriented_code
  Ok(1)
}

///|
/// `ff_parse_a53_cc` (`atsc_a53.c`): parse one GA94 caption container,
/// appending its `cc_count` caption triples to `cur` (captions of the two
/// fields of a picture merge into one buffer). Returns the new buffer (null
/// when `cur` was null and the container carries no captions) together with
/// the C's return value: 0 = ignore, `cc_count` = appended triples,
/// `Err("EINVAL")` on invalid data. */
fn parse_a53_cc(cur : Bytes?, payload : Bytes) -> Result[(Int32, Bytes?), String] {
  let size = payload.length()
  if size < 3 {
    return Err("EINVAL")
  }
  if payload[0].to_int() != 0x3 {
    // user_data_type_code
    return Ok((0, cur))
  }
  if (payload[1].to_int() & 0x40) == 0 {
    // process_cc_data_flag
    return Ok((0, cur))
  }
  let cc_count = payload[1].to_int() & 0x1F
  if cc_count == 0 {
    return Ok((0, cur))
  }
  // content of data[2] is reserved
  // 3 bytes per CC plus one byte marker_bits at the end
  if cc_count * 3 >= size - 3 {
    return Err("EINVAL")
  }
  let out : Array[Byte] = []
  match cur {
    Some(prev) => for i = 0; i < prev.length(); i = i + 1 {
      out.push(prev[i])
    }
    None => ()
  }
  for i = 0; i < cc_count * 3; i = i + 1 {
    out.push(payload[3 + i])
  }
  Ok((cc_count, Some(Bytes::from_array(out[:]))))
}

///|
/// `AVHDRVivid3SplineParams` (`libavutil/hdr_dynamic_vivid_metadata.h`). */
pub struct Vivid3Spline {
  mut th_mode : Int32
  mut th_enable_mb : @libavutil.AVRational
  mut th_enable : @libavutil.AVRational
  mut th_delta1 : @libavutil.AVRational
  mut th_delta2 : @libavutil.AVRational
  mut enable_strength : @libavutil.AVRational
}

///|
fn new_vivid_3_spline() -> Vivid3Spline {
  {
    th_mode: 0,
    th_enable_mb: @libavutil.av_make_q(0, 1),
    th_enable: @libavutil.av_make_q(0, 1),
    th_delta1: @libavutil.av_make_q(0, 1),
    th_delta2: @libavutil.av_make_q(0, 1),
    enable_strength: @libavutil.av_make_q(0, 1),
  }
}

///|
/// `AVHDRVividColorToneMappingParams`. */
pub struct VividToneMapping {
  mut targeted_system_display_maximum_luminance : @libavutil.AVRational
  mut base_enable_flag : Int32
  mut base_param_m_p : @libavutil.AVRational
  mut base_param_m_m : @libavutil.AVRational
  mut base_param_m_a : @libavutil.AVRational
  mut base_param_m_b : @libavutil.AVRational
  mut base_param_m_n : @libavutil.AVRational
  mut base_param_k1 : Int32
  mut base_param_k2 : Int32
  mut base_param_k3 : Int32
  mut base_param_Delta_enable_mode : Int32
  mut base_param_Delta : @libavutil.AVRational
  mut three_Spline_enable_flag : Int32
  mut three_Spline_num : Int32
  three_spline : Array[Vivid3Spline]
}

///|
fn new_vivid_tone_mapping() -> VividToneMapping {
  {
    targeted_system_display_maximum_luminance: @libavutil.av_make_q(0, 1),
    base_enable_flag: 0,
    base_param_m_p: @libavutil.av_make_q(0, 1),
    base_param_m_m: @libavutil.av_make_q(0, 1),
    base_param_m_a: @libavutil.av_make_q(0, 1),
    base_param_m_b: @libavutil.av_make_q(0, 1),
    base_param_m_n: @libavutil.av_make_q(0, 1),
    base_param_k1: 0,
    base_param_k2: 0,
    base_param_k3: 0,
    base_param_Delta_enable_mode: 0,
    base_param_Delta: @libavutil.av_make_q(0, 1),
    three_Spline_enable_flag: 0,
    three_Spline_num: 0,
    three_spline: [new_vivid_3_spline(), new_vivid_3_spline()],
  }
}

///|
/// `AVHDRVividColorTransformParams`. */
pub struct VividColorTransformParams {
  mut minimum_maxrgb : @libavutil.AVRational
  mut average_maxrgb : @libavutil.AVRational
  mut variance_maxrgb : @libavutil.AVRational
  mut maximum_maxrgb : @libavutil.AVRational
  mut tone_mapping_mode_flag : Int32
  mut tone_mapping_param_num : Int32
  tm_params : Array[VividToneMapping]
  mut color_saturation_mapping_flag : Int32
  mut color_saturation_num : Int32
  color_saturation_gain : Array[@libavutil.AVRational]
}

///|
fn new_vivid_color_transform_params() -> VividColorTransformParams {
  let gains : Array[@libavutil.AVRational] = []
  for _i = 0; _i < 8; _i = _i + 1 {
    gains.push(@libavutil.av_make_q(0, 1))
  }
  {
    minimum_maxrgb: @libavutil.av_make_q(0, 1),
    average_maxrgb: @libavutil.av_make_q(0, 1),
    variance_maxrgb: @libavutil.av_make_q(0, 1),
    maximum_maxrgb: @libavutil.av_make_q(0, 1),
    tone_mapping_mode_flag: 0,
    tone_mapping_param_num: 0,
    tm_params: [new_vivid_tone_mapping(), new_vivid_tone_mapping()],
    color_saturation_mapping_flag: 0,
    color_saturation_num: 0,
    color_saturation_gain: gains,
  }
}

///|
/// `AVDynamicHDRVivid`. */
pub struct HdrVivid {
  mut system_start_code : Int32
  mut num_windows : Int32
  params : Array[VividColorTransformParams]
}

///|
fn new_hdr_vivid() -> HdrVivid {
  {
    system_start_code: 0,
    num_windows: 0,
    params: [
      new_vivid_color_transform_params(),
      new_vivid_color_transform_params(),
      new_vivid_color_transform_params(),
    ],
  }
}

///|
/// `ff_parse_itu_t_t35_to_dynamic_hdr_vivid` (`dynamic_hdr_vivid.c`):
/// T/UWA 005.1-2022 dynamic metadata. */
fn parse_hdr_vivid(s : HdrVivid, data : Bytes) -> Result[Int32, String] {
  let gb = BitReader::new(data)
  if gb.bits_left() < 8 {
    return Err("EINVAL")
  }
  let maxrgb_den = 4095
  let color_saturation_gain_den = 128
  let maximum_luminance_den = 4095
  let base_param_m_p_den = 16383
  let base_param_m_m_den = 10
  let base_param_m_a_den = 1023
  let base_param_m_b_den = 1023
  let base_param_m_n_den = 10
  let base_param_Delta_den = 127
  s.system_start_code = gb.read(8).reinterpret_as_int()
  // T/UWA 005.1-2022, table 11
  if s.system_start_code >= 0x01 && s.system_start_code <= 0x07 {
    s.num_windows = 1
    if gb.bits_left() < 12 * 4 * s.num_windows {
      return Err("EINVAL")
    }
    for w = 0; w < s.num_windows; w = w + 1 {
      let params = s.params[w]
      params.minimum_maxrgb = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), maxrgb_den)
      params.average_maxrgb = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), maxrgb_den)
      params.variance_maxrgb = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), maxrgb_den)
      params.maximum_maxrgb = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), maxrgb_den)
    }
    if gb.bits_left() < 2 * s.num_windows {
      return Err("EINVAL")
    }
    for w = 0; w < s.num_windows; w = w + 1 {
      let params = s.params[w]
      params.tone_mapping_mode_flag = gb.read1().reinterpret_as_int()
      if params.tone_mapping_mode_flag != 0 {
        if gb.bits_left() < 1 {
          return Err("EINVAL")
        }
        params.tone_mapping_param_num = gb.read1().reinterpret_as_int() + 1
        for i = 0; i < params.tone_mapping_param_num; i = i + 1 {
          let tm_params = params.tm_params[i]
          if gb.bits_left() < 13 {
            return Err("EINVAL")
          }
          tm_params.targeted_system_display_maximum_luminance = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), maximum_luminance_den)
          tm_params.base_enable_flag = gb.read1().reinterpret_as_int()
          if tm_params.base_enable_flag != 0 {
            if gb.bits_left() < 14 + 6 + 10 + 10 + 6 + 8 + 10 {
              return Err("EINVAL")
            }
            tm_params.base_param_m_p = @libavutil.av_make_q(gb.read(14).reinterpret_as_int(), base_param_m_p_den)
            tm_params.base_param_m_m = @libavutil.av_make_q(gb.read(6).reinterpret_as_int(), base_param_m_m_den)
            tm_params.base_param_m_a = @libavutil.av_make_q(gb.read(10).reinterpret_as_int(), base_param_m_a_den)
            tm_params.base_param_m_b = @libavutil.av_make_q(gb.read(10).reinterpret_as_int(), base_param_m_b_den)
            tm_params.base_param_m_n = @libavutil.av_make_q(gb.read(6).reinterpret_as_int(), base_param_m_n_den)
            tm_params.base_param_k1 = gb.read(2).reinterpret_as_int()
            tm_params.base_param_k2 = gb.read(2).reinterpret_as_int()
            tm_params.base_param_k3 = gb.read(4).reinterpret_as_int()
            tm_params.base_param_Delta_enable_mode = gb
              .read(3)
              .reinterpret_as_int()
            tm_params.base_param_Delta = @libavutil.av_make_q(gb.read(7).reinterpret_as_int(), base_param_Delta_den)
          }
          if gb.bits_left() < 1 {
            return Err("EINVAL")
          }
          tm_params.three_Spline_enable_flag = gb.read1().reinterpret_as_int()
          if tm_params.three_Spline_enable_flag != 0 {
            if gb.bits_left() < 1 + tm_params.three_Spline_num * (2 + 12 + 28 + 1) {
              return Err("EINVAL")
            }
            tm_params.three_Spline_num = gb.read1().reinterpret_as_int() + 1
            if tm_params.three_Spline_num > tm_params.three_spline.length() {
              return Err("EINVAL")
            }
            for j = 0; j < tm_params.three_Spline_num; j = j + 1 {
              let three_spline = tm_params.three_spline[j]
              three_spline.th_mode = gb.read(2).reinterpret_as_int()
              if three_spline.th_mode == 0 || three_spline.th_mode == 2 {
                if gb.bits_left() < 8 {
                  return Err("EINVAL")
                }
                three_spline.th_enable_mb = @libavutil.av_make_q(gb.read(8).reinterpret_as_int(), 255)
              }
              three_spline.th_enable = @libavutil.av_make_q(gb.read(12).reinterpret_as_int(), 4095)
              three_spline.th_delta1 = @libavutil.av_make_q(gb.read(10).reinterpret_as_int(), 1023)
              three_spline.th_delta2 = @libavutil.av_make_q(gb.read(10).reinterpret_as_int(), 1023)
              three_spline.enable_strength = @libavutil.av_make_q(gb.read(8).reinterpret_as_int(), 255)
            }
          }
        }
      }
      params.color_saturation_mapping_flag = gb.read1().reinterpret_as_int()
      if params.color_saturation_mapping_flag != 0 {
        if gb.bits_left() < 3 + params.color_saturation_num * 8 {
          return Err("EINVAL")
        }
        params.color_saturation_num = gb.read(3).reinterpret_as_int()
        for i = 0; i < params.color_saturation_num; i = i + 1 {
          params.color_saturation_gain[i] = @libavutil.av_make_q(gb.read(8).reinterpret_as_int(), color_saturation_gain_den)
        }
      }
    }
  }
  Ok(0)
}

///|
/// `AVFilmGrainAOMParams` (the subset filled by the AFGS1 payload parser),
/// kept together with the `AVFilmGrainParams` header fields. Integer
/// truncation on store matches the C's uint8_t fields. */
pub struct AomFilmGrainParams {
  /// `AV_FILM_GRAIN_PARAMS_AV1` (1); 0 for a disabled set slot.
  mut grain_type : Int32
  mut seed : Int32
  mut width : Int32
  mut height : Int32
  mut subsampling_x : Int32
  mut subsampling_y : Int32
  mut bit_depth_luma : Int32
  mut bit_depth_chroma : Int32
  mut color_primaries : Int32
  mut color_trc : Int32
  mut color_space : Int32
  mut color_range : Int32
  mut chroma_scaling_from_luma : Int32
  mut num_y_points : Int32
  y_points : Array[Array[Int32]]
  num_uv_points : Array[Int32]
  uv_points : Array[Array[Array[Int32]]]
  mut scaling_shift : Int32
  mut ar_coeff_lag : Int32
  ar_coeffs_y : Array[Int32]
  ar_coeffs_uv : Array[Array[Int32]]
  mut ar_coeff_shift : Int32
  mut grain_scale_shift : Int32
  uv_mult : Array[Int32]
  uv_mult_luma : Array[Int32]
  uv_offset : Array[Int32]
  mut overlap_flag : Int32
  mut limit_output_range : Int32
}

///|
fn new_aom_film_grain_params() -> AomFilmGrainParams {
  let y_points : Array[Array[Int32]] = []
  let uv_points : Array[Array[Array[Int32]]] = []
  let ar_coeffs_uv : Array[Array[Int32]] = []
  for _i = 0; _i < 14; _i = _i + 1 {
    y_points.push([0, 0])
  }
  for _uv = 0; _uv < 2; _uv = _uv + 1 {
    let per_uv : Array[Array[Int32]] = []
    for _i = 0; _i < 10; _i = _i + 1 {
      per_uv.push([0, 0])
    }
    uv_points.push(per_uv)
    ar_coeffs_uv.push(Array::make(25, 0))
  }
  {
    grain_type: 0,
    seed: 0,
    width: 0,
    height: 0,
    subsampling_x: 0,
    subsampling_y: 0,
    bit_depth_luma: 0,
    bit_depth_chroma: 0,
    color_primaries: 0,
    color_trc: 0,
    color_space: 0,
    color_range: 0,
    chroma_scaling_from_luma: 0,
    num_y_points: 0,
    y_points,
    num_uv_points: [0, 0],
    uv_points,
    scaling_shift: 0,
    ar_coeff_lag: 0,
    ar_coeffs_y: Array::make(24, 0),
    ar_coeffs_uv,
    ar_coeff_shift: 0,
    grain_scale_shift: 0,
    uv_mult: [0, 0],
    uv_mult_luma: [0, 0],
    uv_offset: [0, 0],
    overlap_flag: 0,
    limit_output_range: 0,
  }
}

///|
/// `AVFilmGrainAFGS1Params`: `enable` plus up to eight film grain sets. */
pub struct AomFgs1Params {
  mut enable : Int32
  sets : Array[AomFilmGrainParams?]
}

///|
pub fn new_aom_fgs1_params() -> AomFgs1Params {
  let sets : Array[AomFilmGrainParams?] = []
  for _i = 0; _i < 8; _i = _i + 1 {
    sets.push(None)
  }
  { enable: 0, sets }
}

///|
/// `av_clip_uint8`. */
fn clip_u8(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// `ff_aom_parse_film_grain_sets` (`aom_film_grain.c`): the AFGS1 payload of
/// an AOM T.35 message. Malformed sets clear every previous set, like the
/// C's error path. */
pub fn parse_aom_film_grain_sets(
  s : AomFgs1Params,
  payload : Bytes,
) -> Result[Int32, String] {
  let gb = BitReader::new(payload)
  s.enable = gb.read1().reinterpret_as_int()
  if s.enable == 0 {
    return Ok(0)
  }
  for i = 0; i < s.sets.length(); i = i + 1 {
    s.sets[i] = None
  }
  // reserved
  gb.skip(4)
  let num_sets = gb.read(3).reinterpret_as_int() + 1
  // `ref_set` of the C: the first set of this message, assigned only once it
  // was fully transmitted (the `continue` paths skip the assignment, so a
  // later set may not predict from it).
  let mut ref_set : AomFilmGrainParams? = None
  for n = 0; n < num_sets; n = n + 1 {
    let start_position = gb.count()
    let payload_4byte = gb.read1().reinterpret_as_int()
    let payload_size = gb.read(if payload_4byte != 0 { 2 } else { 8 })
      .reinterpret_as_int()
    let set_idx = gb.read(3).reinterpret_as_int()
    if s.sets[set_idx] is Some(_) {
      return aom_fgs_error(s)
    }
    let fgp = new_aom_film_grain_params()
    let aom = fgp
    fgp.grain_type = if gb.read1().reinterpret_as_int() != 0 { 1 } else { 0 }
    if fgp.grain_type == 0 {
      // AV_FILM_GRAIN_PARAMS_NONE: not transmitted, slot stays empty
      continue
    }
    fgp.seed = gb.read(16).reinterpret_as_int()
    let update_grain = gb.read1().reinterpret_as_int()
    if update_grain == 0 {
      continue
    }
    let apply_units_log2 = gb.read(4).reinterpret_as_int()
    fgp.width = gb.read(12).reinterpret_as_int() << apply_units_log2
    fgp.height = gb.read(12).reinterpret_as_int() << apply_units_log2
    let luma_only = gb.read1().reinterpret_as_int()
    if luma_only != 0 {
      fgp.subsampling_x = 0
      fgp.subsampling_y = 0
    } else {
      fgp.subsampling_x = gb.read1().reinterpret_as_int()
      fgp.subsampling_y = gb.read1().reinterpret_as_int()
    }
    fgp.bit_depth_luma = 0
    fgp.bit_depth_chroma = 0
    fgp.color_primaries = 2
    // AVCOL_PRI_UNSPECIFIED
    fgp.color_trc = 2
    // AVCOL_TRC_UNSPECIFIED
    fgp.color_space = 2
    // AVCOL_SPC_UNSPECIFIED
    fgp.color_range = 0
    // AVCOL_RANGE_UNSPECIFIED
    let vsc_flag = gb.read1().reinterpret_as_int()
    // video_signal_characteristics_flag
    if vsc_flag != 0 {
      fgp.bit_depth_luma = gb.read(3).reinterpret_as_int() + 8
      if luma_only == 0 {
        fgp.bit_depth_chroma = fgp.bit_depth_luma
      }
      let cicp_flag = gb.read1().reinterpret_as_int()
      if cicp_flag != 0 {
        fgp.color_primaries = gb.read(8).reinterpret_as_int()
        fgp.color_trc = gb.read(8).reinterpret_as_int()
        fgp.color_space = gb.read(8).reinterpret_as_int()
        fgp.color_range = if gb.read1().reinterpret_as_int() != 0 {
          2
        } else {
          1
        }
        // AVCOL_RANGE_JPEG / _MPEG; the C rejects out-of-range CICP values
        // before storing the set (AVCOL_*_NB and the reserved entries).
        let pri_ok = fgp.color_primaries < 23 &&
          fgp.color_primaries != 0 &&
          fgp.color_primaries != 3
        let trc_ok = fgp.color_trc < 19 &&
          fgp.color_trc != 0 &&
          fgp.color_trc != 3
        let spc_ok = fgp.color_space < 18 && fgp.color_space != 3
        if !(pri_ok && trc_ok && spc_ok) {
          return aom_fgs_error(s)
        }
      }
    }
    let predict_scaling = gb.read1().reinterpret_as_int()
    if predict_scaling != 0 && ref_set is None {
      // prediction must be from a valid, different set
      return aom_fgs_error(s)
    }
    let predict_y_scaling = if predict_scaling != 0 {
      gb.read1().reinterpret_as_int()
    } else {
      0
    }
    if predict_y_scaling != 0 {
      let ref_set = match ref_set {
        Some(r) => r
        None => return aom_fgs_error(s)
      }
      let y_scale = gb.read(9).reinterpret_as_int() - 256
      let y_offset = gb.read(9).reinterpret_as_int() - 256
      let bits_res = gb.read(3).reinterpret_as_int()
      if bits_res != 0 {
        let res : Array[Int32] = Array::make(14, 0)
        aom.num_y_points = ref_set.num_y_points
        for i = 0; i < aom.num_y_points; i = i + 1 {
          res[i] = gb.read(bits_res).reinterpret_as_int()
        }
        let granularity = gb.read(3).reinterpret_as_int()
        for i = 0; i < aom.num_y_points; i = i + 1 {
          let mut pred = ref_set.y_points[i][1]
          pred = ((pred * y_scale + 8) >> 4) + y_offset
          pred = pred + (res[i] - (1 << (bits_res - 1))) * granularity
          aom.y_points[i][0] = ref_set.y_points[i][0]
          aom.y_points[i][1] = clip_u8(pred)
        }
      }
    } else {
      aom.num_y_points = gb.read(4).reinterpret_as_int()
      if aom.num_y_points > 14 {
        return aom_fgs_error(s)
      } else if aom.num_y_points != 0 {
        let mut y_value = 0
        let bits_inc = gb.read(3).reinterpret_as_int() + 1
        let bits_scaling = gb.read(2).reinterpret_as_int() + 5
        for i = 0; i < aom.num_y_points; i = i + 1 {
          y_value = y_value + gb.read(bits_inc).reinterpret_as_int()
          if y_value > 255 {
            return aom_fgs_error(s)
          }
          aom.y_points[i][0] = y_value
          aom.y_points[i][1] = gb.read(bits_scaling).reinterpret_as_int()
        }
      }
    }
    let predict_uv_scaling : Array[Int32] = [0, 0]
    if luma_only != 0 {
      aom.chroma_scaling_from_luma = 0
      aom.num_uv_points[0] = 0
      aom.num_uv_points[1] = 0
    } else {
      aom.chroma_scaling_from_luma = gb.read1().reinterpret_as_int()
      if aom.chroma_scaling_from_luma != 0 {
        aom.num_uv_points[0] = 0
        aom.num_uv_points[1] = 0
      } else {
        for uv = 0; uv < 2; uv = uv + 1 {
          predict_uv_scaling[uv] = if predict_scaling != 0 {
            gb.read1().reinterpret_as_int()
          } else {
            0
          }
          if predict_uv_scaling[uv] != 0 {
            let ref_set = match ref_set {
              Some(r) => r
              None => return aom_fgs_error(s)
            }
            let uv_scale = gb.read(9).reinterpret_as_int() - 256
            let uv_offset = gb.read(9).reinterpret_as_int() - 256
            let bits_res = gb.read(3).reinterpret_as_int()
            aom.uv_mult[uv] = ref_set.uv_mult[uv]
            aom.uv_mult_luma[uv] = ref_set.uv_mult_luma[uv]
            aom.uv_offset[uv] = ref_set.uv_offset[uv]
            if bits_res != 0 {
              let res : Array[Int32] = Array::make(10, 0)
              aom.num_uv_points[uv] = ref_set.num_uv_points[uv]
              for i = 0; i < aom.num_uv_points[uv]; i = i + 1 {
                res[i] = gb.read(bits_res).reinterpret_as_int()
              }
              let granularity = gb.read(3).reinterpret_as_int()
              for i = 0; i < aom.num_uv_points[uv]; i = i + 1 {
                let mut pred = ref_set.uv_points[uv][i][1]
                pred = ((pred * uv_scale + 8) >> 4) + uv_offset
                pred = pred + (res[i] - (1 << (bits_res - 1))) * granularity
                aom.uv_points[uv][i][0] = ref_set.uv_points[uv][i][0]
                aom.uv_points[uv][i][1] = clip_u8(pred)
              }
            }
          } else {
            let mut uv_value = 0
            aom.num_uv_points[uv] = gb.read(4).reinterpret_as_int()
            if aom.num_uv_points[uv] > 10 {
              return aom_fgs_error(s)
            }
            let bits_inc = gb.read(3).reinterpret_as_int() + 1
            let bits_scaling = gb.read(2).reinterpret_as_int() + 5
            let uv_offset = gb.read(8).reinterpret_as_int()
            for i = 0; i < aom.num_uv_points[uv]; i = i + 1 {
              uv_value = uv_value + gb.read(bits_inc).reinterpret_as_int()
              if uv_value > 255 {
                return aom_fgs_error(s)
              }
              aom.uv_points[uv][i][0] = uv_value
              aom.uv_points[uv][i][1] = (gb.read(bits_scaling)
                  .reinterpret_as_int() +
                uv_offset) &
                0xFF
            }
          }
        }
      }
    }
    aom.scaling_shift = gb.read(2).reinterpret_as_int() + 8
    aom.ar_coeff_lag = gb.read(2).reinterpret_as_int()
    let num_y_coeffs = 2 * aom.ar_coeff_lag * (aom.ar_coeff_lag + 1)
    if aom.num_y_points != 0 {
      let ar_bits = gb.read(2).reinterpret_as_int() + 5
      for i = 0; i < num_y_coeffs; i = i + 1 {
        aom.ar_coeffs_y[i] = gb.read(ar_bits).reinterpret_as_int() -
          (1 << (ar_bits - 1))
      }
    }
    for uv = 0; uv < 2; uv = uv + 1 {
      if aom.chroma_scaling_from_luma != 0 || aom.num_uv_points[uv] != 0 {
        let ar_bits = gb.read(2).reinterpret_as_int() + 5
        for i = 0; i < num_y_coeffs + (if aom.num_y_points != 0 { 1 } else { 0 })
            i = i + 1 {
          aom.ar_coeffs_uv[uv][i] = gb.read(ar_bits).reinterpret_as_int() -
            (1 << (ar_bits - 1))
        }
      }
    }
    aom.ar_coeff_shift = gb.read(2).reinterpret_as_int() + 6
    aom.grain_scale_shift = gb.read(2).reinterpret_as_int()
    for uv = 0; uv < 2; uv = uv + 1 {
      if aom.num_uv_points[uv] != 0 && predict_uv_scaling[uv] == 0 {
        aom.uv_mult[uv] = gb.read(8).reinterpret_as_int() - 128
        aom.uv_mult_luma[uv] = gb.read(8).reinterpret_as_int() - 128
        aom.uv_offset[uv] = gb.read(9).reinterpret_as_int() - 256
      }
    }
    aom.overlap_flag = gb.read1().reinterpret_as_int()
    aom.limit_output_range = gb.read1().reinterpret_as_int()
    // use first set as reference only if it was fully transmitted
    if n == 0 {
      ref_set = Some(fgp)
    }
    let payload_bits = gb.count() - start_position
    if payload_bits > payload_size * 8 {
      return aom_fgs_error(s)
    }
    gb.skip(payload_size * 8 - payload_bits)
    s.sets[set_idx] = Some(fgp)
  }
  Ok(0)
}

///|
/// The C's error path: free the partially parsed set, clear every stored
/// set of the message and disable it (`ff_aom_uninit_film_grain_params`). */
fn aom_fgs_error(s : AomFgs1Params) -> Result[Int32, String] {
  for i = 0; i < s.sets.length(); i = i + 1 {
    s.sets[i] = None
  }
  s.enable = 0
  Err("EINVAL")
}

///|
/// `ff_itut_t35_parse_payload_to_struct` (H.264 path: no `DOVIContext`, so
/// the Dolby provider is acknowledged and ignored exactly like the C).
/// Returns `Err` on payload errors, which the SEI message loop treats as
/// fatal for the NAL (`ff_h2645_sei_message_decode` semantics). */
pub fn itut_t35_parse_payload(meta : ItutT35Meta, itut_t35 : ItutT35) -> Result[Int32, String] {
  if itut_t35.country_code == itut_t35_country_code_us {
    if itut_t35.provider_code == itut_t35_provider_code_aom {
      aom_fgs_uninit(meta.aom_film_grain)
      match
        parse_aom_film_grain_sets(meta.aom_film_grain, itut_t35.payload) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if itut_t35.provider_code == itut_t35_provider_code_atsc {
      if itut_t35.provider_oriented_code == itut_t35_atsc_afd_tag {
        // afd_data
        meta.afd = Some(itut_t35.payload[0].to_int() & 0xf)
      } else if itut_t35.provider_oriented_code == itut_t35_atsc_cc_tag {
        // closed captions
        match parse_a53_cc(meta.a53_cc, itut_t35.payload) {
          Ok((_ret, buf)) => meta.a53_cc = buf
          Err(e) => return Err(e)
        }
      }
    } else if itut_t35.provider_code == itut_t35_provider_code_samsung {
      meta.hdr_plus = Some(itut_t35.payload)
    } else if itut_t35.provider_code == itut_t35_provider_code_dolby {
      // No DOVIContext in the H.264 SEI path: the C returns 0 (ignore).
      ()
    } else if itut_t35.provider_code == itut_t35_provider_code_smpte {
      meta.hdr_smpte2094_app5 = Some(itut_t35.payload)
    }
  } else if itut_t35.country_code == itut_t35_country_code_uk {
    if itut_t35.provider_code == itut_t35_provider_code_vnova {
      meta.lcevc = Some(itut_t35.payload)
    }
  } else if itut_t35.country_code == itut_t35_country_code_cn {
    if itut_t35.provider_code == itut_t35_provider_code_hdr_vivid {
      let hdr_vivid = new_hdr_vivid()
      match parse_hdr_vivid(hdr_vivid, itut_t35.payload) {
        Ok(_) => meta.hdr_vivid = Some(hdr_vivid)
        Err(e) => return Err(e)
      }
    }
  }
  Ok(0)
}

///|
/// `ff_aom_uninit_film_grain_params`. */
pub fn aom_fgs_uninit(s : AomFgs1Params) -> Unit {
  for i = 0; i < s.sets.length(); i = i + 1 {
    s.sets[i] = None
  }
  s.enable = 0
}

///|
/// `FFITUTT35Meta`: per-message payloads of the T.35 providers, drained to
/// frame side data at the picture boundary. `hdr_plus` /
/// `hdr_smpte2094_app5` keep the raw payload bytes (see the file header);
/// `dovi` is absent because the H.264 path never parses Dolby RPUs. */
pub struct ItutT35Meta {
  /// Active format description, `& 0xf` of the DTG1 payload byte.
  mut afd : Int32?
  /// A/53 closed captions (GA94), merged across the two fields of a picture.
  mut a53_cc : Bytes?
  /// LCEVC (V-Nova) payload bytes.
  mut lcevc : Bytes?
  /// Samsung HDR10+ payload bytes (raw).
  mut hdr_plus : Bytes?
  /// SMPTE ST 2094-40 application 5 payload bytes (raw).
  mut hdr_smpte2094_app5 : Bytes?
  /// HDR Vivid (China UWA) dynamic metadata.
  mut hdr_vivid : HdrVivid?
  aom_film_grain : AomFgs1Params
}

///|
pub fn new_itut_t35_meta() -> ItutT35Meta {
  {
    afd: None,
    a53_cc: None,
    lcevc: None,
    hdr_plus: None,
    hdr_smpte2094_app5: None,
    hdr_vivid: None,
    aom_film_grain: new_aom_fgs1_params(),
  }
}

///|
/// `ff_itut_t35_unref`. */
pub fn itut_t35_unref(meta : ItutT35Meta) -> Unit {
  aom_fgs_uninit(meta.aom_film_grain)
  meta.afd = None
  meta.a53_cc = None
  meta.hdr_plus = None
  meta.hdr_smpte2094_app5 = None
  meta.lcevc = None
  meta.hdr_vivid = None
}
