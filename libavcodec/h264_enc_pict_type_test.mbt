// Blackbox tests for the §431 per-picture type forcing of the streaming
// encoder: the libx264.c vocabulary (Auto / Keyframe / Idr / P / B), the
// non-IDR open-GOP I writer, and the scheduler's pair handling around
// forced types. The checks decode the streams with the package's own
// decoder and compare every non-IDR reconstruction with the decoder's
// output, so a wrong reference or POC ordering cannot pass silently.

///|
/// Parse every slice NAL of an Annex B stream into
/// `(nal_unit_type, pic_order_cnt_lsb, slice_type_nos, frame_num)`,
/// threading the parameter sets the encoder re-emits on each IDR.
fn h264pt_slices(stream : Bytes) -> Array[(Int32, Int32, Int32, Int32)] raise {
  let ps = @libavcodec.new_h264_param_sets()
  let out : Array[(Int32, Int32, Int32, Int32)] = []
  for nal in vbv_nals(stream) {
    let payload = vbv_nal_payload(stream, nal)
    let reader = @libavcodec.BitReader::new(payload)
    if nal.0 == 7 {
      match @libavcodec.ff_h264_decode_seq_parameter_set(reader, ps, false) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal.0 == 8 {
      match
        @libavcodec.ff_h264_decode_picture_parameter_set(
          reader,
          ps,
          payload.length() * 8,
        ) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal.0 == 1 || nal.0 == 5 {
      let ref_idc = (stream[nal.1 + 4].to_int() >> 5) & 3
      let sh = match
        @libavcodec.ff_h264_decode_slice_header(reader, nal.0, ref_idc, ps) {
        Ok(h) => h
        Err(e) => fail(e)
      }
      out.push((nal.0, sh.pic_order_cnt_lsb, sh.slice_type_nos, sh.frame_num))
    }
  }
  out
}

///|
/// Decode one Annex B stream, failing the test on a decoder error.
fn h264pt_decode(stream : Bytes) -> Array[@libavcodec.H264Frame] raise {
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
}

///|
/// Every non-IDR reconstruction must be exactly one decoded picture's
/// output (the stream's `recons` are in coding order, the decoder's frames
/// in display order).
fn h264pt_recons_match(
  recons : Array[Bytes],
  decoded : Array[@libavcodec.H264Frame],
) -> Unit raise {
  for r in recons {
    assert_true(
      decoded.any(f => h264s_bytes_eq(r, f.yuvp())),
      msg="encoder reconstruction absent from the decoded output",
    )
  }
}

///|
/// Batch-encode a tiny 32x32 sequence with the matching entropy entry.
fn h264pt_batch(
  frames : Array[(Bytes, Bytes, Bytes)],
  cabac : Bool,
  b_slices : Bool,
) -> Bytes raise {
  let result = if cabac {
    @libavcodec.h264_encode_frames_cabac(frames, width=32, height=32, b_slices~)
  } else {
    @libavcodec.h264_encode_frames(frames, width=32, height=32, b_slices~)
  }
  match result {
    Ok(s) => s
    Err(e) => fail(e)
  }
}

///|
/// Batch-encode with per-display-position type requests.
fn h264pt_batch_types(
  frames : Array[(Bytes, Bytes, Bytes)],
  cabac : Bool,
  b_slices : Bool,
  types : Array[Int32],
) -> Result[Bytes, String] {
  if cabac {
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=32,
      height=32,
      b_slices~,
      pict_types=types,
    )
  } else {
    @libavcodec.h264_encode_frames(
      frames,
      width=32,
      height=32,
      b_slices~,
      pict_types=types,
    )
  }
}

///|
/// Stream-encode the same requests through `H264StreamEncoder`.
fn h264pt_stream_types(
  frames : Array[(Bytes, Bytes, Bytes)],
  cabac : Bool,
  b_slices : Bool,
  types : Array[Int32],
) -> Bytes raise {
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=32, height=32, cabac~, b_slices~) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for i, (y, u, v) in frames {
    match enc.push_frame(y, u, v, pict_type=types[i]) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  h264s_concat(aus)
}

///|
test "h264 pict type: batch schedules match the streaming encoder" {
  let schedules : Array[(Int32, Array[Int32])] = [
    // Forced keyframe mid-GOP.
    (6, [0, 0, 1, 0, 0, 0]),
    // Forced P at an odd display position (no B pairing).
    (6, [0, 3, 0, 0, 0, 0]),
    // Forced B at an even display position (waits for the next frame).
    (7, [0, 0, 4, 0, 0, 0, 0]),
    // Mid-sequence IDR restarts the GOP.
    (8, [0, 0, 0, 0, 2, 0, 0, 0]),
    // Mixed keyframe / P forcing.
    (8, [0, 0, 1, 3, 0, 0, 0, 0]),
  ]
  for cabac in [false, true] {
    for b_slices in [false, true] {
      for (n, types) in schedules {
        // B requests need POC type 0.
        if b_slices || !types.contains(4) {
          let frames = h264p_fixture(32, 32, n)
          let batch = match h264pt_batch_types(frames, cabac, b_slices, types) {
            Ok(s) => s
            Err(e) => fail(e)
          }
          let stream = h264pt_stream_types(frames, cabac, b_slices, types)
          assert_true(
            h264s_bytes_eq(batch, stream),
            msg="cabac=\{cabac} b_slices=\{b_slices} n=\{n}",
          )
        }
      }
    }
  }
}

///|
test "h264 pict type: empty and all-auto request arrays are no-ops" {
  let frames = h264p_fixture(32, 32, 6)
  for cabac in [false, true] {
    for b_slices in [false, true] {
      let base = h264pt_batch(frames, cabac, b_slices)
      let with_autos = match
        h264pt_batch_types(frames, cabac, b_slices, Array::make(6, 0)) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      assert_true(
        h264s_bytes_eq(base, with_autos),
        msg="cabac=\{cabac} b_slices=\{b_slices}: all-auto changed the stream",
      )
    }
  }
}

///|
test "h264 pict type: batch request validation" {
  let frames = h264p_fixture(32, 32, 4)
  // Length mismatch.
  match h264pt_batch_types(frames, false, true, [0, 0]) {
    Ok(_) => fail("short pict_types accepted")
    Err(e) => assert_true(e.contains("pict_types"))
  }
  // Unknown selector.
  match h264pt_batch_types(frames, false, true, [0, 0, 9, 0]) {
    Ok(_) => fail("invalid pict_type accepted")
    Err(e) => assert_true(e.contains("unsupported pict_type"))
  }
  // Forced B without POC type 0.
  match h264pt_batch_types(frames, false, false, [0, 4, 0, 0]) {
    Ok(_) => fail("forced B accepted without b_slices")
    Err(e) => assert_true(e.contains("b_slices"))
  }
  // Rate control cannot follow the forced coding order.
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=32,
      height=32,
      target_bytes=400,
      pict_types=[0, 1, 0, 0],
    ) {
    Ok(_) => fail("forced types accepted with target_bytes")
    Err(e) => assert_true(e.contains("not supported"))
  }
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=32,
      height=32,
      vbv_maxrate=320000,
      vbv_bufsize=128000,
      fps=25,
      pict_types=[0, 1, 0, 0],
    ) {
    Ok(_) => fail("forced types accepted with VBV")
    Err(e) => assert_true(e.contains("not supported"))
  }
}

