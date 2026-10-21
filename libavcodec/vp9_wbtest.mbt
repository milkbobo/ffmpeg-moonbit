///|
/// VP9 header/range-decoder tests.
///
/// Vectors were produced by libvpx-vp9 in docker `linuxserver/ffmpeg:9.0.2`
/// from lavfi sources; expected uncompressed-header values come from
/// `-bsf:v trace_headers`.  Transform mode is not shown by `trace_headers`;
/// the expected values were read from FFmpeg's own VP9 decoder (`vp9.c`
/// `txfmmode` instrumentation) on the same packets.  Lossless frames force
/// 4x4 (0).

///|
let vp9_kf_b64 : Bytes = bcat([
  b"gkmDQgAB8AH2AjgkHBhCAAKgP2L1u790dN3d6z5HkGiOoum6N9ePgvYfYfYunaP9b03dXr/W+v0fZNAAfvHQkWYQ42d8RHIHGcP6FM5YifughR+PzHXfybmQEIh4D1+jYYevroLqBdh31avn/Ig8+wSDS3r0TWvbB/nGcuyXwfFtutfTee/W/4JTU/df8AhiQYW21zG22YMc+JO2+Oi6q9qjeYVvv0ISbKp948ro+J5Prb7BcAIgcbFbXOL6D6T4K7yeIol+nMWMW4vrH3NRqr3sQ8SqAP/v6qx/6lPvG195f/Bf9koMJ4Bl0Rm2//5YIuXLW8UdX8tNurigVCy8o7L3a9skxorMjGw/PZS0dEjwirWX4FfgmAMED3fZETl5p8V5bSuWKtPRWIgXN1orP8N1ApQd08WYWQxzYAY9Iu3H8FyZGnruBCJWjjvEdkFR6zg3YlWGyVEC9N1DnhpGHXbY4WSAiiNQtVpI7R+zq2nkxvHHarkOzI47qv6aph9w7QOU2PYK0eeceAZ7XS24q6dpmU/KCxf4/lC+n9qIEZnGrKX46iYSJGUg/5KGHBHF7e+jwcJNatOmFrb5j0bscjJWgVXyavwb//+IIo32yIlFbn45e6EutpPOvnb6oys5ynfq1qS1Xw/XEoIMVhtXxyY5Ivrif8teuypFCIjxwut7m4ng9mv+Izmkqwt1D14772oQIKVDnye9xD3XjpDgf2OI+yrz6xg14ik04A==",
])

///|
let vp9_lossless_b64 : Bytes = bcat([
  b"gkmDQgAB8AH2ADgkHBgAAAQwfY/Y/Vex5i+J7Fv/zo30G35+y/72rP4Ot3aP6LreJ6viviiaXijCH4o4rvo4Bujii9nt+u8A5oh2LBU4o4omBuwAAHio5TCD9w7DK3PjxGW+9chyWNgYU9OhlH3Pe4mR8RReu3/YAfX2oMdRgaNtOrUiWc//uU9HpcDj15JgtasT6CjMU91/cK3UnEQhijQY6GWFFa0wv9crkA4eWM0usNYc/gKaYWIIo/eH7r0wfwMGhP6XLOfE2mnWftB4Gv732ji3B8xbrb3oA5b8+zHF/nIWarbaWCV8I2wyc//oeGFkAlnh7uqo/4Q2f//JkNN2uEIv2zf7VfE5dsy6DH+WL6QyAftQqaZzi46KIFBYvCTPd8tT7T0qTTkFxCWjEoN3u4bn/QMHFfWGu4c4PhgHZutjZ1MZ/zsGdxFnA33Ikcn6pL8KRqQGDwN7qIypjg/LmkVSxsGpZAJCL03l8TblsnOMtYHdTmvNKimgWzP8qr1cxwu1En1cEXty33QqgbdHP/OxP9SGNtuw6Qe7JUOgONEUGylfXZdb70vie9HZKUS9Y/DCkjUuF1p9Ld735xjRTV+lRvG1ynC2IH3S/9BzTpfCZj4JKj97e8wH8p7J2GouOqsN/9Kf/07Ygmj48OY9wbVbpjBnJQ1FNDbkOqv/FPzr8OnJ5tT2gMtnTF6Q0rFk7zO9vverf6irz4SKvOTBx/Qsv46tdQOOX/iMl/L+2tUfIQXjBHaDu54MDE0PJf1dSlCu5345C019+tAKiAe9lpLwE9oe6bdO+a9y7G58MBXrMpL/hDF97KshpLp+k8BxVt9so1G9pWJ1lQWiesZA",
])

