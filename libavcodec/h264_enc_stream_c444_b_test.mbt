///|
test "h264 stream c444 B: default tools accepted" {
  for cabac in [false, true] {
    match
      @libavcodec.H264StreamEncoder::open(
        width=32,
        height=32,
        chroma_format=3,
        cabac~,
        b_slices=true,
      ) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
}

///|
test "h264 stream c444 B: forced IDR flushes pending picture with online VBV" {
  let frames = c444b_stream_fixture(5)
  for cabac in [false, true] {
    for vbv in [false, true] {
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=32,
          height=32,
          chroma_format=3,
          cabac~,
          b_slices=true,
          b_parts=false,
          intra_in_b=false,
          intra4x4_in_b=false,
          dct8x8=false,
          vbv_maxrate=if vbv { 320000 } else { 0 },
          vbv_bufsize=if vbv { 128000 } else { 0 },
          fps=if vbv { 25 } else { 0 },
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for i in 0..<5 {
        let (y, u, v) = frames[i]
        match enc.push_frame(y, u, v, force_idr=i == 2) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        let ready = enc.drain()
        assert_eq(
          ready.length(),
          if i == 0 {
            1
          } else if i == 2 || i == 4 {
            2
          } else {
            0
          },
        )
        for au in ready {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(tail) => assert_eq(tail.length(), 0)
        Err(e) => fail(e)
      }
      let stream = h264s_concat(aus)
      let mut idrs = 0
      for nal in vbv_nals(stream) {
        if nal.0 == 5 {
          idrs += 1
        }
      }
      assert_eq(idrs, 2)
      let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      assert_eq(decoded.length(), 5)
      assert_eq(enc.recons.length(), 3)
      for (i, coded) in [(0, 1), (1, 3), (2, 4)] {
        assert_true(h264s_bytes_eq(enc.recons[i], decoded[coded].yuvp()))
      }
    }
  }
}

///|
fn c444b_stream_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  Array::makei(n, f => {
    let y = Bytes::from_array(
      Array::makei(1024, i => {
        ((i % 32 * 2 + i / 32 * 3 + f * 7) & 255).to_byte()
      })[:],
    )
    let u = Bytes::from_array(
      Array::makei(1024, i => {
        ((i % 32 + i / 32 * 2 + f * 5 + 40) & 255).to_byte()
      })[:],
    )
    let v = Bytes::from_array(
      Array::makei(1024, i => {
        ((i % 32 * 3 + i / 32 + f * 3 + 70) & 255).to_byte()
      })[:],
    )
    (y, u, v)
  })
}

///|
test "h264 stream c444 B: batch equality, scheduling and tail flush" {
  for cabac in [false, true] {
    for multi_ref in [1, 3] {
      for n in [4, 5] {
        let frames = c444b_stream_fixture(n)
        let result = if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=32,
            height=32,
            chroma_format=3,
            b_slices=true,
            b_parts=false,
            intra_in_b=false,
            intra4x4_in_b=false,
            dct8x8=false,
            multi_ref~,
            aq=true,
            aud=true,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=32,
            height=32,
            chroma_format=3,
            b_slices=true,
            b_parts=false,
            intra_in_b=false,
            intra4x4_in_b=false,
            dct8x8=false,
            multi_ref~,
            aq=true,
            aud=true,
          )
        }
        let batch = match result {
          Ok(s) => s
          Err(e) => fail(e)
        }
        let enc = match
          @libavcodec.H264StreamEncoder::open(
            width=32,
            height=32,
            chroma_format=3,
            cabac~,
            b_slices=true,
            b_parts=false,
            intra_in_b=false,
            intra4x4_in_b=false,
            dct8x8=false,
            multi_ref~,
            aq=true,
            aud=true,
          ) {
          Ok(e) => e
          Err(e) => fail(e)
        }
        let aus : Array[Bytes] = []
        for i in 0..<n {
          let (y, u, v) = frames[i]
          match enc.push_frame(y, u, v) {
            Ok(_) => ()
            Err(e) => fail(e)
          }
          let ready = enc.drain()
          assert_eq(
            ready.length(),
            if i == 0 {
              1
            } else if i % 2 == 1 {
              0
            } else {
              2
            },
          )
          for au in ready {
            aus.push(au)
          }
        }
        let tail = match enc.finish() {
          Ok(t) => t
          Err(e) => fail(e)
        }
        assert_eq(tail.length(), if n % 2 == 0 { 1 } else { 0 })
        for au in tail {
          aus.push(au)
        }
        let stream = h264s_concat(aus)
        assert_true(h264s_bytes_eq(stream, batch))
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, true) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), n)
        for i in 0..<(n - 1) {
          assert_true(h264s_bytes_eq(enc.recons[i], decoded[i + 1].yuvp()))
        }
      }
    }
  }
}
