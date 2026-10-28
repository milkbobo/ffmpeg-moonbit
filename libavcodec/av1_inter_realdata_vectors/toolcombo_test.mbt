///|
test "AV1 interintra family (wedge/smooth) matches libdav1d" {
  check_session(tool_iic_ivf_b64, tool_iic_md5, "tool-iic")
}

///|
test "AV1 masked compound matches libdav1d" {
  check_session(tool_masked_ivf_b64, tool_masked_md5, "tool-masked")
}

///|
test "AV1 OBMC and local warp match libdav1d" {
  check_session(tool_obmc_ivf_b64, tool_obmc_md5, "tool-obmc")
}

///|
test "AV1 dual filter and ref-frame-mvs match libdav1d" {
  check_session(tool_rf_mvs_ivf_b64, tool_rf_mvs_md5, "tool-rf-mvs")
}

///|
test "AV1 all inter tools together match libdav1d" {
  check_session(tool_all_ivf_b64, tool_all_md5, "tool-all")
}
