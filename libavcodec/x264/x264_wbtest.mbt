// Round-trip validation of the libx264 binding: the encoder's output is
// decoded by BOTH the real FFmpeg H.264 decoder (C oracle via
// `x264_decode_annexb`) and the pure MoonBit decoder of this repository,
// and the two must agree pixel-for-pixel - the same standard the decoder
// itself was accepted against. Determinism (two opens, byte-identical
// streams) pins the thread_count=1 + BITEXACT configuration the binding
// runs.

///|
// fn x264_put_sample(
//   plane : Array[Byte],
//   idx : Int32,
//   s : Int32,
//   bps : Int32,
// ) -> Unit {
//   plane[idx * bps] = (s & 0xFF).to_byte()
//   if bps == 2 {
//     plane[idx * bps + 1] = ((s >> 8) & 0xFF).to_byte()
//   }
// }

///|
/// Deterministic YUV 4:2:0 fixture: moving gradient + checkerboard + a
/// roaming 16x16 box (luma) and drifting chroma, `bps` bytes per sample LE.
// fn x264_fixture(
//   n : Int32,
//   w : Int32,
//   h : Int32,
//   bps : Int32,
// ) -> Array[(Int64, Bytes, Bytes, Bytes)] {
//   let cw = w / 2
//   let ch = h / 2
//   let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
//   for f in 0..<n {
//     let y : Array[Byte] = Array::make(w * h * bps, b'\x00')
//     let u : Array[Byte] = Array::make(cw * ch * bps, b'\x00')
//     let v : Array[Byte] = Array::make(cw * ch * bps, b'\x00')
//     let bx = f * 4 % (w - 16)
//     let by = f * 6 % (h - 16)
//     for row in 0..<h {
//       for col in 0..<w {
//         let mut s = (col * 2 + row * 3 + f * 7) & 0xFF
//         if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
//           s = (s + 48) & 0xFF
//         }
//         let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
//         let border = col == bx || col == bx + 15 || row == by || row == by + 15
//         if inbox && border {
//           s = 40
//         } else if inbox {
//           s = 220
//         }
//         x264_put_sample(y, row * w + col, s, bps)
//       }
//     }
//     for row in 0..<ch {
//       for col in 0..<cw {
//         x264_put_sample(u, row * cw + col, ((col + f) & 0x3F) + 96, bps)
//         x264_put_sample(v, row * cw + col, ((row + f * 2) & 0x3F) + 96, bps)
//       }
//     }
//     frames.push(
//       (
//         f.to_int64(),
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   frames
// }

///|
/// Encode the fixture once; returns `(extradata, packets)`.
// fn x264_run(
//   frames : Array[(Int64, Bytes, Bytes, Bytes)],
//   options : Array[(String, String)],
//   pix : X264PixelFormat,
//   global_header : Bool,
//   bit_rate : Int32,
//   rc_max_rate~ : Int32 = 0,
//   rc_buffer_size~ : Int32 = 0,
// ) -> (Bytes?, Array[X264Packet]) raise X264Error {
//   let enc = X264Encoder::open(
//     width=96,
//     height=64,
//     pix_fmt=pix,
//     time_base=(1, 25),
//     framerate=(25, 1),
//     bit_rate~,
//     global_header~,
//     options~,
//     rc_max_rate~,
//     rc_buffer_size~,
//   )
//   let extra = if global_header { Some(enc.extradata()) } else { None }
//   let packets = enc.encode_all(frames)
//   enc.close()
//   (extra, packets)
// }

///|
// fn x264_bytes_eq(a : Bytes, b : Bytes) -> Bool {
//   if a.length() != b.length() {
//     return false
//   }
//   for i in 0..<a.length() {
//     if a[i] != b[i] {
//       return false
//     }
//   }
//   true
// }

///|
// fn x264_concat(packets : Array[X264Packet]) -> Bytes {
//   let out : Array[Byte] = []
//   for p in packets {
//     for i in 0..<p.data.length() {
//       out.push(p.data[i])
//     }
//   }
//   Bytes::from_array(out[:])
// }

///|
/// Diff a whole encoded stream both ways: decode with the pure MoonBit
/// decoder (presentation order) and with the in-stub C oracle, then compare
/// every frame's packed planes byte-for-byte. `bps` is bytes per sample.
// fn x264_cross_decode(
//   stream : Bytes,
//   want_frames : Int32,
//   bps : Int32,
// ) -> Unit raise {
//   let c = match x264_decode_annexb(stream) {
//     Ok(v) => v
//     Err(e) => fail(e)
//   }
//   let n = c.n_frames
//   let width = c.width
//   let height = c.height
//   let frames = match
//     @libavcodec.h264_decode_annexb_display_frames(stream, false) {
//     Ok(v) => v
//     Err(e) => fail(e)
//   }
//   if n != frames.length() {
//     fail("frame count: C \{n} vs pure \{frames.length()}")
//   }
//   if n != want_frames {
//     fail("expected \{want_frames} frames, decoded \{n}")
//   }
//   if c.bytes_per_sample() != bps {
//     fail("bps: C \{c.bytes_per_sample()} vs test \{bps}")
//   }
//   let plane_y = width * height * bps
//   let plane_c = width / 2 * (height / 2) * bps
//   for i = 0; i < n; i = i + 1 {
//     let f = frames[i]
//     if f.width != width || f.height != height {
//       fail(
//         "frame \{i}: geometry \{f.width}x\{f.height} vs C \{width}x\{height}",
//       )
//     }
//     let got = f.yuvp()
//     if !x264_bytes_eq(got[0:plane_y].to_owned(), c.frame_y(i)) {
//       fail("frame \{i}: luma planes differ (kind=\{c.kind})")
//     }
//     if !x264_bytes_eq(got[plane_y:plane_y + plane_c].to_owned(), c.frame_u(i)) {
//       fail("frame \{i}: Cb planes differ")
//     }
//     if !x264_bytes_eq(
//         got[plane_y + plane_c:plane_y + 2 * plane_c].to_owned(),
//         c.frame_v(i),
//       ) {
//       fail("frame \{i}: Cr planes differ")
//     }
//   }
// }

///|
// test "x264 forced IDR respects PTS and does not persist across frames" {
//   for bframes in [0, 2] {
//     let enc = X264Encoder::open(width=96, height=64, global_header=false, options=[
//       ("preset", "medium"),
//       ("g", "100"),
//       ("bf", bframes.to_string()),
//       ("b_strategy", "0"),
//       ("sc_threshold", "0"),
//       ("x264-params", "open-gop=1"),
//     ])
//     let packets : Array[X264Packet] = []
//     fn pull(enc : X264Encoder, packets : Array[X264Packet]) -> Unit raise {
//       for ;; {
//         match enc.receive_packet() {
//           Packet(p) => packets.push(p)
//           Again | Eof => break
//         }
//       }
//     }
//     for frame in x264_fixture(9, 96, 64, 1) {
//       let (pts, y, u, v) = frame
//       while !enc.send_frame(pts~, y~, u~, v~, force_idr=pts == 4L) {
//         pull(enc, packets)
//       }
//       pull(enc, packets)
//     }
//     for p in enc.flush() {
//       packets.push(p)
//     }
//     enc.close()
//     assert_eq(packets.length(), 9)
//     for p in packets {
//       assert_eq(p.keyframe, p.pts == Some(0L) || p.pts == Some(4L))
//     }
//     let stream = x264_concat(packets)
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.errors, 0)
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.nal_types.filter(t => t == 5).length(), 2)
//     if bframes > 0 {
//       let fp = match x264_probe_frames(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_true(fp.frames.any(f => f.pict_type == 3))
//     }
//     x264_cross_decode(stream, 9, 1)
// An IDR must also be independently decodable from its own access unit.
//     let tail : Array[X264Packet] = []
//     let mut started = false
//     for p in packets {
//       if p.pts == Some(4L) {
//         started = true
//       }
//       if started {
//         tail.push(p)
//       }
//     }
//     x264_cross_decode(x264_concat(tail), 5, 1)
//   }
// }

///|
// test "x264 oracle: pure multiref warm-up is warning-free and matches FFmpeg pixels" {
//   let input = x264_fixture(7, 96, 64, 1)
//   let frames = input.map(f => (f.1, f.2, f.3))
//   for nrefs in [2, 3, 16] {
//     for cabac in [false, true] {
//       for weightp in [false, true] {
//         let stream = match
//           (if cabac {
//             @libavcodec.h264_encode_frames_cabac(
//               frames,
//               width=96,
//               height=64,
//               qp=26,
//               b_slices=false,
//               multi_ref=nrefs,
//               weightp~,
//             )
//           } else {
//             @libavcodec.h264_encode_frames(
//               frames,
//               width=96,
//               height=64,
//               qp=26,
//               b_slices=false,
//               multi_ref=nrefs,
//               weightp~,
//             )
//           }) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 7)
//         x264_cross_decode(stream, 7, 1)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: multiref eviction across frame_num wraps is warning-free" {
//   let frames = x264_fixture(35, 32, 32, 1).map(f => (f.1, f.2, f.3))
//   for nrefs in [3, 16] {
//     for cabac in [false, true] {
//       let stream = match
//         (if cabac {
//           @libavcodec.h264_encode_frames_cabac(
//             frames,
//             width=32,
//             height=32,
//             qp=26,
//             b_slices=false,
//             multi_ref=nrefs,
//           )
//         } else {
//           @libavcodec.h264_encode_frames(
//             frames,
//             width=32,
//             height=32,
//             qp=26,
//             b_slices=false,
//             multi_ref=nrefs,
//           )
//         }) {
//         Ok(s) => s
//         Err(e) => fail(e)
//       }
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 35)
//       x264_cross_decode(stream, 35, 1)
//     }
//   }
// }

///|
// test "x264 oracle: chroma-only AC residuals match FFmpeg at 8 and 10 bits" {
//   for depth in [8, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames : Array[(Bytes, Bytes, Bytes)] = []
//     for f in 0..<7 {
//       let y = Array::make(1024 * bps, b'\x00')
//       let c = Array::make(256 * bps, b'\x00')
//       for i in 0..<1024 {
//         x264_put_sample(y, i, 128 << (depth - 8), bps)
//       }
//       for i in 0..<256 {
//         let value = if (i / 16 / 2 + i % 16 / 2 + f % 2) % 2 == 0 {
//           40
//         } else {
//           210
//         }
//         x264_put_sample(c, i, value << (depth - 8), bps)
//       }
//       let chroma = Bytes::from_array(c[:])
//       frames.push((Bytes::from_array(y[:]), chroma, chroma))
//     }
//     for cabac in [false, true] {
//       for weightp in [false, true] {
//         let stream = match
//           (if cabac {
//             @libavcodec.h264_encode_frames_cabac(
//               frames,
//               width=32,
//               height=32,
//               qp=16,
//               b_slices=false,
//               multi_ref=2,
//               bit_depth=depth,
//               weightp~,
//             )
//           } else {
//             @libavcodec.h264_encode_frames(
//               frames,
//               width=32,
//               height=32,
//               qp=16,
//               b_slices=false,
//               multi_ref=2,
//               bit_depth=depth,
//               weightp~,
//             )
//           }) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         x264_cross_decode(stream, 7, bps)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: multiref average-byte control matches FFmpeg" {
//   for depth in [8, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(5, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       fn encode(qp : Int32, target : Int32) -> Bytes raise {
//         match
//           (if cabac {
//             @libavcodec.h264_encode_frames_cabac(
//               frames,
//               width=32,
//               height=32,
//               qp~,
//               target_bytes=target,
//               b_slices=false,
//               multi_ref=3,
//               bit_depth=depth,
//             )
//           } else {
//             @libavcodec.h264_encode_frames(
//               frames,
//               width=32,
//               height=32,
//               qp~,
//               target_bytes=target,
//               b_slices=false,
//               multi_ref=3,
//               bit_depth=depth,
//             )
//           }) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//       }
//       let fine = encode(20, 0)
//       let coarse = encode(51, 0)
//       let target = (fine.length() + coarse.length()) / 2
//       let stream = encode(20, target)
//       assert_true(stream.length() <= target)
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 5)
//       x264_cross_decode(stream, 5, bps)
//     }
//   }
// }

