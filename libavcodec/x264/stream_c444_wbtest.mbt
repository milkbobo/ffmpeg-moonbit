///|
// test "pure H264 444 P anchor: full chroma RD agrees with FFmpeg" {
//   let frames : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<2 {
//     let y = Bytes::from_array(
//       Array::makei(6144, i => {
//         ((i % 96 * 2 + i / 96 * 3 + f * 7) & 255).to_byte()
//       })[:],
//     )
//     let u = Bytes::from_array(
//       Array::makei(6144, i => {
//         ((i % 96 + i / 96 * 2 + f * 5 + 40) & 255).to_byte()
//       })[:],
//     )
//     let v = Bytes::from_array(
//       Array::makei(6144, i => {
//         ((i % 96 * 3 + i / 96 + f * 3 + 70) & 255).to_byte()
//       })[:],
//     )
//     frames.push((y, u, v))
//   }
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       chroma_format=3,
//       b_slices=false,
//       dct8x8=false,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let pixels = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   assert_eq(pixels.n_frames, 2)
//   assert_eq(pixels.warnings, 0)
//   assert_eq(pixels.errors, 0)
//   for i in 0..<2 {
//     let mut hash = 14695981039346656037UL
//     for b in decoded[i].yuvp() {
//       hash = (hash ^ b.to_uint64()) * 1099511628211UL
//     }
//     assert_eq(pixels.frames[i].digest_lo, hash.to_int())
//     assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//   }
//   assert_eq(x264_md5(decoded[1].yuvp()), "4f1577f252c919ebc3f8e1b2890085fc")
// }

///|
// test "pure H264 444 B: FFmpeg agrees on inter pictures" {
//   let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
//   let ramp = Bytes::from_array(
//     Array::makei(1024, i => ((i % 32 * 6 + i / 32 * 2) & 255).to_byte())[:],
//   )
//   let frames = [(flat, flat, flat), (ramp, ramp, ramp), (flat, ramp, flat)]
//   for cabac in [false, true] {
//     let stats = @libavcodec.H264EncStats::new()
//     let result = if cabac {
//       @libavcodec.h264_encode_frames_cabac(
//         frames,
//         width=32,
//         height=32,
//         qp=26,
//         chroma_format=3,
//         b_slices=true,
//         b_parts=false,
//         intra_in_b=false,
//         intra4x4_in_b=false,
//         dct8x8=false,
//         stats~,
//       )
//     } else {
//       @libavcodec.h264_encode_frames(
//         frames,
//         width=32,
//         height=32,
//         qp=26,
//         chroma_format=3,
//         b_slices=true,
//         b_parts=false,
//         intra_in_b=false,
//         intra4x4_in_b=false,
//         dct8x8=false,
//         stats~,
//       )
//     }
//     let stream = match result {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     let enc = match
//       @libavcodec.H264StreamEncoder::open(
//         width=32,
//         height=32,
//         qp=26,
//         chroma_format=3,
//         cabac~,
//         b_slices=true,
//         b_parts=false,
//         intra_in_b=false,
//         intra4x4_in_b=false,
//         dct8x8=false,
//       ) {
//       Ok(e) => e
//       Err(e) => fail(e)
//     }
//     let bytes : Array[Byte] = []
//     for (y, u, v) in frames {
//       match enc.push_frame(y, u, v) {
//         Ok(_) => ()
//         Err(e) => fail(e)
//       }
//       for au in enc.drain() {
//         for b in au {
//           bytes.push(b)
//         }
//       }
//     }
//     match enc.finish() {
//       Ok(tail) =>
//         for au in tail {
//           for b in au {
//             bytes.push(b)
//           }
//         }
//       Err(e) => fail(e)
//     }
//     let streamed = Bytes::from_array(bytes[:])
//     assert_eq(streamed.length(), stream.length())
//     assert_eq(x264_md5(streamed), x264_md5(stream))
//     let stream = streamed
//     assert_true(stats.b_mbs > 0)
//     let pixels = match x264_probe_frames(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//       Ok(d) => d
//       Err(e) => fail(e)
//     }
//     assert_eq(pixels.n_frames, 3)
//     assert_eq(pixels.warnings, 0)
//     assert_eq(pixels.errors, 0)
//     for (i, coded) in [(0, 0), (1, 2), (2, 1)] {
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

