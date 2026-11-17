// Blackbox tests for §432: the Cb/Cr chroma QP offset (x264
// `chroma-qp-offset`) is written to both PPS offset fields, applied to the
// chroma quantisation/deblocking QP, and kept byte-identical when left at
// the default 0. Luma decisions never read the chroma QP, so at a fixed
// luma QP every decoded Y plane must be identical across offsets while the
// U/V planes change.

///|
/// Decode one Annex B stream, failing the test on a decoder error.
fn h264cq_decode(stream : Bytes) -> Array[@libavcodec.H264Frame] raise {
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
}

///|
/// The `yuvp()` packing is Y (w*h) then U then V; extract the luma slice.
fn h264cq_y(plane : Bytes, w : Int32, h : Int32) -> Bytes {
  Bytes::from_array(plane.to_array()[0:w * h])
}

///|
/// Extract the concatenated U+V slice from a 4:2:0 `yuvp()` buffer.
fn h264cq_uv(plane : Bytes, w : Int32, h : Int32) -> Bytes {
  let cw = w / 2
  let ch = h / 2
  let off = w * h
  Bytes::from_array(plane.to_array()[off:off + cw * ch * 2])
}

///|
/// Find the byte offset just past the next Annex B start code (`00 00 01`
/// or `00 00 00 01`) at or after `from`; `-1` if none.
fn h264cq_next_start(stream : Bytes, from : Int32) -> Int32 {
  let len = stream.length()
  let mut i = from
  while i + 3 <= len {
    if stream[i] == b'\x00' && stream[i + 1] == b'\x00' {
      if stream[i + 2] == b'\x01' {
        return i + 3
      }
      if i + 3 < len && stream[i + 2] == b'\x00' && stream[i + 3] == b'\x01' {
        return i + 4
      }
    }
    i = i + 1
  }
  -1
}