///|
let vp9_inter_a_b64 : Bytes = b"hgBAkpwUSUAAA2AAAH/QLSQPwPN3FGda7/mmCv98RpQ3G45R+APs04qrGZjsnEp72oOdfej7qousxN2WEWuZs4fHAyl9M3+lZa9pBwbmns/VYbJ/YEtMmbrur3Fa9ur8hyndA4FtPXFHkOTnNkQ="

///|
let vp9_inter_b_b64 : Bytes = b"hgBAkpwUSsAAA2AAAHo5C6GKtC4R7O9X+dGil1wwS1HPch/3YmOP+rM9ZtOxXptxPFVr0KfY/dHiv+lIF2K28X9rJrpFwAA="

///|
let vp9_tiles_b64 : Bytes = b"gkmDQgAf8A/2ADgkHBhcEAA4YfY69oAAAAAAAAxnFL4dW06PBpvhXABnFL4dW06PBpvhXAA="

///|
let vp9_tiles_rows_b64 : Bytes = b"gkmDQgAf8B/2ADgkHBhcGAAoYfY69oBc0e4AAAAAAAtnFL4c1UMcaOnQAAAAAAtnFL4c1UMcaOnQAAAAAAYDQ0b+FCADQ0b+FCA="

///|
let vp9_tx2_b64 : Bytes = b"gkmDQgAH8Af2ADgkHBhCAAAgQAATv//7hYD///t6Cc///7ehZv//+3oJz///t6Cc//Xylp/+vk9D/9fKWn///b0LN/+vk9D/9fKWn/6+T0P//+3oJz/9fKWn/6+T0P/18paBCf/7ehZv//+3oJz///t6Fm///7egnP/18nof/r5S0//Xyeh/+vlLT/9fKWn/6+T0P/18paf/r5PQ//Xyeh/+vlLT/9fJ6H/6+UtAhP/9vQs3/6+T0P/18paf/r5PQ///7egnP/18paf/r5PQ//Xylp///29Czf/r5PQ//Xylp/+vk9D///t6Cc//Xylp/+vk9D/9fKWgQn18Am//Xyeh/+vlLT/9fJ6H/6+T0P/18paf/r5PQ//Xylp/+vlLT/9fJ6H/6+UtP/18nof/r5PQ//Xylp/+vk9D/9fKWgAA"

///|
let vp9_tx4_b64 : Bytes = b"gkmDQgAH8Af2ADgkHBhCAACgdlj9j97jCMAAAGmH//9fEWFUM+yb7iAZAzPf0w/qSIAfBmzXaH7y82fkcT+zrahy1le4Oqnf0w/qSIAfBk/ejD+pIgB8FmREm04aoctZllcWMAyBXQiuGyfbIfvLzZ+RxUatr2+rAMgZQSfmx0wg47OKjVte31YBkC9YGhHW1DlrK9v5vOtqHLWV7fzedbUOWsr2/m862octZXuAJR8A"

///|
fn vp9_test_bytes(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 100000).unwrap()
}

///|
fn vp9_test_ref_32() -> (Array[Int32], Array[Int32]) {
  ([32, 32, 32, 32, 32, 32, 32, 32], [32, 32, 32, 32, 32, 32, 32, 32])
}

///|
fn vp9_test_assert_tile_markers(data : Bytes, pkt : Vp9PacketInfo) -> Unit raise {
  for tile in pkt.tiles {
    let c = vp9_rac_init(data, tile.offset, tile.size).unwrap()
    // Every tile starts with a zero marker bit.
    assert_eq(vp9_rac_get_prob(c, 128), 0)
  }
}

