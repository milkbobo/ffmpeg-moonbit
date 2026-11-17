///|
/// `§423`: run the shared H.264 deblocking filter over a finished encoder
/// reconstruction. The encoder reconstructs exactly like a conforming decoder,
/// so filtering the completed picture in macroblock raster order reproduces
/// FFmpeg's row-by-row `loop_filter()` (which never reads rows below the edge,
/// and intra prediction never sees filtered neighbours). The filtered planes
/// are what the decoder will output and must be what the encoder keeps as the
/// reference for following pictures.
fn h264_enc_deblock_picture(
  rec_y : Array[Int32],
  rec_u : Array[Int32],
  rec_v : Array[Int32],
  ystride : Int32,
  cstride : Int32,
  mb_width : Int32,
  mb_height : Int32,
  infos : Array[H264MbInfo],
  pps : H264Pps,
  bit_depth : Int32,
  /// `§433`: slice-level offsets in div2 units; the filter tables index
  /// `qp + 52 + 2*offset` exactly like the decoder's per-MB
  /// `alpha_offset`/`beta_offset` (`h264_picture_slice.mbt`).
  alpha~ : Int32 = 0,
  beta~ : Int32 = 0,
) -> Unit {
  let chroma_format = pps.chroma_format
  let chroma_hshift = if chroma_format <= 2 { 1 } else { 0 }
  let chroma_vshift = if chroma_format == 1 { 1 } else { 0 }
  // The deblock's bS=1 test compares reference-picture identity, not the
  // coded index: two blocks naming the same picture must compare equal and
  // two different pictures must not. The encoder's reference lists hold
  // distinct pictures (no reordering aliases), so the coded index seeds a
  // per-list namespace. L0 and L1 are kept disjoint because the swapped
  // comparison in `h264_bs_pair` matches L0 of one side against L1 of the
  // other.
  for info in infos {
    for i = 0; i < 16; i = i + 1 {
      info.ref_identity[i] = if info.ref_idx[i] >= 0 {
        info.ref_idx[i] * 8 + 3
      } else {
        -1
      }
      info.ref_identity1[i] = if info.ref_idx1[i] >= 0 {
        info.ref_idx1[i] * 8 + 7
      } else {
        -1
      }
    }
  }
  // Progressive frame pictures only: the encoder never codes fields or MBAFF
  // pairs, so the field/MBAFF fields take their frame defaults and the
  // reference buffers map is empty.
  let ctx : H264DecCtx = {
    bit_depth,
    chroma_format,
    chroma_hshift,
    chroma_vshift,
    si_slice: false,
    active_list: 0,
    ref_list1: [],
    ref_count1: 0,
    direct_spatial: true,
    direct_8x8: true,
    colocated: [],
    reference_buffers: Map([]),
    colocated_mbaff: false,
    colocated_field_picture: false,
    poc: 0,
    poc_top: 0,
    poc_bottom: 0,
    long_pocs: [],
    slice_num: 0,
    pps,
    mb_width,
    mb_height,
    field_picture: false,
    bottom_field: false,
    mb_aff: false,
    mb_field: false,
    prev_mb_skipped: false,
    next_mb_skipped: false,
    y: rec_y,
    u: rec_u,
    v: rec_v,
    ystride,
    cstride,
    infos,
    failed_mb: -1,
    qscale: 0,
    last_qscale_diff: 0,
    slice_type_nos: 2,
    cur_mb_is_intra: true,
    ref_count0: 0,
    ref_list0: [],
    mb_skip_run: -1,
    pwt: new_h264_pred_weight(),
  }
  for i = 0; i < mb_width * mb_height; i = i + 1 {
    // FFmpeg's filter indexes the tables with `qp + 52 + offset`
    // (`h264_loopfilter.c`); `52` is the neutral base the decoder's
    // `H264MbInfo` defaults carry, and the slice-level div2 offsets ride on
    // top of it (`§433`; both stay 0 when the PPS has no deblocking control).
    h264_filter_mb(
      ctx,
      i,
      i % mb_width,
      i / mb_width,
      52 + 2 * alpha,
      52 + 2 * beta,
    )
  }
}

///|
/// `§433`: validate the slice-level deblocking offsets (div2 units, the
/// spec's -6..=6 range for both `slice_alpha_c0_offset_div2` and
/// `slice_beta_offset_div2`). Nonzero offsets need the in-loop filter on:
/// with `deblock=false` the encoder would keep unfiltered references while
/// the stream tells decoders to filter at a non-neutral strength.
fn h264_enc_deblock_offsets_ok(
  deblock : Bool,
  alpha : Int32,
  beta : Int32,
) -> Result[Unit, String] {
  if alpha < -6 || alpha > 6 {
    return Err("h264 enc: deblock_alpha must be in -6..=6")
  }
  if beta < -6 || beta > 6 {
    return Err("h264 enc: deblock_beta must be in -6..=6")
  }
  if !deblock && (alpha != 0 || beta != 0) {
    return Err("h264 enc: deblock offsets require deblock=true")
  }
  Ok(())
}

///|
/// Build the deblock-facing `H264MbInfo` view of a CAVLC intra picture from
/// the encoder's per-macroblock state. Every macroblock is intra, so only the
/// nz counts, the extended QP and the 8x8-transform flag matter.
fn h264_enc_infos_from_intra(
  states : Array[H264EncMbState],
) -> Array[H264MbInfo] {
  let infos : Array[H264MbInfo] = []
  for st in states {
    let info = h264_new_mb_info()
    info.mb_type_bits = h264_mb_type_intra4x4
    info.transform_8x8 = st.transform_8x8
    info.qp = st.qp
    for i = 0; i < 48; i = i + 1 {
      info.nz[i] = st.nz[i]
    }
    infos.push(info)
  }
  infos
}

///|
/// Build the deblock-facing `H264MbInfo` view of a CAVLC P picture. The
/// helper fills the reference identities from the coded indices; only the nz
/// counts, the extended QP, the 8x8-transform flag and the per-block motion
/// need lifting out of the encoder's per-macroblock state.
fn h264_enc_infos_from_p(states : Array[H264PMbState]) -> Array[H264MbInfo] {
  let infos : Array[H264MbInfo] = []
  for st in states {
    let info = h264_new_mb_info()
    info.mb_type_bits = if st.intra {
      h264_mb_type_intra16x16
    } else if st.has_data {
      h264_mb_type_16x16
    } else {
      h264_mb_type_skip
    }
    info.transform_8x8 = st.tf8
    info.qp = st.qp
    for i = 0; i < 48; i = i + 1 {
      info.nz[i] = st.nz[i]
    }
    for i = 0; i < 16; i = i + 1 {
      info.ref_idx[i] = st.ref_idx[i]
      info.mv[2 * i] = st.mv[2 * i]
      info.mv[2 * i + 1] = st.mv[2 * i + 1]
    }
    infos.push(info)
  }
  infos
}
