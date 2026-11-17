///|
/// `§427` fixtures: reuse the blocky-gradient deblock fixture (the SAR
/// tests' source) so the IDR stream is representative.
fn h264sei_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  h264dbg_fixture(64, 48, n, 1)
}

///|
/// Whole-stream byte equality (the package has no public helper for it).
fn h264sei_bytes_equal(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
/// One `user_data_unregistered` payload: a 16-byte UUID of `tag` bytes
/// plus a small user-data tail (18 bytes, distinct per `tag`). `extra`
/// appends that many filler bytes to cross the 255-byte SEI size step.
fn h264sei_payload(tag : Byte, extra~ : Int32 = 0) -> Bytes {
  let out : Array[Byte] = []
  for _i = 0; _i < 16; _i = _i + 1 {
    out.push(tag)
  }
  out.push(b'-')
  out.push(b'x')
  for _i = 0; _i < extra; _i = _i + 1 {
    out.push(b'.')
  }
  Bytes::from_array(out[:])
}

///|
/// The frame's A53 caption payload, if any.
fn h264sei_a53(frame : @libavcodec.H264Frame) -> Bytes? {
  for sd in frame.side_data {
    match sd {
      A53Cc(cc) => return Some(cc)
      _ => ()
    }
  }
  None
}

///|
/// The frame's unregistered SEI payload, if any.
fn h264sei_unreg(frame : @libavcodec.H264Frame) -> Bytes? {
  for sd in frame.side_data {
    match sd {
      SeiUnregistered(p) => return Some(p)
      _ => ()
    }
  }
  None
}

///|
/// Decode helper shared by the tests below.
fn h264sei_decode(stream : Bytes) -> Array[@libavcodec.H264Frame] raise {
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
}

///|
/// `§427`: the intra entry wraps A53 caption triples in the GA94
/// container and writes the unregistered payload verbatim; the decoder
/// hands both back on the frame unchanged.
test "h264 enc sei: intra entry round trips both payloads" {
  let frames = h264sei_fixture(1)
  let cc = b"\xFC\x01\x02\xFC\x03\x04"
  let pl = h264sei_payload(b'\x11')
  let (y, u, v) = frames[0]
  let out = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=48,
      qp=26,
      a53=Some(cc),
      sei_unregistered=Some(pl),
    ) {
    Ok(e) => e.annexb
    Err(e) => fail(e)
  }
  let decoded = h264sei_decode(out)
  assert_eq(decoded.length(), 1)
  match h264sei_a53(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc) {
        fail("a53 payload changed in transit")
      }
    None => fail("intra frame carries no A53 side data")
  }
  match h264sei_unreg(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, pl) {
        fail("unregistered payload changed in transit")
      }
    None => fail("intra frame carries no unregistered side data")
  }
}

///|
/// `§427`: the batch entry attaches each display position's side data to
/// its own picture (P line, display order == coding order).
test "h264 enc sei: per-frame side data on the P line" {
  let frames = h264sei_fixture(3)
  let cc0 = b"\xFC\x01\x02\xFC\x03\x04"
  let cc2 = b"\xFD\x05\x06"
  let pl1 = h264sei_payload(b'\x22')
  let plain = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let with_sei = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
      a53=[Some(cc0), None, Some(cc2)],
      sei_unregistered=[None, Some(pl1), None],
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if h264sei_bytes_equal(plain, with_sei) {
    fail("side data left the stream unchanged")
  }
  let decoded = h264sei_decode(with_sei)
  assert_eq(decoded.length(), 3)
  match h264sei_a53(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc0) {
        fail("frame 0 a53 mismatch")
      }
    None => fail("frame 0 carries no A53")
  }
  if h264sei_a53(decoded[1]) is Some(_) {
    fail("frame 1 must not carry A53")
  }
  match h264sei_unreg(decoded[1]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, pl1) {
        fail("frame 1 unregistered mismatch")
      }
    None => fail("frame 1 carries no unregistered SEI")
  }
  match h264sei_a53(decoded[2]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc2) {
        fail("frame 2 a53 mismatch")
      }
    None => fail("frame 2 carries no A53")
  }
}