///|
test "h264 pict type: a batch mid-IDR decodes as an independent GOP" {
  let frames = h264p_fixture(32, 32, 8)
  for cabac in [false, true] {
    let types : Array[Int32] = [0, 0, 0, 0, 2, 0, 0, 0]
    let recon : Array[Bytes] = []
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=32,
          height=32,
          pict_types=types,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=32,
          height=32,
          pict_types=types,
          recon~,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let nals = vbv_nals(stream)
    assert_eq(nals.filter(n => n.0 == 5).length(), 2)
    assert_eq(nals.filter(n => n.0 == 7).length(), 2)
    let decoded = h264pt_decode(stream)
    assert_eq(decoded.length(), 8)
    assert_eq(recon.length(), 6)
    h264pt_recons_match(recon, decoded)
  }
}

///|
test "h264 pict type: a forced keyframe is a non-IDR I picture" {
  let frames = h264p_fixture(32, 32, 6)
  for cabac in [false, true] {
    for b_slices in [false, true] {
      let enc = match
        @libavcodec.H264StreamEncoder::open(
          width=32,
          height=32,
          cabac~,
          b_slices~,
          aud=true,
        ) {
        Ok(e) => e
        Err(e) => fail(e)
      }
      let aus : Array[Bytes] = []
      for i, (y, u, v) in frames {
        match enc.push_frame(y, u, v, pict_type=if i == 2 { 1 } else { 0 }) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
        for au in enc.drain() {
          aus.push(au)
        }
      }
      match enc.finish() {
        Ok(tail) =>
          for au in tail {
            aus.push(au)
          }
        Err(e) => fail(e)
      }
      let stream = h264s_concat(aus)
      let nals = vbv_nals(stream)
      // Only the sequence's first picture carries parameter sets and an
      // IDR slice; the forced keyframe is a type-1 NAL.
      assert_eq(nals.filter(n => n.0 == 5).length(), 1)
      assert_eq(nals.filter(n => n.0 == 7).length(), 1)
      assert_eq(nals.filter(n => n.0 == 8).length(), 1)
      let slices = h264pt_slices(stream)
      assert_eq(slices.length(), 6)
      let key = slices.filter(s => s.0 == 1 && s.2 == 2)
      assert_eq(key.length(), 1)
      if b_slices {
        // Open GOP: the keyframe keeps the sequence's POC (display 2).
        assert_eq(key[0].1, 4)
      }
      assert_eq(enc.stats.frame_qps.length(), 6)
      let decoded = h264pt_decode(stream)
      assert_eq(decoded.length(), 6)
      assert_eq(enc.recons.length(), 5)
      h264pt_recons_match(enc.recons, decoded)
      // The keyframe's pixels are the intra reconstruction of its source.
      let solo = h264pt_batch([frames[2]], cabac, false)
      let solo_decoded = h264pt_decode(solo)
      assert_eq(solo_decoded.length(), 1)
      assert_true(
        h264s_bytes_eq(solo_decoded[0].yuvp(), decoded[2].yuvp()),
        msg="cabac=\{cabac} b_slices=\{b_slices}: keyframe mismatch",
      )
    }
  }
}