///|
test "vp9: keyframe header, compressed header and tile split" {
  let data = vp9_test_bytes(vp9_kf_b64)
  assert_eq(data.length(), 556)
  let pkt = vp9_parse_packet(data).unwrap()
  let h = pkt.header
  assert_eq(h.profile, 0)
  assert_true(h.keyframe)
  assert_true(h.show_frame)
  assert_false(h.error_resilient)
  assert_false(h.intra_only)
  assert_true(h.complete)
  assert_eq(h.width, 32)
  assert_eq(h.height, 32)
  assert_eq(h.render_width, 0)
  assert_eq(h.render_height, 0)
  assert_eq(h.refresh_frame_flags, 0xFF)
  assert_eq(h.bit_depth, 8)
  assert_eq(h.color_space, 0)
  assert_eq(h.color_range, 0)
  assert_true(h.chroma_subsampling_x)
  assert_true(h.chroma_subsampling_y)
  assert_eq(h.refreshctx, 1)
  assert_eq(h.parallelmode, 1)
  assert_eq(h.frame_context_idx, 0)
  assert_eq(h.filter_level, 1)
  assert_eq(h.filter_sharpness, 0)
  assert_true(h.lf_delta_enabled)
  assert_true(h.lf_delta_updated)
  assert_eq(h.lf_ref_deltas, [1, 0, -1, -1])
  assert_eq(h.lf_mode_deltas, [0, 0])
  assert_eq(h.base_q_idx, 33)
  assert_eq(h.ydc_qdelta, 0)
  assert_eq(h.uvdc_qdelta, 0)
  assert_eq(h.uvac_qdelta, 0)
  assert_false(h.lossless)
  assert_false(h.segmentation.enabled)
  assert_eq(h.log2_tile_cols, 0)
  assert_eq(h.log2_tile_rows, 0)
  assert_eq(h.tile_cols, 1)
  assert_eq(h.tile_rows, 1)
  assert_eq(h.uncompressed_header_size, 18)
  assert_eq(h.compressed_header_size, 42)
  assert_eq(h.header_size, 60)
  // libvpx chose ONLY_8X8 for this 32x32 keyframe.
  assert_eq(h.tx_mode, 1)
  assert_eq(h.skip_probs, [192, 128, 64])
  assert_eq(pkt.header_size, 60)
  assert_eq(pkt.tile_data_offset, 60)
  assert_eq(pkt.tiles.length(), 1)
  assert_eq(pkt.tiles[0].offset, 60)
  assert_eq(pkt.tiles[0].size, 496)
  vp9_test_assert_tile_markers(data, pkt)
}

///|
test "vp9: lossless keyframe forces 4x4 transform mode" {
  let data = vp9_test_bytes(vp9_lossless_b64)
  assert_eq(data.length(), 642)
  let pkt = vp9_parse_packet(data).unwrap()
  let h = pkt.header
  assert_true(h.keyframe)
  assert_eq(h.width, 32)
  assert_eq(h.height, 32)
  assert_eq(h.base_q_idx, 0)
  assert_true(h.lossless)
  assert_eq(h.filter_level, 0)
  assert_eq(h.uncompressed_header_size, 18)
  assert_eq(h.compressed_header_size, 67)
  assert_eq(h.header_size, 85)
  assert_eq(h.tx_mode, 0)
  assert_eq(pkt.tiles.length(), 1)
  assert_eq(pkt.tiles[0].offset, 85)
  assert_eq(pkt.tiles[0].size, 557)
  vp9_test_assert_tile_markers(data, pkt)
}

