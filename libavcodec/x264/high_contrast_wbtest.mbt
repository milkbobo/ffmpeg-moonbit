///|
// test "pure H264 high contrast: wide RD costs agree with FFmpeg" {
//   for bit_depth in [12, 14] {
//     for chroma_format in [1, 3] {
//       let max = (1 << bit_depth) - 1
//       let samples : Array[Byte] = []
//       for _ in 0..<256 {
//         samples.push((max & 255).to_byte())
//         samples.push((max >> 8).to_byte())
//       }
//       let light = Bytes::from_array(samples[:])
//       let cbytes = if chroma_format == 3 { 512 } else { 128 }
//       let frames = [
//         (Bytes::make(512, 0), Bytes::make(cbytes, 0), Bytes::make(cbytes, 0)),
//         (
//           light,
//           Bytes::from_array(samples[:cbytes]),
//           Bytes::from_array(samples[:cbytes]),
//         ),
//         (Bytes::make(512, 0), Bytes::make(cbytes, 0), Bytes::make(cbytes, 0)),
//       ]
//       for cabac in [false, true] {
//         for b_slices in [false, true] {
//           let stats = @libavcodec.H264EncStats::new()
//           let result = if cabac {
//             @libavcodec.h264_encode_frames_cabac(
//               frames,
//               width=16,
//               height=16,
//               bit_depth~,
//               chroma_format~,
//               b_slices~,
//               b_parts=false,
//               intra_in_b=true,
//               intra4x4_in_b=false,
//               dct8x8=!b_slices,
//               stats~,
//               weightp=false,
//             )
//           } else {
//             @libavcodec.h264_encode_frames(
//               frames,
//               width=16,
//               height=16,
//               bit_depth~,
//               chroma_format~,
//               b_slices~,
//               b_parts=false,
//               intra_in_b=true,
//               intra4x4_in_b=false,
//               dct8x8=!b_slices,
//               stats~,
//               weightp=false,
//             )
//           }
//           let stream = match result {
//             Ok(s) => s
//             Err(e) => fail(e)
//           }
//           if b_slices {
//             assert_true(stats.bi16_mbs > 0)
//           }
//           let pixels = match x264_probe_frames(stream) {
//             Ok(p) => p
//             Err(e) => fail(e)
//           }
//           let decoded = match
//             @libavcodec.h264_decode_annexb_frames(stream, false) {
//             Ok(d) => d
//             Err(e) => fail(e)
//           }
//           assert_eq(pixels.n_frames, 3)
//           assert_eq(pixels.warnings, 0)
//           assert_eq(pixels.errors, 0)
//           for i in 0..<3 {
//             let coded = if b_slices { [0, 2, 1][i] } else { i }
//             let mut hash = 14695981039346656037UL
//             for b in decoded[coded].yuvp() {
//               hash = (hash ^ b.to_uint64()) * 1099511628211UL
//             }
//             assert_eq(pixels.frames[i].digest_lo, hash.to_int())
//             assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//             assert_eq(pixels.frames[i].decode_error_flags, 0)
//           }
//           for value in decoded[if b_slices { 2 } else { 1 }].y {
//             assert_true(value > max * 3 / 4)
//           }
//           for value in decoded[if b_slices { 1 } else { 2 }].y {
//             assert_true(value < max / 4)
//           }
//         }
//       }
//     }
//   }
// }