///|
/// `§427`: with the default B schedule the side data must follow the
/// picture through the reorder (each AU carries its own display
/// position's payloads: IDR, the P at e+1, the B at e and the trailing P).
test "h264 enc sei: B schedule keeps side data with its own picture" {
  let frames = h264sei_fixture(4)
  let cc1 = b"\xFC\x11\x12"
  let pl2 = h264sei_payload(b'\x33')
  let cc3 = b"\xFC\x21\x22\xFD\x23\x24"
  let with_sei = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      a53=[None, Some(cc1), None, Some(cc3)],
      sei_unregistered=[None, None, Some(pl2), Some(h264sei_payload(b'\x44'))],
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let decoded = h264sei_decode(with_sei)
  assert_eq(decoded.length(), 4)
  // The decoder emits coding order (display [0, 2, 1, 3] → decode): the
  // side data must still ride each picture's own AU through the reorder.
  if h264sei_a53(decoded[0]) is Some(_) {
    fail("IDR must not carry A53")
  }
  match h264sei_unreg(decoded[1]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, pl2) {
        fail("P picture (display 2) unregistered mismatch")
      }
    None => fail("P picture (display 2) carries no unregistered SEI")
  }
  match h264sei_a53(decoded[2]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc1) {
        fail("B picture (display 1) lost its captions in the reorder")
      }
    None => fail("B picture (display 1) carries no A53")
  }
  match h264sei_a53(decoded[3]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc3) {
        fail("trailing P a53 mismatch")
      }
    None => fail("trailing P carries no A53")
  }
  match h264sei_unreg(decoded[3]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, h264sei_payload(b'\x44')) {
        fail("trailing P unregistered mismatch")
      }
    None => fail("trailing P carries no unregistered SEI")
  }
}

///|
/// `§427`: the CABAC entry carries the same arrays (IDR header, P loop
/// and the B line's three AU sites).
test "h264 enc sei: CABAC line round trips side data" {
  let frames = h264sei_fixture(3)
  let cc0 = b"\xFC\x31\x32\xFC\x33\x34"
  let pl2 = h264sei_payload(b'\x55')
  let with_sei = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      a53=[Some(cc0), None, None],
      sei_unregistered=[None, None, Some(pl2)],
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let decoded = h264sei_decode(with_sei)
  assert_eq(decoded.length(), 3)
  // Coding order [IDR, P (display 2), B (display 1)].
  match h264sei_a53(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc0) {
        fail("CABAC IDR a53 mismatch")
      }
    None => fail("CABAC IDR carries no A53")
  }
  match h264sei_unreg(decoded[1]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, pl2) {
        fail("CABAC P picture (display 2) unregistered mismatch")
      }
    None => fail("CABAC P picture (display 2) carries no unregistered SEI")
  }
  if h264sei_a53(decoded[2]) is Some(_) {
    fail("CABAC B picture must not carry A53")
  }
}

///|
/// `§427`: payloads above the 254-byte SEI size field ride the 0xFF size
/// steps; the decoder reassembles them byte-exactly.
test "h264 enc sei: payload crossing the 255-byte size step" {
  let frames = h264sei_fixture(1)
  let big = h264sei_payload(b'\x66', extra=320)
  let (y, u, v) = frames[0]
  let out = match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=48,
      qp=26,
      sei_unregistered=Some(big),
    ) {
    Ok(e) => e.annexb
    Err(e) => fail(e)
  }
  let decoded = h264sei_decode(out)
  assert_eq(decoded.length(), 1)
  match h264sei_unreg(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, big) {
        fail("big payload changed in transit")
      }
    None => fail("big payload missing")
  }
}

///|
/// `§427`: the streaming encoder (and its VBV transactional path) attach
/// the side data of the frame it was pushed with — including the pending
/// B picture, whose payloads wait for its future reference.
test "h264 enc sei: stream encoder attaches side data per picture" {
  let frames = h264sei_fixture(3)
  fn run(vbv : Bool, a0 : Bytes?, a1 : Bytes?, s2 : Bytes?) -> Bytes raise {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=64,
        height=48,
        qp=28,
        vbv_maxrate=if vbv { 60000 } else { 0 },
        vbv_bufsize=if vbv { 1400000 } else { 0 },
        fps=if vbv { 25 } else { 0 },
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let side = [a0, a1, None]
    let seis = [None, None, s2]
    for i = 0; i < frames.length(); i = i + 1 {
      let (y, u, v) = frames[i]
      match enc.push_frame(y, u, v, a53=side[i], sei_unregistered=seis[i]) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    }
    let parts = match enc.finish() {
      Ok(t) => t
      Err(e) => fail(e)
    }
    let joined : Array[Byte] = []
    for part in parts {
      for i = 0; i < part.length(); i = i + 1 {
        joined.push(part[i])
      }
    }
    Bytes::from_array(joined[:])
  }
  let cc0 = b"\xFC\x41\x42\xFC\x43\x44"
  let cc1 = b"\xFC\x51\x52"
  let pl2 = h264sei_payload(b'\x77')
  for vbv in [false, true] {
    let stream = run(vbv, Some(cc0), Some(cc1), Some(pl2))
    let decoded = h264sei_decode(stream)
    assert_eq(decoded.length(), 3, msg="vbv=\{vbv}")
    // Coding order [IDR, P (display 2), B (display 1)].
    match h264sei_a53(decoded[0]) {
      Some(got) =>
        if !h264sei_bytes_equal(got, cc0) {
          fail("stream IDR a53 mismatch (vbv=\{vbv})")
        }
      None => fail("stream IDR carries no A53 (vbv=\{vbv})")
    }
    match h264sei_unreg(decoded[1]) {
      Some(got) =>
        if !h264sei_bytes_equal(got, pl2) {
          fail("stream P unregistered mismatch (vbv=\{vbv})")
        }
      None => fail("stream P carries no unregistered SEI (vbv=\{vbv})")
    }
    match h264sei_a53(decoded[2]) {
      Some(got) =>
        if !h264sei_bytes_equal(got, cc1) {
          fail("stream B a53 mismatch (vbv=\{vbv})")
        }
      None => fail("stream B carries no A53 (vbv=\{vbv})")
    }
  }
}