///|
// test "x264 oracle: multiref VBV streams match FFmpeg" {
//   for depth in [8, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(6, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for tight in [false, true] {
//         let rate = if tight { 32000 } else { 200000 }
//         let buffer = if tight { 8000 } else { 32000 }
//         let stream = match
//           (if cabac {
//             @libavcodec.h264_encode_frames_cabac(
//               frames,
//               width=32,
//               height=32,
//               qp=20,
//               b_slices=false,
//               multi_ref=3,
//               bit_depth=depth,
//               vbv_maxrate=rate,
//               vbv_bufsize=buffer,
//               fps=25,
//             )
//           } else {
//             @libavcodec.h264_encode_frames(
//               frames,
//               width=32,
//               height=32,
//               qp=20,
//               b_slices=false,
//               multi_ref=3,
//               bit_depth=depth,
//               vbv_maxrate=rate,
//               vbv_bufsize=buffer,
//               fps=25,
//             )
//           }) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 6)
//         x264_cross_decode(stream, 6, bps)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: multiref VBV frame_num wrap matches FFmpeg" {
//   let frames = x264_fixture(35, 32, 32, 1).map(f => (f.1, f.2, f.3))
//   for nrefs in [3, 16] {
//     for cabac in [false, true] {
//       let stream = match
//         (if cabac {
//           @libavcodec.h264_encode_frames_cabac(
//             frames,
//             width=32,
//             height=32,
//             qp=20,
//             b_slices=false,
//             multi_ref=nrefs,
//             vbv_maxrate=200000,
//             vbv_bufsize=32000,
//             fps=25,
//           )
//         } else {
//           @libavcodec.h264_encode_frames(
//             frames,
//             width=32,
//             height=32,
//             qp=20,
//             b_slices=false,
//             multi_ref=nrefs,
//             vbv_maxrate=200000,
//             vbv_bufsize=32000,
//             fps=25,
//           )
//         }) {
//         Ok(s) => s
//         Err(e) => fail(e)
//       }
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 35)
//       x264_cross_decode(stream, 35, 1)
//     }
//   }
// }

