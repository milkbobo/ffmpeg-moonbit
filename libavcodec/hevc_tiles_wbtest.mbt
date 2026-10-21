///|
/// White-box tests for HEVC tiles: PPS uniform tile layout, CTB raster/tile-scan
/// maps, tile-boundary CABAC restart, tile-aware prediction availability and
/// cross-tile deblocking/SAO boundaries. Compared per frame against FFmpeg
/// 9.0.2 with and without in-loop filters.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
test "hevc tiles: 2x2 tile stream matches FFmpeg (deblock+SAO)" {
  hevc_check_stream(hevc_tiles_b64, hevc_tiles_filtered_refs)
}

///|
test "hevc tiles: 2x2 tile stream matches FFmpeg (unfiltered)" {
  hevc_check_stream_ex(hevc_tiles_b64, hevc_tiles_unfiltered_refs, false)
}
