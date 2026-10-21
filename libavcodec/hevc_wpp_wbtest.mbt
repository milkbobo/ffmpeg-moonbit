///|
/// White-box tests for single-slice HEVC WPP (entropy coding sync): the slice
/// header's entry-point table, per-row CABAC rewinding/state reload after the
/// second CTB of the previous row, and the resulting pixels. Compared per
/// frame against FFmpeg 9.0.2 with and without in-loop filters.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
test "hevc wpp: single-slice stream matches FFmpeg (deblock+SAO)" {
  hevc_check_stream(hevc_wpp1_b64, hevc_wpp1_filtered_refs)
}

///|
test "hevc wpp: single-slice stream matches FFmpeg (unfiltered)" {
  hevc_check_stream_ex(hevc_wpp1_b64, hevc_wpp1_unfiltered_refs, false)
}
