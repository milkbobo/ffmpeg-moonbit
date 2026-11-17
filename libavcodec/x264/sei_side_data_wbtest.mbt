// §424b binding slice: libx264.c's per-frame SEI side-data path.
// `a53` attaches raw closed-caption blocks (wrapped upstream into a
// registered ITU-T T.35 GA94 SEI by ff_alloc_a53_sei, option a53cc
// default-on) and `sei_unregistered` passes one UUID+data payload through
// (option udu_sei, default-off, enabled by the binding on demand). The
// round-trip is arbitrated with this repository's pure H.264 decoder
// (H264FrameSideData::A53Cc / SeiUnregistered) and the NAL probe (SEI
// type 6 present in the annexb stream).

///|
/// Pull every A53Cc payload out of the decoded frames' side data.
// fn x264_sei_find_a53(frames : Array[@libavcodec.H264Frame]) -> Array[Bytes] {
//   let out : Array[Bytes] = []
//   for f in frames {
//     for sd in f.side_data {
//       match sd {
//         A53Cc(b) => out.push(b)
//         _ => ()
//       }
//     }
//   }
//   out
// }

///|
/// Pull every SeiUnregistered payload out of the decoded frames' side data.
// fn x264_sei_find_unreg(frames : Array[@libavcodec.H264Frame]) -> Array[Bytes] {
//   let out : Array[Bytes] = []
//   for f in frames {
//     for sd in f.side_data {
//       match sd {
//         SeiUnregistered(b) => out.push(b)
//         _ => ()
//       }
//     }
//   }
//   out
// }

///|
/// x264's own version SEI fingerprint ("x264" after the 16-byte UUID).
// fn x264_sei_is_version(p : Bytes) -> Bool {
//   if p.length() < 20 {
//     return false
//   }
//   for i in 0..<=(p.length() - 4) {
//     if p[i] == b'x' && p[i + 1] == b'2' && p[i + 2] == b'6' && p[i + 3] == b'4' {
//       return true
//     }
//   }
//   false
// }

///|
// test "x264 sei: A53 captions round trip through the GA94 SEI" {
//   let frames = ptf_fixture(4, 32, 16)
//   let enc = X264Encoder::open(width=32, height=16, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0"),
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
// Two caption blocks on pictures 0 and 2, none on 1 and 3.
//   let cc_a = b"\x94\x02\x00\x94\xfe\x02"
//   let cc_b = b"\x00\x01\x02\x03\x04\x05"
//   for i, (pts, y, u, v) in frames {
//     let cc = if i == 0 { cc_a } else if i == 2 { cc_b } else { b"" }
//     while !enc.send_frame(pts~, y~, u~, v~, a53=cc) {
//       pull()
//     }
//     pull()
//   }
//   for p in enc.flush() {
//     packets.push(p)
//   }
//   enc.close()
//   assert_eq(packets.length(), 4)
//   let stream = x264_concat(packets)
// The SEI NAL (type 6) appears on the two captioned pictures - plus
// possibly x264's own version SEI (libx264.c maps nothing onto
// AV_CODEC_FLAG_BITEXACT, so the core's unregistered "x264 - core ..."
// payload is always emitted on the first AU).
//   let nal = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(nal.errors, 0)
//   assert_eq(nal.warnings, 0)
//   assert_true(nal.nal_types.filter(t => t == 6).length() >= 2)
// The pure decoder unwraps the GA94 container back to the exact blocks.
//   let decoded = match
//     @libavcodec.h264_decode_annexb_display_frames(stream, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   assert_eq(decoded.length(), 4)
//   let got = x264_sei_find_a53(decoded)
//   assert_eq(got.length(), 2)
//   assert_eq(got[0], cc_a)
//   assert_eq(got[1], cc_b)
// No caption bytes leaked into the unregistered channel; anything there
// is x264's version payload.
//   for p in x264_sei_find_unreg(decoded) {
//     assert_true(x264_sei_is_version(p), msg="unexpected unreg payload")
//   }
// }

///|
// test "x264 sei: unregistered UUID payload passes through verbatim" {
//   let frames = ptf_fixture(3, 32, 16)
//   let enc = X264Encoder::open(width=32, height=16, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0"),
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
// 16-byte UUID + ASCII payload; a conforming decoder hands the whole
// payload (UUID included) back as SeiUnregistered side data.
//   let payload = b"0123456789abcdef" + b"moonbit-sei-roundtrip"
//   for i, (pts, y, u, v) in frames {
//     let sei = if i == 1 { payload } else { b"" }
//     while !enc.send_frame(pts~, y~, u~, v~, sei_unregistered=sei) {
//       pull()
//     }
//     pull()
//   }
//   for p in enc.flush() {
//     packets.push(p)
//   }
//   enc.close()
//   assert_eq(packets.length(), 3)
//   let stream = x264_concat(packets)
//   let nal = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(nal.errors, 0)
//   assert_eq(nal.warnings, 0)
//   assert_true(nal.nal_types.filter(t => t == 6).length() >= 1)
//   let decoded = match
//     @libavcodec.h264_decode_annexb_display_frames(stream, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   assert_eq(decoded.length(), 3)
//   let got = x264_sei_find_unreg(decoded)
// Exactly one copy of OUR payload; the only other allowed unregistered
// payload is x264's version SEI on the first AU (unsuppressed: see the
// A53 test above).
//   assert_eq(got.filter(p => p == payload).length(), 1)
//   for p in got {
//     if p != payload {
//       assert_true(x264_sei_is_version(p), msg="unexpected unreg payload")
//     }
//   }
// No A53 container was synthesized along the way.
//   assert_eq(x264_sei_find_a53(decoded).length(), 0)
// }

///|
// test "x264 sei: A53 payload shape is validated at the safe boundary" {
//   let enc = X264Encoder::open(width=32, height=16, global_header=false, options=[
//     ("preset", "ultrafast"),
//   ])
//   let y = Bytes::makei(32 * 16, i => ((i * 7) & 0xFF).to_byte())
//   let cw = 16
//   let ch = 8
//   let u = Bytes::makei(cw * ch, i => (96 + i % 32).to_byte())
//   let v = Bytes::makei(cw * ch, i => (160 - i % 32).to_byte())
//   try enc.send_frame(pts=0L, y~, u~, v~, a53=b"\x00\x01") catch {
//     BadSideData(_) => ()
//     _ => fail("non-multiple-of-3 A53 payload accepted")
//   } noraise {
//     _ => fail("non-multiple-of-3 A53 payload accepted")
//   }
//   try
//     enc.send_frame(pts=0L, y~, u~, v~, a53=Bytes::makei(66, i => i.to_byte()))
//   catch {
//     BadSideData(_) => ()
//     _ => fail("oversized A53 payload accepted")
//   } noraise {
//     _ => fail("oversized A53 payload accepted")
//   }
//   enc.close()
// }