///|
test "h264 pict type: a forced P skips the B pairing" {
  let frames = h264p_fixture(32, 32, 6)
  for cabac in [false, true] {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=32,
        height=32,
        cabac~,
        b_slices=true,
        aud=true,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let aus : Array[Bytes] = []
    for i, (y, u, v) in frames {
      match enc.push_frame(y, u, v, pict_type=if i == 1 { 3 } else { 0 }) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      for au in enc.drain() {
        aus.push(au)
      }
    }
    match enc.finish() {
      Ok(tail) =>
        for au in tail {
          aus.push(au)
        }
      Err(e) => fail(e)
    }
    let stream = h264s_concat(aus)
    let slices = h264pt_slices(stream)
    assert_eq(slices.length(), 6)
    // Display 1 is a P picture, so only the default odd position 3 is a B.
    let at2 = slices.filter(s => s.1 == 2)
    assert_eq(at2.length(), 1)
    assert_eq(at2[0].2, 0)
    assert_eq(slices.filter(s => s.2 == 1).length(), 1)
    let decoded = h264pt_decode(stream)
    assert_eq(decoded.length(), 6)
    h264pt_recons_match(enc.recons, decoded)
    // The forced P references the IDR exactly like the all-P batch entry.
    let head = h264pt_batch(frames[0:2].to_owned(), cabac, false)
    let head_decoded = h264pt_decode(head)
    assert_true(
      h264s_bytes_eq(head_decoded[1].yuvp(), decoded[1].yuvp()),
      msg="cabac=\{cabac}: forced P differs from the batch P",
    )
  }
}

