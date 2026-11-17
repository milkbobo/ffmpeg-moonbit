///|
// fn lifecycle_backlog() -> (X264Encoder, Array[(Int64, Bytes, Bytes, Bytes)]) raise {
//   let enc = X264Encoder::open(width=96, height=64, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("tune", "zerolatency"),
//     ("bf", "0"),
//   ])
//   let accepted : Array[(Int64, Bytes, Bytes, Bytes)] = []
//   for frame in x264_fixture(12, 96, 64, 1) {
//     let (pts, y, u, v) = frame
//     if !enc.send_frame(pts~, y~, u~, v~) {
//       return (enc, accepted)
//     }
//     accepted.push(frame)
//   }
//   enc.close()
//   fail("fixture did not reach send backpressure")
// }

///|
// test "x264 lifecycle: EOF backpressure is reported" {
//   let (enc, _) = lifecycle_backlog()
//   try enc.send_eof() catch {
//     SendFailed(1) => ()
//     _ => fail("unexpected EOF error")
//   } noraise {
//     _ => {
//       enc.close()
//       fail("EOF reported accepted despite pending frame")
//     }
//   }
//   enc.close()
// }

///|
// test "x264 lifecycle: flush retries EOF without losing buffered packets" {
//   let (enc, frames) = lifecycle_backlog()
//   let packets = enc.flush()
//   assert_eq(packets.length(), frames.length())
//   let reference = X264Encoder::open(width=96, height=64, global_header=false, options=[
//     ("preset", "ultrafast"),
//     ("tune", "zerolatency"),
//     ("bf", "0"),
//   ])
//   let expected = reference.encode_all(frames)
//   reference.close()
//   for i in 0..<packets.length() {
//     assert_eq(packets[i].pts, expected[i].pts)
//     assert_true(packets[i].data == expected[i].data)
//   }
//   assert_eq(enc.flush().length(), 0)
//   enc.send_eof()
//   assert_true(enc.receive_packet() is Eof)
//   x264_cross_decode(x264_concat(packets), frames.length(), 1)
//   enc.close()
//   enc.close()
// }

///|
// test "x264 lifecycle: empty flush is repeatable" {
//   let enc = X264Encoder::open(width=32, height=16)
//   assert_eq(enc.flush().length(), 0)
//   assert_eq(enc.flush().length(), 0)
//   enc.close()
//   try enc.flush() catch {
//     SendFailed(_) => ()
//     _ => fail("unexpected closed encoder error")
//   } noraise {
//     _ => fail("closed encoder accepted flush")
//   }
// }

///|
// test "x264 lifecycle: drained and closed handles reject new work" {
//   let enc = X264Encoder::open(width=32, height=16)
//   let y = Bytes::make(32 * 16, b'\x80')
//   let c = Bytes::make(16 * 8, b'\x80')
//   assert_eq(enc.flush().length(), 0)
//   try enc.send_frame(pts=0L, y~, u=c, v=c) catch {
//     SendFailed(_) => ()
//     _ => fail("unexpected drained encoder error")
//   } noraise {
//     _ => fail("drained encoder accepted frame")
//   }
//   enc.close()
//   try enc.send_frame(pts=0L, y~, u=c, v=c) catch {
//     SendFailed(_) => ()
//     _ => fail("unexpected closed encoder error")
//   } noraise {
//     _ => fail("closed encoder accepted frame")
//   }
//   try enc.receive_packet() catch {
//     ReceiveFailed(_) => ()
//     _ => fail("unexpected closed receive error")
//   } noraise {
//     _ => fail("closed encoder returned packet state")
//   }
//   try enc.extradata() catch {
//     ExtradataUnavailable => ()
//     _ => fail("unexpected closed extradata error")
//   } noraise {
//     _ => fail("closed encoder retained extradata")
//   }
//   enc.close()
// }
