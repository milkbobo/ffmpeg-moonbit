///|
/// MBAFF frames conceal missing slices on the plain macroblock raster grid.
/// `h264_slice_init` scales the slice address by `FIELD_OR_MBAFF_PICTURE`, so
/// an MBAFF frame counts macroblock *pairs*; `ff_er_frame_end` then works on
/// the ordinary `mb_width * mb_height` raster with no further interlacing
/// special cases. Concealed macroblocks always become frame macroblocks
/// (`h264_er_decode_mb` clears `mb_field_decoding_flag`).
///
/// The picture is 96x64 (6x4 macroblocks, 6x2 pairs) and every frame is coded
/// as two slices, `first_mb_in_slice` 0 and 6. Dropping the second slice
/// therefore damages 6 pairs = 12 macroblocks, which is the `12 DC, 12 AC,
/// 12 MV` FFmpeg reports for the IDR frame.
///
/// Reference: FFmpeg 9.0.2
/// `-flags2 +showall -fps_mode passthrough -f framemd5`, one entry per frame in
/// display order.
let h264_er_mbaff_expected : Array[(Int32, Array[String])] = [
  (
    5,
    [
      "5e2986f008f19d7d4c67b344552597ed", "a44ec2229f66ed2990a0a6fd7ee2d8cd", "98011513757dd7f558f8215380a3b892",
      "b0020f4014563afd449aba819e913b34", "06eb582a2eae2558a632247799105108", "0f196f3ea08cabfe544d4442c3861c31",
      "3ff31889e478d3e2d29d09498084455d", "9b13e0eb8ad93af7976e579e5bd335fe",
    ],
  ),
  (
    8,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "84498df0d374677ffe25974b488cdd88", "9a0214d80a65a3aa67440a297b2bcdf3",
      "8b248ca753b37d899dc7ec97429a2a41", "6435d0b231eeace7cf8a655f258de09a", "aae8a8531136f2e720d3c4e0a172d6e9",
      "3836fde755d8af0df625a8098910c8b3", "0f88dde74db682a19b206555d71ab08d",
    ],
  ),
  (
    11,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "6530c5e00da095bcc83bb689e2837d13", "aff59553d78ef575b173a884be22cf03",
      "e836f447a574e22b5276e30aab30bd2b", "c2a590451ebed990cc061fd191e62525", "8d1293e843cdac1f660e8ae90393d2fe",
      "afcfab5625eed2474c57ed466dfa24a4", "63892467c89b3548968743e4460023ed",
    ],
  ),
  (
    14,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "a0c146e628158f6ee0e67ce26bd577fe", "67501f6be7c7275776da874f8ca85add", "ee341c7a575fbecc68aae8ac6933d58a",
      "a8cc03605702fd784ff6382f5811e53e", "cad3e5780faade5d4320b375a9da8f71",
    ],
  ),
  (
    17,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "c3afc246b005e53bccfb556f83658ccb", "c2a590451ebed990cc061fd191e62525", "8d1293e843cdac1f660e8ae90393d2fe",
      "afcfab5625eed2474c57ed466dfa24a4", "63892467c89b3548968743e4460023ed",
    ],
  ),
  (
    20,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "e836f447a574e22b5276e30aab30bd2b", "c2a590451ebed990cc061fd191e62525", "9171450148762691d1b46c52c22a452e",
      "3fdf2112483b9c6cbd7f979f37af3e74", "de927040e632ebf82869980a22cb95c6",
    ],
  ),
  (
    23,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "e836f447a574e22b5276e30aab30bd2b", "c2a590451ebed990cc061fd191e62525", "4ce594e6a9855fc047e7cebb3480ba67",
      "afcfab5625eed2474c57ed466dfa24a4", "63892467c89b3548968743e4460023ed",
    ],
  ),
  (
    26,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "e836f447a574e22b5276e30aab30bd2b", "c2a590451ebed990cc061fd191e62525", "8d1293e843cdac1f660e8ae90393d2fe",
      "afcfab5625eed2474c57ed466dfa24a4", "915100ce2ce8290108c991aa0b408e27",
    ],
  ),
  // Dropping the *first* slice of a picture leaves the head of the frame
  // missing, including the whole first pair row of the IDR.
  (
    4,
    [
      "195a1729f8d024a1648d17d1b6f71836", "5f9859091bd4b5b8a79071279dd5c33f", "b647fecc4ab8034be659ab92348b91d6",
      "88b7de21576934d4af06dad7efaab18a", "d90c4238971634cf3163d379f475c07a", "fce0569e96345066b8be1d6029ba22b8",
      "2914e3d1d63c48717ff4dea8613d9855", "1cbb2727a4705dccb18551366827ecf0",
    ],
  ),
  (
    7,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "926c2e9233bdac63a708f3bf4c015f30", "900f5e35fe4c380d224d3446f5ffa305",
      "08b8e0685bce6154e477ab10095ecaa8", "da224971a0c791aa6cbe6d7bcabcf258", "5befceff1387c3954e41f5f113c680f4",
      "41201dfc9f0491c2bb81c23f58de0af5", "f59df06cca784ec052b50995983c7b00",
    ],
  ),
  (
    10,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "fc77032d79957319dde13d707a0c990b", "aff59553d78ef575b173a884be22cf03",
      "e836f447a574e22b5276e30aab30bd2b", "c2a590451ebed990cc061fd191e62525", "8d1293e843cdac1f660e8ae90393d2fe",
      "afcfab5625eed2474c57ed466dfa24a4", "63892467c89b3548968743e4460023ed",
    ],
  ),
  (
    13,
    [
      "1f580b7a84617f4cc2f84dd52685ac29", "b175883f7da5c0b1cc37633094a7d09f", "aff59553d78ef575b173a884be22cf03",
      "221bf6e748177897269c65c27626bbd2", "3e6dda294c11097c445d2abfe3b3c28b", "9d1cea309d35b7ce15ba3944db5a16bb",
      "77d92ed0f056d3a79e632b39994a4d16", "42e896f33e09f38f5bd56858daa0bb0d",
    ],
  ),
]

