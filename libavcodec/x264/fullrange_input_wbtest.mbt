///|
/// §423a native full-range inputs: FFmpeg's deprecated `yuvj*` aliases are
/// the last pixel formats of libx264.c's pix_fmts_all the binding did not
/// accept. Same plane geometry as the limited-range planar formats; the
/// wrapper turns on VUI full-range signalling by itself (libx264.c
/// X264_init: pix_fmt == YUVJ* -> vui.b_fullrange = 1) and FFmpeg's decoder
/// exports it back (h264_slice.c: video_signal_type_present -> JPEG/MPEG
/// binary range, so the packed oracle must read AVCOL_RANGE_JPEG).
test "x264 full-range: yuvj 420/422/444 inputs signal full-range VUI" {
  // All three decode to the full-range alias of their planar layout
  // (video_signal_type present + full_range 1). A 4:4:4 stream would flip
  // to GBRP only if the colour description named RGB, which the default
  // (unspecified) colourspace never does.
  for (fmt, cf, kind) in [
    (Yuvj420p, 1, 0),
    (Yuvj422p, 2, 3),
    (Yuvj444p, 3, 5),
  ] {
    assert_true(x264_supports("libx264", fmt))
    // 420 subsamples both axes, so the luma width and height must both
    // be even; the same even geometry keeps the three formats comparable.
    let width = 34
    let height = 18
    let cw = if cf == 3 { width } else { width / 2 }
    let ch = if cf == 1 { height / 2 } else { height }
    let enc = X264Encoder::open(
      width~,
      height~,
      pix_fmt=fmt,
      global_header=false,
      options=[("preset", "medium"), ("qp", "20"), ("bf", "0")],
    )
    let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
    for f in 0..<3 {
      fn plane(n : Int32, seed : Int32) -> Bytes {
        Bytes::makei(n, i => ((i * 37 + seed * 53) % 256).to_byte())
      }
      frames.push(
        (
          f.to_int64(),
          plane(width * height, f),
          plane(cw * ch, f + 1),
          plane(cw * ch, f + 2),
        ),
      )
    }
    // The yuvj formats keep the planar layout, so a 420-sized chroma plane
    // must still be rejected for 422/444 inputs.
    if cf != 1 {
      try
        enc.send_frame(
          pts=0L,
          y=frames[0].1,
          u=Bytes::new(17 * 9),
          v=frames[0].3,
        )
      catch {
        SendFailed(_) => ()
        _ => fail("unexpected error variant")
      } noraise {
        _ => fail("420-sized chroma accepted for yuvj 422/444")
      }
    }
    let packets = enc.encode_all(frames)
    enc.close()
    let stream = x264_concat(packets)
    let oracle = match x264_probe_frames(stream) {
      Ok(p) => p
      Err(e) => fail(e)
    }
    assert_eq(oracle.n_frames, 3)
    assert_eq(oracle.warnings, 0)
    assert_eq(oracle.errors, 0)
    let packed = match x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    let decoded = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(packed.n_frames, 3)
    assert_eq(packed.kind, kind)
    assert_eq(packed.bytes_per_sample(), 1)
    // Full-range VUI: the wrapper derives it from the YUVJ format.
    assert_eq(packed.color_range, x264_color_range_jpeg)
    assert_eq(decoded.length(), 3)
    for i in 0..<3 {
      assert_eq(
        packed.frame_y(i) + packed.frame_u(i) + packed.frame_v(i),
        decoded[i].yuvp(),
      )
    }
  }
}

