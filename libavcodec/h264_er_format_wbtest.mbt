///|
/// Reference: FFmpeg 9.0.2 `-flags2 +showall -fps_mode passthrough -f framemd5`
/// on the intact streams. These pin multi-slice decoding for 10-bit 4:2:0,
/// 4:4:4 and 4:2:2, which the error-concealment matrix builds on.
let h264_er_format_intact : Array[(String, Bytes, Array[String])] = [
  (
    "10-bit 4:2:0",
    h264_er_10bit_slices_b64,
    [
      "dafece2993529b2260bf420e7fcced68",
      "8b653b2e0a72f4b5dfbb41842bf468ee",
      "794f9225c06f0007910fb989f30b3537",
      "c5651213450623df5ebdd825c404cf1c",
      "4511636aa1d2b77dccf68f1f7f48a73b",
    ],
  ),
  (
    "8-bit 4:4:4",
    h264_er_444_slices_b64,
    [
      "1850ac7b2c498ada4f0630e1e74b145b",
      "e7daa9360cf6352fa18bd630bd777246",
      "fd94b08d0c77b45755b0b2c13e920eae",
      "890125e76d0bd81aea9a956ebf2028af",
      "4f219136d50b2a3cc37bfe0e9671d639",
    ],
  ),
  (
    "8-bit 4:2:2",
    h264_er_422_slices_b64,
    [
      "37bf46bca4a1eed77f63be475d0d0589",
      "ca3cc81890daba9e225ba22fc93b974c",
      "b8ce4a02120c732e781acd86fdc108e4",
      "ca3ad6aa290d7b661c5f3db96e6dd94e",
      "d686e40739ed8f8fda236f9f21f51d2d",
    ],
  ),
]

///|
test "h264: multi-slice 10-bit/4:4:4/4:2:2 streams match FFmpeg 9.0.2" {
  for entry in h264_er_format_intact {
    let (name, b64, expected) = entry
    let data = @libavutil.av_base64_decode(b64, 1000000).unwrap()
    for conceal in [false, true] {
      let dec = new_h264_decoder()
      dec.set_error_concealment(conceal)
      let frames = match dec.decode_annexb(data, false) {
        Ok(value) => h264_display_order(value)
        Err(error) => fail("\{name}: \{error}")
      }
      if frames.length() != expected.length() {
        fail("\{name}: \{frames.length()} frames, expected \{expected.length()}")
      }
      for i, frame in frames {
        let got = h264_yuv_md5(frame)
        if got != expected[i] {
          fail("\{name} frame \{i} (concealment \{conceal}): \{got} != \{expected[i]}")
        }
        assert_eq(frame.damaged_macroblocks, 0)
      }
    }
  }
}