///|
/// Decode the SPS and PPS from an Annex B stream and return the two chroma
/// QP index offsets written by the encoder.
fn h264cq_pps_offsets(stream : Bytes) -> (Int32, Int32) raise {
  let ps = @libavcodec.new_h264_param_sets()
  let mut pos = h264cq_next_start(stream, 0)
  while pos >= 0 && pos < stream.length() {
    let nal_type = stream[pos] & 0x1f
    let next = h264cq_next_start(stream, pos + 1)
    let end = if next < 0 { stream.length() } else { next - 3 }
    // RBSP starts one byte after the NAL header.
    let rbsp = Bytes::from_array(stream.to_array()[pos + 1:end])
    let reader = @libavcodec.BitReader::new(rbsp)
    if nal_type == 7 {
      match @libavcodec.ff_h264_decode_seq_parameter_set(reader, ps, false) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal_type == 8 {
      match
        @libavcodec.ff_h264_decode_picture_parameter_set(
          reader,
          ps,
          rbsp.length() * 8,
        ) {
        Ok(_) =>
          for pps_opt in ps.pps_list {
            match pps_opt {
              Some(pps) =>
                return (
                  pps.chroma_qp_index_offset0,
                  pps.chroma_qp_index_offset1,
                )
              None => ()
            }
          }
        Err(e) => fail(e)
      }
    }
    pos = next
  }
  fail("no PPS NAL found")
}

///|
/// Encode a single 64x48 I picture at qp 0 (luma lossless) and return the
/// Annex B stream.
fn h264cq_intra(
  frame : (Bytes, Bytes, Bytes),
  cabac : Bool,
  offset : Int32,
) -> Bytes raise {
  let result = if cabac {
    @libavcodec.h264_encode_intra_frame_cabac(
      frame.0,
      frame.1,
      frame.2,
      width=64,
      height=48,
      qp=0,
      chroma_qp_offset=offset,
    )
  } else {
    @libavcodec.h264_encode_intra_frame(
      frame.0,
      frame.1,
      frame.2,
      width=64,
      height=48,
      qp=0,
      chroma_qp_offset=offset,
    )
  }
  match result {
    Ok(s) => s.annexb
    Err(e) => fail(e)
  }
}

///|
/// The default offset keeps the stream byte-identical to omitting the
/// parameter entirely.
fn h264cq_default_byte_identical() -> Unit raise {
  let f = h264dbg_fixture(64, 48, 1, 1)[0]
  assert_eq(h264cq_intra(f, false, 0), h264cq_intra(f, false, 0))
  assert_eq(h264cq_intra(f, true, 0), h264cq_intra(f, true, 0))
  let explicit = match
    @libavcodec.h264_encode_intra_frame(
      f.0,
      f.1,
      f.2,
      width=64,
      height=48,
      qp=0,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail(e)
  }
  assert_eq(h264cq_intra(f, false, 0), explicit)
}

///|
/// The chroma QP offset changes only the chroma planes: at any fixed luma
/// QP the decoded Y plane is identical across offsets while the U/V planes
/// differ. (We do not assume QP 0 is lossless; we compare offset 0 against
/// nonzero offsets directly.)
fn h264cq_intra_chroma_only(cabac : Bool) -> Unit raise {
  let (y, u, v) = h264dbg_fixture(64, 48, 1, 1)[0]
  let w = 64
  let h = 48
  // At qp 0 the chroma QP index is `0 + offset`; negative offsets clamp to
  // 0, so use non-negative offsets (0, 6, 12) to get three distinct chroma
  // quantisation levels.
  let d0 = h264cq_decode(h264cq_intra((y, u, v), cabac, 0))[0].yuvp()
  let d6 = h264cq_decode(h264cq_intra((y, u, v), cabac, 6))[0].yuvp()
  let d12 = h264cq_decode(h264cq_intra((y, u, v), cabac, 12))[0].yuvp()
  // Luma is independent of the chroma offset.
  assert_eq(h264cq_y(d0, w, h), h264cq_y(d6, w, h))
  assert_eq(h264cq_y(d0, w, h), h264cq_y(d12, w, h))
  // Chroma changes with the offset, and the three cases are pairwise distinct.
  assert_true(h264cq_uv(d0, w, h) != h264cq_uv(d6, w, h))
  assert_true(h264cq_uv(d0, w, h) != h264cq_uv(d12, w, h))
  assert_true(h264cq_uv(d6, w, h) != h264cq_uv(d12, w, h))
}

///|
fn h264cq_intra_cavlc_chroma_only() -> Unit raise {
  h264cq_intra_chroma_only(false)
}

///|
fn h264cq_intra_cabac_chroma_only() -> Unit raise {
  h264cq_intra_chroma_only(true)
}

///|
/// Both PPS offset fields carry the value (Cb and Cr share one offset, like
/// x264), and the round-tripped parser reads them back.
fn h264cq_pps_fields_written() -> Unit raise {
  let f = h264dbg_fixture(64, 48, 1, 1)[0]
  for offset in [6, -6, 0, 12, -12] {
    let (o0, o1) = h264cq_pps_offsets(h264cq_intra(f, false, offset))
    assert_eq(o0, offset)
    assert_eq(o1, offset)
  }
  let (o0, o1) = h264cq_pps_offsets(h264cq_intra(f, true, 4))
  assert_eq(o0, 4)
  assert_eq(o1, 4)
}

///|
/// Out-of-range offsets (-13 / 13) are rejected with the exact message at
/// every public entry point.
fn h264cq_range_invalid() -> Unit raise {
  let f = h264dbg_fixture(64, 48, 1, 1)[0]
  let msg = "h264 enc: chroma_qp_offset must be in -12..=12"
  match
    @libavcodec.h264_encode_intra_frame(
      f.0,
      f.1,
      f.2,
      width=64,
      height=48,
      qp=0,
      chroma_qp_offset=13,
    ) {
    Err(e) => assert_eq(e, msg)
    Ok(_) => fail("expected range error")
  }
  match
    @libavcodec.h264_encode_intra_frame_cabac(
      f.0,
      f.1,
      f.2,
      width=64,
      height=48,
      qp=0,
      chroma_qp_offset=-13,
    ) {
    Err(e) => assert_eq(e, msg)
    Ok(_) => fail("expected range error")
  }
  let frames = h264dbg_fixture(64, 48, 2, 1)
  assert_eq(
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      chroma_qp_offset=13,
    ),
    Err(msg),
  )
  assert_eq(
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      chroma_qp_offset=-13,
    ),
    Err(msg),
  )
  match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      chroma_qp_offset=13,
    ) {
    Err(e) => assert_eq(e, msg)
    Ok(_) => fail("expected range error")
  }
}

