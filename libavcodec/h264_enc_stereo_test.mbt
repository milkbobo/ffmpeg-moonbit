///|
/// `§428` fixtures: reuse the deblock fixture (the SAR/SEI tests' source).
fn h264st_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  h264dbg_fixture(64, 48, n, 1)
}

///|
/// The frame's stereo side data, if any.
fn h264st_stereo(frame : @libavcodec.H264Frame) -> @libavcodec.H264Stereo3d? {
  for sd in frame.side_data {
    match sd {
      Stereo3d(s) => return Some(s)
      _ => ()
    }
  }
  None
}

///|
/// The SEI (type 6) NAL of an Annex B access unit with emulation
/// prevention bytes stripped (`h264_enc_nal` escapes the whole SEI RBSP,
/// so a `00 00 02` payload tail arrives as `00 00 03 02`).
fn h264st_sei_rbsp(au : Bytes) -> Bytes raise {
  let mut start = -1
  let mut end = au.length()
  let mut i = 0
  while i + 4 < au.length() {
    let sc = au[i] == b'\x00' &&
      au[i + 1] == b'\x00' &&
      au[i + 2] == b'\x00' &&
      au[i + 3] == b'\x01'
    if start < 0 {
      if sc && au[i + 4] == b'\x06' {
        start = i + 4
        i = i + 4
      } else {
        i = i + 1
      }
    } else if sc {
      end = i
      i = au.length()
    } else {
      i = i + 1
    }
  }
  if start < 0 {
    fail("no SEI NAL in the access unit")
  }
  let nal = au[start:end].to_owned()
  let out : Array[Byte] = []
  let mut zeros = 0
  for k = 0; k < nal.length(); k = k + 1 {
    let b = nal[k]
    let epb = zeros >= 2 &&
      (b == b'\x00' || b == b'\x01' || b == b'\x02' || b == b'\x03')
    if epb {
      zeros = 0
    } else {
      out.push(b)
      if b == b'\x00' {
        zeros = zeros + 1
      } else {
        zeros = 0
      }
    }
  }
  Bytes::from_array(out[:])
}

///|
/// `§428`: the intra entry writes one `frame_packing_arrangement` SEI per
/// layout; the decoder maps every layout back to its `AVStereo3DType`
/// (frame sequence also carries the frame-0 view).
test "h264 enc stereo: FPA SEI round trips every layout" {
  let frames = h264st_fixture(1)
  let (y, u, v) = frames[0]
  let cases : Array[(Int32, Int32)] = [
    (@libavcodec.av_stereo3d_checkerboard, @libavcodec.av_stereo3d_view_packed),
    (@libavcodec.av_stereo3d_columns, @libavcodec.av_stereo3d_view_packed),
    (@libavcodec.av_stereo3d_lines, @libavcodec.av_stereo3d_view_packed),
    (@libavcodec.av_stereo3d_side_by_side, @libavcodec.av_stereo3d_view_packed),
    (
      @libavcodec.av_stereo3d_side_by_side_quincunx, @libavcodec.av_stereo3d_view_packed,
    ),
    (@libavcodec.av_stereo3d_top_bottom, @libavcodec.av_stereo3d_view_packed),
    (@libavcodec.av_stereo3d_frame_sequence, @libavcodec.av_stereo3d_view_left),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (layout, want_view) = cases[i]
    let out = match
      @libavcodec.h264_encode_intra_frame(
        y,
        u,
        v,
        width=64,
        height=48,
        qp=26,
        stereo3d=layout,
      ) {
      Ok(e) => e.annexb
      Err(e) => fail(e)
    }
    let decoded = match @libavcodec.h264_decode_annexb_frames(out, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.length(), 1)
    match h264st_stereo(decoded[0]) {
      Some(s) => {
        assert_eq(s.stereo_type, layout, msg="layout \{i} type")
        assert_eq(s.flags, 0, msg="layout \{i} flags")
        assert_eq(s.view, want_view, msg="layout \{i} view")
      }
      None => fail("layout \{i} carries no stereo side data")
    }
  }
}

///|
/// `§428`: every layout's `frame_packing_arrangement` SEI has the canonical
/// shape — NAL type 6, payload type 45, a byte-aligned payload of 6 bytes
/// (grid positions present) or 4 bytes (quincunx and frame sequence skip
/// them) — and the rbsp trailing byte aligns.
test "h264 enc stereo: FPA SEI payload shapes per layout" {
  let frames = h264st_fixture(1)
  let (y, u, v) = frames[0]
  let cases : Array[(Int32, Int32)] = [
    (@libavcodec.av_stereo3d_checkerboard, 6),
    (@libavcodec.av_stereo3d_columns, 6),
    (@libavcodec.av_stereo3d_lines, 6),
    (@libavcodec.av_stereo3d_side_by_side, 6),
    (@libavcodec.av_stereo3d_side_by_side_quincunx, 4),
    (@libavcodec.av_stereo3d_top_bottom, 6),
    (@libavcodec.av_stereo3d_frame_sequence, 4),
  ]
  for i = 0; i < cases.length(); i = i + 1 {
    let (layout, want_len) = cases[i]
    let au = match
      @libavcodec.h264_encode_intra_frame(
        y,
        u,
        v,
        width=64,
        height=48,
        qp=26,
        stereo3d=layout,
      ) {
      Ok(e) => e.annexb
      Err(e) => fail(e)
    }
    let sei = h264st_sei_rbsp(au)
    assert_eq(sei[0].to_int(), 0x06, msg="nal header type 6")
    assert_eq(sei[1].to_int(), 45, msg="sei payload type 45")
    assert_eq(sei[2].to_int(), want_len, msg="payload size for \{layout}")
    assert_eq(
      sei.length(),
      4 + want_len,
      msg="rbsp length for payload \{want_len}",
    )
    assert_eq(sei[sei.length() - 1].to_int(), 0x80, msg="trailing bits")
  }
}