///|
// test "x264 oracle: all P tools compose at 8 9 and 10 bits" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     fn scale(plane : Bytes) -> Bytes {
//       if depth == 8 {
//         return plane
//       }
//       let out = Array::make(plane.length(), b'\x00')
//       for i in 0..<(plane.length() / 2) {
//         let sample = plane[i * 2].to_int() | (plane[i * 2 + 1].to_int() << 8)
//         x264_put_sample(out, i, sample << (depth - 8), 2)
//       }
//       Bytes::from_array(out[:])
//     }
//     let frames = x264_fixture(6, 32, 32, bps).map(f => {
//       (scale(f.1), scale(f.2), scale(f.3))
//     })
//     for cabac in [false, true] {
//       for dct8x8 in [false, true] {
//         let stream = match
//           @libavcodec.video_encode(frames, codec=@libavcodec.VideoCodec::H264, config={
//             ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//             cabac,
//             dct8x8,
//             b_slices: false,
//             multi_ref: 3,
//             bit_depth: depth,
//             aud: true,
//             aq: true,
//             aq_strength: 6,
//             weightp: true,
//             vbv_maxrate: 200000,
//             vbv_bufsize: 32000,
//             fps: 25,
//           }) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 6)
//         let decoded = match x264_decode_annexb(stream) {
//           Ok(d) => d
//           Err(e) => fail(e)
//         }
//         assert_eq(
//           decoded.kind,
//           if depth == 8 {
//             0
//           } else if depth == 9 {
//             2
//           } else {
//             1
//           },
//         )
//         assert_eq(decoded.bytes_per_sample(), bps)
//         x264_cross_decode(stream, 6, bps)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: pure streaming forced IDR is independently decodable" {
//   fn join(aus : Array[Bytes]) -> Bytes {
//     let bytes : Array[Byte] = []
//     for au in aus {
//       for byte in au {
//         bytes.push(byte)
//       }
//     }
//     Bytes::from_array(bytes[:])
//   }
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(8, 32, 32, bps)
//     for
//       (cabac, aud) in [
//         (false, false),
//         (false, true),
//         (true, false),
//         (true, true),
//       ] {
//       let enc = match
//         @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config={
//           ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//           cabac,
//           b_slices: false,
//           multi_ref: 3,
//           bit_depth: depth,
//           aq: true,
//           aq_strength: 6,
//           aud,
//         }) {
//         Ok(e) => e
//         Err(e) => fail(e)
//       }
//       let aus : Array[Bytes] = []
//       for i, (_, y, u, v) in frames {
//         match enc.push_frame(y, u, v, force_idr=i == 3 || i == 4) {
//           Ok(_) => ()
//           Err(e) => fail(e)
//         }
//         for au in enc.drain() {
//           aus.push(au)
//         }
//       }
//       match enc.finish() {
//         Ok(tail) =>
//           for au in tail {
//             aus.push(au)
//           }
//         Err(e) => fail(e)
//       }
//       assert_eq(aus.length(), 8)
//       let stream = join(aus)
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       for ty in [5, 7, 8] {
//         assert_eq(probe.nal_types.filter(t => t == ty).length(), 3)
//       }
//       x264_cross_decode(stream, 8, bps)
//       for start in [3, 4] {
//         let tail = join(aus[start:].to_owned())
//         let tp = match x264_probe_annexb(tail) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(tp.warnings, 0)
//         assert_eq(tp.errors, 0)
//         x264_cross_decode(tail, 8 - start, bps)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: periodic batch IDR GOPs are independent" {
//   fn join(aus : Array[Bytes]) -> Bytes {
//     let bytes : Array[Byte] = []
//     for au in aus {
//       for byte in au {
//         bytes.push(byte)
//       }
//     }
//     Bytes::from_array(bytes[:])
//   }
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(8, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       let config = {
//         ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//         cabac,
//         keyint: 3,
//         b_slices: false,
//         multi_ref: 3,
//         bit_depth: depth,
//         aud: true,
//         aq: true,
//         aq_strength: 6,
//       }
//       let stream = match
//         @libavcodec.video_encode(
//           frames,
//           codec=@libavcodec.VideoCodec::H264,
//           config~,
//         ) {
//         Ok(s) => s
//         Err(e) => fail(e)
//       }
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.nal_types.filter(t => t == 5).length(), 3)
//       x264_cross_decode(stream, 8, bps)
//       let enc = match
//         @libavcodec.VideoEncoder::open(
//           codec=@libavcodec.VideoCodec::H264,
//           config~,
//         ) {
//         Ok(e) => e
//         Err(e) => fail(e)
//       }
//       let aus : Array[Bytes] = []
//       for (y, u, v) in frames {
//         match enc.push_frame(y, u, v) {
//           Ok(_) => ()
//           Err(e) => fail(e)
//         }
//         for au in enc.drain() {
//           aus.push(au)
//         }
//       }
//       match enc.finish() {
//         Ok(tail) =>
//           for au in tail {
//             aus.push(au)
//           }
//         Err(e) => fail(e)
//       }
//       assert_eq(stream, join(aus))
//       for start in [3, 6] {
//         let tail = join(aus[start:].to_owned())
//         let tp = match x264_probe_annexb(tail) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(tp.warnings, 0)
//         assert_eq(tp.errors, 0)
//         x264_cross_decode(tail, 8 - start, bps)
//       }
//     }
//   }
// }

///|
// test "x264 oracle: periodic ABR uses a whole-sequence budget" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(7, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       let config = {
//         ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//         cabac,
//         keyint: 3,
//         b_slices: false,
//         multi_ref: 3,
//         bit_depth: depth,
//         qp: 20,
//         aud: true,
//         aq: true,
//         aq_strength: 3,
//       }
//       fn encode(config : @libavcodec.VideoEncConfig) -> Bytes raise {
//         match
//           @libavcodec.video_encode(
//             frames,
//             codec=@libavcodec.VideoCodec::H264,
//             config~,
//           ) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//       }
//       let fine = encode(config)
//       let coarse = encode({ ..config, qp: 51, })
//       let target = (fine.length() + coarse.length()) / 2
//       let stream = encode({ ..config, target_bytes: target, })
//       assert_true(stream.length() <= target)
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 7)
//       assert_eq(probe.nal_types.filter(t => t == 5).length(), 3)
//       x264_cross_decode(stream, 7, bps)
//       assert_eq(probe.au_sizes.length(), 7)
//       let mut offset = 0
//       for i in 0..<7 {
//         if i == 3 || i == 6 {
//           let tail = stream[offset:].to_owned()
//           let tp = match x264_probe_annexb(tail) {
//             Ok(p) => p
//             Err(e) => fail(e)
//           }
//           assert_eq(tp.warnings, 0)
//           assert_eq(tp.errors, 0)
//           x264_cross_decode(tail, 7 - i, bps)
//         }
//         offset += probe.au_sizes[i]
//       }
//       assert_eq(offset, stream.length())
//     }
//   }
// }

///|
// test "x264 oracle: periodic VBV keeps CPB continuity and random access" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(8, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [1, 3] {
//         let stats = @libavcodec.H264EncStats::new()
//         let stream = match
//           @libavcodec.video_encode(
//             frames,
//             codec=@libavcodec.VideoCodec::H264,
//             config={
//               ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//               cabac,
//               keyint,
//               b_slices: false,
//               multi_ref: 3,
//               bit_depth: depth,
//               qp: 10,
//               aud: true,
//               aq: true,
//               aq_strength: 3,
//               vbv_maxrate: 64000,
//               vbv_bufsize: 8000,
//               fps: 25,
//             },
//             stats~,
//           ) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 8)
//         assert_eq(probe.au_sizes.length(), 8)
//         assert_eq(
//           probe.nal_types.filter(t => t == 5).length(),
//           (8 + keyint - 1) / keyint,
//         )
//         let mut fullness = 7200
//         for size in probe.au_sizes {
//           assert_true(size * 8 <= fullness)
//           fullness = fullness - size * 8 + 2560
//           assert_true(fullness <= 8000)
//         }
//         assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
//         x264_cross_decode(stream, 8, bps)
//         let mut offset = 0
//         for i in 0..<8 {
//           if i > 0 && i % keyint == 0 {
//             let tail = stream[offset:].to_owned()
//             let tp = match x264_probe_annexb(tail) {
//               Ok(p) => p
//               Err(e) => fail(e)
//             }
//             assert_eq(tp.warnings, 0)
//             assert_eq(tp.errors, 0)
//             x264_cross_decode(tail, 8 - i, bps)
//           }
//           offset += probe.au_sizes[i]
//         }
//         assert_eq(offset, stream.length())
//       }
//     }
//   }
// }

///|
// test "x264 oracle: periodic B GOPs preserve display order and random access" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(9, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [1, 3, 4] {
//         let config = {
//           ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//           cabac,
//           keyint,
//           bit_depth: depth,
//           aq: true,
//           aq_strength: 3,
//           aud: keyint == 4,
//         }
//         let stream = match
//           @libavcodec.video_encode(frames, codec=@libavcodec.H264, config~) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 9)
//         assert_eq(probe.au_sizes.length(), 9)
//         assert_eq(
//           probe.nal_types.filter(t => t == 5).length(),
//           (9 + keyint - 1) / keyint,
//         )
//         x264_cross_decode(stream, 9, bps)
//         let mut offset = 0
//         for i in 0..<9 {
//           if i > 0 && i % keyint == 0 {
//             let tail = stream[offset:].to_owned()
//             let tp = match x264_probe_annexb(tail) {
//               Ok(p) => p
//               Err(e) => fail(e)
//             }
//             assert_eq(tp.warnings, 0)
//             assert_eq(tp.errors, 0)
//             x264_cross_decode(tail, 9 - i, bps)
//           }
//           offset += probe.au_sizes[i]
//         }
//         assert_eq(offset, stream.length())
//       }
//     }
//   }
// }

///|
// test "x264 oracle: high-depth B intra texture uses extended QP" {
//   let mut intra_mbs = 0
// Moving bordered box and chroma ramps, matching the pure encoder's
// High 10 fixture. Frame 4 used to select an I8 B macroblock that was
// reconstructed with the helper's default 8-bit depth and user QP.
//   for depth in [9, 10] {
//     let scale = 1 << (depth - 8)
//     let frames : Array[(Bytes, Bytes, Bytes)] = []
//     for f in 0..<9 {
//       let planes : Array[Bytes] = []
//       for plane in 0..<3 {
//         let size = if plane == 0 { 32 } else { 16 }
//         let data : Array[Byte] = []
//         for row in 0..<size {
//           for col in 0..<size {
//             let value = if plane == 0 {
//               let bx = f * 4 % 16
//               let by = f * 3 % 16
//               let inside = col >= bx &&
//                 col < bx + 16 &&
//                 row >= by &&
//                 row < by + 16
//               if inside &&
//                 (col == bx || col == bx + 15 || row == by || row == by + 15) {
//                 40
//               } else if inside {
//                 220
//               } else {
//                 (col * 2 + row * 3 + f) & 255
//               }
//             } else if plane == 1 {
//               ((col + f) & 63) + 96
//             } else {
//               ((row + f * 2) & 63) + 96
//             }
//             let sample = value * scale
//             data.push((sample & 255).to_byte())
//             data.push((sample >> 8).to_byte())
//           }
//         }
//         planes.push(Bytes::from_array(data[:]))
//       }
//       frames.push((planes[0], planes[1], planes[2]))
//     }
//     for cabac in [false, true] {
//       for keyint in [0, 3] {
//         let stats = @libavcodec.H264EncStats::new()
//         let recon : Array[Bytes] = []
//         let stream = match
//           @libavcodec.video_encode(
//             frames,
//             codec=@libavcodec.H264,
//             config={
//               ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//               cabac,
//               keyint,
//               bit_depth: depth,
//               aq: true,
//               aq_strength: 3,
//             },
//             stats~,
//             recon~,
//           ) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         intra_mbs += stats.bi4_mbs + stats.bi8_mbs
//         let decoded = match
//           @libavcodec.h264_decode_annexb_frames(stream, true) {
//           Ok(d) => d
//           Err(e) => fail(e)
//         }
//         let mut r = 0
//         for i, frame in decoded {
//           if i == 0 || (keyint > 0 && i % keyint == 0) {
//             continue
//           }
//           assert_true(x264_bytes_eq(recon[r], frame.yuvp()))
//           r += 1
//         }
//         assert_eq(recon.length(), r)
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         x264_cross_decode(stream, 9, 2)
//       }
//     }
//   }
//   assert_true(intra_mbs > 0)
// }

///|
// fn x264_md5(data : Bytes) -> String {
//   let digest = FixedArray::make(16, b'\x00')
//   @libavutil.av_md5_sum(digest, data, data.length())
//   let hex = "0123456789abcdef"
//   let out = StringBuilder()
//   for b in digest {
//     out.write_char(hex.get_char(b.to_int() >> 4).unwrap())
//     out.write_char(hex.get_char(b.to_int() & 15).unwrap())
//   }
//   out.to_string()
// }

///|
// test "x264 oracle: legacy six-frame B snapshots have independent pixels" {
//   let frames : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<6 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let bx = f * 6 % 80
//     let by = f * 4 % 48
//     for row in 0..<64 {
//       for col in 0..<96 {
//         let inside = col >= bx && col < bx + 16 && row >= by && row < by + 16
//         let value = if inside &&
//           (col == bx || col == bx + 15 || row == by || row == by + 15) {
//           40
//         } else if inside {
//           220
//         } else {
//           (col * 2 + row * 3 + f) & 255
//         }
//         y.push(value.to_byte())
//       }
//     }
//     for row in 0..<32 {
//       for col in 0..<48 {
//         u.push((((col + f) & 63) + 96).to_byte())
//         v.push((((row + f * 2) & 63) + 96).to_byte())
//       }
//     }
//     frames.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   for aq in [false, true] {
//     let stream = match
//       @libavcodec.h264_encode_frames(
//         frames,
//         width=96,
//         height=64,
//         qp=if aq { 26 } else { 24 },
//         b_slices=true,
//         aq~,
//         aud=aq,
//       ) {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     x264_cross_decode(stream, 6, 1)
//     let c = match x264_decode_annexb(stream) {
//       Ok(d) => d
//       Err(e) => fail(e)
//     }
//     println("B reference aq=\{aq} stream=\{x264_md5(stream)}")
//     for i in 0..<6 {
//       let data = c.frame_y(i) + c.frame_u(i) + c.frame_v(i)
//       println("B reference aq=\{aq} frame=\{i} md5=\{x264_md5(data)}")
//     }
//   }
// }

///|
// test "x264 oracle: periodic B ABR budgets the full reordered sequence" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(7, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [3, 4] {
//         let base = {
//           ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//           cabac,
//           keyint,
//           qp: 20,
//           bit_depth: depth,
//           aq: true,
//           aq_strength: 3,
//           aud: keyint == 4,
//         }
//         fn encode(
//           config : @libavcodec.VideoEncConfig,
//           stats : @libavcodec.H264EncStats,
//         ) -> Bytes raise {
//           match
//             @libavcodec.video_encode(
//               frames,
//               codec=@libavcodec.H264,
//               config~,
//               stats~,
//             ) {
//             Ok(s) => s
//             Err(e) => fail(e)
//           }
//         }
//         let fine = encode(base, @libavcodec.H264EncStats::new())
//         let coarse = encode(
//           { ..base, qp: 51, },
//           @libavcodec.H264EncStats::new(),
//         )
//         assert_true(fine.length() > coarse.length())
//         let target = (fine.length() + coarse.length()) / 2
//         let stats = @libavcodec.H264EncStats::new()
//         let stream = encode({ ..base, target_bytes: target, }, stats)
//         assert_true(stream.length() <= target)
//         assert_eq(stats.frame_qps.length(), 7)
//         assert_eq(stats.b_mbs, 8)
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.n_frames, 7)
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.au_sizes.length(), 7)
//         assert_eq(
//           probe.nal_types.filter(t => t == 5).length(),
//           (7 + keyint - 1) / keyint,
//         )
//         x264_cross_decode(stream, 7, bps)
//         let mut offset = 0
//         for i in 0..<7 {
//           if i > 0 && i % keyint == 0 {
//             let tail = stream[offset:].to_owned()
//             let tp = match x264_probe_annexb(tail) {
//               Ok(p) => p
//               Err(e) => fail(e)
//             }
//             assert_eq(tp.warnings, 0)
//             assert_eq(tp.errors, 0)
//             x264_cross_decode(tail, 7 - i, bps)
//           }
//           offset += probe.au_sizes[i]
//         }
//         assert_eq(offset, stream.length())
//       }
//     }
//   }
// }

///|
// test "x264 oracle: periodic B VBV keeps decoding-order CPB and random access" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(8, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [3, 4] {
//         println("B VBV oracle depth=\{depth} cabac=\{cabac} keyint=\{keyint}")
//         let stats = @libavcodec.H264EncStats::new()
//         let stream = match
//           @libavcodec.video_encode(
//             frames,
//             codec=@libavcodec.H264,
//             config={
//               ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//               cabac,
//               keyint,
//               bit_depth: depth,
//               qp: 26,
//               aq: true,
//               aq_strength: 3,
//               aud: keyint == 4,
//               vbv_maxrate: 64000,
//               vbv_bufsize: 4000,
//               fps: 25,
//             },
//             stats~,
//           ) {
//           Ok(s) => s
//           Err(e) => fail(e)
//         }
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.n_frames, 8)
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.au_sizes.length(), 8)
//         assert_eq(stats.frame_qps.length(), 8)
//         assert_eq(stats.b_mbs, 8)
//         assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
//         let mut fullness = 3600
//         for size in probe.au_sizes {
//           assert_true(size * 8 <= fullness)
//           fullness = fullness - size * 8 + 2560
//           assert_true(fullness <= 4000)
//         }
//         x264_cross_decode(stream, 8, bps)
//         let mut offset = 0
//         for i in 0..<8 {
//           if i > 0 && i % keyint == 0 {
//             let tail = stream[offset:].to_owned()
//             let tp = match x264_probe_annexb(tail) {
//               Ok(p) => p
//               Err(e) => fail(e)
//             }
//             assert_eq(tp.warnings, 0)
//             assert_eq(tp.errors, 0)
//             x264_cross_decode(tail, 8 - i, bps)
//           }
//           offset += probe.au_sizes[i]
//         }
//         assert_eq(offset, stream.length())
//       }
//     }
//   }
// }

///|
// test "x264 oracle: B VBV filler works for ordinary and short GOPs" {
//   let frames = Array::make(
//     6,
//     (Bytes::make(1024, 128), Bytes::make(256, 128), Bytes::make(256, 128)),
//   )
//   for cabac in [false, true] {
//     for keyint in [0, 1, 2, 20] {
//       let stats = @libavcodec.H264EncStats::new()
//       let stream = match
//         @libavcodec.video_encode(
//           frames,
//           codec=@libavcodec.H264,
//           config={
//             ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//             cabac,
//             keyint,
//             aud: true,
//             vbv_maxrate: 128000,
//             vbv_bufsize: 16000,
//             fps: 25,
//           },
//           stats~,
//         ) {
//         Ok(s) => s
//         Err(e) => fail(e)
//       }
//       assert_true(stats.vbv_filler_bytes > 0)
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       let mut fullness = 14400
//       for size in probe.au_sizes {
//         assert_true(size * 8 <= fullness)
//         fullness = fullness - size * 8 + 5120
//         assert_true(fullness <= 16000)
//       }
//       x264_cross_decode(stream, 6, 1)
//     }
//   }
// }