///|
test "vp9: inter headers use reference size and common fields" {
  let (ref_w, ref_h) = vp9_test_ref_32()
  let data_a = vp9_test_bytes(vp9_inter_a_b64)
  assert_eq(data_a.length(), 110)
  let pkt_a = vp9_parse_packet_with_refs(data_a, ref_w, ref_h).unwrap()
  let h_a = pkt_a.header
  assert_false(h_a.keyframe)
  assert_true(h_a.show_frame)
  assert_false(h_a.intra_only)
  assert_eq(h_a.resetctx, 0)
  assert_eq(h_a.refresh_frame_flags, 1)
  assert_eq(h_a.ref_indices, [0, 1, 2])
  assert_eq(h_a.frame_size_from_ref, 0)
  assert_eq(h_a.width, 32)
  assert_eq(h_a.height, 32)
  assert_true(h_a.high_precision_mvs)
  assert_eq(h_a.filter_mode, 1)
  assert_false(h_a.allow_comp_inter)
  assert_eq(h_a.comp_pred_mode, 0)
  assert_eq(h_a.refreshctx, 1)
  assert_eq(h_a.parallelmode, 1)
  assert_eq(h_a.filter_level, 5)
  assert_false(h_a.lf_delta_updated)
  assert_eq(h_a.base_q_idx, 74)
  assert_false(h_a.segmentation.enabled)
  assert_eq(h_a.uncompressed_header_size, 10)
  assert_eq(h_a.compressed_header_size, 3)
  assert_eq(h_a.header_size, 13)
  assert_eq(h_a.tx_mode, 3)
  assert_eq(pkt_a.tiles.length(), 1)
  assert_eq(pkt_a.tiles[0].offset, 13)
  assert_eq(pkt_a.tiles[0].size, 97)
  vp9_test_assert_tile_markers(data_a, pkt_a)

  let data_b = vp9_test_bytes(vp9_inter_b_b64)
  assert_eq(data_b.length(), 71)
  let pkt_b = vp9_parse_packet_with_refs(data_b, ref_w, ref_h).unwrap()
  let h_b = pkt_b.header
  assert_eq(h_b.base_q_idx, 86)
  assert_eq(h_b.frame_size_from_ref, 0)
  assert_eq(h_b.width, 32)
  assert_eq(h_b.height, 32)
  assert_eq(h_b.header_size, 13)
  assert_eq(h_b.tx_mode, 3)
  assert_eq(pkt_b.tiles[0].size, 58)
  vp9_test_assert_tile_markers(data_b, pkt_b)
}

///|
test "vp9: inter frame without reference dimensions is incomplete" {
  let data = vp9_test_bytes(vp9_inter_a_b64)
  let h = vp9_parse_frame_header(data).unwrap()
  assert_false(h.complete)
  assert_eq(h.width, 0)
  assert_eq(h.height, 0)
  assert_eq(h.resetctx, 0)
  assert_eq(h.refresh_frame_flags, 1)
  assert_eq(h.ref_indices, [0, 1, 2])
  let err = match vp9_parse_packet(data) {
    Err(e) => e
    Ok(_) => fail("expected packet parsing to require references")
  }
  assert_eq(err, "vp9: inter frame size requires reference dimensions")
}

///|
test "vp9: multi-tile packet splits 4-byte big-endian sizes" {
  let data = vp9_test_bytes(vp9_tiles_b64)
  assert_eq(data.length(), 53)
  let pkt = vp9_parse_packet(data).unwrap()
  let h = pkt.header
  assert_eq(h.width, 512)
  assert_eq(h.height, 256)
  assert_eq(h.base_q_idx, 46)
  assert_eq(h.tx_mode, 3)
  assert_eq(h.log2_tile_cols, 1)
  assert_eq(h.log2_tile_rows, 0)
  assert_eq(h.tile_cols, 2)
  assert_eq(h.tile_rows, 1)
  assert_eq(h.uncompressed_header_size, 18)
  assert_eq(h.compressed_header_size, 7)
  assert_eq(h.header_size, 25)
  assert_eq(pkt.tile_data_offset, 25)
  assert_eq(pkt.tiles.length(), 2)
  assert_eq(pkt.tiles[0].row, 0)
  assert_eq(pkt.tiles[0].col, 0)
  assert_eq(pkt.tiles[0].offset, 29)
  assert_eq(pkt.tiles[0].size, 12)
  assert_eq(pkt.tiles[1].row, 0)
  assert_eq(pkt.tiles[1].col, 1)
  assert_eq(pkt.tiles[1].offset, 41)
  assert_eq(pkt.tiles[1].size, 12)
  vp9_test_assert_tile_markers(data, pkt)
}

