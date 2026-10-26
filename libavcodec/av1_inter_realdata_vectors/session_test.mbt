///|
fn check_session(
  encoded : Bytes,
  expected : Array[String],
  name : String,
) -> Unit raise {
  let ivf = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
  let decoder = @libavcodec.Av1Decoder::new()
  let mut pos = 32
  let mut frame = 0
  while pos + 12 <= ivf.length() {
    let size = ivf[pos].to_int() |
      (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16) |
      (ivf[pos + 3].to_int() << 24)
    let packet = ivf[pos + 12:pos + 12 + size].to_owned()
    let output = match decoder.decode_packet(packet) {
      Ok(Some(p)) => p
      Ok(None) => {
        pos += 12 + size
        continue
      }
      Err(e) => fail("\{name} frame \{frame}: \{e}")
    }
    let packed = output.packed()
    let digest = FixedArray::make(16, b'\x00')
    @libavutil.av_md5_sum(digest, packed, packed.length())
    let text = StringBuilder()
    let hex = "0123456789abcdef"
    for byte in digest {
      text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
      text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
    }
    let hash = text.to_string()
    assert_eq(
      hash,
      expected[frame],
      msg="\{name} frame \{frame}: got \{hash}, want \{expected[frame]}",
    )
    frame += 1
    pos += 12 + size
  }
  assert_eq(frame, expected.length())
}

///|
test "AV1 key and seven P frames match libdav1d" {
  check_session(session_ivf_b64, session_md5, "P8")
}

///|
test "AV1 inter tiles share projected motion and preserve row boundaries" {
  check_session(inter_tiles_ivf_b64, inter_tiles_md5, "tiles")
}

///|
test "AV1 10-bit inter frames match libdav1d" {
  check_session(inter_10bit_ivf_b64, inter_10bit_md5, "10-bit")
}

///|
test "AV1 frame global motion matches libdav1d" {
  check_session(inter_global_ivf_b64, inter_global_md5, "global")
}

///|
test "AV1 hidden and show-existing frames match libdav1d" {
  check_session(inter_reorder_ivf_b64, inter_reorder_md5, "reorder")
}

///|
test "AV1 fixed-denom superres inter frames match libdav1d" {
  check_session(superres_inter_ivf_b64, superres_inter_md5, "superres")
}

///|
test "AV1 all-keyframe superres (denom 9) matches libdav1d" {
  check_session(superres_kf_ivf_b64, superres_kf_md5, "superres-kf")
}

///|
test "AV1 10-bit superres frames match libdav1d" {
  check_session(superres_10bit_ivf_b64, superres_10bit_md5, "superres-10bit")
}

///|
test "AV1 random-denom superres frames match libdav1d" {
  check_session(superres_mixed_ivf_b64, superres_mixed_md5, "superres-mixed")
}

///|
test "AV1 session rejects incomplete packets and returns saved key pictures" {
  let decoder = @libavcodec.Av1Decoder::new()
  assert_true(decoder.decode_packet(b"\x80") is Err(_))
  assert_true(decoder.decode_packet(b"\x1a\x80") is Err(_))
  assert_true(decoder.decode_packet(b"\x1a\x01\x80") is Err(_))
  let ivf = @libavutil.av_base64_decode(session_ivf_b64, 1048576).unwrap()
  let size = ivf[32].to_int() |
    (ivf[33].to_int() << 8) |
    (ivf[34].to_int() << 16) |
    (ivf[35].to_int() << 24)
  let key = decoder
    .decode_packet(ivf[44:44 + size].to_owned())
    .unwrap()
    .unwrap()
  // FRAME_HEADER OBU: show_existing_frame=1, frame_to_show_map_idx=0.
  let saved = decoder.decode_packet(b"\x1a\x01\x80").unwrap().unwrap()
  assert_eq(saved.packed(), key.packed())
  // A rejected packet must not destroy the completed reference.
  assert_true(decoder.decode_packet(b"\x1a\x7f") is Err(_))
  assert_eq(
    decoder.decode_packet(b"\x1a\x01\x80").unwrap().unwrap().packed(),
    key.packed(),
  )
}
