///|
/// FFmpeg 9.0.2 does not conceal field pictures at all:
///
///   * `h264_slice.c` sets `pic->field_picture = h->picture_structure != PICT_FRAME`,
///   * `error_resilience.c:er_supported()` returns 0 when `s->cur_pic.field_picture`,
///   * `ff_er_frame_end()` returns immediately when `!er_supported(s)`, and the
///     function still carries the comment "We do not support ER of field
///     pictures yet".
///
/// Verified against the reference decoder: dropping one slice of a PAFF picture
/// prints neither `concealing ... errors` nor `corrupt decoded frame`, so
/// upstream emits an un-concealed frame whose missing macroblocks keep whatever
/// the buffer held. That output depends on decoder history and is not
/// reproducible, so the port reports an explicit error rather than inventing
/// pixels upstream never produced.
test "h264: field picture damaged slice is rejected because upstream has no recovery" {
  let data = @libavutil.av_base64_decode(jm_paff_b_slices_b64(), 1000000).unwrap()
  // Pictures after the IDR each carry five slices (first_mb_in_slice 0, 11, 22,
  // 33, 44); dropping any one of them leaves a gap inside a field picture.
  for target in [10, 15, 20, 25] {
    for conceal in [false, true] {
      let dec = new_h264_decoder()
      dec.set_error_concealment(conceal)
      match dec.decode_annexb(h264_drop_annexb_nal(data, target), false) {
        Ok(_) =>
          fail(
            "drop NAL \{target} (concealment \{conceal}) decoded instead of failing",
          )
        Err(error) => assert_eq(error, "incomplete H.264 picture")
      }
    }
  }
}

///|
test "h264: enabling concealment leaves intact field pictures untouched" {
  let data = @libavutil.av_base64_decode(jm_paff_b_slices_b64(), 1000000).unwrap()
  for conceal in [false, true] {
    let dec = new_h264_decoder()
    dec.set_error_concealment(conceal)
    let frames = dec.decode_annexb(data, false).unwrap()
    assert_eq(frames.length(), jm_paff_b_slices_md5.length())
    for i, frame in h264_display_order(frames) {
      assert_eq(h264_yuv_md5(frame), jm_paff_b_slices_md5[i])
      assert_eq(frame.damaged_macroblocks, 0)
    }
  }
}
