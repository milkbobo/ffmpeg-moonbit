///|
test "AV1 resize-mode keyframe-to-inter downscale matches libdav1d" {
  check_session(resize_up_ivf_b64, resize_up_md5, "resize-up")
}

///|
test "AV1 resize-mode 10-bit matches libdav1d" {
  check_session(resize_10bit_ivf_b64, resize_10bit_md5, "resize-10bit")
}

///|
test "AV1 resize-mode random per-frame sizes match libdav1d" {
  check_session(resize_random_ivf_b64, resize_random_md5, "resize-random")
}

///|
test "AV1 resize-mode qmatrix combination matches libdav1d" {
  check_session(resize_qm_ivf_b64, resize_qm_md5, "resize-qm")
}

///|
test "AV1 resize-mode constant-size controls match libdav1d" {
  // Fixed mode with a single denominator left these streams at the source
  // size; they still exercise non-uniform tile parsing, 4:2:0 444 layouts
  // and hidden alt-ref frames through the resize-mode encode path.
  check_session(resize_down_ivf_b64, resize_down_md5, "resize-constant-420")
  check_session(resize_444_ivf_b64, resize_444_md5, "resize-constant-444")
  check_session(resize_lag_ivf_b64, resize_lag_md5, "resize-constant-lag")
}
