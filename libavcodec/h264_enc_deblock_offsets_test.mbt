// Blackbox tests for §433: slice-level deblocking alpha/beta offsets (x264
// `--deblock alpha:beta`). Either nonzero offset opts the PPS into
// `deblocking_filter_control_present_flag`; every slice header then carries
// `disable_deblocking_filter_idc = 0` plus both div2 offsets, and the
// encoder's in-loop filter runs at the shifted strength so its
// reconstructions stay equal to a conforming decoder's filtered output.
// The default 0/0 keeps every stream byte-identical.

///|
fn h264do_decode(stream : Bytes) -> Array[@libavcodec.H264Frame] raise {
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(d) => d
    Err(e) => fail(e)
  }
}

///|
/// The PPS `deblocking_filter_parameters_present` flag read back through
/// the real parser.
fn h264do_pps_flag(stream : Bytes) -> Int32 raise {
  let ps = @libavcodec.new_h264_param_sets()
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
        Ok(_) =>
          for pps_opt in ps.pps_list {
            match pps_opt {
              Some(pps) => return pps.deblocking_filter_parameters_present
              None => ()
            }
          }
        Err(e) => fail(e)
      }
    }
  }
  fail("no PPS NAL found")
}

///|
/// `(disable_deblocking_filter_idc, slice_alpha_c0_offset,
/// slice_beta_offset)` of every slice NAL, in stream order. The parser
/// already doubles the div2 syntax values.
fn h264do_slice_offsets(stream : Bytes) -> Array[(Int32, Int32, Int32)] raise {
  let ps = @libavcodec.new_h264_param_sets()
  let out : Array[(Int32, Int32, Int32)] = []
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
      out.push(
        (
          sh.disable_deblocking_filter_idc,
          sh.slice_alpha_c0_offset,
          sh.slice_beta_offset,
        ),
      )
    }
  }
  out
}

///|
/// One 96x64 blocky I picture at qp 26 with the given offsets.
fn h264do_intra(
  cabac : Bool,
  alpha : Int32,
  beta : Int32,
) -> @libavcodec.H264EncodedFrame raise {
  let (y, u, v) = h264dbg_fixture(96, 64, 1, 1)[0]
  let result = if cabac {
    @libavcodec.h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      deblock_alpha=alpha,
      deblock_beta=beta,
    )
  } else {
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      deblock_alpha=alpha,
      deblock_beta=beta,
    )
  }
  match result {
    Ok(e) => e
    Err(e) => fail(e)
  }
}

///|
/// The default 0/0 keeps the PPS flag off and every stream byte-identical
/// to omitting the parameters.
test "h264do: default offsets are byte-identical" {
  let frames = h264dbg_fixture(96, 64, 3, 1)
  for cabac in [false, true] {
    let explicit = h264do_intra(cabac, 0, 0)
    let (y, u, v) = frames[0]
    let omitted = if cabac {
      @libavcodec.h264_encode_intra_frame_cabac(
        y,
        u,
        v,
        width=96,
        height=64,
        qp=26,
      )
    } else {
      @libavcodec.h264_encode_intra_frame(y, u, v, width=96, height=64, qp=26)
    }
    let omitted_stream = match omitted {
      Ok(s) => s.annexb
      Err(e) => fail(e)
    }
    assert_eq(explicit.annexb, omitted_stream, msg="cabac=\{cabac}")
    assert_eq(h264do_pps_flag(explicit.annexb), 0)
  }
  let batch_default = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let batch_zero = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      deblock_alpha=0,
      deblock_beta=0,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(batch_default, batch_zero)
}

///|
/// With nonzero offsets the PPS opts in, every slice carries idc 0 and the
/// doubled offsets, the decoded pixels change, and the encoder's
/// reconstruction equals the decoder's filtered output — including the
/// extreme ±6 corners.
test "h264do: intra recon equals filtered decode with offsets" {
  for cabac in [false, true] {
    let default_decoded = h264do_decode(h264do_intra(cabac, 0, 0).annexb)
    for (alpha, beta) in [(3, 2), (-3, -2), (6, 6), (-6, -6), (2, -5)] {
      let enc = h264do_intra(cabac, alpha, beta)
      assert_eq(h264do_pps_flag(enc.annexb), 1, msg="cabac=\{cabac}")
      let slices = h264do_slice_offsets(enc.annexb)
      assert_eq(slices.length(), 1)
      assert_eq(slices[0], (0, 2 * alpha, 2 * beta))
      let decoded = h264do_decode(enc.annexb)
      let recon = h264dbg_pack_planes(
        enc.recon_y,
        enc.recon_u,
        enc.recon_v,
        96,
        64,
        enc.ystride,
        enc.cstride,
        1,
      )
      assert_eq(
        mr_md5(recon),
        mr_md5(decoded[0].yuvp()),
        msg="cabac=\{cabac} a=\{alpha} b=\{beta}",
      )
      assert_true(
        mr_md5(decoded[0].yuvp()) != mr_md5(default_decoded[0].yuvp()),
        msg="offsets must change the filtered output",
      )
    }
  }
}

