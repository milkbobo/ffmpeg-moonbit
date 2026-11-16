///|
fn c444_depth_frames(depth : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for (y, u, v) in c444b_stream_fixture(6) {
    let planes : Array[Bytes] = []
    for plane in [y, u, v] {
      if depth == 8 {
        planes.push(plane)
        continue
      }
      let bytes : Array[Byte] = []
      for b in plane {
        let value = b.to_int() << (depth - 8)
        bytes.push((value & 255).to_byte())
        bytes.push((value >> 8).to_byte())
      }
      planes.push(Bytes::from_array(bytes[:]))
    }
    frames.push((planes[0], planes[1], planes[2]))
  }
  frames
}

///|
test "h264 c444 online: depth, default B tools, VBV, IDR and tail" {
  for bit_depth in [8, 10, 12, 14] {
    let frames = c444_depth_frames(bit_depth)
    for cabac in [false, true] {
      let stats = @libavcodec.H264EncStats::new()
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=32,
          height=32,
          chroma_format=3,
          bit_depth~,
          cabac~,
          multi_ref=3,
          aq=true,
          aud=true,
          vbv_maxrate=320000,
          vbv_bufsize=128000,
          fps=25,
          stats~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for i in 0..<6 {
        let (y, u, v) = frames[i]
        match enc.push_frame(y, u, v, force_idr=i == 2) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(tail) => {
          assert_eq(tail.length(), 1)
          for au in tail {
            aus.push(au)
          }
        }
        Err(e) => fail(e)
      }
      assert_eq(aus.length(), 6)
      assert_eq(stats.frame_qps.length(), 6)
      assert_eq(stats.vbv_bits, h264s_concat(aus).length().to_int64() * 8L)
      let decoded = match
        @libavcodec.h264_decode_annexb_frames(h264s_concat(aus), true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 6)
      assert_eq(enc.recons.length(), 4)
      for (i, coded) in [(0, 1), (1, 3), (2, 4), (3, 5)] {
        assert_true(
          h264s_bytes_eq(enc.recons[i], decoded[coded].yuvp()),
          msg="depth=\{bit_depth} cabac=\{cabac} coded=\{coded}",
        )
      }
    }
  }
}