///|
/// §423a explicit colour metadata: an explicit range wins over the YUVJ
/// format (libx264.c checks color_range first), and the AVCOL_* /
/// AVCHROMA_LOC_* ints ride the SPS VUI out to the decoder. An explicit
/// AVCOL_RANGE_MPEG keeps vui.b_fullrange at x264's default (0), so the
/// stream carries no full-range signalling and the decoder export falls
/// back to UNSPECIFIED. A plain limited-range encode with no metadata
/// leaves every field untouched.
test "x264 colour metadata: explicit range overrides, VUI fields pass through" {
  // An explicit MPEG range cannot suppress the YUVJ full-range
  // signalling: encode.c's ff_encode_preinit force-rewrites
  // avctx->color_range = AVCOL_RANGE_JPEG for every selected yuvj format
  // before the wrapper's private init runs (the format IS the range in
  // FFmpeg 9's deprecated-alias semantics). The stream must therefore
  // still decode as full-range.
  let enc = X264Encoder::open(
    width=32,
    height=18,
    pix_fmt=Yuvj420p,
    global_header=false,
    color_range=x264_color_range_mpeg,
    options=[("preset", "ultrafast"), ("qp", "20"), ("bf", "0")],
  )
  let y = Bytes::makei(32 * 18, i => ((i * 29) % 256).to_byte())
  let c = Bytes::makei(16 * 9, i => ((i * 17 + 96) % 256).to_byte())
  let packets = enc.encode_all([(0L, y, c, c)])
  enc.close()
  let packed = match x264_decode_annexb(x264_concat(packets)) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(packed.n_frames, 1)
  assert_eq(packed.color_range, x264_color_range_jpeg)
  // Full-range signalling is a VUI detail only: the pixels round trip.
  assert_eq(packed.frame_y(0).length(), 32 * 18)

  // BT.709 colour description and centred chroma location pass through
  // the SPS VUI and come back off the decoded frames.
  let enc709 = X264Encoder::open(
    width=32,
    height=18,
    pix_fmt=Yuv420p,
    global_header=false,
    colorspace=x264_col_spc_bt709,
    color_primaries=x264_col_pri_bt709,
    color_trc=x264_col_trc_bt709,
    chroma_sample_location=x264_chroma_loc_center,
    options=[("preset", "ultrafast"), ("qp", "20"), ("bf", "0")],
  )
  let packets709 = enc709.encode_all([(0L, y, c, c)])
  enc709.close()
  let packed709 = match x264_decode_annexb(x264_concat(packets709)) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(packed709.n_frames, 1)
  // The colour description lives inside video_signal_type, so writing it
  // makes video_signal_type_present 1 and the decoder export collapses
  // the absent full_range_flag to the binary MPEG value (h264_slice.c:
  // full_range > 0 ? JPEG : MPEG).
  assert_eq(packed709.color_range, x264_color_range_mpeg)
  assert_eq(packed709.colorspace, x264_col_spc_bt709)
  assert_eq(packed709.color_primaries, x264_col_pri_bt709)
  assert_eq(packed709.color_trc, x264_col_trc_bt709)
  // chroma_loc_info_present with loc_type 1 -> decoded value loc_type+1.
  assert_eq(packed709.chroma_location, x264_chroma_loc_center)

  // No metadata, limited range: every colour field stays unspecified.
  let encPlain = X264Encoder::open(
    width=32,
    height=18,
    pix_fmt=Yuv420p,
    global_header=false,
    options=[("preset", "ultrafast"), ("qp", "20"), ("bf", "0")],
  )
  let packetsPlain = encPlain.encode_all([(0L, y, c, c)])
  encPlain.close()
  let packedPlain = match x264_decode_annexb(x264_concat(packetsPlain)) {
    Ok(d) => d
    Err(e) => fail(e)
  }
  assert_eq(packedPlain.n_frames, 1)
  // Even the metadata-free encode writes a VUI with video_signal_type
  // (video_format 5, full_range 0), and a present video_signal_type
  // collapses the range export to the binary MPEG value; only the
  // colour description fields stay unspecified without explicit input.
  assert_eq(packedPlain.color_range, x264_color_range_mpeg)
  // A fresh AVFrame initialises its colour fields to each type's own
  // UNSPECIFIED value (libavutil/frame.c: primaries/trc/colorspace = 2),
  // so fill_frame_props copies the context values across: x264 writes an
  // explicit colour_description with the spec's unspecified triple
  // (primaries/trc/matrix = 2, 2, 2), which lands verbatim.
  assert_eq(packedPlain.colorspace, x264_col_spc_unspecified)
  assert_eq(packedPlain.color_primaries, 2)
  assert_eq(packedPlain.color_trc, 2)
  // h264_slice.c exports chroma_location unconditionally, and a VUI
  // without chroma_loc_info parses to the spec default LEFT.
  assert_eq(packedPlain.chroma_location, x264_chroma_loc_left)
}
