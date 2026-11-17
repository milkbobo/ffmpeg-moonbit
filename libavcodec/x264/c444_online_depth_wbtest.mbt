///|
// test "pure H264 c444 online depth: VBV and forced IDR agree with FFmpeg" {
//   for bit_depth in [10, 12, 14] {
//     for cabac in [false, true] {
//       let enc = match
//         @libavcodec.H264StreamEncoder::open(
//           width=32,
//           height=32,
//           chroma_format=3,
//           bit_depth~,
//           cabac~,
//           multi_ref=3,
//           aq=true,
//           aud=true,
//           vbv_maxrate=320000,
//           vbv_bufsize=128000,
//           fps=25,
//         ) {
//         Ok(e) => e
//         Err(e) => fail(e)
//       }
//       let bytes : Array[Byte] = []
//       for f in 0..<6 {
//         let planes : Array[Bytes] = []
//         for p in 0..<3 {
//           let samples : Array[Byte] = []
//           for i in 0..<1024 {
//             let value = ((i % 32 * (p + 2) + i / 32 * 3 + f * 7 + p * 40) & 255) <<
//               (bit_depth - 8)
//             samples.push((value & 255).to_byte())
//             samples.push((value >> 8).to_byte())
//           }
//           planes.push(Bytes::from_array(samples[:]))
//         }
//         match
//           enc.push_frame(planes[0], planes[1], planes[2], force_idr=f == 2) {
//           Ok(_) => ()
//           Err(e) => fail(e)
//         }
//         for au in enc.drain() {
//           for b in au {
//             bytes.push(b)
//           }
//         }
//       }
//       match enc.finish() {
//         Ok(tail) =>
//           for au in tail {
//             for b in au {
//               bytes.push(b)
//             }
//           }
//         Err(e) => fail(e)
//       }
//       let stream = Bytes::from_array(bytes[:])
//       let pixels = match x264_probe_frames(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//         Ok(d) => d
//         Err(e) => fail(e)
//       }
//       assert_eq(pixels.n_frames, 6)
//       assert_eq(pixels.warnings, 0)
//       assert_eq(pixels.errors, 0)
//       for (i, coded) in [(0, 0), (1, 1), (2, 2), (3, 4), (4, 3), (5, 5)] {
//         let mut hash = 14695981039346656037UL
//         for b in decoded[coded].yuvp() {
//           hash = (hash ^ b.to_uint64()) * 1099511628211UL
//         }
//         assert_eq(
//           pixels.frames[i].digest_lo,
//           hash.to_int(),
//           msg="depth=\{bit_depth} cabac=\{cabac} frame=\{i}",
//         )
//         assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//         assert_eq(pixels.frames[i].decode_error_flags, 0)
//       }
//     }
//   }
// }