///|
/// `§427`: the `VideoEncoder` facade forwards the side data to the H.264
/// stream encoder.
test "h264 enc sei: facade push_frame forwards side data" {
  let frames = h264sei_fixture(2)
  let cc = b"\xFC\x61\x62\xFC\x63\x64"
  let pl = h264sei_payload(b'\x88')
  let config = {
    ..@libavcodec.VideoEncConfig::new(width=64, height=48),
    qp: 26,
  }
  let enc = match
    @libavcodec.VideoEncoder::open(codec=@libavcodec.VideoCodec::H264, config~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for i = 0; i < frames.length(); i = i + 1 {
    let (y, u, v) = frames[i]
    match
      enc.push_frame(
        y,
        u,
        v,
        a53=if i == 0 { Some(cc) } else { None },
        sei_unregistered=if i == 1 { Some(pl) } else { None },
      ) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let tail = match enc.finish() {
    Ok(t) => t
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in tail {
    for i = 0; i < part.length(); i = i + 1 {
      joined.push(part[i])
    }
  }
  let decoded = h264sei_decode(Bytes::from_array(joined[:]))
  assert_eq(decoded.length(), 2)
  match h264sei_a53(decoded[0]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, cc) {
        fail("facade IDR a53 mismatch")
      }
    None => fail("facade IDR carries no A53")
  }
  match h264sei_unreg(decoded[1]) {
    Some(got) =>
      if !h264sei_bytes_equal(got, pl) {
        fail("facade P unregistered mismatch")
      }
    None => fail("facade P carries no unregistered SEI")
  }
}

///|
/// `§427`: malformed side data is rejected with the exact reason, at both
/// the scalar (intra) and array (batch) surfaces.
test "h264 enc sei: validation rejects malformed side data" {
  let frames = h264sei_fixture(2)
  let (y, u, v) = frames[0]
  fn intra_err(a53 : Bytes?, sei : Bytes?) -> String raise {
    match
      @libavcodec.h264_encode_intra_frame(
        y,
        u,
        v,
        width=64,
        height=48,
        qp=26,
        a53~,
        sei_unregistered=sei,
      ) {
      Ok(_) => fail("intra entry accepted malformed side data")
      Err(e) => e
    }
  }
  let out = intra_err(Some(b"\x01\x02"), None)
  assert_eq(out, "h264 enc: a53 captions must be cc_data triples (got 2 bytes)")
  let big_cc : Array[Byte] = []
  for _i = 0; _i < 66; _i = _i + 1 {
    big_cc.push(b'\xFF')
  }
  let big_cc_b = Bytes::from_array(big_cc[:])
  let out2 = intra_err(Some(big_cc_b), None)
  assert_eq(
    out2, "h264 enc: a53 captions cap at 21 triples / 63 bytes (got 66 bytes)",
  )
  let out3 = intra_err(None, Some(b"\x01\x02\x03"))
  assert_eq(
    out3, "h264 enc: unregistered SEI payload needs a 16-byte UUID prefix (3 bytes)",
  )
  let out4 = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
      a53=[Some(b"\xFC\x01\x02")],
    ) {
    Ok(_) => fail("batch entry accepted a short side data array")
    Err(e) => e
  }
  assert_eq(
    out4, "h264 enc: side data arrays must be empty or match the frame count (2)",
  )
}

///|
/// `§427`: absent side data keeps every stream byte-identical — explicit
/// empty inputs and the no-argument defaults encode the same bytes.
test "h264 enc sei: defaults leave the stream byte-identical" {
  let frames = h264sei_fixture(3)
  let no_args = match
    @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let explicit_none = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      a53=[None, None, None],
      sei_unregistered=[None, None, None],
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if !h264sei_bytes_equal(no_args, explicit_none) {
    fail("explicit empty side data changed the default stream")
  }
  let cabac_none = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      a53=[None, None, None],
      sei_unregistered=[None, None, None],
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let cabac_plain = match
    @libavcodec.h264_encode_frames_cabac(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if !h264sei_bytes_equal(cabac_none, cabac_plain) {
    fail("explicit empty side data changed the CABAC stream")
  }
  assert_true(no_args.length() > 0)
}