///|
// test "x264 oracle: legacy B rate-control snapshots match FFmpeg" {
// Exact 64x48 checkerboard/box fixture used by h264_enc_brc_test.
//   let frames : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<6 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let bx = f * 4 % 48
//     let by = f * 3 % 32
//     for row in 0..<48 {
//       for col in 0..<64 {
//         let mut value = (col * 2 + row * 3 + f * 5) & 255
//         if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
//           value = (value + 40) & 255
//         }
//         let inside = col >= bx && col < bx + 16 && row >= by && row < by + 16
//         if inside &&
//           (col == bx || col == bx + 15 || row == by || row == by + 15) {
//           value = 40
//         } else if inside {
//           value = 220
//         }
//         y.push(value.to_byte())
//       }
//     }
//     for row in 0..<24 {
//       for col in 0..<32 {
//         u.push((((col + f) & 63) + 96).to_byte())
//         v.push((((row + f * 2) & 63) + 96).to_byte())
//       }
//     }
//     frames.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   for vbv in [false, true] {
//     let stream = match
//       @libavcodec.h264_encode_frames(
//         frames,
//         width=64,
//         height=48,
//         qp=26,
//         b_slices=true,
//         target_bytes=if vbv { 0 } else { 4000 },
//         vbv_maxrate=if vbv { 90000 } else { 0 },
//         vbv_bufsize=if vbv { 18000 } else { 0 },
//         fps=if vbv { 30 } else { 0 },
//         aud=vbv,
//       ) {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     if vbv {
//       let mut fullness = 16200
//       for size in probe.au_sizes {
//         assert_true(size * 8 <= fullness)
//         fullness = fullness - size * 8 + 2999
//         assert_true(fullness <= 18000)
//       }
//     } else {
//       assert_true(stream.length() <= 4000)
//     }
//     x264_cross_decode(stream, 6, 1)
//     let c = match x264_decode_annexb(stream) {
//       Ok(d) => d
//       Err(e) => fail(e)
//     }
//     for i in 0..<6 {
//       println(
//         "BRC reference vbv=\{vbv} frame=\{i} md5=\{x264_md5(c.frame_y(i) + c.frame_u(i) + c.frame_v(i))}",
//       )
//     }
//   }
// }

///|
// test "x264 oracle: online P VBV preserves pixels and independent IDRs" {
//   fn join(aus : Array[Bytes]) -> Bytes {
//     let out : Array[Byte] = []
//     for au in aus {
//       for b in au {
//         out.push(b)
//       }
//     }
//     Bytes::from_array(out[:])
//   }
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(7, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [0, 3] {
//         let stats = @libavcodec.H264EncStats::new()
//         let enc = match
//           @libavcodec.VideoEncoder::open(
//             codec=@libavcodec.H264,
//             config={
//               ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//               cabac,
//               keyint,
//               b_slices: false,
//               multi_ref: 3,
//               bit_depth: depth,
//               qp: 26,
//               aq: true,
//               aq_strength: 3,
//               aud: true,
//               vbv_maxrate: 64000,
//               vbv_bufsize: 4000,
//               fps: 25,
//             },
//             stats~,
//           ) {
//           Ok(e) => e
//           Err(e) => fail(e)
//         }
//         let aus : Array[Bytes] = []
//         let mut fullness = 3600
//         for i, (y, u, v) in frames {
//           match
//             enc.push_frame(y, u, v, force_idr=keyint == 0 && (i == 3 || i == 4)) {
//             Ok(_) => ()
//             Err(e) => fail(e)
//           }
//           let ready = enc.drain()
//           assert_eq(ready.length(), 1)
//           assert_eq(stats.frame_qps.length(), i + 1)
//           let bytes = ready[0]
//           assert_true(bytes.length() * 8 <= fullness)
//           fullness = fullness - bytes.length() * 8 + 2560
//           assert_true(fullness <= 4000)
//           aus.push(bytes)
//         }
//         let tail = match enc.finish() {
//           Ok(t) => t
//           Err(e) => fail(e)
//         }
//         assert_eq(tail.length(), 0)
//         let stream = join(aus)
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 7)
//         assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
//         x264_cross_decode(stream, 7, bps)
//         for start in (if keyint == 0 { [3, 4] } else { [3, 6] }) {
//           let tail = join(aus[start:].to_owned())
//           let tp = match x264_probe_annexb(tail) {
//             Ok(p) => p
//             Err(e) => fail(e)
//           }
//           assert_eq(tp.warnings, 0)
//           assert_eq(tp.errors, 0)
//           x264_cross_decode(tail, 7 - start, bps)
//         }
//       }
//     }
//   }
// }

///|
// test "x264 oracle: online P VBV filler survives reference and frame_num wraps" {
//   for cabac in [false, true] {
//     let stats = @libavcodec.H264EncStats::new()
//     let enc = match
//       @libavcodec.H264StreamEncoder::open(
//         width=32,
//         height=32,
//         cabac~,
//         b_slices=false,
//         multi_ref=16,
//         aud=true,
//         vbv_maxrate=128000,
//         vbv_bufsize=16000,
//         fps=25,
//         stats~,
//       ) {
//       Ok(e) => e
//       Err(e) => fail(e)
//     }
//     let packets : Array[X264Packet] = []
//     let mut fullness = 14400
//     for _ in 0..<35 {
//       match
//         enc.push_frame(
//           Bytes::make(1024, 128),
//           Bytes::make(256, 128),
//           Bytes::make(256, 128),
//         ) {
//         Ok(_) => ()
//         Err(e) => fail(e)
//       }
//       let ready = enc.drain()
//       assert_eq(ready.length(), 1)
//       assert_true(ready[0].length() * 8 <= fullness)
//       fullness = fullness - ready[0].length() * 8 + 5120
//       assert_true(fullness <= 16000)
//       packets.push({ data: ready[0], pts: None, dts: None, keyframe: false, })
//     }
//     assert_true(stats.vbv_filler_bytes > 0)
//     let stream = x264_concat(packets)
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     x264_cross_decode(stream, 35, 1)
//   }
// }

///|
// fn x264_join_online_aus(aus : Array[Bytes]) -> Bytes {
//   let out : Array[Byte] = []
//   for au in aus {
//     for b in au {
//       out.push(b)
//     }
//   }
//   Bytes::from_array(out[:])
// }

///|
// test "x264 oracle: online B VBV preserves reordered pixels and independent GOPs" {
//   for depth in [8, 9, 10] {
//     let bps = if depth == 8 { 1 } else { 2 }
//     let frames = x264_fixture(8, 32, 32, bps).map(f => (f.1, f.2, f.3))
//     for cabac in [false, true] {
//       for keyint in [0, 3, 4] {
//         let stats = @libavcodec.H264EncStats::new()
//         let enc = match
//           @libavcodec.VideoEncoder::open(
//             codec=@libavcodec.H264,
//             config={
//               ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//               cabac,
//               keyint,
//               bit_depth: depth,
//               qp: 26,
//               aq: true,
//               aq_strength: 3,
//               aud: keyint == 4,
//               vbv_maxrate: 64000,
//               vbv_bufsize: 4000,
//               fps: 25,
//             },
//             stats~,
//           ) {
//           Ok(e) => e
//           Err(e) => fail(e)
//         }
//         let aus : Array[Bytes] = []
//         for (y, u, v) in frames {
//           match enc.push_frame(y, u, v) {
//             Ok(_) => ()
//             Err(e) => fail(e)
//           }
//           for au in enc.drain() {
//             aus.push(au)
//           }
//           assert_eq(stats.frame_qps.length(), aus.length())
//         }
//         match enc.finish() {
//           Ok(t) =>
//             for au in t {
//               aus.push(au)
//             }
//           Err(e) => fail(e)
//         }
//         assert_eq(aus.length(), 8)
//         assert_eq(stats.frame_qps.length(), 8)
//         assert_eq(stats.b_mbs, if keyint == 0 { 12 } else { 8 })
//         let stream = x264_join_online_aus(aus)
//         let probe = match x264_probe_annexb(stream) {
//           Ok(p) => p
//           Err(e) => fail(e)
//         }
//         assert_eq(probe.warnings, 0)
//         assert_eq(probe.errors, 0)
//         assert_eq(probe.n_frames, 8)
//         assert_eq(probe.au_sizes.length(), 8)
//         assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
//         let mut fullness = 3600
//         for size in probe.au_sizes {
//           assert_true(size * 8 <= fullness)
//           fullness = fullness - size * 8 + 2560
//           assert_true(fullness <= 4000)
//         }
//         x264_cross_decode(stream, 8, bps)
//         if keyint > 0 {
//           for start in (if keyint == 3 { [3, 6] } else { [4] }) {
//             let tail = x264_join_online_aus(aus[start:].to_owned())
//             let tp = match x264_probe_annexb(tail) {
//               Ok(p) => p
//               Err(e) => fail(e)
//             }
//             assert_eq(tp.warnings, 0)
//             assert_eq(tp.errors, 0)
//             x264_cross_decode(tail, 8 - start, bps)
//           }
//         }
//       }
//     }
//   }
// }

///|
// test "x264 oracle: online B VBV manual IDR and short GOP filler" {
//   let texture = x264_fixture(9, 32, 32, 1).map(f => (f.1, f.2, f.3))
//   let flat = Array::make(
//     9,
//     (Bytes::make(1024, 128), Bytes::make(256, 128), Bytes::make(256, 128)),
//   )
//   for cabac in [false, true] {
//     for keyint in [0, 1, 2] {
//       let frames = if keyint == 0 { texture } else { flat }
//       let stats = @libavcodec.H264EncStats::new()
//       let enc = match
//         @libavcodec.VideoEncoder::open(
//           codec=@libavcodec.H264,
//           config={
//             ..@libavcodec.VideoEncConfig::new(width=32, height=32),
//             cabac,
//             keyint,
//             aud: true,
//             vbv_maxrate: 128000,
//             vbv_bufsize: 16000,
//             fps: 25,
//           },
//           stats~,
//         ) {
//         Ok(e) => e
//         Err(e) => fail(e)
//       }
//       let aus : Array[Bytes] = []
//       for i, (y, u, v) in frames {
//         match
//           enc.push_frame(
//             y,
//             u,
//             v,
//             force_idr=keyint == 0 && [2, 5, 6].contains(i),
//           ) {
//           Ok(_) => ()
//           Err(e) => fail(e)
//         }
//         for au in enc.drain() {
//           aus.push(au)
//         }
//       }
//       match enc.finish() {
//         Ok(t) =>
//           for au in t {
//             aus.push(au)
//           }
//         Err(e) => fail(e)
//       }
//       let stream = x264_join_online_aus(aus)
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 9)
//       assert_eq(stats.frame_qps.length(), 9)
//       assert_true(stats.vbv_filler_bytes > 0)
//       let mut fullness = 14400
//       for size in probe.au_sizes {
//         assert_true(size * 8 <= fullness)
//         fullness = fullness - size * 8 + 5120
//         assert_true(fullness <= 16000)
//       }
//       x264_cross_decode(stream, 9, 1)
//       if keyint == 0 {
//         for start in [2, 5, 6] {
//           let tail = x264_join_online_aus(aus[start:].to_owned())
//           let tp = match x264_probe_annexb(tail) {
//             Ok(p) => p
//             Err(e) => fail(e)
//           }
//           assert_eq(tp.warnings, 0)
//           assert_eq(tp.errors, 0)
//           x264_cross_decode(tail, 9 - start, 1)
//         }
//       }
//     }
//   }
// }

