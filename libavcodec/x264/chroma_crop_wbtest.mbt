///|
test "pure H264 crop: FFmpeg verifies 34x18 422 and 444" {
  for chroma_format in [2, 3] {
    let cw = if chroma_format == 3 { 34 } else { 17 }
    let frames = Array::makei(3, f => {
      let y = Bytes::from_array(
        Array::makei(612, i => {
          ((i % 34 * 3 + i / 34 * 2 + f * 7) & 255).to_byte()
        })[:],
      )
      let u = Bytes::from_array(
        Array::makei(cw * 18, i => {
          ((i % cw * 2 + i / cw + f * 3 + 40) & 255).to_byte()
        })[:],
      )
      let v = Bytes::from_array(
        Array::makei(cw * 18, i => {
          ((i % cw + i / cw * 3 + f * 5 + 70) & 255).to_byte()
        })[:],
      )
      (y, u, v)
    })
    for cabac in [false, true] {
      for b_slices in [false, true] {
        let result = if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=34,
            height=18,
            chroma_format~,
            b_slices~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=34,
            height=18,
            chroma_format~,
            b_slices~,
          )
        }
        let stream = match result {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let probe = match x264_probe_frames(stream) {
          Ok(p) => p
          Err(e) => fail(e)
        }
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, false) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(probe.width, 34)
        assert_eq(probe.height, 18)
        assert_eq(probe.n_frames, 3)
        assert_eq(probe.warnings, 0)
        assert_eq(probe.errors, 0)
        let order = if b_slices { [0, 2, 1] } else { [0, 1, 2] }
        for i in 0..<3 {
          let mut hash = 14695981039346656037UL
          for b in decoded[order[i]].yuvp() {
            hash = (hash ^ b.to_uint64()) * 1099511628211UL
          }
          assert_eq(probe.frames[i].digest_lo, hash.to_int())
          assert_eq(probe.frames[i].digest_hi, (hash >> 32).to_int())
          assert_eq(probe.frames[i].decode_error_flags, 0)
        }
      }
    }
  }
}
