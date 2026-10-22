///|
test "vp9 public decoder: empty state and unsupported display reference" {
  let decoder = @libavcodec.vp9_decoder_new()
  assert_eq(decoder.frame_bytes().length(), 0)
  match decoder.decode_frame(b"\x88") {
    Ok(_) => fail("show_existing_frame must be rejected")
    Err(e) => assert_eq(e, "vp9: show_existing_frame not supported")
  }
}