///|
// test "x264 oracle: online B VBV long GOP survives POC and frame_num wraps" {
//   for cabac in [false, true] {
//     let stats = @libavcodec.H264EncStats::new()
//     let enc = match
//       @libavcodec.H264StreamEncoder::open(
//         width=32,
//         height=32,
//         cabac~,
//         aud=true,
//         vbv_maxrate=128000,
//         vbv_bufsize=16000,
//         fps=25,
//         stats~,
//       ) {
//       Ok(e) => e
//       Err(e) => fail(e)
//     }
//     let aus : Array[Bytes] = []
//     for _ in 0..<35 {
//       match
//         enc.push_frame(
//           Bytes::make(1024, 128),
//           Bytes::make(256, 128),
//           Bytes::make(256, 128),
//         ) {
//         Ok(_) => ()
//         Err(e) => fail(e)
//       }
//       for au in enc.drain() {
//         aus.push(au)
//       }
//     }
//     match enc.finish() {
//       Ok(t) =>
//         for au in t {
//           aus.push(au)
//         }
//       Err(e) => fail(e)
//     }
//     assert_eq(aus.length(), 35)
//     assert_eq(stats.frame_qps.length(), 35)
//     assert_eq(stats.b_mbs, 68)
//     assert_true(stats.vbv_filler_bytes > 0)
//     let stream = x264_join_online_aus(aus)
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     let mut fullness = 14400
//     for size in probe.au_sizes {
//       assert_true(size * 8 <= fullness)
//       fullness = fullness - size * 8 + 5120
//       assert_true(fullness <= 16000)
//     }
//     x264_cross_decode(stream, 35, 1)
//   }
// }

///|
// test "x264 supports the canonical formats" {
//   assert_true(x264_supports("libx264", Yuv420p))
// The nine-x264 image pins Ubuntu noble's multi-bit-depth x264 build.
//   assert_true(x264_supports("libx264", Yuv420p10le))
//   assert_false(x264_supports("no-such-encoder", Yuv420p))
// }

///|
// test "x264 encode is deterministic (ultrafast/baseline, no B pictures)" {
//   let frames = x264_fixture(33, 96, 64, 1)
//   let options : Array[(String, String)] = [
//     ("preset", "ultrafast"),
//     ("profile", "baseline"),
//     ("g", "25"),
//   ]
//   let (extra1, pk1) = x264_run(frames, options, Yuv420p, false, 0)
//   let (extra2, pk2) = x264_run(frames, options, Yuv420p, false, 0)
//   assert_true(extra1 is None)
//   assert_true(extra2 is None)
//   if pk1.length() != 33 || pk2.length() != 33 {
//     fail("expected 33 packets, got \{pk1.length()} / \{pk2.length()}")
//   }
//   for i in 0..<pk1.length() {
//     if !x264_bytes_eq(pk1[i].data, pk2[i].data) {
//       fail("packet \{i} differs between two identical runs")
//     }
//     assert_eq(pk1[i].pts, pk2[i].pts)
//     assert_eq(pk1[i].dts, pk2[i].dts)
//     assert_eq(pk1[i].keyframe, pk2[i].keyframe)
//   }
//   assert_true(pk1[0].keyframe)
// }

///|
// test "x264 ultrafast/baseline annexb round-trip matches both decoders" {
//   let frames = x264_fixture(33, 96, 64, 1)
//   let (_, pk) = x264_run(
//     frames,
//     [("preset", "ultrafast"), ("profile", "baseline"), ("g", "25")],
//     Yuv420p,
//     false,
//     0,
//   )
// No global header: packets are complete Annex B access units
// (SPS/PPS in-band at every IDR); plain concatenation is a valid stream.
//   x264_cross_decode(x264_concat(pk), 33, 1)
// }

///|
// test "x264 medium preset round-trip (CABAC, High profile, B pictures)" {
//   let frames = x264_fixture(33, 96, 64, 1)
//   let (_, pk) = x264_run(
//     frames,
//     [("preset", "medium"), ("crf", "23"), ("g", "25"), ("bf", "3")],
//     Yuv420p,
//     false,
//     0,
//   )
//   if pk.length() != 33 {
//     fail("expected 33 packets (one per picture), got \{pk.length()}")
//   }
//   x264_cross_decode(x264_concat(pk), 33, 1)
// }

///|
/// Split an Annex B byte stream into its NAL payloads (start codes dropped,
/// trailing zero bytes of 4-byte codes stripped).
// fn x264_split_annexb(data : Bytes) -> Array[Bytes] {
//   let nals : Array[Bytes] = []
//   let len = data.length()
//   let mut i = 0
//   let mut start = -1
//   while i < len {
//     if i + 2 < len &&
//       data[i] == b'\x00' &&
//       data[i + 1] == b'\x00' &&
//       data[i + 2] == b'\x01' {
//       if start >= 0 {
//         let mut end = i
// trailing zeros before a start code belong to the code
//         while end > start && data[end - 1] == b'\x00' {
//           end = end - 1
//         }
//         nals.push(data[start:end].to_owned())
//       }
//       start = i + 3
//       i = start
//     } else {
//       i = i + 1
//     }
//   }
//   if start >= 0 && start < len {
//     nals.push(data[start:len].to_owned())
//   }
//   nals
// }

///|
/// Build an avcC record from Annex B SPS/PPS NALs - exactly what movenc
/// does when muxing libx264 output (FFmpeg's wrapper hands the muxer an
/// Annex B parameter-set blob as extradata).
// fn x264_build_avcc(nals : Array[Bytes]) -> Bytes raise {
//   let mut sps : Bytes? = None
//   let mut pps : Bytes? = None
//   for nal in nals {
// nal header: forbidden_zero(1) nal_ref_idc(2) nal_unit_type(5)
//     match nal[0].to_int() & 0x1F {
//       7 => sps = Some(nal)
//       8 => pps = Some(nal)
//       _ => ()
//     }
//   }
//   let sps = match sps {
//     Some(v) => v
//     None => fail("no SPS NAL in extradata")
//   }
//   let pps = match pps {
//     Some(v) => v
//     None => fail("no PPS NAL in extradata")
//   }
//   let out : Array[Byte] = [
//     b'\x01', // configurationVersion
//     sps[1], // profile_idc
//     sps[2], // constraint flags + reserved
//     sps[3], // level_idc
//     b'\xFF', // lengthSizeMinusOne = 3 -> 4-byte lengths
//     b'\xE1', // 1 SPS
//     (sps.length() >> 8).to_byte(),
//     sps.length().to_byte(),
//   ]
//   for i in 0..<sps.length() {
//     out.push(sps[i])
//   }
//   out.push(b'\x01') // 1 PPS
//   out.push((pps.length() >> 8).to_byte())
//   out.push(pps.length().to_byte())
//   for i in 0..<pps.length() {
//     out.push(pps[i])
//   }
//   Bytes::from_array(out[:])
// }

///|
/// One Annex B access unit -> one MP4-style sample: every NAL prefixed with
/// its u32be length.
// fn x264_au_to_lenprefixed(au : Bytes) -> Bytes {
//   let out : Array[Byte] = []
//   for nal in x264_split_annexb(au) {
//     let len = nal.length()
//     out.push((len >> 24).to_byte())
//     out.push(((len >> 16) & 0xFF).to_byte())
//     out.push(((len >> 8) & 0xFF).to_byte())
//     out.push((len & 0xFF).to_byte())
//     for i in 0..<len {
//       out.push(nal[i])
//     }
//   }
//   Bytes::from_array(out[:])
// }

///|
// test "x264 global header -> avcC path (movenc-style) round-trip" {
//   let frames = x264_fixture(33, 96, 64, 1)
// global_header: the wrapper moves SPS/PPS out of the bitstream into
// extradata (an Annex B parameter-set blob) and stops repeating headers.
//   let (extra, pk) = x264_run(
//     frames,
//     [("preset", "medium"), ("g", "25")],
//     Yuv420p,
//     true,
//     0,
//   )
//   let annexb_ps = match extra {
//     Some(b) => b
//     None => fail("no extradata with global_header")
//   }
// Build the avcC the way an MP4 muxer would, then decode the pure MP4
// path: avcC extradata + length-prefixed samples.
//   let avcc = x264_build_avcc(x264_split_annexb(annexb_ps))
//   if avcc[0] != b'\x01' {
//     fail("built record is not avcC")
//   }
//   let ps = @libavcodec.new_h264_param_sets()
//   let info = match @libavcodec.ff_h264_decode_extradata(avcc, ps) {
//     Ok(v) => v
//     Err(e) => fail(e)
//   }
//   assert_eq(info.nal_length_size, 4)
//   let sps = match ps.sps_list[0] {
//     Some(v) => v
//     None => fail("no SPS decoded from extradata")
//   }
// medium preset: 8x8 transform + CABAC -> High profile, 4:2:0, 8-bit.
//   assert_eq(sps.profile_idc, 100)
//   assert_eq(sps.chroma_format_idc, 1)
//   assert_eq(sps.bit_depth_luma, 8)
//   let samples : Array[Bytes] = []
//   for p in pk {
//     samples.push(x264_au_to_lenprefixed(p.data))
//   }
//   let frames_avc = match
//     @libavcodec.h264_decode_avc_display_frames(avcc, samples, false) {
//     Ok(v) => v
//     Err(e) => fail(e)
//   }
//   if frames_avc.length() != 33 {
//     fail("avc path: expected 33 frames, got \{frames_avc.length()}")
//   }
// The same bitstream as Annex B (extradata in front of the packets) via
// the C oracle must produce identical pixels.
//   let stream_parts : Array[X264Packet] = [
//     { data: annexb_ps, pts: None, dts: None, keyframe: false, },
//   ]
//   for p in pk {
//     stream_parts.push(p)
//   }
//   let stream = x264_concat(stream_parts)
//   let c = match x264_decode_annexb(stream) {
//     Ok(v) => v
//     Err(e) => fail("C oracle decode of the repacked stream: \{e}")
//   }
//   if c.n_frames != frames_avc.length() {
//     fail(
//       "repacked stream frame count: C \{c.n_frames} vs pure \{frames_avc.length()}",
//     )
//   }
//   for i = 0; i < c.n_frames; i = i + 1 {
//     let packed = frames_avc[i].yuvp()
//     if !x264_bytes_eq(packed[0:96 * 64].to_owned(), c.frame_y(i)) ||
//       !x264_bytes_eq(packed[96 * 64:96 * 64 + 48 * 32].to_owned(), c.frame_u(i)) ||
//       !x264_bytes_eq(packed[96 * 64 + 48 * 32:].to_owned(), c.frame_v(i)) {
//       fail("frame \{i}: avc path and C repack decode differ")
//     }
//   }
// }

