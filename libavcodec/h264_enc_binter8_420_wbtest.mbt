///|
/// §422e fixture: 4:2:0/4:2:2 planes with a moving textured luma (low QP
/// keeps residuals on the B pictures so the transform flags appear). The
/// chroma planes follow `cf`: 1 = `w/2 x h/2`, 2 = `w/2 x h`.
fn binter8_420_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
  cf : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let ch = if cf == 2 { h } else { h / 2 }
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<n {
    let y = Bytes::from_array(
      Array::makei(w * h, i => {
        let row = i / w
        let col = i % w
        ((col * 5 + row * 3 + f * 11 + row / 8 * (col / 8) * f) & 255).to_byte()
      })[:],
    )
    let cu = Bytes::from_array(
      Array::makei(w / 2 * ch, i => {
        let row = i / (w / 2)
        let col = i % (w / 2)
        (((col * 3 + row + f * 5) & 0x3F) + 96).to_byte()
      })[:],
    )
    let cv = Bytes::from_array(
      Array::makei(w / 2 * ch, i => {
        let row = i / (w / 2)
        let col = i % (w / 2)
        (((row * 7 + col / 2 + f) & 0x3F) + 96).to_byte()
      })[:],
    )
    frames.push((y, cu, cv))
  }
  frames
}

///|
/// §422e: B-slice inter macroblocks at 4:2:0/4:2:2 use the 8x8 luma
/// transform when the partitions qualify (`h264_b_transform8_allowed`
/// mirrors the decoder gate; chroma stays 4x4 + DC). Both entropies:
/// the decoded B pictures carry inter transform_8x8 macroblocks, the
/// recon equals the local skip-filter decode, and the streaming encoder
/// reproduces the batch bytes.
test "h264 b inter8 420/422: transform flags, reconstruction, stream" {
  for cf in [1, 2] {
    let frames = binter8_420_fixture(96, 64, 7, cf)
    for cabac in [false, true] {
      let recon : Array[Bytes] = []
      let result = if cabac {
        h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=20,
          chroma_format=cf,
          recon~,
        )
      } else {
        h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=20,
          chroma_format=cf,
          recon~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail("cf=\{cf} cabac=\{cabac}: \{e}")
      }
      let enc = match
        H264StreamEncoder::open(
          width=96,
          height=64,
          qp=20,
          chroma_format=cf,
          cabac~,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let bytes : Array[Byte] = []
      for (y, u, v) in frames {
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
      assert_eq(
        Bytes::from_array(bytes[:]),
        stream,
        msg="cf=\{cf} cabac=\{cabac} stream != batch",
      )
      // §424 made in-loop deblocking the default, so the encoder's recon
      // is the FILTERED picture — decode with the loop filter on to
      // compare (the pre-§424 `true` here skipped it and went stale when
      // the wbtest unit lost its wasm runner; re-pinned with §435).
      let decoded = match h264_decode_annexb_frames(stream, false) {
        Ok(d) => d
        Err(e) => fail("cf=\{cf} cabac=\{cabac}: \{e}")
      }
      assert_eq(decoded.length(), 7)
      // The B pictures (decode order 1, 3, 5) carry inter macroblocks
      // with transform_8x8 set and residuals coded.
      let mut count = 0
      for f in [1, 3, 5] {
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
      assert_true(count > 0, msg="cf=\{cf} cabac=\{cabac} no inter 8x8 MBs")
      for i = 0; i < 6; i = i + 1 {
        assert_eq(
          recon[i],
          decoded[i + 1].yuvp(),
          msg="cf=\{cf} cabac=\{cabac} recon \{i}",
        )
      }
    }
  }
  // The partition gate: plain 8x8 sub-partitions qualify, 4x4 ones do not.
  assert_true(
    h264_b_transform8_allowed(BParts(22, [3, 3, 3, 3], [], []), false),
  )
  assert_false(
    h264_b_transform8_allowed(BParts(22, [10, 10, 10, 10], [], []), true),
  )
}