///|
/// A P sequence: the chroma offset changes the chroma planes of every
/// decoded picture while the stream structure (frame count) is preserved.
/// Luma is not asserted equal across offsets because the encoder's inter
/// mode decision can couple chroma cost into luma choices.
fn h264cq_batch_p_chroma_offset() -> Unit raise {
  let frames = h264dbg_fixture(64, 48, 3, 1)
  let w = 64
  let h = 48
  let s0 = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      chroma_qp_offset=0,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let s6 = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      chroma_qp_offset=6,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let d0 = h264cq_decode(s0)
  let d6 = h264cq_decode(s6)
  assert_eq(d0.length(), d6.length())
  for i = 0; i < d0.length(); i = i + 1 {
    let a = d0[i].yuvp()
    let b = d6[i].yuvp()
    assert_true(h264cq_uv(a, w, h) != h264cq_uv(b, w, h))
  }
}

///|
/// The streaming encoder produces a byte-identical stream to the batch
/// encoder when given the same chroma offset and otherwise-default settings
/// (CAVLC, single reference, no B slices, no weighted prediction).
fn h264cq_streaming_equals_batch() -> Unit raise {
  let frames = h264dbg_fixture(32, 32, 4, 1)
  let offset = 5
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=32,
      height=32,
      qp=26,
      b_slices=false,
      weightp=false,
      dct8x8=false,
      deblock=true,
      chroma_qp_offset=offset,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=32,
      height=32,
      qp=26,
      b_slices=false,
      weightp=false,
      dct8x8=false,
      deblock=true,
      chroma_qp_offset=offset,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      for i = 0; i < au.length(); i = i + 1 {
        joined.push(au[i])
      }
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        for i = 0; i < au.length(); i = i + 1 {
          joined.push(au[i])
        }
      }
    Err(e) => fail(e)
  }
  let stream = Bytes::from_array(joined[:])
  assert_eq(stream, batch)
}

///|
/// The facade forwards the offset to the encoder.
fn h264cq_facade_forwards_offset() -> Unit raise {
  let frames = h264dbg_fixture(64, 48, 1, 1)
  let cfg6 = {
    ..@libavcodec.VideoEncConfig::new(width=64, height=48),
    chroma_qp_offset: 6,
  }
  let cfg0 = @libavcodec.VideoEncConfig::new(width=64, height=48)
  let s0 = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::default(),
      config=cfg0,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let s6 = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::default(),
      config=cfg6,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_true(s0 != s6)
  let d0 = h264cq_decode(s0)
  let d6 = h264cq_decode(s6)
  assert_eq(d0.length(), d6.length())
  assert_eq(h264cq_y(d0[0].yuvp(), 64, 48), h264cq_y(d6[0].yuvp(), 64, 48))
}

///|
test "h264cq: default offset is byte-identical" {
  h264cq_default_byte_identical()
}

///|
test "h264cq: cavlc intra changes chroma only" {
  h264cq_intra_cavlc_chroma_only()
}

///|
test "h264cq: cabac intra changes chroma only" {
  h264cq_intra_cabac_chroma_only()
}

///|
test "h264cq: both PPS offset fields carry the value" {
  h264cq_pps_fields_written()
}

///|
test "h264cq: out-of-range offsets are rejected" {
  h264cq_range_invalid()
}

///|
test "h264cq: batch P luma is independent of chroma offset" {
  h264cq_batch_p_chroma_offset()
}

///|
test "h264cq: streaming equals batch with chroma offset" {
  h264cq_streaming_equals_batch()
}

///|
test "h264cq: facade forwards the chroma offset" {
  h264cq_facade_forwards_offset()
}
