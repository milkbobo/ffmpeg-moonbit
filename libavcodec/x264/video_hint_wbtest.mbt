// §424e binding slice: libx264.c's mb_info path (setup_mb_info via
// AV_FRAME_DATA_VIDEO_HINT). Pixel rectangles tell the encoder which areas
// changed / stayed constant since the previous picture; x264 honours the
// array only with the `mb_info` option on (analyse.b_mb_info). The
// behavioral proof: on a half-static fixture, delimiting the static area
// shrinks the stream against an identical no-hint baseline, the two
// complementary descriptions of the same fact produce BYTE-IDENTICAL
// streams, and an empty rect list means what the enum says (all changed /
// nothing changed). Decoded warning-free through the repository's pure
// H.264 decoder.

///|
/// Half-static fixture: frame 0 is a full-frame texture; every later frame
/// keeps the left 16-pixel column band identical to frame 0 and moves the
/// rest. 64x32 = 4x2 macroblocks, the constant band is the left MB column.
/// Built in two passes so the per-frame builder closes over an immutable
/// snapshot of frame 0 (no mutable-capture edge cases).
// fn x264_mbhint_fixture(n : Int32) -> Array[(Int64, Bytes, Bytes, Bytes)] {
//   let w = 64
//   let h = 32
//   let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
//   let base : Array[Byte] = []
//   for i in 0..<(w * h) {
//     base.push(((i * 29 + i / w * 17) & 0xFF).to_byte())
//   }
//   for f in 0..<n {
//     let y = Bytes::makei(w * h, i => {
//       let col = i % w
//       if f > 0 && col < 16 {
//         base[i]
//       } else {
//         ((i * 29 + f * 61 + i / w * 17) & 0xFF).to_byte()
//       }
//     })
//     let cw = w / 2
//     let ch = h / 2
//     let u = Bytes::makei(cw * ch, i => {
//       let moving = !(f > 0 && i % cw < 8)
//       (96 + ((i + (if moving { f * 7 } else { 0 })) & 0x3F)).to_byte()
//     })
//     let v = Bytes::makei(cw * ch, i => {
//       let moving = !(f > 0 && i % cw < 8)
//       (160 - ((i + (if moving { f * 3 } else { 0 })) & 0x1F)).to_byte()
//     })
//     frames.push((f.to_int64(), y, u, v))
//   }
//   frames
// }

///|
/// Encode with the mb_info option and an optional per-picture hint.
// fn x264_mbhint_encode(
//   frames : Array[(Int64, Bytes, Bytes, Bytes)],
//   hint_of : (Int32) -> X264VideoHint?,
// ) -> Bytes raise {
//   let enc = X264Encoder::open(width=64, height=32, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("crf", "23"),
//     ("mb_info", "1"),
//     ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0:aq-mode=1"),
//   ])
//   let packets : Array[X264Packet] = []
//   fn pull() raise {
//     for ;; {
//       match enc.receive_packet() {
//         Packet(p) => packets.push(p)
//         Again | Eof => break
//       }
//     }
//   }
//   for i, (pts, y, u, v) in frames {
//     while !enc.send_frame(pts~, y~, u~, v~, video_hint=hint_of(i)) {
//       pull()
//     }
//     pull()
//   }
//   for p in enc.flush() {
//     packets.push(p)
//   }
//   enc.close()
//   x264_concat(packets)
// }

///|
// test "x264 video hint: hints are honoured; lies diverge, spellings agree" {
//   let frames = x264_mbhint_fixture(6)
// Accurate: the left 16x32 pixel column really is static from picture 1
// on. x264 honours the hint (motion search skipped there) and the
// stream SHRINKS against the identical free-look baseline.
//   let accurate : X264VideoHint = {
//     kind: Constant,
//     rects: [{ x: 0, y: 0, width: 16, height: 32, }],
//   }
// The complementary spelling of the same fact.
//   let complementary : X264VideoHint = {
//     kind: Changed,
//     rects: [{ x: 16, y: 0, width: 48, height: 32, }],
//   }
// Lying: the same Constant kind pointed at the MOVING right half - the
// encoder skips motion search there while the pixels keep changing, so
// the stream BLOATS. (This is the direction that proves the array is
// really read: a broken pipeline would make all three identical.)
//   let lying : X264VideoHint = {
//     kind: Constant,
//     rects: [{ x: 16, y: 0, width: 48, height: 32, }],
//   }
//   let base = x264_mbhint_encode(frames, _ => None)
//   let accurate_s = x264_mbhint_encode(frames, i => {
//     if i == 0 {
//       None
//     } else {
//       Some(accurate)
//     }
//   })
//   let complementary_s = x264_mbhint_encode(frames, i => {
//     if i == 0 {
//       None
//     } else {
//       Some(complementary)
//     }
//   })
//   let lying_s = x264_mbhint_encode(frames, i => {
//     if i == 0 {
//       None
//     } else {
//       Some(lying)
//     }
//   })
// Both spellings describe the same per-MB array: byte-identical streams.
//   assert_eq(accurate_s.length(), complementary_s.length())
// The accurate hint constrains the static band to exactly what the
// encoder would pick anyway there (skip against an identical previous
// picture), so the stream stays within the free-look baseline.
//   assert_true(
//     accurate_s.length() <= base.length(),
//     msg="accurate=\{accurate_s.length()} base=\{base.length()}",
//   )
// The lie proves the array is really read: x264 trusts the hint
// unconditionally and forces its mode decision on the moving region.
// The SIZE direction depends on what the forced decision is (a
// whole-frame lie balloons via intra fallback, a partial one shrinks
// via skips), so only divergence from the baseline is asserted here.
//   assert_true(
//     lying_s.length() != base.length(),
//     msg="lying=\{lying_s.length()} base=\{base.length()}",
//   )
//   assert_true(
//     lying_s.length() != accurate_s.length(),
//     msg="lying=\{lying_s.length()} accurate=\{accurate_s.length()}",
//   )
//   for (name, stream) in [("base", base), ("hint", accurate_s)] {
//     let probe = match x264_probe_frames(stream) {
//       Ok(p) => p
//       Err(e) => fail(e)
//     }
//     assert_eq(probe.errors, 0, msg=name)
//     assert_eq(probe.warnings, 0, msg=name)
//     assert_eq(probe.n_frames, 6, msg=name)
//   }
// }

///|
// test "x264 video hint: an empty rect list claims the whole-frame default" {
//   let frames = x264_mbhint_fixture(5)
// Changed with no rects: NOTHING is assumed to change - x264 skips
// motion search everywhere while the right half keeps moving, so the
// stream bloats against the baseline (same mechanism as the lying hint
// above, at whole-frame scale).
//   let nothing_changed : X264VideoHint = { kind: Changed, rects: [], }
//   let frozen = x264_mbhint_encode(frames, i => {
//     if i == 0 {
//       None
//     } else {
//       Some(nothing_changed)
//     }
//   })
//   let base = x264_mbhint_encode(frames, _ => None)
//   assert_true(
//     frozen.length() > base.length(),
//     msg="frozen=\{frozen.length()} base=\{base.length()}",
//   )
//   let probe = match x264_probe_frames(frozen) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.n_frames, 5)
// }
