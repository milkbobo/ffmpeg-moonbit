///|
test "h264 high contrast: P skip cannot win with an overflowed SSD" {
  for bit_depth in [12, 14] {
    for chroma_format in [1, 3] {
      let max = (1 << bit_depth) - 1
      let plane : Array[Byte] = []
      for _ in 0..<256 {
        plane.push((max & 255).to_byte())
        plane.push((max >> 8).to_byte())
      }
      let light = Bytes::from_array(plane[:])
      let dark = Bytes::make(512, 0)
      let cbytes = if chroma_format == 3 { 512 } else { 128 }
      let frames = [
        (dark, Bytes::make(cbytes, 0), Bytes::make(cbytes, 0)),
        (
          light,
          Bytes::from_array(plane[:cbytes]),
          Bytes::from_array(plane[:cbytes]),
        ),
        (dark, Bytes::make(cbytes, 0), Bytes::make(cbytes, 0)),
      ]
      for cabac in [false, true] {
        for b_slices in [false, true] {
          let stats = @libavcodec.H264EncStats::new()
          let recon : Array[Bytes] = []
          let result = if cabac {
            @libavcodec.h264_encode_frames_cabac(
              frames,
              width=16,
              height=16,
              bit_depth~,
              chroma_format~,
              b_slices~,
              b_parts=false,
              intra_in_b=true,
              intra4x4_in_b=false,
              dct8x8=!b_slices,
              stats~,
              weightp=false,
              recon~,
            )
          } else {
            @libavcodec.h264_encode_frames(
              frames,
              width=16,
              height=16,
              bit_depth~,
              chroma_format~,
              b_slices~,
              b_parts=false,
              intra_in_b=true,
              intra4x4_in_b=false,
              dct8x8=!b_slices,
              stats~,
              weightp=false,
              recon~,
            )
          }
          let stream = match result {
            Ok(s) => s
            Err(e) => fail(e)
          }
          if b_slices {
            assert_true(stats.bi16_mbs > 0)
          }
          let decoded = match
            @libavcodec.h264_decode_annexb_frames(stream, false) {
            Ok(d) => d
            Err(e) => fail(e)
          }
          assert_eq(decoded.length(), 3)
          for i in 0..<2 {
            assert_eq(recon[i], decoded[i + 1].yuvp())
          }
          for value in decoded[if b_slices { 2 } else { 1 }].y {
            assert_true(
              value > max * 3 / 4,
              msg="depth=\{bit_depth} chroma=\{chroma_format} cabac=\{cabac}",
            )
          }
          for value in decoded[if b_slices { 1 } else { 2 }].y {
            assert_true(value < max / 4)
          }
        }
      }
    }
  }
}
