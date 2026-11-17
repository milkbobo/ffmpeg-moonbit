// §424 binding slice: libx264.c's per-picture type forcing (X264_frame's
// switch on frame->pict_type) exposed as X264PictType. The IDR leg of the
// old `force_idr` bool stays byte-compatible; the new surface adds the
// non-IDR Keyframe, P and B pins. Arbitrated against the real FFmpeg H.264
// decoder through x264_probe_frames (pict_type / key_frame) and
// x264_probe_annexb (NAL types).

///|
// fn ptf_fixture(
//   n : Int32,
//   width : Int32,
//   height : Int32,
// ) -> Array[(Int64, Bytes, Bytes, Bytes)] {
//   let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
//   for f in 0..<n {
//     let y = Bytes::makei(width * height, i => {
//       ((i * 29 + f * 61 + i / width * 17) & 0xFF).to_byte()
//     })
//     let cw = width / 2
//     let ch = height / 2
//     let u = Bytes::makei(cw * ch, i => (96 + ((i + f * 7) & 0x3F)).to_byte())
//     let v = Bytes::makei(cw * ch, i => (160 - ((i + f * 3) & 0x1F)).to_byte())
//     frames.push((f.to_int64(), y, u, v))
//   }
//   frames
// }

///|
/// Drive one encoder over the fixture with per-picture requests: `pick`
/// maps the display index to the request (`Auto` by default). Returns the
/// concatenated Annex B stream and the packet list.
// fn ptf_encode(
//   params : String,
//   frames : Array[(Int64, Bytes, Bytes, Bytes)],
//   pick : (Int32) -> X264PictType,
// ) -> (Bytes, Array[X264Packet]) raise {
//   let enc = X264Encoder::open(width=32, height=16, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("x264-params", params),
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
//     while !enc.send_frame(pts~, y~, u~, v~, pict_type=pick(i)) {
//       pull()
//     }
//     pull()
//   }
//   for p in enc.flush() {
//     packets.push(p)
//   }
//   enc.close()
//   (x264_concat(packets), packets)
// }

///|
// test "x264 pict type: Idr, Keyframe and P forcing (closed GOP upgrades keyframes)" {
//   let frames = ptf_fixture(9, 32, 16)
//   let params = "keyint=250:min-keyint=250:scenecut=0:bframes=3:b-adapt=0"
//   let pick = (i : Int32) => {
//     if i == 0 || i == 7 {
//       Idr
//     } else if i == 4 {
//       Keyframe
//     } else {
//       P
//     }
//   }
//   let (stream, packets) = ptf_encode(params, frames, pick)
//   assert_eq(packets.length(), 9)
// The packet keyframe flags carry exactly the three I pictures.
//   for p in packets {
//     assert_eq(
//       p.keyframe,
//       match p.pts {
//         Some(t) => t == 0L || t == 4L || t == 7L
//         None => false
//       },
//     )
//   }
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.n_frames, 9)
// I at 0/4/7, P everywhere else, and no B survived the P pins.
//   for i, f in probe.frames {
//     let want = if i == 0 || i == 4 || i == 7 { 1 } else { 2 }
//     assert_eq(f.pict_type, want, msg="frame \{i}")
//     if i == 0 || i == 4 || i == 7 {
//       assert_eq(f.key_frame, 1, msg="frame \{i}")
//     }
//   }
//   assert_false(probe.frames.any(f => f.pict_type == 3))
// Closed-GOP upstream semantics: x264 (open-gop off) upgrades the
// Keyframe request at 4 to a full IDR, so all three I pictures re-emit
// SPS/PPS and use the type-5 slice NAL.
//   let nal = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(nal.nal_types.filter(t => t == 7).length(), 3)
//   assert_eq(nal.nal_types.filter(t => t == 5).length(), 3)
//   assert_eq(nal.errors, 0)
//   assert_eq(nal.warnings, 0)
// Control leg: the same content with Auto everywhere lets b-adapt=0
// place B pictures among 1..8, proving the P pins changed the GOP.
//   let (astream, _) = ptf_encode(params, frames, _ => Auto)
//   let aprobe = match x264_probe_frames(astream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_true(
//     aprobe.frames.any(f => f.pict_type == 3),
//     msg="auto leg placed no B picture",
//   )
// }

///|
// test "x264 pict type: open GOP keeps the Keyframe request non-IDR" {
//   let frames = ptf_fixture(9, 32, 16)
//   let params = "keyint=250:min-keyint=250:scenecut=0:bframes=3:b-adapt=0:open-gop=1"
//   let pick = (i : Int32) => {
//     if i == 0 || i == 7 {
//       Idr
//     } else if i == 4 {
//       Keyframe
//     } else {
//       P
//     }
//   }
//   let (stream, packets) = ptf_encode(params, frames, pick)
//   assert_eq(packets.length(), 9)
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.n_frames, 9)
// I at 0/4/7 and P elsewhere still holds...
//   for i, f in probe.frames {
//     let want = if i == 0 || i == 4 || i == 7 { 1 } else { 2 }
//     assert_eq(f.pict_type, want, msg="frame \{i}")
//   }
//   assert_false(probe.frames.any(f => f.pict_type == 3))
// ...but with open-gop only the two Idr requests produce IDR access
// units: the Keyframe at 4 stays a non-IDR I - no SPS/PPS re-emission
// and no type-5 slice for it.
//   let nal = match x264_probe_annexb(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(nal.nal_types.filter(t => t == 7).length(), 2)
//   assert_eq(nal.nal_types.filter(t => t == 5).length(), 2)
//   assert_eq(nal.errors, 0)
// The forcing did not leak: keyframe flags belong to the IDRs only
// (open-GOP keyframes are not random-access points for the decoder).
//   for p in packets {
//     assert_eq(
//       p.keyframe,
//       match p.pts {
//         Some(t) => t == 0L || t == 7L
//         None => false
//       },
//     )
//   }
// }

///|
// test "x264 pict type: B forcing pins a B on an all-P schedule" {
//   let frames = ptf_fixture(9, 32, 16)
// x264 only codes B pictures when bframes>0 (an explicit B request on a
// bframes=0 schedule is demoted to P), and its lookahead caps B runs at
// bframes - so the honest witness pins frames 1..3 to P first, leaving
// frame 4 a lone forced B between the P3 anchor and whatever auto
// schedule follows.
//   let params = "keyint=250:min-keyint=250:scenecut=0:bframes=3:b-adapt=0"
//   let (stream, packets) = ptf_encode(params, frames, i => {
//     if i == 0 {
//       Idr
//     } else if i >= 1 && i <= 3 {
//       P
//     } else if i == 4 {
//       B
//     } else {
//       Auto
//     }
//   })
//   assert_eq(packets.length(), 9)
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.n_frames, 9)
// The forced B lands at 4 between P anchors; 5..8 keep x264's own
// b-adapt=0 schedule (not asserted).
//   assert_eq(probe.frames[0].pict_type, 1)
//   for i in 1..<=3 {
//     assert_eq(probe.frames[i].pict_type, 2, msg="frame \{i}")
//   }
//   assert_eq(probe.frames[4].pict_type, 3, msg="frame 4 must be a forced B")
// The forcing did not leak: keyframe flags belong to the IDR at 0 only.
//   for p in packets {
//     assert_eq(
//       p.keyframe,
//       match p.pts {
//         Some(t) => t == 0L
//         None => false
//       },
//     )
//   }
//   x264_cross_decode(stream, 9, 1)
// }
