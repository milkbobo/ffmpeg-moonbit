///|
test "h264 c444 CABAC: repeated flat frames preserve all planes" {
  let plane = Bytes::from_array(Array::make(32 * 32, b'\x80')[:])
  let frames = Array::make(4, (plane, plane, plane))
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=32,
      height=32,
      chroma_format=3,
      b_slices=false,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 4)
  for i in 0..<3 {
    assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
  }
}

///|
test "h264 c444 CABAC: streaming and batch I/P reconstruction" {
  for cabac_rd in [false, true] {
    for
      (multi_ref, aq, dct8x8) in [
        (1, false, true),
        (3, true, true),
        (1, true, false),
      ] {
      let frames = c444_fixture(4)
      let recon : Array[Bytes] = []
      let batch = match
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
          b_slices=false,
          cabac_rd~,
          multi_ref~,
          recon~,
          aq~,
          dct8x8~,
        ) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=96,
          height=64,
          qp=24,
          chroma_format=3,
          b_slices=false,
          cabac=true,
          cabac_rd~,
          multi_ref~,
          aq~,
          dct8x8~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for (y, u, v) in frames {
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        let ready = enc.drain()
        assert_eq(ready.length(), 1)
        aus.push(ready[0])
      }
      assert_true(h264s_bytes_eq(h264s_concat(aus), batch))
      let decoded = match @libavcodec.h264_decode_annexb_frames(batch, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 4)
      assert_eq(recon.length(), 3)
      for i in 0..<3 {
        assert_eq(recon[i].length(), 96 * 64 * 3)
        assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
        assert_true(h264s_bytes_eq(enc.recons[i], recon[i]))
      }
    }
  }
}
