///|
test "h264 chroma crop: visible dimensions and reconstruction at 34x18" {
  for chroma_format in [1, 2, 3] {
    let cw = if chroma_format == 3 { 34 } else { 17 }
    let ch = if chroma_format == 1 { 9 } else { 18 }
    let frames = Array::makei(3, f => {
      let y = Bytes::from_array(
        Array::makei(34 * 18, i => {
          ((i % 34 * 3 + i / 34 * 2 + f * 7) & 255).to_byte()
        })[:],
      )
      let u = Bytes::from_array(
        Array::makei(cw * ch, i => {
          ((i % cw * 2 + i / cw + f * 3 + 40) & 255).to_byte()
        })[:],
      )
      let v = Bytes::from_array(
        Array::makei(cw * ch, i => {
          ((i % cw + i / cw * 3 + f * 5 + 70) & 255).to_byte()
        })[:],
      )
      (y, u, v)
    })
    for cabac in [false, true] {
      for b_slices in [false, true] {
        let recon : Array[Bytes] = []
        let result = if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=34,
            height=18,
            chroma_format~,
            cabac_rd=true,
            b_slices~,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=34,
            height=18,
            chroma_format~,
            b_slices~,
            recon~,
          )
        }
        let stream = match result {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let enc = match
          @libavcodec.H264StreamEncoder::open(
            width=34,
            height=18,
            chroma_format~,
            cabac~,
            b_slices~,
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
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 3)
        for frame in decoded {
          assert_eq(frame.width, 34)
          assert_eq(frame.height, 18)
        }
        for i in 0..<2 {
          assert_eq(recon[i].length(), 34 * 18 + 2 * cw * ch)
          assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
        }
      }
    }
  }
}
