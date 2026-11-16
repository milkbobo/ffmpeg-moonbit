///|
test "h264 c444 I8: three-plane reconstruction at 8 and 10 bits" {
  for bit_depth in [8, 10] {
    let planes : Array[Bytes] = []
    for p in 0..<3 {
      let bytes : Array[Byte] = []
      for i in 0..<1024 {
        let sample = ((i % 32 * (p + 2) + i / 32 * 3 + p * 40) & 255) <<
          (bit_depth - 8)
        bytes.push((sample & 255).to_byte())
        if bit_depth > 8 {
          bytes.push((sample >> 8).to_byte())
        }
      }
      planes.push(Bytes::from_array(bytes[:]))
    }
    for cabac in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let result = if cabac {
        @libavcodec.h264_encode_intra_frame_cabac(
          planes[0],
          planes[1],
          planes[2],
          width=32,
          height=32,
          chroma_format=3,
          dct8x8=true,
          bit_depth~,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_intra_frame(
          planes[0],
          planes[1],
          planes[2],
          width=32,
          height=32,
          chroma_format=3,
          dct8x8=true,
          bit_depth~,
          stats~,
        )
      }
      let encoded = match result {
        Ok(e) => e
        Err(e) => fail(e)
      }
      assert_eq(stats.i8_mbs, 4)
      let decoded = match
        @libavcodec.h264_decode_annexb_frames(encoded.annexb, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let packed : Array[Byte] = []
      for plane in [encoded.recon_y, encoded.recon_u, encoded.recon_v] {
        for sample in plane {
          packed.push((sample & 255).to_byte())
          if bit_depth > 8 {
            packed.push((sample >> 8).to_byte())
          }
        }
      }
      assert_eq(decoded.length(), 1)
      assert_true(
        h264s_bytes_eq(Bytes::from_array(packed[:]), decoded[0].yuvp()),
      )
    }
  }
}
