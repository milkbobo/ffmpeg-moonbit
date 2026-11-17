///|
test "h264 c444 B inter8: transform flags, reconstruction and partition gate" {
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<5 {
    let planes : Array[Bytes] = []
    for p in 0..<3 {
      planes.push(
        Bytes::from_array(
          Array::makei(1024, i => {
            let row = i / 32
            let col = i % 32
            let noise = if f % 2 == 1 {
              (row * 7 + col * 11 + p * 3) % 17
            } else {
              0
            }
            ((col * 3 + row * 2 + f * 3 + p * 40 + noise) & 255).to_byte()
          })[:],
        ),
      )
    }
    frames.push((planes[0], planes[1], planes[2]))
  }
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
      let recon : Array[Bytes] = []
      let result = if cabac {
        h264_encode_frames_cabac(
          inputs,
          width=32,
          height=32,
          qp=20,
          chroma_format=3,
          dct8x8=true,
          recon~,
          bit_depth~,
        )
      } else {
        h264_encode_frames(
          inputs,
          width=32,
          height=32,
          qp=20,
          chroma_format=3,
          dct8x8=true,
          recon~,
          bit_depth~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let enc = match
        H264StreamEncoder::open(
          width=32,
          height=32,
          qp=20,
          chroma_format=3,
          cabac~,
          bit_depth~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let bytes : Array[Byte] = []
      for (y, u, v) in inputs {
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          for b in au {
            bytes.push(b)
          }
        }
      }
      match enc.finish() {
        Ok(tail) =>
          for au in tail {
            for b in au {
              bytes.push(b)
            }
          }
        Err(e) => fail(e)
      }
      assert_eq(Bytes::from_array(bytes[:]), stream)
      // §424 made in-loop deblocking the default, so the encoder's recon
      // is the FILTERED picture — decode with the loop filter on to
      // compare (the pre-§424 `true` here skipped it and went stale when
      // the wbtest unit lost its wasm runner; re-pinned with §435).
      let decoded = match h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail(e)
      }
      let mut count = 0
      for f in [2, 4] {
        for info in decoded[f].infos {
          if info.transform_8x8 &&
            (
              info.mb_type_bits &
              (
                h264_mb_type_intra4x4 |
                h264_mb_type_intra16x16 |
                h264_mb_type_intra_pcm
              )
            ) ==
            0 {
            count += 1
          }
        }
      }
      assert_true(count > 0)
      for i in 0..<4 {
        assert_eq(recon[i], decoded[i + 1].yuvp())
      }
    }
  }
  assert_true(h264_b_transform8_allowed(BL0x16(0, 0, 0), false))
  assert_false(h264_b_transform8_allowed(BDirect16, false))
  assert_true(h264_b_transform8_allowed(BDirect16, true))
  assert_false(
    h264_b_transform8_allowed(BParts(22, [10, 10, 10, 10], [], []), true),
  )
}
