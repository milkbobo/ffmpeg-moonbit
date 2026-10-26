///|
/// Header-only prefixes of libaom testsrc2 160x120, cpu-used=6, crf=30,
/// aq-mode=1, lag-in-frames=0, g=30 (linuxserver/ffmpeg:9.0.2).
/// FFmpeg trace_headers: P2 primary_ref_frame=0, base_q_idx=120,
/// segmentation_enabled at payload bit 72 (OBU bit 96).
/// Regenerate: moon run scripts/emit_av1_segment_header_fixture.mbtx
fn av1_segment_key_header() -> Bytes {
  b"CgoAAAADtP9za+QBMiAUACBoAAAhCCACgN0wDgTn8QWYvqMTlW48pwezbr3MzA=="
}

///|
fn av1_segment_inter_payload() -> Bytes {
  b"MgIAggAAI0eACCBShJcFQADeCa+Fw1Lrwm+PAsBUBuY="
}