///|
test "h264: MBAFF damaged slice recovery matches FFmpeg 9.0.2" {
  let data = @libavutil.av_base64_decode(h264_mbaff_slices_b64, 1000000).unwrap()
  for entry in h264_er_mbaff_expected {
    let (target, expected) = entry
    let damaged = h264_drop_annexb_nal(data, target)
    let dec = new_h264_decoder()
    dec.set_error_concealment(true)
    let frames = match dec.decode_annexb(damaged, false) {
      Ok(value) => h264_display_order(value)
      Err(error) => fail("drop NAL \{target}: \{error}")
    }
    if frames.length() != expected.length() {
      fail(
        "drop NAL \{target}: \{frames.length()} frames, expected \{expected.length()}",
      )
    }
    for i, frame in frames {
      let got = h264_yuv_md5(frame)
      if got != expected[i] {
        fail(
          "drop NAL \{target} frame \{i}: got \{got} expected \{expected[i]}",
        )
      }
    }
  }
}

///|
test "h264: MBAFF damaged slice counts twelve concealed macroblocks" {
  let data = @libavutil.av_base64_decode(h264_mbaff_slices_b64, 1000000).unwrap()
  let dec = new_h264_decoder()
  dec.set_error_concealment(true)
  let frames = dec.decode_annexb(h264_drop_annexb_nal(data, 5), false).unwrap()
  // 6 pairs (macroblock row 2 and 3) are absent from the IDR picture.
  assert_eq(frames[0].damaged_macroblocks, 12)
  for i = 1; i < frames.length(); i = i + 1 {
    assert_eq(frames[i].damaged_macroblocks, 0)
  }
}

///|
test "h264: MBAFF damaged slice still fails without error concealment" {
  let data = @libavutil.av_base64_decode(h264_mbaff_slices_b64, 1000000).unwrap()
  let dec = new_h264_decoder()
  match dec.decode_annexb(h264_drop_annexb_nal(data, 5), false) {
    Ok(_) => fail("expected an incomplete picture error")
    Err(error) => assert_eq(error, "incomplete H.264 picture")
  }
}
