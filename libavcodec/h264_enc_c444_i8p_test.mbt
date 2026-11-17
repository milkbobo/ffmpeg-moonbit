///|
test "h264 c444 I8 in P: scene change uses three-plane intra" {
  let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
  let ramp = Bytes::from_array(
    Array::makei(1024, i => ((i % 32 * 6 + i / 32 * 2) & 255).to_byte())[:],
  )
  let frames = [(flat, flat, flat), (ramp, ramp, ramp), (flat, ramp, flat)]
  for bit_depth in [8, 10] {
    let inputs : Array[(Bytes, Bytes, Bytes)] = []
    for (y, u, v) in frames {
      let planes : Array[Bytes] = []
      for plane in [y, u, v] {
        if bit_depth == 8 {
          planes.push(plane)
          continue
        }
        let bytes : Array[Byte] = []
        for b in plane {
          let sample = b.to_int() << 2
          bytes.push((sample & 255).to_byte())
          bytes.push((sample >> 8).to_byte())
        }
        planes.push(Bytes::from_array(bytes[:]))
      }
      inputs.push((planes[0], planes[1], planes[2]))
    }
    for cabac in [false, true] {
      for cabac_rd in [false, true] {
        let stats = @libavcodec.H264EncStats::new()
        let recon : Array[Bytes] = []
        let result = if cabac {
          @libavcodec.h264_encode_frames_cabac(
            inputs,
            width=32,
            height=32,
            qp=26,
            chroma_format=3,
            b_slices=false,
            intra_in_p=true,
            bit_depth~,
            cabac_rd~,
            stats~,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            inputs,
            width=32,
            height=32,
            qp=26,
            chroma_format=3,
            b_slices=false,
            intra_in_p=true,
            bit_depth~,
            stats~,
            recon~,
          )
        }
        let stream = match result {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_true(stats.i8p_mbs > 0)
        let decoded = match
          @libavcodec.h264_decode_annexb_frames(stream, false) {
          Ok(d) => d
          Err(e) => fail(e)
        }
        assert_eq(decoded.length(), 3)
        for i in 0..<2 {
          assert_true(h264s_bytes_eq(recon[i], decoded[i + 1].yuvp()))
        }
      }
    }
  }
}