///|
/// `§428`: unsupported layout values are rejected with the exact reason.
/// Zero (`av_stereo3d_2d`) is the documented "off" value and is accepted.
test "h264 enc stereo: invalid layout values are rejected" {
  let frames = h264st_fixture(1)
  let (y, u, v) = frames[0]
  for bad in [8, -1] {
    let out = match
      @libavcodec.h264_encode_intra_frame(
        y,
        u,
        v,
        width=64,
        height=48,
        qp=26,
        stereo3d=bad,
      ) {
      Ok(_) => fail("accepted stereo layout \{bad}")
      Err(e) => e
    }
    assert_eq(
      out,
      "h264 enc: unsupported stereo layout \{bad} (av_stereo3d_* value, 0 = off)",
    )
  }
}

///|
/// `§428`: the batch entry writes the layout with the IDR AU only — the
/// upstream x264 fact (`§424d`): the frame-packing SEI rides IDR pictures,
/// and the following access units carry none (`h264dec.c`
/// `decode_nal_units` resets the SEI state at every AU, so the decoder
/// exports `Stereo3d` for the IDR picture alone).
test "h264 enc stereo: batch writes the layout with the IDR only" {
  let frames = h264st_fixture(3)
  let with_st = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      stereo3d=@libavcodec.av_stereo3d_top_bottom,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let decoded = match @libavcodec.h264_decode_annexb_frames(with_st, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 3)
  match h264st_stereo(decoded[0]) {
    Some(s) =>
      assert_eq(s.stereo_type, @libavcodec.av_stereo3d_top_bottom, msg="IDR")
    None => fail("the IDR lost the layout")
  }
  for i = 1; i < decoded.length(); i = i + 1 {
    match h264st_stereo(decoded[i]) {
      Some(_) => fail("non-IDR frame \{i} carries the layout")
      None => ()
    }
  }
}

///|
/// `§428`: the streaming encoder stashes the layout and writes it with
/// IDR AUs only — a later push with `force_idr` updates the arrangement
/// from that AU onward (the `§424d` per-layout forced-IDR pattern).
test "h264 enc stereo: stream stashes the layout for the next IDR" {
  let frames = h264st_fixture(3)
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=64, height=48, qp=26) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let pushes : Array[Int32] = [
    @libavcodec.av_stereo3d_side_by_side, 0, @libavcodec.av_stereo3d_checkerboard,
  ]
  let forced = [false, false, true]
  let parts : Array[Bytes] = []
  for i = 0; i < frames.length(); i = i + 1 {
    let (y, u, v) = frames[i]
    match enc.push_frame(y, u, v, force_idr=forced[i], stereo3d=pushes[i]) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      parts.push(au)
    }
  }
  match enc.finish() {
    Ok(t) =>
      for part in t {
        parts.push(part)
      }
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for part in parts {
    for i = 0; i < part.length(); i = i + 1 {
      joined.push(part[i])
    }
  }
  let decoded = match
    @libavcodec.h264_decode_annexb_frames(Bytes::from_array(joined[:]), false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(decoded.length(), 3)
  // Coding order: IDR0 (side by side), P1 (no SEI), IDR2 (checkerboard
  // via force_idr) — the layout rides IDR AUs only.
  match h264st_stereo(decoded[0]) {
    Some(s) =>
      assert_eq(
        s.stereo_type,
        @libavcodec.av_stereo3d_side_by_side,
        msg="frame 0",
      )
    None => fail("frame 0 carries no stereo side data")
  }
  match h264st_stereo(decoded[1]) {
    Some(_) => fail("frame 1 (P) carries stereo side data")
    None => ()
  }
  match h264st_stereo(decoded[2]) {
    Some(s) =>
      assert_eq(
        s.stereo_type,
        @libavcodec.av_stereo3d_checkerboard,
        msg="frame 2",
      )
    None => fail("frame 2 carries no stereo side data")
  }
}

///|
/// `§428`: absent stereo keeps every stream byte-identical.
test "h264 enc stereo: defaults leave the stream byte-identical" {
  let frames = h264st_fixture(2)
  let no_args = match
    @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let explicit_off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      stereo3d=0,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if no_args.length() != explicit_off.length() {
    fail("stereo3d=0 changed the stream length")
  }
  for i = 0; i < no_args.length(); i = i + 1 {
    if no_args[i] != explicit_off[i] {
      fail("stereo3d=0 changed byte \{i}")
    }
  }
  assert_true(no_args.length() > 0)
}
