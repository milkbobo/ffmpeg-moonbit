///|
/// White-box tests for HEVC transform skip: the per-TU transform_skip_flag,
/// transform-skip significance contexts, coefficient dequantization without an
/// inverse transform, and the resulting pixels. Compared per frame against
/// FFmpeg 9.0.2 with and without in-loop filters.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
test "hevc tskip: transform-skip stream matches FFmpeg (deblock+SAO)" {
  hevc_check_stream(hevc_tskip_b64, hevc_tskip_filtered_refs)
}

///|
test "hevc tskip: transform-skip stream matches FFmpeg (unfiltered)" {
  hevc_check_stream_ex(hevc_tskip_b64, hevc_tskip_unfiltered_refs, false)
}
