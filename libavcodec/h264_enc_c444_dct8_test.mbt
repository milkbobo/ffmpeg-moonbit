///|
test "h264 c444 inter8: chroma-only residuals and 4x4 fallback" {
  let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
  let frames : Array[(Bytes, Bytes, Bytes)] = [(flat, flat, flat)]
  for f in 1..<3 {
    let u = Bytes::from_array(
      Array::makei(1024, i => {
        ((i % 32 * 5 + i / 32 * 2 + f * 7) & 255).to_byte()
      })[:],
    )
    frames.push((flat, u, flat))
  }
  for cabac in [false, true] {
    let outputs : Array[Bytes] = []
    let last_recons : Array[Bytes] = []
    for dct8x8 in [false, true] {
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=32,
          height=32,
          chroma_format=3,
          b_slices=false,
          dct8x8~,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=32,
          height=32,
          chroma_format=3,
          b_slices=false,
          dct8x8~,
          recon~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      outputs.push(stream)
      last_recons.push(recon[1])
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 3)
      for i in 0..<2 {
        assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
      }
    }
    assert_false(h264s_bytes_eq(outputs[0], outputs[1]))
    assert_false(h264s_bytes_eq(last_recons[0], last_recons[1]))
  }
}