///|
test "h264 pict type: a forced B at an even position waits for its future P" {
  let frames = h264p_fixture(32, 32, 7)
  for cabac in [false, true] {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=32,
        height=32,
        cabac~,
        b_slices=true,
        aud=true,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let aus : Array[Bytes] = []
    for i, (y, u, v) in frames {
      match enc.push_frame(y, u, v, pict_type=if i == 2 { 4 } else { 0 }) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      for au in enc.drain() {
        aus.push(au)
      }
    }
    match enc.finish() {
      Ok(tail) =>
        for au in tail {
          aus.push(au)
        }
      Err(e) => fail(e)
    }
    let stream = h264s_concat(aus)
    let slices = h264pt_slices(stream)
    assert_eq(slices.length(), 7)
    // Display 2 is coded as a B against the future P at display 3; the
    // default schedule's odd position 5 is the only other B.
    let at2 = slices.filter(s => s.1 == 4)
    assert_eq(at2.length(), 1)
    assert_eq(at2[0].2, 1)
    let at3 = slices.filter(s => s.1 == 6)
    assert_eq(at3.length(), 1)
    assert_eq(at3[0].2, 0)
    assert_eq(slices.filter(s => s.2 == 1).length(), 2)
    let decoded = h264pt_decode(stream)
    assert_eq(decoded.length(), 7)
    assert_eq(enc.recons.length(), 6)
    h264pt_recons_match(enc.recons, decoded)
    // The tail P (display 1) is byte-equivalent in pixels to the batch
    // all-P picture, proving the forced B did not disturb the chain.
    let head = h264pt_batch(frames[0:2].to_owned(), cabac, false)
    let head_decoded = h264pt_decode(head)
    assert_true(
      h264s_bytes_eq(head_decoded[1].yuvp(), decoded[1].yuvp()),
      msg="cabac=\{cabac}: tail P differs from the batch P",
    )
  }
}

///|
test "h264 pict type: validation, force_idr precedence and the B guard" {
  let frames = h264p_fixture(32, 32, 3)
  let enc = match @libavcodec.H264StreamEncoder::open(width=32, height=32) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let (y0, u0, v0) = frames[0]
  match enc.push_frame(y0, u0, v0, pict_type=99) {
    Ok(_) => fail("invalid pict_type accepted")
    Err(e) => assert_true(e.contains("pict_type"))
  }
  // Forced B needs POC type 0 (the b_slices SPS). The first picture is
  // always the IDR, so the guard shows on the following push.
  let p_enc = match
    @libavcodec.H264StreamEncoder::open(width=32, height=32, b_slices=false) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  match p_enc.push_frame(y0, u0, v0) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let (y1, u1, v1) = frames[1]
  match p_enc.push_frame(y1, u1, v1, pict_type=4) {
    Ok(_) => fail("forced B accepted without b_slices")
    Err(e) => assert_true(e.contains("b_slices"))
  }
  // `force_idr` wins over `pict_type` (libx264.c's forced-idr rule).
  let idr_enc = match @libavcodec.H264StreamEncoder::open(width=32, height=32) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  match idr_enc.push_frame(y0, u0, v0) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  match idr_enc.push_frame(y1, u1, v1, force_idr=true, pict_type=3) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let ready = idr_enc.drain()
  assert_eq(ready.length(), 2)
  assert_eq(vbv_nals(ready[1]).filter(n => n.0 == 5).length(), 1)
  assert_eq(vbv_nals(ready[1]).filter(n => n.0 == 7).length(), 1)
}

///|
test "h264 pict type: a VBV keyframe rides the transactional path" {
  let frames = h264p_fixture(32, 32, 5)
  for cabac in [false, true] {
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=32,
        height=32,
        cabac~,
        b_slices=true,
        vbv_maxrate=320000,
        vbv_bufsize=128000,
        fps=25,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let aus : Array[Bytes] = []
    for i, (y, u, v) in frames {
      match enc.push_frame(y, u, v, pict_type=if i == 2 { 1 } else { 0 }) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      for au in enc.drain() {
        aus.push(au)
      }
    }
    match enc.finish() {
      Ok(tail) =>
        for au in tail {
          aus.push(au)
        }
      Err(e) => fail(e)
    }
    let stream = h264s_concat(aus)
    let nals = vbv_nals(stream)
    assert_eq(nals.filter(n => n.0 == 5).length(), 1)
    let slices = h264pt_slices(stream)
    assert_eq(slices.length(), 5)
    assert_eq(slices.filter(s => s.0 == 1 && s.2 == 2).length(), 1)
    let decoded = h264pt_decode(stream)
    assert_eq(decoded.length(), 5)
    assert_eq(enc.recons.length(), 4)
    h264pt_recons_match(enc.recons, decoded)
  }
}
