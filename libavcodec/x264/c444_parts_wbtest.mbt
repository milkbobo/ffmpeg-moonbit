///|
// fn x264_c444_parts_fixture() -> Array[(Bytes, Bytes, Bytes)] {
//   let lumas : Array[Bytes] = []
//   for f in 0..<5 {
//     let y : Array[Byte] = []
//     let tx = f * 8 % 24
//     let bx = (4 - f) * 8 % 24
//     for row in 0..<48 {
//       for col in 0..<48 {
//         let mut s = (col * 3 + row * 2 + f * 5) & 255
//         let top_box = row >= 8 && row < 24 && col >= tx && col < tx + 16
//         let bot_box = row >= 24 && row < 40 && col >= bx && col < bx + 16
//         if top_box && (col == tx || col == tx + 15 || row == 8 || row == 23) {
//           s = 30
//         } else if top_box {
//           s = 235
//         } else if bot_box &&
//           (col == bx || col == bx + 15 || row == 24 || row == 39) {
//           s = 220
//         } else if bot_box {
//           s = 50
//         }
//         y.push(s.to_byte())
//       }
//     }
//     lumas.push(Bytes::from_array(y[:]))
//   }
//   Array::makei(5, f => {
//     let u = Bytes::from_array(
//       Array::makei(2304, i => {
//         ((i % 48 * 3 + i / 48 * 2 + f * 11 + 40) & 255).to_byte()
//       })[:],
//     )
//     (lumas[f], u, lumas[4 - f])
//   })
// }

///|
// test "pure H264 c444 B parts: FFmpeg pixels and diagnostics" {
//   let frames = x264_c444_parts_fixture()
//   for cabac in [false, true] {
//     let stats = @libavcodec.H264EncStats::new()
//     let result = if cabac {
//       @libavcodec.h264_encode_frames_cabac(
//         frames,
//         width=48,
//         height=48,
//         qp=22,
//         chroma_format=3,
//         b_slices=true,
//         b_parts=true,
//         intra_in_b=false,
//         intra4x4_in_b=false,
//         dct8x8=false,
//         multi_ref=3,
//         stats~,
//       )
//     } else {
//       @libavcodec.h264_encode_frames(
//         frames,
//         width=48,
//         height=48,
//         qp=22,
//         chroma_format=3,
//         b_slices=true,
//         b_parts=true,
//         intra_in_b=false,
//         intra4x4_in_b=false,
//         dct8x8=false,
//         multi_ref=3,
//         stats~,
//       )
//     }
//     let stream = match result {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     assert_true(stats.bpart_mbs > 0)
//     assert_true(stats.b8x8_mbs > 0)
//     let pixels = match x264_probe_frames(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//       Ok(d) => d
//       Err(e) => fail(e)
//     }
//     assert_eq(pixels.n_frames, 5)
//     assert_eq(pixels.warnings, 0)
//     assert_eq(pixels.errors, 0)
//     for (i, coded) in [(0, 0), (1, 2), (2, 1), (3, 4), (4, 3)] {
//       let mut hash = 14695981039346656037UL
//       for b in decoded[coded].yuvp() {
//         hash = (hash ^ b.to_uint64()) * 1099511628211UL
//       }
//       assert_eq(pixels.frames[i].digest_lo, hash.to_int())
//       assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//       assert_eq(pixels.frames[i].decode_error_flags, 0)
//     }
//   }
// }