///|
// test "x264 10-bit round-trip (High 10)" {
//   let frames = x264_fixture(33, 96, 64, 2)
//   let (_, pk) = x264_run(
//     frames,
//     [("preset", "medium"), ("crf", "20"), ("profile", "high10"), ("g", "25")],
//     Yuv420p10le,
//     false,
//     0,
//   )
// C blob kind 1 = yuv420p10le; every sample is 2 bytes LE.
//   x264_cross_decode(x264_concat(pk), 33, 2)
// }

///|
// test "x264 oracle: pure-MoonBit CABAC encoder stream decodes identically in C" {
// The repository's own CABAC encoder (Main profile I+P): its Annex B
// stream must satisfy the dual-decode standard - FFmpeg's C decoder and
// the pure MoonBit decoder agree pixel-for-pixel.
//   let frames8 = x264_fixture(6, 96, 64, 1)
//   let planes : Array[(Bytes, Bytes, Bytes)] = []
//   for f in frames8 {
//     let (_, y, u, v) = f
//     planes.push((y, u, v))
//   }
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(planes, width=96, height=64, qp=24) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 6, 1)
// }

///|
/// Deterministic scene cut for the pure-MoonBit encoder's Intra16x16-in-P
/// path: a gradient I picture followed by two flat white pictures (the
/// whole frame with `split_col=0`, only the right half otherwise).
// fn x264_cut_fixture(split_col : Int32) -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 96
//   let h = 64
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<3 {
//     let y : Array[Byte] = Array::make(w * h, b'\x00')
//     let u : Array[Byte] = Array::make(w / 2 * (h / 2), b'\x00')
//     let v : Array[Byte] = Array::make(w / 2 * (h / 2), b'\x00')
//     for row = 0; row < h; row = row + 1 {
//       for col = 0; col < w; col = col + 1 {
//         let flat = f > 0 && col >= split_col
//         let s = if flat { 240 } else { (col * 2 + row * 3) & 0xFF }
//         y[row * w + col] = s.to_byte()
//       }
//     }
//     for row = 0; row < h / 2; row = row + 1 {
//       for col = 0; col < w / 2; col = col + 1 {
//         let flat = f > 0 && col * 2 >= split_col
//         u[row * (w / 2) + col] = (if flat {
//           128
//         } else {
//           96 + ((col + row) & 0x3F)
//         }).to_byte()
//         v[row * (w / 2) + col] = (if flat {
//           128
//         } else {
//           96 + ((col * 2 + row) & 0x3F)
//         }).to_byte()
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// The intra16x16-in-P macroblock syntax (mb_type 5..30, DC/AC CAVLC
/// splitting) must satisfy the same dual-decode standard as the x264 and
/// CABAC encoder streams: FFmpeg's C decoder and this repository's decoder
/// agree on every pixel of every frame.
// test "x264 oracle: pure-MoonBit P-slice Intra16x16 stream decodes identically in C" {
//   let frames = x264_cut_fixture(0)
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// A partial cut puts intra and inter macroblocks in the same P slice; the
/// nC mirror across that boundary is the subtle part of §383, so it gets
/// its own C-oracle regression.
// test "x264 oracle: mixed intra/inter P slice decodes identically in C" {
//   let frames = x264_cut_fixture(48)
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Shape validation is the safe wrapper's job (moonbit-c-binding phase 3).
/// Empty and start-code-only buffers must fail before the extern is called,
/// never as an opaque NULL blob from C.
// test "x264 oracle: short streams are rejected by the safe wrapper" {
//   match x264_decode_annexb(b"") {
//     Ok(_) => fail("empty stream unexpectedly decoded")
//     Err(_) => ()
//   }
//   match x264_decode_annexb(b"\x00\x00\x00\x01") {
//     Ok(_) => fail("start-code-only stream unexpectedly decoded")
//     Err(_) => ()
//   }
// }

///|
/// §384: the CABAC P-slice intra16x16 branch (ctx_base 17, intra_slice 0)
/// must satisfy the same dual-decode standard - FFmpeg's C decoder and the
/// pure MoonBit decoder agree on every pixel of every frame.
// test "x264 oracle: CABAC P-slice Intra16x16 stream decodes identically in C" {
//   let frames = x264_cut_fixture(0)
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// The mixed CABAC slice puts intra and inter macroblocks behind the same
/// arithmetic engine, so the C oracle also covers the context transition.
// test "x264 oracle: CABAC mixed intra/inter P slice decodes identically in C" {
//   let frames = x264_cut_fixture(48)
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Textured ramps + a roaming box: content the 8x8 transform's compaction
/// wins on, so the I frame codes genuine I8x8 macroblocks and the P frames
/// carry inter 8x8 residuals.
// fn x264_dct8_fixture() -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 96
//   let h = 64
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<3 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let bx = f * 4 % (w - 16)
//     let by = f * 6 % (h - 16)
//     for row = 0; row < h; row = row + 1 {
//       for col = 0; col < w; col = col + 1 {
//         let mut s = ((col + row) * 2) & 0xFF
//         if (col / 8 + row / 8 + f) % 2 == 1 {
//           s = (s + 24) & 0xFF
//         }
//         if col >= bx && col < bx + 16 && row >= by && row < by + 16 {
//           s = (s + 90) & 0xFF
//         }
//         y.push(s.to_byte())
//       }
//     }
//     for row = 0; row < h / 2; row = row + 1 {
//       for col = 0; col < w / 2; col = col + 1 {
//         u.push((96 + ((col + f) & 0x1F)).to_byte())
//         v.push((160 - ((row + 2 * f) & 0x1F)).to_byte())
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// The High-profile transform_8x8 stream (SPS profile 100, PPS
/// transform_8x8_mode_flag, I-frame I8x8 macroblocks and inter 8x8
/// residuals) must satisfy the dual-decode standard: FFmpeg's C decoder
/// and the pure MoonBit decoder agree pixel-for-pixel.
// test "x264 oracle: pure-MoonBit 8x8DCT CABAC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       dct8x8=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// The CAVLC High-profile 8x8DCT stream (four interleaved sub-lists per
/// quadrant, transform_size_8x8_flag, leader nz sums) through the same
/// dual-decode standard: FFmpeg's C decoder and the pure MoonBit decoder
/// agree pixel-for-pixel.
// test "x264 oracle: pure-MoonBit 8x8DCT CAVLC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       dct8x8=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Scene change onto busy content (smooth gradient, then a fresh
/// checkerboard + gradient + roaming box): inter prediction cannot follow,
/// so the intra candidates compete and the texture favours Intra 8x8 in
/// the P slices.
// fn x264_i8p_fixture() -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 96
//   let h = 64
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<3 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let bx = f * 5 % (w - 16)
//     let by = f * 3 % (h - 16)
//     for row = 0; row < h; row = row + 1 {
//       for col = 0; col < w; col = col + 1 {
//         let s = if f == 0 {
//           (col * 2 + row * 3) & 0xFF
//         } else {
//           let mut t = ((col * 3 - row * 2 + f * 11) & 0x7F) + 40
//           if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
//             t = (t + 48) & 0xFF
//           }
//           let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
//           let border = col == bx ||
//             col == bx + 15 ||
//             row == by ||
//             row == by + 15
//           if inbox && border {
//             40
//           } else if inbox {
//             220
//           } else {
//             t
//           }
//         }
//         y.push(s.to_byte())
//       }
//     }
//     for row = 0; row < h / 2; row = row + 1 {
//       for col = 0; col < w / 2; col = col + 1 {
//         u.push(
//           (if f == 0 {
//             96 + ((col + row) & 0x3F)
//           } else {
//             120 + ((col - row + f) & 0x1F)
//           }).to_byte(),
//         )
//         v.push(
//           (if f == 0 {
//             160 - (row & 0x3F)
//           } else {
//             90 + ((col * 2 + row + f) & 0x3F)
//           }).to_byte(),
//         )
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// Intra 8x8 macroblocks inside P slices (mb_type 5 + transform flag + four
/// `pred8x8l` modes, CAVLC sub-list residuals): FFmpeg's C decoder and the
/// pure MoonBit decoder must agree pixel-for-pixel.
// test "x264 oracle: P-slice Intra 8x8 CAVLC stream decodes identically in C" {
//   let frames = x264_i8p_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//       dct8x8=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// The CABAC twin (ctx 14 -> 17 I_NxN bins, ctx 399 transform flag, cat 5
/// residuals) behind the same dual-decode standard.
// test "x264 oracle: P-slice Intra 8x8 CABAC stream decodes identically in C" {
//   let frames = x264_i8p_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=24,
//       intra_in_p=true,
//       dct8x8=true,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Rate-controlled streams (per-picture QPs in `slice_qp_delta`, dithered
/// across pictures): the C decoder and the pure MoonBit decoder must agree
/// pixel-for-pixel through both entropy coders.
// test "x264 oracle: rate-controlled CAVLC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       target_bytes=1400,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
// test "x264 oracle: rate-controlled CABAC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       target_bytes=1200,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Adaptive-quantisation streams (per-MB `mb_qp_delta` accumulating onto
/// the decoder's running QP, both entropy coders): the C decoder and the
/// pure MoonBit decoder must agree pixel-for-pixel.
// test "x264 oracle: adaptive-quantisation CAVLC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       aq=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.dqp_mbs == 0 {
//     fail("fixture must drive non-zero mb_qp_delta")
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
// test "x264 oracle: adaptive-quantisation CABAC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       aq=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.dqp_mbs == 0 {
//     fail("fixture must drive non-zero mb_qp_delta")
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// Roaming hard-edged box over fine checker texture: with
/// `intra4x4_in_p` the P slices must actually pick Intra_NxN macroblocks
/// (mb_type 5), and those streams must satisfy the dual-decode standard.
// fn x264_i4p_fixture() -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 64
//   let h = 48
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<4 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let bx = f * 4 % (w - 16)
//     let by = f * 3 % (h - 16)
//     for row = 0; row < h; row = row + 1 {
//       for col = 0; col < w; col = col + 1 {
//         let mut s = (col * 2 + row * 3 + f * 5) & 0xFF
//         if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
//           s = (s + 40) & 0xFF
//         }
//         let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
//         let border = col == bx || col == bx + 15 || row == by || row == by + 15
//         if inbox && border {
//           s = 40
//         } else if inbox {
//           s = 220
//         }
//         y.push(s.to_byte())
//       }
//     }
//     for row = 0; row < h / 2; row = row + 1 {
//       for col = 0; col < w / 2; col = col + 1 {
//         u.push((((col + f) & 0x3F) + 96).to_byte())
//         v.push((((row + f * 2) & 0x3F) + 96).to_byte())
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// Per-frame re-sloped diagonal stripes: the gradient direction changes
/// every frame (not a pure translation), so inter prediction cannot
/// follow, while the diagonal 4x4 predictors (DDL/DDR/VL/VR) track the
/// stripes that the 16x16 V/H/DC/Plane modes cannot.
// fn x264_i4_stripe_fixture() -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 64
//   let h = 48
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<4 {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
//     let a = 1 + f % 3
//     let b = 1 + f * 2 % 3
//     for row = 0; row < h; row = row + 1 {
//       for col = 0; col < w; col = col + 1 {
//         y.push(((col * a + row * b + f * 13) & 0xFF).to_byte())
//       }
//     }
//     for row = 0; row < h / 2; row = row + 1 {
//       for col = 0; col < w / 2; col = col + 1 {
//         u.push((96 + ((col + row + f) & 0x1F)).to_byte())
//         v.push((160 - ((row + f) & 0x1F)).to_byte())
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// P-slice Intra4x4 (mb_type 5: sixteen independently predicted 4x4 blocks,
/// CAVLC residual cat 1) with the 8x8 transform tree present: the C decoder
/// and the pure MoonBit decoder must agree pixel-for-pixel.
// test "x264 oracle: P-slice Intra 4x4 CAVLC stream decodes identically in C" {
//   let frames = x264_i4p_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=64,
//       height=48,
//       qp=26,
//       intra_in_p=true,
//       intra4x4_in_p=true,
//       dct8x8=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.i4p_mbs == 0 {
//     fail("fixture must drive P-slice Intra4x4 macroblocks")
//   }
//   x264_cross_decode(stream, 4, 1)
// }

///|
/// Same Intra4x4 P slices through CABAC (ctx 14/17, intra_chroma_pred_mode
/// tree, residual cat 2): dual-decode standard, pixel-for-pixel.
// test "x264 oracle: P-slice Intra 4x4 CABAC stream decodes identically in C" {
//   let frames = x264_i4p_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=64,
//       height=48,
//       qp=26,
//       intra_in_p=true,
//       intra4x4_in_p=true,
//       dct8x8=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.i4p_mbs == 0 {
//     fail("fixture must drive P-slice Intra4x4 macroblocks")
//   }
//   x264_cross_decode(stream, 4, 1)
// }

///|
/// Per-frame re-sloped diagonal stripes: motion cannot follow the changing
/// gradient and the diagonal detail favours Intra4x4 over Intra16x16, so
/// P slices pick I_NxN macroblocks even without transform_8x8_mode_flag
/// (no transform_size_8x8_flag bit at all). C decoder must agree.
// test "x264 oracle: Intra 4x4 P slices without 8x8 transform (CAVLC) decode identically in C" {
//   let frames = x264_i4_stripe_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=64,
//       height=48,
//       qp=26,
//       intra_in_p=true,
//       intra4x4_in_p=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.i4p_mbs == 0 {
//     fail("fixture must drive P-slice Intra4x4 macroblocks")
//   }
//   x264_cross_decode(stream, 4, 1)
// }

///|
// test "x264 oracle: Intra 4x4 P slices without 8x8 transform (CABAC) decode identically in C" {
//   let frames = x264_i4_stripe_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=64,
//       height=48,
//       qp=26,
//       intra_in_p=true,
//       intra4x4_in_p=true,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.i4p_mbs == 0 {
//     fail("fixture must drive P-slice Intra4x4 macroblocks")
//   }
//   x264_cross_decode(stream, 4, 1)
// }

///|
/// CPB-constrained CBR with filler-data NALs (type 12) between slices: the
/// C decoder must skip the filler and agree with the pure MoonBit decoder
/// pixel-for-pixel.
// test "x264 oracle: VBV/CBR CAVLC stream with filler decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       vbv_maxrate=1000000,
//       vbv_bufsize=100000,
//       fps=25,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   if stats.vbv_fills == 0 {
//     fail("fixture must emit filler-data NALs")
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
/// A buffer that cannot hold one picture at the starting QP forces the
/// solver to coarsen pictures; those slice_qp_delta values must decode
/// identically in C through both entropy coders.
// test "x264 oracle: VBV tight-buffer CAVLC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       vbv_maxrate=60000,
//       vbv_bufsize=12000,
//       fps=25,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let mut raised = false
//   for q in stats.frame_qps {
//     if q > 26 {
//       raised = true
//     }
//   }
//   if !raised {
//     fail("tight buffer must raise at least one picture QP")
//   }
//   x264_cross_decode(stream, 3, 1)
// }

///|
// test "x264 oracle: VBV tight-buffer CABAC stream decodes identically in C" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       vbv_maxrate=60000,
//       vbv_bufsize=12000,
//       fps=25,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let mut raised = false
//   for q in stats.frame_qps {
//     if q > 26 {
//       raised = true
//     }
//   }
//   if !raised {
//     fail("tight buffer must raise at least one picture QP")
//   }
//   x264_cross_decode(stream, 3, 1)
// }

// ---------------------------------------------------------------------------
// C-side Annex B probe: NAL inventory, parser AUs and decode diagnostics
// ---------------------------------------------------------------------------

///|
/// Independent MoonBit-side NAL walk (4-byte start codes only, which is
/// what this repository's encoder emits). Used to cross-check the C stub's
/// own raw start-code inventory.
// fn x264_probe_nal_walk(stream : Bytes) -> Array[Int32] {
//   let out : Array[Int32] = []
//   let mut i = 0
//   while i + 4 < stream.length() {
//     if stream[i].to_int() == 0 &&
//       stream[i + 1].to_int() == 0 &&
//       stream[i + 2].to_int() == 0 &&
//       stream[i + 3].to_int() == 1 {
//       out.push(stream[i + 4].to_int() & 0x1F)
//       i = i + 5
//     } else {
//       i = i + 1
//     }
//   }
//   out
// }

///|
// fn x264_probe_count(types : Array[Int32], needle : Int32) -> Int32 {
//   let mut n = 0
//   for t in types {
//     if t == needle {
//       n = n + 1
//     }
//   }
//   n
// }

///|
// fn x264_probe_types_eq(a : Array[Int32], b : Array[Int32]) -> Bool {
//   if a.length() != b.length() {
//     return false
//   }
//   for i = 0; i < a.length(); i = i + 1 {
//     if a[i] != b[i] {
//       return false
//     }
//   }
//   true
// }

///|
/// A CBR stream adds SPS VUI/HRD, buffering-period and picture-timing SEIs,
/// and filler-data NALs. The C stub's independent NAL inventory, FFmpeg's
/// AU splitter and the real decoder must all agree with the pure MoonBit
/// encoder's own layout, with no WARNING/ERROR diagnostics.
// test "x264 oracle: VBV CBR NAL layout agrees in C and decodes warning-free" {
//   let frames = x264_dct8_fixture()
//   let stats = @libavcodec.H264EncStats::new()
//   let stream = match
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       vbv_maxrate=1000000,
//       vbv_bufsize=100000,
//       fps=25,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let probe = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   if probe.n_frames != 3 {
//     fail("C decoder produced \{probe.n_frames} frames, expected 3")
//   }
//   if probe.warnings != 0 || probe.errors != 0 {
//     fail(
//       "VBV CBR stream raised C diagnostics: warnings=\{probe.warnings} errors=\{probe.errors}",
//     )
//   }
//   if probe.au_sizes.length() != 3 {
//     fail("C parser split \{probe.au_sizes.length()} AUs, expected 3")
//   }
//   let walk = x264_probe_nal_walk(stream)
//   if !x264_probe_types_eq(probe.nal_types, walk) {
//     fail("C NAL inventory \{Repr(probe.nal_types)} != MoonBit \{Repr(walk)}")
//   }
//   let fillers = x264_probe_count(probe.nal_types, 12)
//   if fillers == 0 {
//     fail("CBR fixture must emit filler-data NALs")
//   }
//   if fillers != stats.vbv_fills {
//     fail("C saw \{fillers} filler NALs, encoder reported \{stats.vbv_fills}")
//   }
// One buffering-period SEI plus one picture-timing SEI per picture.
//   let sei = x264_probe_count(probe.nal_types, 6)
//   if sei != 4 {
//     fail("expected 4 SEI NALs for 3 pictures, C saw \{sei}")
//   }
//   if x264_probe_count(probe.nal_types, 7) != 1 ||
//     x264_probe_count(probe.nal_types, 8) != 1 {
//     fail("expected exactly one SPS and one PPS")
//   }
//   if x264_probe_count(probe.nal_types, 5) + x264_probe_count(probe.nal_types, 1) !=
//     3 {
//     fail("expected three VCL NALs")
//   }
// }

///|
/// The opt-in contract is visible from C as well: a flat stream has no SEI
/// or filler, while a tight-buffer CABAC stream (adaptive per-picture QPs,
/// HRD VUI, SEI) still decodes without diagnostics.
// test "x264 oracle: probe separates flat and VBV CABAC streams" {
//   let frames = x264_dct8_fixture()
//   let flat = match
//     @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=26) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let fp = match x264_probe_annexb(flat) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   if fp.n_frames != 3 || fp.au_sizes.length() != 3 {
//     fail(
//       "flat stream: C decoded \{fp.n_frames} frames / \{fp.au_sizes.length()} AUs",
//     )
//   }
//   if fp.warnings != 0 || fp.errors != 0 {
//     fail("flat stream raised C diagnostics")
//   }
//   if x264_probe_count(fp.nal_types, 6) != 0 ||
//     x264_probe_count(fp.nal_types, 12) != 0 {
//     fail("flat stream must not carry SEI or filler NALs")
//   }
//   let stats = @libavcodec.H264EncStats::new()
//   let tight = match
//     @libavcodec.h264_encode_frames_cabac(
//       frames,
//       width=96,
//       height=64,
//       qp=26,
//       vbv_maxrate=60000,
//       vbv_bufsize=12000,
//       fps=25,
//       stats~,
//     ) {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
//   let tp = match x264_probe_annexb(tight) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   if tp.n_frames != 3 || tp.au_sizes.length() != 3 {
//     fail(
//       "tight CABAC: C decoded \{tp.n_frames} frames / \{tp.au_sizes.length()} AUs",
//     )
//   }
//   if tp.warnings != 0 || tp.errors != 0 {
//     fail(
//       "tight CABAC stream raised C diagnostics: warnings=\{tp.warnings} errors=\{tp.errors}",
//     )
//   }
//   if x264_probe_count(tp.nal_types, 6) != 4 {
//     fail("tight CABAC: expected 4 SEI NALs")
//   }
//   let mut raised = false
//   for q in stats.frame_qps {
//     if q > 26 {
//       raised = true
//     }
//   }
//   if !raised {
//     fail("tight buffer must raise at least one picture QP")
//   }
// }

///|
/// The same probe also reads a real libx264 CBR/HRD stream: this exercises
/// the C oracle side independently of the pure MoonBit encoder and confirms
/// the entry point is not tailored to our own bitstream layout. The VBV
/// fields travel through `AVCodecContext` (see `rc_max_rate` in the stub),
/// because `av_dict_parse_string` would split a colon-bearing
/// `x264-params` value into separate options.
// test "x264 oracle: probe reads a real libx264 nal-hrd CBR stream" {
//   let frames = x264_fixture(3, 96, 64, 1)
//   let (_, packets) = x264_run(
//     frames,
//     [("preset", "ultrafast"), ("x264-params", "nal-hrd=cbr")],
//     Yuv420p,
//     false,
//     500000,
//     rc_max_rate=500000,
//     rc_buffer_size=100000,
//   )
//   let stream = x264_concat(packets)
//   let probe = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   if probe.n_frames != 3 {
//     fail("libx264 CBR stream: C decoded \{probe.n_frames} frames, expected 3")
//   }
//   if probe.errors != 0 || probe.warnings != 0 {
//     fail(
//       "libx264 CBR stream raised C diagnostics: warnings=\{probe.warnings} errors=\{probe.errors}",
//     )
//   }
//   if probe.au_sizes.length() != 3 {
//     fail("libx264 CBR stream: \{probe.au_sizes.length()} AUs, expected 3")
//   }
// With the VBV fields wired through, x264 emits buffering_period and
// picture_timing SEIs rather than dropping nal-hrd for lack of a buffer.
//   let sei = x264_probe_count(probe.nal_types, 6)
//   if sei < 2 {
//     fail("nal-hrd=cbr must emit HRD SEI NALs, C saw \{sei}")
//   }
// }

///|
// test "x264 oracle: probe rejects shape-invalid streams" {
//   let short = Bytes::from_array([b'\x00', b'\x00', b'\x00', b'\x01'])
//   match x264_probe_annexb(short) {
//     Ok(_) => fail("probe accepted a start-code-only stream")
//     Err(_) => ()
//   }
// }

///|
// test "pure H264 streaming CABAC RD: C parser and dual decoder" {
//   for b_slices in [false, true] {
//     let enc = match
//       @libavcodec.H264StreamEncoder::open(
//         width=96,
//         height=64,
//         cabac=true,
//         cabac_rd=true,
//         b_slices~,
//         aq=true,
//         aud=true,
//       ) {
//       Ok(e) => e
//       Err(e) => fail(e)
//     }
//     let bytes : Array[Byte] = []
//     for frame in x264_dct8_fixture() {
//       match enc.push_frame(frame.0, frame.1, frame.2) {
//         Ok(_) => ()
//         Err(e) => fail(e)
//       }
//       for au in enc.drain() {
//         for b in au {
//           bytes.push(b)
//         }
//       }
//     }
//     let stream = Bytes::from_array(bytes[:])
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.n_frames, 3)
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     x264_cross_decode(stream, 3, 1)
//   }
// }

///|
// test "pure H264 AUD: C parser boundaries and dual decoder" {
//   let frames = x264_dct8_fixture()
//   for cabac in [false, true] {
//     let result = if cabac {
//       @libavcodec.h264_encode_frames_cabac(
//         frames,
//         width=96,
//         height=64,
//         aud=true,
//       )
//     } else {
//       @libavcodec.h264_encode_frames(frames, width=96, height=64, aud=true)
//     }
//     let stream = match result {
//       Ok(s) => s
//       Err(e) => fail(e)
//     }
//     let probe = match x264_probe_annexb(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.n_frames, 3)
//     assert_eq(probe.au_sizes.length(), 3)
//     assert_eq(probe.warnings, 0)
//     assert_eq(probe.errors, 0)
//     assert_eq(x264_probe_count(probe.nal_types, 9), 3)
//     assert_eq(probe.nal_types[0], 9)
//     let mut total = 0
//     for size in probe.au_sizes {
//       total += size
//     }
//     assert_eq(total, stream.length())
//     x264_cross_decode(stream, 3, 1)
//   }
// }

///|
// test "pure H264 AQ strength: maximum deltas decode identically in C" {
//   let frames = x264_dct8_fixture()
//   for cabac in [false, true] {
//     for qp in [0, 26, 51] {
//       let result = if cabac {
//         @libavcodec.h264_encode_frames_cabac(
//           frames,
//           width=96,
//           height=64,
//           aq=true,
//           aq_strength=6,
//           qp~,
//         )
//       } else {
//         @libavcodec.h264_encode_frames(
//           frames,
//           width=96,
//           height=64,
//           aq=true,
//           aq_strength=6,
//           qp~,
//         )
//       }
//       let stream = match result {
//         Ok(s) => s
//         Err(e) => fail(e)
//       }
//       let probe = match x264_probe_annexb(stream) {
//         Ok(p) => p
//         Err(e) => fail(e)
//       }
//       assert_eq(probe.warnings, 0)
//       assert_eq(probe.errors, 0)
//       assert_eq(probe.n_frames, 3)
//       x264_cross_decode(stream, 3, 1)
//     }
//   }
// }

// ---------------------------------------------------------------------------
// Frame-level C arbitration probe (§403): an independent FFmpeg decoder view
// of the pure-MoonBit B-slice / 8x8DCT streams whose syntax bugs were fixed
// in this section. Where `x264_probe_annexb` sees NALs and AUs, this probe
// sees pictures: types, reordering, geometry, diagnostics and pixel digests.
// ---------------------------------------------------------------------------

///|
// fn x264_frame_probe_fixture(count : Int32) -> Array[(Bytes, Bytes, Bytes)] {
//   let w = 96
//   let h = 64
//   let out : Array[(Bytes, Bytes, Bytes)] = []
//   for f in 0..<count {
//     let y : Array[Byte] = []
//     let u : Array[Byte] = []
//     let v : Array[Byte] = []
// A moving diagonal edge gives the intra / inter / 8x8 decisions signal.
//     for row in 0..<h {
//       for col in 0..<w {
//         let edge = (col + row + f * 3) % 24 < 4
//         y.push((if edge { 208 } else { 48 }).to_byte())
//       }
//     }
//     for _row in 0..<(h / 2) {
//       for _col in 0..<(w / 2) {
//         u.push((128).to_byte())
//         v.push((128).to_byte())
//       }
//     }
//     out.push(
//       (
//         Bytes::from_array(y[:]),
//         Bytes::from_array(u[:]),
//         Bytes::from_array(v[:]),
//       ),
//     )
//   }
//   out
// }

///|
/// `all_on` is exactly the combination that used to produce broken B slices
/// (I4x4-in-B x 8x8DCT); `false` is the legacy I/P-only default.
// fn x264_frame_probe_encode(
//   frames : Array[(Bytes, Bytes, Bytes)],
//   qp : Int32,
//   all_on : Bool,
// ) -> Bytes raise {
//   let result = if all_on {
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp~,
//       b_slices=true,
//       b_parts=true,
//       intra_in_b=true,
//       intra4x4_in_b=true,
//       dct8x8=true,
//     )
//   } else {
// §403 turned b_slices on by default; the "legacy" leg must pin it
// off explicitly to produce an I/P-only stream.
//     @libavcodec.h264_encode_frames(
//       frames,
//       width=96,
//       height=64,
//       qp~,
//       b_slices=false,
//     )
//   }
//   match result {
//     Ok(s) => s
//     Err(e) => fail(e)
//   }
// }

///|
/// Bad input is rejected on the MoonBit side before it can reach the C
/// decoder (skill Phase 3: validate shapes at the safe boundary).
// test "x264 oracle: frame probe rejects short and shape-invalid streams" {
//   let short : Array[Byte] = [0, 0, 0]
//   match x264_probe_frames(Bytes::from_array(short[:])) {
//     Ok(_) => fail("frame probe accepted a 3-byte stream")
//     Err(_) => ()
//   }
// A start-code-only blob reaches C; it may fail outright or produce no
// pictures, but it must never be reported as a decoded frame sequence.
//   let junk : Array[Byte] = [0, 0, 0, 1, 0x67, 0x42, 0, 0, 1]
//   match x264_probe_frames(Bytes::from_array(junk[:])) {
//     Ok(p) => assert_eq(p.frames.length(), 0)
//     Err(_) => ()
//   }
// }

///|
/// The real FFmpeg decoder must consume the all-on B stream with zero
/// diagnostics and see the reordered GOP as pictures, not just NALs.
// test "x264 oracle: frame probe arbitrates an all-on B-slice stream" {
//   let frames = x264_frame_probe_fixture(5)
//   let stream = x264_frame_probe_encode(frames, 24, true)
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.n_frames, 5)
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.width, 96)
//   assert_eq(probe.height, 64)
//   assert_eq(probe.frames.length(), 5)
// FFmpeg outputs pictures in display order: an I key frame first, then
// at least one B picture from the reordered GOP.
//   assert_eq(probe.frames[0].pict_type, 1)
//   assert_eq(probe.frames[0].key_frame, 1)
//   let mut n_b = 0
//   for info in probe.frames {
//     if info.pict_type == 3 {
//       n_b = n_b + 1
//     }
//   }
//   if n_b == 0 {
//     fail("C decoder saw no B pictures in a b_slices stream")
//   }
// The pure MoonBit decoder must agree on the picture count.
//   let decoded = match @libavcodec.h264_decode_annexb_frames(stream, true) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.frames.length(), decoded.length())
// }

