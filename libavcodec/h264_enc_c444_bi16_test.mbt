///|
test "h264 c444 BI16: DC and AC reconstruction, streaming" {
  let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
  for ac in [false, true] {
    let changed = Bytes::from_array(
      Array::makei(1024, i => {
        (if ac { (i % 32 * 6 + i / 32 * 2) & 255 } else { 200 }).to_byte()
      })[:],
    )
    let frames = [
      (flat, flat, flat),
      (changed, flat, changed),
      (flat, flat, flat),
    ]
    for cabac in [false, true] {
      for cabac_rd in [false, true] {
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let result = if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=32,
            height=32,
            qp=20,
            chroma_format=3,
            b_slices=true,
            intra_in_b=true,
            intra4x4_in_b=false,
            dct8x8=false,
            b_parts=false,
            cabac_rd~,
            stats~,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=32,
            height=32,
            qp=20,
            chroma_format=3,
            b_slices=true,
            intra_in_b=true,
            intra4x4_in_b=false,
            dct8x8=false,
            b_parts=false,
            stats~,
            recon~,
          )
        }
        let stream = match result {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_true(stats.bi16_mbs > 0)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 3)
        for i in 0..<2 {
          assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
        }
        let enc = match
          @libavcodec.H264StreamEncoder::open(
            width=32,
            height=32,
            qp=20,
            chroma_format=3,
            cabac~,
            b_slices=true,
            intra_in_b=true,
            intra4x4_in_b=false,
            dct8x8=false,
            b_parts=false,
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
}
