///|
test "pure H264 c444 BI4 and BI8: FFmpeg pixels and diagnostics" {
  let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
  let ramp = Bytes::from_array(
    Array::makei(1024, i => ((i % 32 * 6 + i / 32 * 2) & 255).to_byte())[:],
  )
  let frames = [(flat, flat, flat), (ramp, flat, ramp), (flat, flat, flat)]
  for cabac in [false, true] {
    for intra4x4_in_b in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=32,
          height=32,
          qp=20,
          chroma_format=3,
          b_slices=true,
          b_parts=true,
          intra_in_b=false,
          intra4x4_in_b~,
          dct8x8=!intra4x4_in_b,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=32,
          height=32,
          qp=20,
          chroma_format=3,
          b_slices=true,
          b_parts=true,
          intra_in_b=false,
          intra4x4_in_b~,
          dct8x8=!intra4x4_in_b,
          stats~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      if intra4x4_in_b {
        assert_true(stats.bi4_mbs > 0)
      } else {
        assert_true(stats.bi8_mbs > 0)
      }
      let pixels = match x264_probe_frames(stream) {
        Ok(p) => p
        Err(e) => fail(e)
      }
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(pixels.n_frames, 3)
      assert_eq(pixels.warnings, 0)
      assert_eq(pixels.errors, 0)
      for (i, coded) in [(0, 0), (1, 2), (2, 1)] {
        let mut hash = 14695981039346656037UL
        for b in decoded[coded].yuvp() {
          hash = (hash ^ b.to_uint64()) * 1099511628211UL
        }
        assert_eq(pixels.frames[i].digest_lo, hash.to_int())
        assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
        assert_eq(pixels.frames[i].decode_error_flags, 0)
      }
    }
  }
}
