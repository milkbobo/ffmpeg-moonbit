///|
fn c444bp_fixture() -> Array[(Bytes, Bytes, Bytes)] {
  let frames = h264bp_fixture(48, 48, 5)
  Array::makei(5, f => {
    let u = Bytes::from_array(
      Array::makei(48 * 48, i => {
        ((i % 48 * 3 + i / 48 * 2 + f * 11 + 40) & 255).to_byte()
      })[:],
    )
    (frames[f].0, u, frames[4 - f].0)
  })
}

///|
test "h264 c444 B parts: actual subpartitions and streaming equality" {
  let frames = c444bp_fixture()
  for cabac in [false, true] {
    for cabac_rd in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=48,
          height=48,
          qp=22,
          chroma_format=3,
          b_slices=true,
          b_parts=true,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          multi_ref=3,
          cabac_rd~,
          stats~,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=48,
          height=48,
          qp=22,
          chroma_format=3,
          b_slices=true,
          b_parts=true,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          multi_ref=3,
          stats~,
          recon~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(stats.bpart_mbs > 0)
      assert_true(stats.b8x8_mbs > 0)
      assert_true(stats.bpart_mbs > stats.b8x8_mbs)
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 5)
      for i in 0..<4 {
        assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
      }
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=48,
          height=48,
          qp=22,
          chroma_format=3,
          cabac~,
          b_slices=true,
          b_parts=true,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          multi_ref=3,
          cabac_rd~,
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
        for au in enc.drain() {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(tail) =>
          for au in tail {
            aus.push(au)
          }
        Err(e) => fail(e)
      }
      assert_true(h264s_bytes_eq(h264s_concat(aus), stream))
    }
  }
}