///|
/// The digest is a stable function of the decoded pixels, so it can be used
/// to compare configurations without shipping raw YUV across the boundary.
// test "x264 oracle: frame digests are stable and content-sensitive" {
//   let frames = x264_frame_probe_fixture(5)
//   let a = x264_frame_probe_encode(frames, 24, true)
//   let b = x264_frame_probe_encode(frames, 30, true)
//   let pa = match x264_probe_frames(a) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   let pa_again = match x264_probe_frames(a) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   let pb = match x264_probe_frames(b) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(pa.frames.length(), pa_again.frames.length())
//   let mut differs = false
//   for i in 0..<pa.frames.length() {
//     assert_eq(pa.frames[i].digest_lo, pa_again.frames[i].digest_lo)
//     assert_eq(pa.frames[i].digest_hi, pa_again.frames[i].digest_hi)
//     if pa.frames[i].digest_lo != pb.frames[i].digest_lo ||
//       pa.frames[i].digest_hi != pb.frames[i].digest_hi {
//       differs = true
//     }
//   }
//   if !differs {
//     fail("QP 24 and QP 30 produced identical C decode digests")
//   }
// }

///|
/// A legacy I/P-only stream has no B pictures; the same frames with the
/// B-line enabled do. This pins the probe's ability to observe reordering.
// test "x264 oracle: frame probe separates I/P-only from B-reordered streams" {
//   let frames = x264_frame_probe_fixture(5)
//   let plain = x264_frame_probe_encode(frames, 24, false)
//   let with_b = x264_frame_probe_encode(frames, 24, true)
//   let pp = match x264_probe_frames(plain) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   let bp = match x264_probe_frames(with_b) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(pp.frames.length(), 5)
//   assert_eq(bp.frames.length(), 5)
//   assert_eq(pp.warnings, 0)
//   assert_eq(pp.errors, 0)
//   for info in pp.frames {
//     if info.pict_type == 3 {
//       fail("legacy I/P-only stream reported a B picture")
//     }
//   }
//   let mut n_b = 0
//   for info in bp.frames {
//     if info.pict_type == 3 {
//       n_b = n_b + 1
//     }
//   }
//   if n_b == 0 {
//     fail("B-line stream reported no B pictures")
//   }
// }