///|
// test "pure H264 444: FFmpeg agrees on I8 inside P slices" {
//   let flat = Bytes::from_array(Array::make(1024, b'\x80')[:])
//   let ramp = Bytes::from_array(
//     Array::makei(1024, i => ((i % 32 * 6 + i / 32 * 2) & 255).to_byte())[:],
//   )
//   let frames = [(flat, flat, flat), (ramp, ramp, ramp), (flat, ramp, flat)]
//   for cabac in [false, true] {
//     let stats = @libavcodec.H264EncStats::new()
//     let result = if cabac {
//       @libavcodec.h264_encode_frames_cabac(
//         frames,
//         width=32,
//         height=32,
//         qp=26,
//         chroma_format=3,
//         b_slices=false,
//         intra_in_p=true,
//         stats~,
//       )
//     } else {
//       @libavcodec.h264_encode_frames(
//         frames,
//         width=32,
//         height=32,
//         qp=26,
//         chroma_format=3,
//         b_slices=false,
//         intra_in_p=true,
//         stats~,
//       )
//     }
//     let stream = match result {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     assert_true(stats.i8p_mbs > 0)
//     let pixels = match x264_probe_frames(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//       Ok(d) => d
//       Err(e) => fail(e)
//     }
//     assert_eq(pixels.n_frames, 3)
//     assert_eq(pixels.warnings, 0)
//     assert_eq(pixels.errors, 0)
//     for i in 0..<3 {
//       let mut hash = 14695981039346656037UL
//       for b in decoded[i].yuvp() {
//         hash = (hash ^ b.to_uint64()) * 1099511628211UL
//       }
//       assert_eq(pixels.frames[i].digest_lo, hash.to_int())
//       assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//       assert_eq(pixels.frames[i].decode_error_flags, 0)
//     }
//   }
// }

///|
// test "pure H264 streaming 444: FFmpeg accepts CAVLC and CABAC I/P" {
//   for cabac in [false, true] {
//     for chroma_only in [false, true] {
//       let enc = match
//         @libavcodec.H264StreamEncoder::open(
//           width=32,
//           height=32,
//           chroma_format=3,
//           cabac~,
//           b_slices=false,
//           qp=24,
//         ) {
//         Ok(e) => e
//         Err(e) => fail(e)
//       }
//       let bytes : Array[Byte] = []
//       for f in 0..<4 {
//         let y = Bytes::from_array(
//           Array::makei(1024, i => {
//             (if chroma_only {
//               128
//             } else {
//               (i % 32 * 2 + i / 32 * 3 + f * 7) & 255
//             }).to_byte()
//           })[:],
//         )
//         let u = Bytes::from_array(
//           Array::makei(1024, i => {
//             ((i % 32 + i / 32 * 2 + f * 5 + 40) & 255).to_byte()
//           })[:],
//         )
//         let v = Bytes::from_array(
//           Array::makei(1024, i => {
//             ((i % 32 * 3 + i / 32 + f * 3 + 70) & 255).to_byte()
//           })[:],
//         )
//         match enc.push_frame(y, u, v) {
//           Ok(_) => ()
//           Err(e) => fail(e)
//         }
//         for au in enc.drain() {
//           for b in au {
//             bytes.push(b)
//           }
//         }
//       }
//       let probe = match x264_probe_annexb(Bytes::from_array(bytes[:])) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.n_frames, 4)
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       let stream = Bytes::from_array(bytes[:])
//       let pixels = match x264_probe_frames(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
//         Ok(d) => d
//         Err(e) => fail(e)
//       }
//       assert_eq(pixels.n_frames, 4)
//       assert_eq(pixels.warnings, 0)
//       assert_eq(pixels.errors, 0)
//       for i in 0..<4 {
//         let mut hash = 14695981039346656037UL
//         for b in decoded[i].yuvp() {
//           hash = (hash ^ b.to_uint64()) * 1099511628211UL
//         }
//         assert_eq(pixels.frames[i].digest_lo, hash.to_int())
//         assert_eq(pixels.frames[i].digest_hi, (hash >> 32).to_int())
//         assert_eq(pixels.frames[i].decode_error_flags, 0)
//       }
//     }
//   }
// }
