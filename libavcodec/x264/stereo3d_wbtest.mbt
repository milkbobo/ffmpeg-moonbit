// §424d binding slice: libx264.c's reconfig_encoder STEREO3D path.
// `stereo3d` attaches an AVStereo3D side data for a picture; x264 turns it
// into frame packing and emits an H.264 frame-packing-arrangement SEI,
// which this repository's pure decoder exports back as `Stereo3d` frame
// side data. FACTS pinned by the docker gate: x264 writes the FPA SEI on
// IDR pictures only, and a request is captured at the moment the picture
// is actually encoded - with x264's lookahead an IDR sent at PTS n is
// encoded during a LATER send_frame call, so a packing request must stay
// in force until that happens (pin each layout on its own forced IDR).

///|
/// Collect every decoded Stereo3d side-data entry.
// fn x264_stereo_collect(
//   frames : Array[@libavcodec.H264Frame],
// ) -> Array[@libavcodec.H264Stereo3d] {
//   let out : Array[@libavcodec.H264Stereo3d] = []
//   for f in frames {
//     for sd in f.side_data {
//       match sd {
//         Stereo3d(s) => out.push(s)
//         _ => ()
//       }
//     }
//   }
//   out
// }

///|
// test "x264 stereo: frame packing arrangement rides the IDR and round trips" {
//   let frames = ptf_fixture(4, 32, 16)
//   fn encode_with(pick : (Int32) -> X264Stereo3D?) -> Bytes raise {
//     let enc = X264Encoder::open(width=32, height=16, global_header=false, options=[
//       ("preset", "ultrafast"),
//       ("x264-params", "keyint=250:min-keyint=250:scenecut=0:bframes=0"),
//     ])
//     let packets : Array[X264Packet] = []
//     fn pull() raise {
//       for ;; {
//         match enc.receive_packet() {
//           Packet(p) => packets.push(p)
//           Again | Eof => break
//         }
//       }
//     }
//     for i, (pts, y, u, v) in frames {
//       while !enc.send_frame(pts~, y~, u~, v~, stereo3d=pick(i)) {
//         pull()
//       }
//       pull()
//     }
//     for p in enc.flush() {
//       packets.push(p)
//     }
//     enc.close()
//     x264_concat(packets)
//   }
// The IDR at frame 0 carries the packing request; frames 1..3 send no
// new request so the packing stays in force while the IDR is encoded.
//   let stream = encode_with(i => if i == 0 { Some(TopBottom) } else { None })
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.n_frames, 4)
//   let decoded = match
//     @libavcodec.h264_decode_annexb_display_frames(stream, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   let stereo = x264_stereo_collect(decoded)
//   assert_true(stereo.length() >= 1, msg="no frame packing SEI decoded")
//   for s in stereo {
//     assert_eq(
//       s.stereo_type,
//       @libavcodec.av_stereo3d_top_bottom,
//       msg="wrong packing type",
//     )
//   }
// Control leg: without the request no packing SEI is emitted and the
// streams differ (the arrangement changes the bitstream).
//   let plain = encode_with(_ => None)
//   let pdecoded = match
//     @libavcodec.h264_decode_annexb_display_frames(plain, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   assert_eq(x264_stereo_collect(pdecoded).length(), 0)
//   assert_true(stream.length() != plain.length(), msg="packing changed nothing")
// }

///|
// test "x264 stereo: each forced IDR captures the packing in force" {
//   let frames = ptf_fixture(9, 32, 16)
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
// Two IDR pictures, one per layout. The request rides the same
// send_frame as its IDR: libx264 reconfigures BEFORE the picture is
// handed to x264, so the IDR captures that layout regardless of the
// lookahead delay (the earlier IDR is encoded during these send calls
// while its request is still the only one in force).
//   let layouts : Array[(Bool, X264Stereo3D)] = [
//     (true, TopBottom),
//     (false, TopBottom),
//     (false, TopBottom),
//     (false, TopBottom),
//     (true, SideBySide),
//     (false, SideBySide),
//     (false, SideBySide),
//     (false, SideBySide),
//     (false, SideBySide),
//   ]
//   for i, (pts, y, u, v) in frames {
//     let (idr, layout) = layouts[i]
//     while !enc.send_frame(
//             pts~,
//             y~,
//             u~,
//             v~,
//             force_idr=idr,
//             stereo3d=Some(layout),
//           ) {
//       pull()
//     }
//     pull()
//   }
//   for p in enc.flush() {
//     packets.push(p)
//   }
//   enc.close()
//   let stream = x264_concat(packets)
//   let decoded = match
//     @libavcodec.h264_decode_annexb_display_frames(stream, false) {
//     Ok(d) => d
//     Err(e) => fail(e)
//   }
//   let stereo = x264_stereo_collect(decoded)
// Both layouts reached the stream through their own IDRs.
//   assert_true(
//     stereo.any(s => s.stereo_type == @libavcodec.av_stereo3d_top_bottom),
//     msg="top-bottom packing missing",
//   )
//   assert_true(
//     stereo.any(s => s.stereo_type == @libavcodec.av_stereo3d_side_by_side),
//     msg="side-by-side packing missing",
//   )
//   let probe = match x264_probe_frames(stream) {
//     Ok(p) => p
//     Err(e) => fail(e)
//   }
//   assert_eq(probe.errors, 0)
//   assert_eq(probe.warnings, 0)
//   assert_eq(probe.n_frames, 9)
// The keyframe flags belong exactly to the two IDRs.
//   for p in packets {
//     assert_eq(
//       p.keyframe,
//       match p.pts {
//         Some(t) => t == 0L || t == 4L
//         None => false
//       },
//     )
//   }
// }