///|
test "vp9: multi-row tile layout" {
  let data = vp9_test_bytes(vp9_tiles_rows_b64)
  assert_eq(data.length(), 74)
  let pkt = vp9_parse_packet(data).unwrap()
  let h = pkt.header
  assert_true(h.keyframe)
  assert_eq(h.width, 512)
  assert_eq(h.height, 512)
  assert_eq(h.base_q_idx, 46)
  assert_eq(h.tx_mode, 3)
  assert_eq(h.log2_tile_cols, 1)
  assert_eq(h.log2_tile_rows, 1)
  assert_eq(h.tile_cols, 2)
  assert_eq(h.tile_rows, 2)
  assert_eq(h.uncompressed_header_size, 18)
  assert_eq(h.compressed_header_size, 10)
  assert_eq(h.header_size, 28)
  assert_eq(pkt.tile_data_offset, 28)
  assert_eq(pkt.tiles.length(), 4)
  assert_eq(pkt.tiles[0].row, 0)
  assert_eq(pkt.tiles[0].col, 0)
  assert_eq(pkt.tiles[0].offset, 32)
  assert_eq(pkt.tiles[0].size, 11)
  assert_eq(pkt.tiles[1].row, 0)
  assert_eq(pkt.tiles[1].col, 1)
  assert_eq(pkt.tiles[1].offset, 47)
  assert_eq(pkt.tiles[1].size, 11)
  assert_eq(pkt.tiles[2].row, 1)
  assert_eq(pkt.tiles[2].col, 0)
  assert_eq(pkt.tiles[2].offset, 62)
  assert_eq(pkt.tiles[2].size, 6)
  assert_eq(pkt.tiles[3].row, 1)
  assert_eq(pkt.tiles[3].col, 1)
  assert_eq(pkt.tiles[3].offset, 68)
  assert_eq(pkt.tiles[3].size, 6)
  vp9_test_assert_tile_markers(data, pkt)
}

///|
test "vp9: keyframe transform modes 2 and 4" {
  let data2 = vp9_test_bytes(vp9_tx2_b64)
  assert_eq(data2.length(), 321)
  let pkt2 = vp9_parse_packet(data2).unwrap()
  let h2 = pkt2.header
  assert_true(h2.keyframe)
  assert_eq(h2.width, 128)
  assert_eq(h2.height, 128)
  assert_eq(h2.base_q_idx, 33)
  assert_eq(h2.uncompressed_header_size, 18)
  assert_eq(h2.compressed_header_size, 2)
  assert_eq(h2.header_size, 20)
  assert_eq(h2.tx_mode, 2)
  assert_eq(pkt2.tiles.length(), 1)
  assert_eq(pkt2.tiles[0].offset, 20)
  assert_eq(pkt2.tiles[0].size, 301)
  vp9_test_assert_tile_markers(data2, pkt2)

  let data4 = vp9_test_bytes(vp9_tx4_b64)
  assert_eq(data4.length(), 177)
  let pkt4 = vp9_parse_packet(data4).unwrap()
  let h4 = pkt4.header
  assert_true(h4.keyframe)
  assert_eq(h4.width, 128)
  assert_eq(h4.height, 128)
  assert_eq(h4.base_q_idx, 33)
  assert_eq(h4.uncompressed_header_size, 18)
  assert_eq(h4.compressed_header_size, 10)
  assert_eq(h4.header_size, 28)
  assert_eq(h4.tx_mode, 4)
  // This vector has no transform-probability updates, so the defaults must
  // survive switchable-mode parsing.
  assert_eq(h4.tx8p, [100, 66])
  assert_eq(h4.tx16p, [[20, 152], [15, 101]])
  assert_eq(h4.tx32p, [[3, 136, 37], [5, 52, 13]])
  assert_eq(pkt4.tiles.length(), 1)
  assert_eq(pkt4.tiles[0].offset, 28)
  assert_eq(pkt4.tiles[0].size, 149)
  vp9_test_assert_tile_markers(data4, pkt4)
}

///|
test "vp9: range decoder and normalisation basics" {
  assert_eq(vp9_norm_shift(0), 8)
  assert_eq(vp9_norm_shift(1), 7)
  assert_eq(vp9_norm_shift(2), 6)
  assert_eq(vp9_norm_shift(3), 6)
  assert_eq(vp9_norm_shift(4), 5)
  assert_eq(vp9_norm_shift(127), 1)
  assert_eq(vp9_norm_shift(128), 0)
  assert_eq(vp9_norm_shift(255), 0)
  let empty : Bytes = b""
  let err = match vp9_rac_init(empty, 0, 0) {
    Err(e) => e
    Ok(_) => fail("expected empty range-coded header to fail")
  }
  assert_eq(err, "vp9: empty range-coded header")
  let one : Bytes = b"\x00"
  let c = vp9_rac_init(one, 0, 1).unwrap()
  assert_eq(vp9_rac_get_prob(c, 128), 0)
}