///|
/// P and B schedules: every slice of every picture (I, P and B) carries the
/// offsets, and each non-IDR reconstruction equals the decoder's filtered
/// output at the shifted strength.
test "h264do: batch sequences recon equals filtered decode" {
  for b_slices in [false, true] {
    for cabac in [false, true] {
      let frames = h264dbg_fixture(96, 64, 5, 1)
      let recon : Array[Bytes] = []
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices~,
          recon~,
          deblock_alpha=2,
          deblock_beta=-3,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          b_slices~,
          recon~,
          deblock_alpha=2,
          deblock_beta=-3,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail("b=\{b_slices} cabac=\{cabac}: \{e}")
      }
      assert_eq(h264do_pps_flag(stream), 1)
      let slices = h264do_slice_offsets(stream)
      assert_eq(slices.length(), 5)
      for s in slices {
        assert_eq(s, (0, 4, -6), msg="b=\{b_slices} cabac=\{cabac}")
      }
      let decoded = h264do_decode(stream)
      assert_eq(recon.length(), 4)
      for i, r in recon {
        assert_eq(
          mr_md5(r),
          mr_md5(decoded[i + 1].yuvp()),
          msg="b=\{b_slices} cabac=\{cabac} frame=\{i}",
        )
      }
    }
  }
}

///|
/// The VBV rate-control path re-encodes pictures at trial QPs; the offsets
/// must survive every trial and appear in every slice of the final stream.
test "h264do: vbv sequence carries the offsets" {
  let frames = h264dbg_fixture(96, 64, 5, 1)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      vbv_maxrate=400000,
      vbv_bufsize=200000,
      fps=25,
      deblock_alpha=-2,
      deblock_beta=4,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(h264do_pps_flag(stream), 1)
  let slices = h264do_slice_offsets(stream)
  assert_eq(slices.length(), 5)
  for s in slices {
    assert_eq(s, (0, -4, 8))
  }
  let decoded = h264do_decode(stream)
  assert_eq(decoded.length(), 5)
  let plain = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      vbv_maxrate=400000,
      vbv_bufsize=200000,
      fps=25,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_true(stream != plain, msg="offsets must change the vbv stream")
}

///|
/// Out-of-range offsets and the deblock=false exclusivity are rejected with
/// the exact messages at every public entry point.
test "h264do: range and exclusivity errors" {
  let (y, u, v) = h264dbg_fixture(96, 64, 1, 1)[0]
  let frames = h264dbg_fixture(96, 64, 2, 1)
  let alpha_msg = "h264 enc: deblock_alpha must be in -6..=6"
  let beta_msg = "h264 enc: deblock_beta must be in -6..=6"
  let excl_msg = "h264 enc: deblock offsets require deblock=true"
  match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      deblock_alpha=7,
    ) {
    Err(e) => assert_eq(e, alpha_msg)
    Ok(_) => fail("expected alpha range error")
  }
  match
    @libavcodec.h264_encode_intra_frame_cabac(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      deblock_beta=-7,
    ) {
    Err(e) => assert_eq(e, beta_msg)
    Ok(_) => fail("expected beta range error")
  }
  match
    @libavcodec.h264_encode_intra_frame(
      y,
      u,
      v,
      width=96,
      height=64,
      qp=26,
      deblock=false,
      deblock_alpha=1,
    ) {
    Err(e) => assert_eq(e, excl_msg)
    Ok(_) => fail("expected exclusivity error")
  }
  assert_eq(
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      deblock_alpha=-7,
    ),
    Err(alpha_msg),
  )
  assert_eq(
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=26,
      deblock_beta=7,
    ),
    Err(beta_msg),
  )
  assert_eq(
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      deblock=false,
      deblock_beta=1,
    ),
    Err(excl_msg),
  )
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      deblock_alpha=7,
    ) {
    Err(e) => assert_eq(e, alpha_msg)
    Ok(_) => fail("expected range error")
  }
  match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=26,
      deblock=false,
      deblock_beta=-1,
    ) {
    Err(e) => assert_eq(e, excl_msg)
    Ok(_) => fail("expected exclusivity error")
  }
  let bad_cfg = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    deblock_alpha: 7,
  }
  assert_eq(
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config=bad_cfg,
    ),
    Err(alpha_msg),
  )
}

///|
/// The streaming encoder produces a byte-identical stream to the batch
/// encoder with the same offsets and otherwise-default settings.
test "h264do: streaming equals batch with offsets" {
  let frames = h264dbg_fixture(32, 32, 4, 1)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=32,
      height=32,
      qp=26,
      b_slices=false,
      weightp=false,
      dct8x8=false,
      deblock_alpha=3,
      deblock_beta=-2,
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
      deblock_alpha=3,
      deblock_beta=-2,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for (y, u, v) in frames {
    match enc.push_frame(y, u, v) {
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
  assert_eq(h264s_concat(aus), batch)
}

///|
/// The facade forwards both offsets: the stream equals a direct batch
/// encode with the same values and differs from the default.
test "h264do: facade forwards the offsets" {
  let frames = h264dbg_fixture(96, 64, 3, 1)
  let cfg = {
    ..@libavcodec.VideoEncConfig::new(width=96, height=64),
    b_slices: false,
    deblock_alpha: 2,
    deblock_beta: -3,
  }
  let via_facade = match
    @libavcodec.video_encode(
      frames,
      codec=@libavcodec.VideoCodec::H264,
      config=cfg,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let direct = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
      deblock_alpha=2,
      deblock_beta=-3,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let default = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(mr_md5(via_facade), mr_md5(direct))
  assert_true(via_facade != default)
}
