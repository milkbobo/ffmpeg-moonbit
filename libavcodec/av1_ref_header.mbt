///|
/// Retain the reference header fields consumed by dav1d's obu.c. Segment
/// feature arrays, filter deltas and GM matrices are copied so parsing a
/// later frame cannot mutate the saved reference state.
pub fn av1_ref_slot_state_from_header(hdr : Av1FrameHeader) -> Av1RefSlotState {
  let saved : Av1FrameHeader = {
    ..hdr,
    segmentation_feature_mask: hdr.segmentation_feature_mask.copy(),
    segmentation_alt_q: hdr.segmentation_alt_q.copy(),
    seg_ref: hdr.seg_ref.copy(),
    seg_skip: hdr.seg_skip.copy(),
    seg_globalmv: hdr.seg_globalmv.copy(),
    seg_delta_lf: hdr.seg_delta_lf.copy(),
    loop_filter_ref_deltas: hdr.loop_filter_ref_deltas.copy(),
    loop_filter_mode_deltas: hdr.loop_filter_mode_deltas.copy(),
  }
  {
    order_hint: hdr.order_hint,
    upscaled_width: hdr.upscaled_width,
    height: hdr.height,
    render_width: hdr.render_width,
    render_height: hdr.render_height,
    gm_types: hdr.gm_types.copy(),
    gm_matrices: hdr.gm_matrices.map(m => m.copy()),
    header: Some(saved),
  }
}
