///|
test "AV1 qmatrix key and inter frames match libdav1d" {
  check_session(qm_inter_ivf_b64, qm_inter_md5, "qmatrix")
}

///|
test "AV1 qmatrix level zero all-key frames match libdav1d" {
  check_session(qm_kf_ivf_b64, qm_kf_md5, "qmatrix-kf")
}

///|
test "AV1 qmatrix 10-bit and 12-bit inter frames match libdav1d" {
  check_session(qm_10bit_ivf_b64, qm_10bit_md5, "qmatrix-10bit")
  check_session(qm_12bit_ivf_b64, qm_12bit_md5, "qmatrix-12bit")
}

///|
test "AV1 qmatrix 422 444 and monochrome inter frames match libdav1d" {
  check_session(qm_422_ivf_b64, qm_422_md5, "qmatrix-422")
  check_session(qm_444_ivf_b64, qm_444_md5, "qmatrix-444")
  check_session(qm_mono_ivf_b64, qm_mono_md5, "qmatrix-mono")
}

///|
test "AV1 qmatrix 10-bit 444 inter frames match libdav1d" {
  check_session(qm_44410_ivf_b64, qm_44410_md5, "qmatrix-44410")
}

///|
test "AV1 qmatrix chroma delta quantization matches libdav1d" {
  check_session(qm_separate_ivf_b64, qm_separate_md5, "qmatrix-chroma-delta")
}

///|
test "AV1 qmatrix independent Y U V levels match libdav1d" {
  check_session(qm_planes_ivf_b64, qm_planes_md5, "qmatrix-planes")
  check_session(
    qm_plane_identity_ivf_b64, qm_plane_identity_md5, "qmatrix-plane-identity",
  )
}

///|
test "AV1 qmatrix frame header preserves levels and UV inference" {
  for
    item in [
      (qm_inter_ivf_b64, false, 5, 5, 5),
      (qm_identity_ivf_b64, false, 15, 15, 15),
      (qm_planes_ivf_b64, true, 3, 8, 12),
      (qm_plane_identity_ivf_b64, true, 0, 15, 7),
    ] {
    let (encoded, separate, y, u, v) = item
    let ivf = @libavutil.av_base64_decode(encoded, 1048576).unwrap()
    let size = ivf[32].to_int() |
      (ivf[33].to_int() << 8) |
      (ivf[34].to_int() << 16) |
      (ivf[35].to_int() << 24)
    let packet = ivf[44:44 + size].to_owned()
    let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
    let hdr = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
    assert_eq(seq.separate_uv_delta_q, separate)
    assert_true(hdr.using_qmatrix)
    assert_eq((hdr.qm_y, hdr.qm_u, hdr.qm_v), (y, u, v))
  }
}

///|
test "AV1 qmatrix identity level matches libdav1d" {
  check_session(qm_identity_ivf_b64, qm_identity_md5, "qmatrix-identity")
}

///|
test "AV1 qmatrix hidden and reordered frames match libdav1d" {
  check_session(qm_reorder_ivf_b64, qm_reorder_md5, "qmatrix-reorder")
}
