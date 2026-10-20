///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/h2645_vui.c` and
/// `libavcodec/h2645data.c`: the VUI fields shared by H.264 and HEVC.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// `av_color_primaries_name` / `av_color_transfer_name` /
/// `av_color_space_name` are replaced by the equivalent validity predicates:
/// FFmpeg maps the reserved enum values and every unknown value to
/// "unspecified" (2), which is all the VUI parser needs.

///| `EXTENDED_SAR`. */
let extended_sar : Int = 255

///| `AVCOL_PRI_UNSPECIFIED`. */
let avcol_pri_unspecified : Int = 2

///| `AVCOL_TRC_UNSPECIFIED`. */
let avcol_trc_unspecified : Int = 2

///| `AVCOL_SPC_UNSPECIFIED`. */
let avcol_spc_unspecified : Int = 2

///| `AVCHROMA_LOC_UNSPECIFIED`. */
let avchroma_loc_unspecified : Int = 0

///| `AVCHROMA_LOC_LEFT`. */
let avchroma_loc_left : Int = 1

///| `ff_h2645_pixel_aspect[16]` from h2645data.c (index 0 is 0/1). */
let h2645_pixel_aspect : Array[(Int, Int)] = [
  (0, 1), (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11),
  (32, 11), (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2),
  (2, 1),
]

///| `H2645VUI` from h2645_vui.h. `sar` is kept as a numerator/denominator
/// pair; color values are the `AVColor*` enum integers. */
pub struct H2645Vui {
  mut sar_num : Int
  mut sar_den : Int
  mut aspect_ratio_idc : Int
  mut aspect_ratio_info_present_flag : Int
  mut overscan_info_present_flag : Int
  mut overscan_appropriate_flag : Int
  mut video_signal_type_present_flag : Int
  mut video_format : Int
  mut video_full_range_flag : Int
  mut colour_description_present_flag : Int
  mut colour_primaries : Int
  mut transfer_characteristics : Int
  mut matrix_coeffs : Int
  mut chroma_loc_info_present_flag : Int
  mut chroma_sample_loc_type_top_field : Int
  mut chroma_sample_loc_type_bottom_field : Int
  mut chroma_location : Int
}

///| Zero-initialised VUI, as `{0}` in the C. */
pub fn new_h2645_vui() -> H2645Vui {
  {
    sar_num: 0,
    sar_den: 0,
    aspect_ratio_idc: 0,
    aspect_ratio_info_present_flag: 0,
    overscan_info_present_flag: 0,
    overscan_appropriate_flag: 0,
    video_signal_type_present_flag: 0,
    video_format: 0,
    video_full_range_flag: 0,
    colour_description_present_flag: 0,
    colour_primaries: 0,
    transfer_characteristics: 0,
    matrix_coeffs: 0,
    chroma_loc_info_present_flag: 0,
    chroma_sample_loc_type_top_field: 0,
    chroma_sample_loc_type_bottom_field: 0,
    chroma_location: 0,
  }
}

///| `av_color_primaries_name(x) != NULL`. */
fn colour_primaries_valid(v : Int) -> Bool {
  (v >= 1 && v <= 12) || v == 22
}

///| `av_color_transfer_name(x) != NULL`. */
fn transfer_characteristics_valid(v : Int) -> Bool {
  v >= 1 && v <= 18 && v != 3
}

///| `av_color_space_name(x) != NULL`. */
fn matrix_coeffs_valid(v : Int) -> Bool {
  v >= 0 && v <= 15 && v != 3
}

///|
/// `ff_h2645_decode_common_vui_params`: aspect ratio, overscan, video signal
/// type + colour description, and chroma location.
pub fn ff_h2645_decode_common_vui_params(gb : BitReader, vui : H2645Vui) -> Unit {
  vui.aspect_ratio_info_present_flag = gb.read1().reinterpret_as_int()
  if vui.aspect_ratio_info_present_flag != 0 {
    vui.aspect_ratio_idc = gb.read(8).reinterpret_as_int()
    if vui.aspect_ratio_idc < h2645_pixel_aspect.length() {
      let (num, den) = h2645_pixel_aspect[vui.aspect_ratio_idc]
      vui.sar_num = num
      vui.sar_den = den
    } else if vui.aspect_ratio_idc == extended_sar {
      vui.sar_num = gb.read(16).reinterpret_as_int()
      vui.sar_den = gb.read(16).reinterpret_as_int()
      if vui.sar_num == 0 || vui.sar_den == 0 {
        vui.sar_num = 0
        vui.sar_den = 1
      }
    }
  } else {
    vui.sar_num = 0
    vui.sar_den = 1
  }

  vui.overscan_info_present_flag = gb.read1().reinterpret_as_int()
  if vui.overscan_info_present_flag != 0 {
    vui.overscan_appropriate_flag = gb.read1().reinterpret_as_int()
  }

  vui.video_signal_type_present_flag = gb.read1().reinterpret_as_int()
  if vui.video_signal_type_present_flag != 0 {
    vui.video_format = gb.read(3).reinterpret_as_int()
    vui.video_full_range_flag = gb.read1().reinterpret_as_int()
    vui.colour_description_present_flag = gb.read1().reinterpret_as_int()
    if vui.colour_description_present_flag != 0 {
      vui.colour_primaries = gb.read(8).reinterpret_as_int()
      vui.transfer_characteristics = gb.read(8).reinterpret_as_int()
      vui.matrix_coeffs = gb.read(8).reinterpret_as_int()
      if !colour_primaries_valid(vui.colour_primaries) {
        vui.colour_primaries = avcol_pri_unspecified
      }
      if !transfer_characteristics_valid(vui.transfer_characteristics) {
        vui.transfer_characteristics = avcol_trc_unspecified
      }
      if !matrix_coeffs_valid(vui.matrix_coeffs) {
        vui.matrix_coeffs = avcol_spc_unspecified
      }
    }
  }

  vui.chroma_loc_info_present_flag = gb.read1().reinterpret_as_int()
  if vui.chroma_loc_info_present_flag != 0 {
    vui.chroma_sample_loc_type_top_field = gb.read_ue31()
    vui.chroma_sample_loc_type_bottom_field = gb.read_ue31()
    if vui.chroma_sample_loc_type_top_field >= 0 &&
      vui.chroma_sample_loc_type_top_field <= 5 {
      vui.chroma_location = vui.chroma_sample_loc_type_top_field + 1
    } else {
      vui.chroma_location = avchroma_loc_unspecified
    }
  } else {
    vui.chroma_location = avchroma_loc_left
  }
}
