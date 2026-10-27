///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/hevc/ps.c` (+ `ps.h`), the HEVC
/// VPS/SPS/PPS parameter set parser, and the extradata walker of
/// `libavcodec/hevc/parse.c` (`ff_hevc_decode_extradata`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope / deviations from the C:
///   * Multilayer HEVC (VPS extension, SPS/PPS multilayer and 3D extensions)
///     is not modelled: a VPS advertising more than one layer and any PPS with
///     the multilayer/3D extension flag returns "PATCHWELCOME". Base-layer,
///     Main/Main10/RExt/SCC syntax is parsed.
///   * HRD parameters are consumed bit-exactly but their arrays are not
///     stored (no decoder-side consumer yet).
///   * `setup_pps` (tile scan-order maps) and the derived pixel-format enum
///     are replaced by the FFmpeg pixel-format name string plus the
///     `hshift`/`vshift`/`pixel_shift`/`qp_bd_offset` fields it implies.
///   * `AVCodecContext` knobs (IGNORE_CROP, err_recognition EXPLODE, debug
///     logging) are not modelled.
///   * The VUI alternate-syntax retry (broken streams with misplaced timing
///     info) is not implemented; normal VUI layouts parse as in the C.

// ---------------------------------------------------------------------------
// limits
// ---------------------------------------------------------------------------

///|
/// `HEVC_MAX_SUB_LAYERS`. */
let hevc_max_sub_layers : Int32 = 7

///|
/// `HEVC_MAX_VPS_COUNT`. */
pub let hevc_max_vps_count : Int32 = 16

///|
/// `HEVC_MAX_SPS_COUNT`. */
pub let hevc_max_sps_count : Int32 = 16

///|
/// `HEVC_MAX_PPS_COUNT`. */
pub let hevc_max_pps_count : Int32 = 64

///|
/// `HEVC_MAX_DPB_SIZE`. */
let hevc_max_dpb_size : Int32 = 16

///|
/// `HEVC_MAX_REFS`. */
let hevc_max_refs : Int32 = 16

///|
/// `HEVC_MAX_SHORT_TERM_REF_PIC_SETS`. */
let hevc_max_short_term_rps : Int32 = 64

///|
/// `HEVC_MAX_LONG_TERM_REF_PICS`. */
let hevc_max_long_term_ref_pics : Int32 = 32

///|
/// `HEVC_MAX_LOG2_CTB_SIZE`. */
let hevc_max_log2_ctb_size : Int32 = 6

///|
/// `HEVC_MAX_CPB_CNT`. */
let hevc_max_cpb_cnt : Int32 = 32

///|
/// `AV_PROFILE_HEVC_REXT`. */
let av_profile_hevc_rext : Int32 = 4

///|
/// `HEVC_MAX_PALETTE_PREDICTOR_SIZE`. */
let hevc_max_palette_predictor_size : Int32 = 128

// ---------------------------------------------------------------------------
// tables
// ---------------------------------------------------------------------------

///|
/// `default_scaling_list_intra[64]`. */
let default_scaling_list_intra : Array[Int32] = [
  16, 16, 16, 16, 17, 18, 21, 24, 16, 16, 16, 16, 17, 19, 22, 25, 16, 16, 17, 18,
  20, 22, 25, 29, 16, 16, 18, 21, 24, 27, 31, 36, 17, 17, 20, 24, 30, 35, 41, 47,
  18, 19, 22, 27, 35, 44, 54, 65, 21, 22, 25, 31, 41, 54, 70, 88, 24, 25, 29, 36,
  47, 65, 88, 115,
]

///|
/// `default_scaling_list_inter[64]`. */
let default_scaling_list_inter : Array[Int32] = [
  16, 16, 16, 16, 17, 18, 20, 24, 16, 16, 16, 17, 18, 20, 24, 25, 16, 16, 17, 18,
  20, 24, 25, 28, 16, 17, 18, 20, 24, 25, 28, 33, 17, 18, 20, 24, 25, 28, 33, 41,
  18, 20, 24, 25, 28, 33, 41, 54, 20, 24, 25, 28, 33, 41, 54, 71, 24, 25, 28, 33,
  41, 54, 71, 91,
]

///|
/// `hevc_sub_width_c[4]`. */
let hevc_sub_width_c : Array[Int32] = [1, 2, 2, 1]

///|
/// `hevc_sub_height_c[4]`. */
let hevc_sub_height_c : Array[Int32] = [1, 2, 1, 1]

///|
/// `ff_hevc_diag_scan4x4_x`. */
let hevc_diag_scan4x4_x : Array[Int32] = [
  0, 0, 1, 0, 1, 2, 0, 1, 2, 3, 1, 2, 3, 2, 3, 3,
]

///|
/// `ff_hevc_diag_scan4x4_y`. */
let hevc_diag_scan4x4_y : Array[Int32] = [
  0, 1, 0, 2, 1, 0, 3, 2, 1, 0, 3, 2, 1, 3, 2, 3,
]

///|
/// `ff_hevc_diag_scan8x8_x`. */
let hevc_diag_scan8x8_x : Array[Int32] = [
  0, 0, 1, 0, 1, 2, 0, 1, 2, 3, 0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5,
  6, 0, 1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 2, 3, 4, 5, 6, 7, 3, 4, 5, 6, 7,
  4, 5, 6, 7, 5, 6, 7, 6, 7, 7,
]

///|
/// `ff_hevc_diag_scan8x8_y`. */
let hevc_diag_scan8x8_y : Array[Int32] = [
  0, 1, 0, 2, 1, 0, 3, 2, 1, 0, 4, 3, 2, 1, 0, 5, 4, 3, 2, 1, 0, 6, 5, 4, 3, 2, 1,
  0, 7, 6, 5, 4, 3, 2, 1, 0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 7, 6, 5, 4, 3,
  7, 6, 5, 4, 7, 6, 5, 7, 6, 7,
]

// ---------------------------------------------------------------------------
// structures
// ---------------------------------------------------------------------------

///|
/// `PTLCommon`. */
pub struct HevcPtlCommon {
  mut profile_space : Int32
  mut tier_flag : Int32
  mut profile_idc : Int32
  profile_compatibility_flag : Array[Int32]
  mut progressive_source_flag : Int32
  mut interlaced_source_flag : Int32
  mut non_packed_constraint_flag : Int32
  mut frame_only_constraint_flag : Int32
  mut max_12bit_constraint_flag : Int32
  mut max_10bit_constraint_flag : Int32
  mut max_8bit_constraint_flag : Int32
  mut max_422chroma_constraint_flag : Int32
  mut max_420chroma_constraint_flag : Int32
  mut max_monochrome_constraint_flag : Int32
  mut intra_constraint_flag : Int32
  mut one_picture_only_constraint_flag : Int32
  mut lower_bit_rate_constraint_flag : Int32
  mut max_14bit_constraint_flag : Int32
  mut inbld_flag : Int32
  mut level_idc : Int32
}

///|
/// Zero-initialised `PTLCommon`. */
fn new_hevc_ptl_common() -> HevcPtlCommon {
  {
    profile_space: 0,
    tier_flag: 0,
    profile_idc: 0,
    profile_compatibility_flag: Array::make(32, 0),
    progressive_source_flag: 0,
    interlaced_source_flag: 0,
    non_packed_constraint_flag: 0,
    frame_only_constraint_flag: 0,
    max_12bit_constraint_flag: 0,
    max_10bit_constraint_flag: 0,
    max_8bit_constraint_flag: 0,
    max_422chroma_constraint_flag: 0,
    max_420chroma_constraint_flag: 0,
    max_monochrome_constraint_flag: 0,
    intra_constraint_flag: 0,
    one_picture_only_constraint_flag: 0,
    lower_bit_rate_constraint_flag: 0,
    max_14bit_constraint_flag: 0,
    inbld_flag: 0,
    level_idc: 0,
  }
}

///|
/// `PTL`. */
pub struct HevcPtl {
  general_ptl : HevcPtlCommon
  sub_layer_ptl : Array[HevcPtlCommon]
  sub_layer_profile_present_flag : Array[Int32]
  sub_layer_level_present_flag : Array[Int32]
}

///|
/// Zero-initialised `PTL`. */
fn new_hevc_ptl() -> HevcPtl {
  {
    general_ptl: new_hevc_ptl_common(),
    sub_layer_ptl: [
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
      new_hevc_ptl_common(),
    ],
    sub_layer_profile_present_flag: Array::make(7, 0),
    sub_layer_level_present_flag: Array::make(7, 0),
  }
}

///|
/// `HEVCWindow`. */
pub struct HevcWindow {
  mut left_offset : Int32
  mut right_offset : Int32
  mut top_offset : Int32
  mut bottom_offset : Int32
}

///|
/// Zero window. */
fn new_hevc_window() -> HevcWindow {
  { left_offset: 0, right_offset: 0, top_offset: 0, bottom_offset: 0, }
}

///|
/// `ShortTermRPS`. */
pub struct HevcStRps {
  mut delta_poc : Array[Int32]
  mut used : UInt32
  mut delta_idx : Int32
  mut num_negative_pics : Int32
  mut num_delta_pocs : Int32
  mut rps_idx_num_delta_pocs : Int32
  mut abs_delta_rps : Int32
  mut delta_rps_sign : Int32
  mut rps_predict : Int32
  mut use_delta : Int32
}

///|
/// Zero `ShortTermRPS`. */
fn new_hevc_st_rps() -> HevcStRps {
  {
    delta_poc: Array::make(32, 0),
    used: 0U,
    delta_idx: 0,
    num_negative_pics: 0,
    num_delta_pocs: 0,
    rps_idx_num_delta_pocs: 0,
    abs_delta_rps: 0,
    delta_rps_sign: 0,
    rps_predict: 0,
    use_delta: 0,
  }
}

///|
/// `VUI` (HEVC-specific fields on top of the H.264/HEVC common part). */
pub struct HevcVui {
  common : H2645Vui
  mut neutra_chroma_indication_flag : Int32
  mut field_seq_flag : Int32
  mut frame_field_info_present_flag : Int32
  mut default_display_window_flag : Int32
  def_disp_win : HevcWindow
  mut vui_timing_info_present_flag : Int32
  mut vui_num_units_in_tick : Int32
  mut vui_time_scale : Int32
  mut vui_poc_proportional_to_timing_flag : Int32
  mut vui_num_ticks_poc_diff_one_minus1 : Int32
  mut vui_hrd_parameters_present_flag : Int32
  mut bitstream_restriction_flag : Int32
  mut tiles_fixed_structure_flag : Int32
  mut motion_vectors_over_pic_boundaries_flag : Int32
  mut restricted_ref_pic_lists_flag : Int32
  mut min_spatial_segmentation_idc : Int32
  mut max_bytes_per_pic_denom : Int32
  mut max_bits_per_min_cu_denom : Int32
  mut log2_max_mv_length_horizontal : Int32
  mut log2_max_mv_length_vertical : Int32
}

///|
/// Zero `VUI`. */
fn new_hevc_vui() -> HevcVui {
  {
    common: new_h2645_vui(),
    neutra_chroma_indication_flag: 0,
    field_seq_flag: 0,
    frame_field_info_present_flag: 0,
    default_display_window_flag: 0,
    def_disp_win: new_hevc_window(),
    vui_timing_info_present_flag: 0,
    vui_num_units_in_tick: 0,
    vui_time_scale: 0,
    vui_poc_proportional_to_timing_flag: 0,
    vui_num_ticks_poc_diff_one_minus1: 0,
    vui_hrd_parameters_present_flag: 0,
    bitstream_restriction_flag: 0,
    tiles_fixed_structure_flag: 0,
    motion_vectors_over_pic_boundaries_flag: 0,
    restricted_ref_pic_lists_flag: 0,
    min_spatial_segmentation_idc: 0,
    max_bytes_per_pic_denom: 0,
    max_bits_per_min_cu_denom: 0,
    log2_max_mv_length_horizontal: 0,
    log2_max_mv_length_vertical: 0,
  }
}

///|
/// `ScalingList`. */
pub struct HevcScalingList {
  sl : Array[Array[Array[Int32]]]
  sl_dc : Array[Array[Int32]]
}

///|
/// Zero `ScalingList`. */
fn new_hevc_scaling_list() -> HevcScalingList {
  {
    sl: [make_matrix6(64), make_matrix6(64), make_matrix6(64), make_matrix6(64)],
    sl_dc: [Array::make(6, 0), Array::make(6, 0)],
  }
}

///|
/// Six independent `n`-entry rows. */
fn make_matrix6(n : Int32) -> Array[Array[Int32]] {
  [
    Array::make(n, 0),
    Array::make(n, 0),
    Array::make(n, 0),
    Array::make(n, 0),
    Array::make(n, 0),
    Array::make(n, 0),
  ]
}

///|
/// `HEVCVPS` (base-layer fields; HRD arrays and multilayer data omitted). */
pub struct HevcVps {
  mut vps_id : Int32
  mut vps_temporal_id_nesting_flag : Int32
  mut vps_max_layers : Int32
  mut vps_max_sub_layers : Int32
  ptl : HevcPtl
  mut vps_sub_layer_ordering_info_present_flag : Int32
  vps_max_dec_pic_buffering : Array[Int32]
  vps_num_reorder_pics : Array[Int32]
  vps_max_latency_increase : Array[Int32]
  mut vps_max_layer_id : Int32
  mut vps_num_layer_sets : Int32
  mut vps_timing_info_present_flag : Int32
  mut vps_num_units_in_tick : Int32
  mut vps_time_scale : Int32
  mut vps_poc_proportional_to_timing_flag : Int32
  mut vps_num_ticks_poc_diff_one : Int32
  mut vps_num_hrd_parameters : Int32
  mut data : Bytes
  mut data_size : Int32
}

///|
/// Zero `HEVCVPS`. */
fn new_hevc_vps() -> HevcVps {
  {
    vps_id: 0,
    vps_temporal_id_nesting_flag: 0,
    vps_max_layers: 0,
    vps_max_sub_layers: 0,
    ptl: new_hevc_ptl(),
    vps_sub_layer_ordering_info_present_flag: 0,
    vps_max_dec_pic_buffering: Array::make(7, 0),
    vps_num_reorder_pics: Array::make(7, 0),
    vps_max_latency_increase: Array::make(7, 0),
    vps_max_layer_id: 0,
    vps_num_layer_sets: 0,
    vps_timing_info_present_flag: 0,
    vps_num_units_in_tick: 0,
    vps_time_scale: 0,
    vps_poc_proportional_to_timing_flag: 0,
    vps_num_ticks_poc_diff_one: 0,
    vps_num_hrd_parameters: 0,
    data: b"",
    data_size: 0,
  }
}

///|
/// `HEVCSPS` (decoder layout tables are derived from these fields). */
pub struct HevcSps {
  mut vps_id : Int32
  mut chroma_format_idc : Int32
  output_window : HevcWindow
  pic_conf_win : HevcWindow
  mut bit_depth : Int32
  mut bit_depth_chroma : Int32
  mut pixel_shift : Bool
  mut pix_fmt : String
  mut log2_max_poc_lsb : Int32
  mut max_sub_layers : Int32
  max_dec_pic_buffering : Array[Int32]
  num_reorder_pics : Array[Int32]
  max_latency_increase : Array[Int32]
  mut vui_present : Int32
  vui : HevcVui
  ptl : HevcPtl
  scaling_list : HevcScalingList
  mut nb_st_rps : Int32
  st_rps : Array[HevcStRps]
  lt_ref_pic_poc_lsb_sps : Array[Int32]
  mut used_by_curr_pic_lt : UInt32
  mut num_long_term_ref_pics_sps : Int32
  mut pcm_bit_depth : Int32
  mut pcm_bit_depth_chroma : Int32
  mut pcm_log2_min_cb_size : Int32
  mut pcm_log2_max_cb_size : Int32
  mut log2_min_cb_size : Int32
  mut log2_diff_max_min_coding_block_size : Int32
  mut log2_min_tb_size : Int32
  mut log2_max_trafo_size : Int32
  mut log2_ctb_size : Int32
  mut log2_min_pu_size : Int32
  mut log2_diff_max_min_transform_block_size : Int32
  mut max_transform_hierarchy_depth_inter : Int32
  mut max_transform_hierarchy_depth_intra : Int32
  mut separate_colour_plane : Int32
  mut conformance_window : Int32
  mut pcm_enabled : Int32
  mut pcm_loop_filter_disabled : Int32
  mut sublayer_ordering_info : Int32
  mut temporal_id_nesting : Int32
  mut extension_present : Int32
  mut scaling_list_enabled : Int32
  mut amp_enabled : Int32
  mut sao_enabled : Int32
  mut long_term_ref_pics_present : Int32
  mut temporal_mvp_enabled : Int32
  mut strong_intra_smoothing_enabled : Int32
  mut range_extension : Int32
  mut transform_skip_rotation_enabled : Int32
  mut transform_skip_context_enabled : Int32
  mut implicit_rdpcm_enabled : Int32
  mut explicit_rdpcm_enabled : Int32
  mut extended_precision_processing : Int32
  mut intra_smoothing_disabled : Int32
  mut high_precision_offsets_enabled : Int32
  mut persistent_rice_adaptation_enabled : Int32
  mut cabac_bypass_alignment_enabled : Int32
  mut multilayer_extension : Int32
  mut sps_3d_extension : Int32
  mut scc_extension : Int32
  mut curr_pic_ref_enabled : Int32
  mut palette_mode_enabled : Int32
  mut palette_predictor_initializers_present : Int32
  mut intra_boundary_filtering_disabled : Int32
  mut palette_max_size : Int32
  mut delta_palette_max_predictor_size : Int32
  mut sps_num_palette_predictor_initializers : Int32
  sps_palette_predictor_initializer : Array[Array[Int32]]
  mut motion_vector_resolution_control_idc : Int32
  mut width : Int32
  mut height : Int32
  mut ctb_width : Int32
  mut ctb_height : Int32
  mut ctb_size : Int32
  mut min_cb_width : Int32
  mut min_cb_height : Int32
  mut min_tb_width : Int32
  mut min_tb_height : Int32
  mut min_pu_width : Int32
  mut min_pu_height : Int32
  mut tb_mask : Int32
  hshift : Array[Int32]
  vshift : Array[Int32]
  mut qp_bd_offset : Int32
  mut data : Bytes
  mut data_size : Int32
}

///|
/// Zero `HEVCSPS`. */
fn new_hevc_sps() -> HevcSps {
  {
    vps_id: 0,
    chroma_format_idc: 0,
    output_window: new_hevc_window(),
    pic_conf_win: new_hevc_window(),
    bit_depth: 0,
    bit_depth_chroma: 0,
    pixel_shift: false,
    pix_fmt: "",
    log2_max_poc_lsb: 0,
    max_sub_layers: 0,
    max_dec_pic_buffering: Array::make(7, 0),
    num_reorder_pics: Array::make(7, 0),
    max_latency_increase: Array::make(7, 0),
    vui_present: 0,
    vui: new_hevc_vui(),
    ptl: new_hevc_ptl(),
    scaling_list: new_hevc_scaling_list(),
    nb_st_rps: 0,
    st_rps: make_st_rps_array(),
    lt_ref_pic_poc_lsb_sps: Array::make(32, 0),
    used_by_curr_pic_lt: 0U,
    num_long_term_ref_pics_sps: 0,
    pcm_bit_depth: 0,
    pcm_bit_depth_chroma: 0,
    pcm_log2_min_cb_size: 0,
    pcm_log2_max_cb_size: 0,
    log2_min_cb_size: 0,
    log2_diff_max_min_coding_block_size: 0,
    log2_min_tb_size: 0,
    log2_max_trafo_size: 0,
    log2_ctb_size: 0,
    log2_min_pu_size: 0,
    log2_diff_max_min_transform_block_size: 0,
    max_transform_hierarchy_depth_inter: 0,
    max_transform_hierarchy_depth_intra: 0,
    separate_colour_plane: 0,
    conformance_window: 0,
    pcm_enabled: 0,
    pcm_loop_filter_disabled: 0,
    sublayer_ordering_info: 0,
    temporal_id_nesting: 0,
    extension_present: 0,
    scaling_list_enabled: 0,
    amp_enabled: 0,
    sao_enabled: 0,
    long_term_ref_pics_present: 0,
    temporal_mvp_enabled: 0,
    strong_intra_smoothing_enabled: 0,
    range_extension: 0,
    transform_skip_rotation_enabled: 0,
    transform_skip_context_enabled: 0,
    implicit_rdpcm_enabled: 0,
    explicit_rdpcm_enabled: 0,
    extended_precision_processing: 0,
    intra_smoothing_disabled: 0,
    high_precision_offsets_enabled: 0,
    persistent_rice_adaptation_enabled: 0,
    cabac_bypass_alignment_enabled: 0,
    multilayer_extension: 0,
    sps_3d_extension: 0,
    scc_extension: 0,
    curr_pic_ref_enabled: 0,
    palette_mode_enabled: 0,
    palette_predictor_initializers_present: 0,
    intra_boundary_filtering_disabled: 0,
    palette_max_size: 0,
    delta_palette_max_predictor_size: 0,
    sps_num_palette_predictor_initializers: 0,
    sps_palette_predictor_initializer: [
      Array::make(hevc_max_palette_predictor_size, 0),
      Array::make(hevc_max_palette_predictor_size, 0),
      Array::make(hevc_max_palette_predictor_size, 0),
    ],
    motion_vector_resolution_control_idc: 0,
    width: 0,
    height: 0,
    ctb_width: 0,
    ctb_height: 0,
    ctb_size: 0,
    min_cb_width: 0,
    min_cb_height: 0,
    min_tb_width: 0,
    min_tb_height: 0,
    min_pu_width: 0,
    min_pu_height: 0,
    tb_mask: 0,
    hshift: Array::make(3, 0),
    vshift: Array::make(3, 0),
    qp_bd_offset: 0,
    data: b"",
    data_size: 0,
  }
}

///|
/// 64 independent short-term RPS entries. */
fn make_st_rps_array() -> Array[HevcStRps] {
  let a : Array[HevcStRps] = []
  for _ in 0..<hevc_max_short_term_rps {
    a.push(new_hevc_st_rps())
  }
  a
}

///|
/// `HEVCPPS` (tile scan-order maps and derived dequant data omitted). */
pub struct HevcPps {
  mut pps_id : Int32
  mut sps_id : Int32
  mut sign_data_hiding_flag : Int32
  mut cabac_init_present_flag : Int32
  mut num_ref_idx_l0_default_active : Int32
  mut num_ref_idx_l1_default_active : Int32
  mut pic_init_qp_minus26 : Int32
  mut constrained_intra_pred_flag : Int32
  mut transform_skip_enabled_flag : Int32
  mut cu_qp_delta_enabled_flag : Int32
  mut diff_cu_qp_delta_depth : Int32
  mut cb_qp_offset : Int32
  mut cr_qp_offset : Int32
  mut pic_slice_level_chroma_qp_offsets_present_flag : Int32
  mut weighted_pred_flag : Int32
  mut weighted_bipred_flag : Int32
  mut output_flag_present_flag : Int32
  mut transquant_bypass_enable_flag : Int32
  mut dependent_slice_segments_enabled_flag : Int32
  mut tiles_enabled_flag : Int32
  mut entropy_coding_sync_enabled_flag : Int32
  mut num_tile_columns : Int32
  mut num_tile_rows : Int32
  mut uniform_spacing_flag : Int32
  mut loop_filter_across_tiles_enabled_flag : Int32
  column_width : Array[Int32]
  row_height : Array[Int32]
  /// Derived tile boundaries and CTB raster<->tile-scan maps (`setup_pps`).
  col_bd : Array[Int32]
  row_bd : Array[Int32]
  col_idxX : Array[Int32]
  ctb_addr_rs_to_ts : Array[Int32]
  ctb_addr_ts_to_rs : Array[Int32]
  tile_id : Array[Int32]
  mut seq_loop_filter_across_slices_enabled_flag : Int32
  mut deblocking_filter_control_present_flag : Int32
  mut deblocking_filter_override_enabled_flag : Int32
  mut disable_dbf : Int32
  mut beta_offset : Int32
  mut tc_offset : Int32
  mut scaling_list_data_present_flag : Int32
  scaling_list : HevcScalingList
  mut lists_modification_present_flag : Int32
  mut log2_parallel_merge_level : Int32
  mut num_extra_slice_header_bits : Int32
  mut slice_header_extension_present_flag : Int32
  mut log2_max_transform_skip_block_size : Int32
  mut pps_extension_present_flag : Int32
  mut pps_range_extensions_flag : Int32
  mut pps_multilayer_extension_flag : Int32
  mut pps_3d_extension_flag : Int32
  mut pps_scc_extension_flag : Int32
  mut cross_component_prediction_enabled_flag : Int32
  mut chroma_qp_offset_list_enabled_flag : Int32
  mut diff_cu_chroma_qp_offset_depth : Int32
  mut chroma_qp_offset_list_len_minus1 : Int32
  cb_qp_offset_list : Array[Int32]
  cr_qp_offset_list : Array[Int32]
  mut log2_sao_offset_scale_luma : Int32
  mut log2_sao_offset_scale_chroma : Int32
  mut pps_curr_pic_ref_enabled_flag : Int32
  mut residual_adaptive_colour_transform_enabled_flag : Int32
  mut pps_slice_act_qp_offsets_present_flag : Int32
  mut pps_act_y_qp_offset : Int32
  mut pps_act_cb_qp_offset : Int32
  mut pps_act_cr_qp_offset : Int32
  mut pps_palette_predictor_initializers_present_flag : Int32
  mut pps_num_palette_predictor_initializers : Int32
  mut monochrome_palette_flag : Int32
  mut luma_bit_depth_entry : Int32
  mut chroma_bit_depth_entry : Int32
  pps_palette_predictor_initializer : Array[Array[Int32]]
  mut data : Bytes
  mut data_size : Int32
}

///|
/// Zero `HEVCPPS`. */
fn new_hevc_pps() -> HevcPps {
  {
    pps_id: 0,
    sps_id: 0,
    sign_data_hiding_flag: 0,
    cabac_init_present_flag: 0,
    num_ref_idx_l0_default_active: 0,
    num_ref_idx_l1_default_active: 0,
    pic_init_qp_minus26: 0,
    constrained_intra_pred_flag: 0,
    transform_skip_enabled_flag: 0,
    cu_qp_delta_enabled_flag: 0,
    diff_cu_qp_delta_depth: 0,
    cb_qp_offset: 0,
    cr_qp_offset: 0,
    pic_slice_level_chroma_qp_offsets_present_flag: 0,
    weighted_pred_flag: 0,
    weighted_bipred_flag: 0,
    output_flag_present_flag: 0,
    transquant_bypass_enable_flag: 0,
    dependent_slice_segments_enabled_flag: 0,
    tiles_enabled_flag: 0,
    entropy_coding_sync_enabled_flag: 0,
    num_tile_columns: 1,
    num_tile_rows: 1,
    uniform_spacing_flag: 1,
    loop_filter_across_tiles_enabled_flag: 1,
    column_width: [],
    row_height: [],
    col_bd: [],
    row_bd: [],
    col_idxX: [],
    ctb_addr_rs_to_ts: [],
    ctb_addr_ts_to_rs: [],
    tile_id: [],
    seq_loop_filter_across_slices_enabled_flag: 0,
    deblocking_filter_control_present_flag: 0,
    deblocking_filter_override_enabled_flag: 0,
    disable_dbf: 0,
    beta_offset: 0,
    tc_offset: 0,
    scaling_list_data_present_flag: 0,
    scaling_list: new_hevc_scaling_list(),
    lists_modification_present_flag: 0,
    log2_parallel_merge_level: 0,
    num_extra_slice_header_bits: 0,
    slice_header_extension_present_flag: 0,
    log2_max_transform_skip_block_size: 2,
    pps_extension_present_flag: 0,
    pps_range_extensions_flag: 0,
    pps_multilayer_extension_flag: 0,
    pps_3d_extension_flag: 0,
    pps_scc_extension_flag: 0,
    cross_component_prediction_enabled_flag: 0,
    chroma_qp_offset_list_enabled_flag: 0,
    diff_cu_chroma_qp_offset_depth: 0,
    chroma_qp_offset_list_len_minus1: 0,
    cb_qp_offset_list: Array::make(6, 0),
    cr_qp_offset_list: Array::make(6, 0),
    log2_sao_offset_scale_luma: 0,
    log2_sao_offset_scale_chroma: 0,
    pps_curr_pic_ref_enabled_flag: 0,
    residual_adaptive_colour_transform_enabled_flag: 0,
    pps_slice_act_qp_offsets_present_flag: 0,
    pps_act_y_qp_offset: 0,
    pps_act_cb_qp_offset: 0,
    pps_act_cr_qp_offset: 0,
    pps_palette_predictor_initializers_present_flag: 0,
    pps_num_palette_predictor_initializers: 0,
    monochrome_palette_flag: 0,
    luma_bit_depth_entry: 0,
    chroma_bit_depth_entry: 0,
    pps_palette_predictor_initializer: [
      Array::make(hevc_max_palette_predictor_size, 0),
      Array::make(hevc_max_palette_predictor_size, 0),
      Array::make(hevc_max_palette_predictor_size, 0),
    ],
    data: b"",
    data_size: 0,
  }
}

///|
/// `HEVCParamSets`. */
pub struct HevcParamSets {
  vps_list : Array[HevcVps?]
  sps_list : Array[HevcSps?]
  pps_list : Array[HevcPps?]
}

///|
/// Empty HEVC parameter set store. */
pub fn new_hevc_param_sets() -> HevcParamSets {
  let vps : Array[HevcVps?] = Array::make(hevc_max_vps_count, None)
  let sps : Array[HevcSps?] = Array::make(hevc_max_sps_count, None)
  let pps : Array[HevcPps?] = Array::make(hevc_max_pps_count, None)
  { vps_list: vps, sps_list: sps, pps_list: pps, }
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

///|
/// `av_image_check_size(w, h, ...)` for the default `AV_PIX_FMT_NONE`. */
fn hevc_image_check_size(w : Int32, h : Int32) -> Bool {
  if w <= 0 || h <= 0 {
    return false
  }
  let stride = 8L * w.to_int64() + 1024L
  stride < 2147483647L && stride * (h.to_int64() + 128L) < 2147483647L
}

///|
/// `read_window`: conformance/default-display window. */
fn read_window(
  gb : BitReader,
  chroma_format_idc : Int32,
  w : Int32,
  h : Int32,
) -> Result[HevcWindow, String] {
  let horiz_mult = hevc_sub_width_c[chroma_format_idc].to_int64()
  let vert_mult = hevc_sub_height_c[chroma_format_idc].to_int64()
  let left = gb.read_ue_long().reinterpret_as_int64() * horiz_mult
  let right = gb.read_ue_long().reinterpret_as_int64() * horiz_mult
  let top = gb.read_ue_long().reinterpret_as_int64() * vert_mult
  let bottom = gb.read_ue_long().reinterpret_as_int64() * vert_mult
  if left < 0 ||
    right < 0 ||
    top < 0 ||
    bottom < 0 ||
    w.to_int64() <= left + right ||
    h.to_int64() <= top + bottom ||
    left > 2147483647L ||
    right > 2147483647L ||
    top > 2147483647L ||
    bottom > 2147483647L {
    return Err("EINVAL")
  }
  Ok({
    left_offset: left.to_int(),
    right_offset: right.to_int(),
    top_offset: top.to_int(),
    bottom_offset: bottom.to_int(),
  })
}

///|
/// `get_bits64`. */
fn read_bits64(gb : BitReader, n : Int32) -> UInt64 {
  let mut v = 0UL
  for i = 0; i < n; i = i + 1 {
    v = (v << 1) | gb.read1().to_uint64()
  }
  v
}

///|
/// `check_profile_idc`: profile_idc or one of the compatibility flags. */
fn ptl_check_profile_idc(ptl : HevcPtlCommon, idc : Int32) -> Bool {
  ptl.profile_idc == idc || ptl.profile_compatibility_flag[idc] != 0
}

///|
/// `decode_profile_tier_level` (the 88-bit profile/tier/level block).
/// Returns "EINVAL" when `get_bits_left` is too small.
fn decode_profile_tier_level(gb : BitReader) -> Result[HevcPtlCommon, String] {
  if gb.bits_left() < 2 + 1 + 5 + 32 + 4 + 43 + 1 {
    return Err("EINVAL")
  }
  let ptl = new_hevc_ptl_common()
  ptl.profile_space = gb.read(2).reinterpret_as_int()
  ptl.tier_flag = gb.read1().reinterpret_as_int()
  ptl.profile_idc = gb.read(5).reinterpret_as_int()
  for i = 0; i < 32; i = i + 1 {
    ptl.profile_compatibility_flag[i] = gb.read1().reinterpret_as_int()
    if ptl.profile_idc == 0 && i > 0 && ptl.profile_compatibility_flag[i] != 0 {
      ptl.profile_idc = i
    }
  }
  ptl.progressive_source_flag = gb.read1().reinterpret_as_int()
  ptl.interlaced_source_flag = gb.read1().reinterpret_as_int()
  ptl.non_packed_constraint_flag = gb.read1().reinterpret_as_int()
  ptl.frame_only_constraint_flag = gb.read1().reinterpret_as_int()
  let is4to10 = ptl_check_profile_idc(ptl, 4) ||
    ptl_check_profile_idc(ptl, 5) ||
    ptl_check_profile_idc(ptl, 6) ||
    ptl_check_profile_idc(ptl, 7) ||
    ptl_check_profile_idc(ptl, 8) ||
    ptl_check_profile_idc(ptl, 9) ||
    ptl_check_profile_idc(ptl, 10)
  if is4to10 {
    ptl.max_12bit_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.max_10bit_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.max_8bit_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.max_422chroma_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.max_420chroma_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.max_monochrome_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.intra_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.one_picture_only_constraint_flag = gb.read1().reinterpret_as_int()
    ptl.lower_bit_rate_constraint_flag = gb.read1().reinterpret_as_int()
    if ptl_check_profile_idc(ptl, 5) ||
      ptl_check_profile_idc(ptl, 9) ||
      ptl_check_profile_idc(ptl, 10) {
      ptl.max_14bit_constraint_flag = gb.read1().reinterpret_as_int()
      gb.skip(33) // XXX_reserved_zero_33bits
    } else {
      gb.skip(34) // XXX_reserved_zero_34bits
    }
  } else if ptl_check_profile_idc(ptl, 2) {
    gb.skip(7)
    ptl.one_picture_only_constraint_flag = gb.read1().reinterpret_as_int()
    gb.skip(35) // XXX_reserved_zero_35bits
  } else {
    gb.skip(43) // XXX_reserved_zero_43bits
  }
  if ptl_check_profile_idc(ptl, 1) ||
    ptl_check_profile_idc(ptl, 2) ||
    ptl_check_profile_idc(ptl, 3) ||
    ptl_check_profile_idc(ptl, 4) ||
    ptl_check_profile_idc(ptl, 5) ||
    ptl_check_profile_idc(ptl, 9) {
    ptl.inbld_flag = gb.read1().reinterpret_as_int()
  } else {
    let _ = gb.read1()
  }
  Ok(ptl)
}

///|
/// `parse_ptl`: general PTL plus the sub-layer flags. */
fn parse_ptl(
  gb : BitReader,
  profile_present : Bool,
  max_num_sub_layers : Int32,
) -> Result[HevcPtl, String] {
  let ptl = new_hevc_ptl()
  if profile_present {
    let general = match decode_profile_tier_level(gb) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    copy_ptl_common(ptl.general_ptl, general)
  }
  if gb.bits_left() < 8 + (if max_num_sub_layers - 1 > 0 { 16 } else { 0 }) {
    return Err("EINVAL")
  }
  ptl.general_ptl.level_idc = gb.read(8).reinterpret_as_int()
  for i = 0; i < max_num_sub_layers - 1; i = i + 1 {
    ptl.sub_layer_profile_present_flag[i] = gb.read1().reinterpret_as_int()
    ptl.sub_layer_level_present_flag[i] = gb.read1().reinterpret_as_int()
  }
  if max_num_sub_layers - 1 > 0 {
    for i = max_num_sub_layers - 1; i < 8; i = i + 1 {
      gb.skip(2) // reserved_zero_2bits[i]
    }
  }
  for i = 0; i < max_num_sub_layers - 1; i = i + 1 {
    if ptl.sub_layer_profile_present_flag[i] != 0 {
      let sub = match decode_profile_tier_level(gb) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      copy_ptl_common(ptl.sub_layer_ptl[i], sub)
    }
    if ptl.sub_layer_level_present_flag[i] != 0 {
      if gb.bits_left() < 8 {
        return Err("EINVAL")
      }
      ptl.sub_layer_ptl[i].level_idc = gb.read(8).reinterpret_as_int()
    }
  }
  Ok(ptl)
}

///|
/// Field-by-field copy (`*dst = *src` for a PTLCommon). */
fn copy_ptl_common(dst : HevcPtlCommon, src : HevcPtlCommon) -> Unit {
  dst.profile_space = src.profile_space
  dst.tier_flag = src.tier_flag
  dst.profile_idc = src.profile_idc
  for i = 0; i < 32; i = i + 1 {
    dst.profile_compatibility_flag[i] = src.profile_compatibility_flag[i]
  }
  dst.progressive_source_flag = src.progressive_source_flag
  dst.interlaced_source_flag = src.interlaced_source_flag
  dst.non_packed_constraint_flag = src.non_packed_constraint_flag
  dst.frame_only_constraint_flag = src.frame_only_constraint_flag
  dst.max_12bit_constraint_flag = src.max_12bit_constraint_flag
  dst.max_10bit_constraint_flag = src.max_10bit_constraint_flag
  dst.max_8bit_constraint_flag = src.max_8bit_constraint_flag
  dst.max_422chroma_constraint_flag = src.max_422chroma_constraint_flag
  dst.max_420chroma_constraint_flag = src.max_420chroma_constraint_flag
  dst.max_monochrome_constraint_flag = src.max_monochrome_constraint_flag
  dst.intra_constraint_flag = src.intra_constraint_flag
  dst.one_picture_only_constraint_flag = src.one_picture_only_constraint_flag
  dst.lower_bit_rate_constraint_flag = src.lower_bit_rate_constraint_flag
  dst.max_14bit_constraint_flag = src.max_14bit_constraint_flag
  dst.inbld_flag = src.inbld_flag
  dst.level_idc = src.level_idc
}

///|
/// Consume one HRD block bit-exactly (`decode_hrd` / `decode_sublayer_hrd`).
/// The values are not stored: no decoder-side consumer exists in this port.
fn skip_hrd(
  gb : BitReader,
  common_inf_present : Bool,
  max_sublayers : Int32,
) -> Result[Unit, String] {
  let mut nal_present = 0
  let mut vcl_present = 0
  let mut sub_pic_present = 0
  if common_inf_present {
    nal_present = gb.read1().reinterpret_as_int()
    vcl_present = gb.read1().reinterpret_as_int()
    if nal_present != 0 || vcl_present != 0 {
      sub_pic_present = gb.read1().reinterpret_as_int()
      if sub_pic_present != 0 {
        let _ = gb.read(8) // tick_divisor_minus2
        let _ = gb.read(5) // du_cpb_removal_delay_increment_length_minus1
        let _ = gb.read1() // sub_pic_cpb_params_in_pic_timing_sei_flag
        let _ = gb.read(5) // dpb_output_delay_du_length_minus1
      }
      let _ = gb.read(4) // bit_rate_scale
      let _ = gb.read(4) // cpb_size_scale
      if sub_pic_present != 0 {
        let _ = gb.read(4) // cpb_size_du_scale
      }
      let _ = gb.read(5) // initial_cpb_removal_delay_length_minus1
      let _ = gb.read(5) // au_cpb_removal_delay_length_minus1
      let _ = gb.read(5) // dpb_output_delay_length_minus1
    }
  }
  for i = 0; i < max_sublayers; i = i + 1 {
    let fixed_general = gb.read1().reinterpret_as_int()
    let mut fixed_within = 0
    let mut low_delay = 0
    if fixed_general == 0 {
      fixed_within = gb.read1().reinterpret_as_int()
    }
    if fixed_within != 0 || fixed_general != 0 {
      let _ = gb.read_ue_long() // elemental_duration_in_tc_minus1
    } else {
      low_delay = gb.read1().reinterpret_as_int()
    }
    let mut cpb_cnt_minus1 = 0
    if low_delay == 0 {
      cpb_cnt_minus1 = gb.read_ue_long().to_int()
      if cpb_cnt_minus1 < 0 || cpb_cnt_minus1 >= hevc_max_cpb_cnt {
        return Err("EINVAL")
      }
    }
    let cpb_count = cpb_cnt_minus1 + 1
    if nal_present != 0 {
      for j = 0; j < cpb_count; j = j + 1 {
        let _ = gb.read_ue_long() // bit_rate_value_minus1
        let _ = gb.read_ue_long() // cpb_size_value_minus1
        if sub_pic_present != 0 {
          let _ = gb.read_ue_long() // cpb_size_du_value_minus1
          let _ = gb.read_ue_long() // bit_rate_du_value_minus1
        }
        let _ = gb.read1() // cbr_flag
      }
    }
    if vcl_present != 0 {
      for j = 0; j < cpb_count; j = j + 1 {
        let _ = gb.read_ue_long()
        let _ = gb.read_ue_long()
        if sub_pic_present != 0 {
          let _ = gb.read_ue_long()
          let _ = gb.read_ue_long()
        }
        let _ = gb.read1()
      }
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// short-term reference picture sets
// ---------------------------------------------------------------------------

///|
/// `ff_hevc_decode_short_term_rps`. `rps_index` is the C's `rps - sps->st_rps`
/// (used for the non-predicted reference in SPS context).
pub fn ff_hevc_decode_short_term_rps(
  gb : BitReader,
  rps : HevcStRps,
  st_rps : Array[HevcStRps],
  nb_st_rps : Int32,
  rps_index : Int32,
  is_slice_header : Bool,
) -> Result[Unit, String] {
  rps.used = 0U
  rps.rps_predict = 0
  // C: `rps != sps->st_rps && sps->nb_st_rps`; a slice-header RPS is never
  // `&sps->st_rps[i]`, so the prediction flag is always present there.
  if (is_slice_header || rps_index > 0) && nb_st_rps > 0 {
    rps.rps_predict = gb.read1().reinterpret_as_int()
  }
  if rps.rps_predict != 0 {
    let used = Array::make(32, 0)
    rps.delta_idx = 0
    let rps_ridx = if is_slice_header {
      rps.delta_idx = gb.read_ue_long().to_int() + 1
      if rps.delta_idx < 1 || rps.delta_idx > nb_st_rps {
        return Err("EINVAL")
      }
      let idx = nb_st_rps - rps.delta_idx
      rps.rps_idx_num_delta_pocs = st_rps[idx].num_delta_pocs
      st_rps[idx]
    } else {
      st_rps[rps_index - 1]
    }
    rps.delta_rps_sign = gb.read1().reinterpret_as_int()
    rps.abs_delta_rps = gb.read_ue_long().to_int() + 1
    if rps.abs_delta_rps < 1 || rps.abs_delta_rps > 32768 {
      return Err("EINVAL")
    }
    let delta_rps = (1 - (rps.delta_rps_sign << 1)) * rps.abs_delta_rps
    let mut k = 0
    let mut k0 = 0
    for i = 0; i <= rps_ridx.num_delta_pocs; i = i + 1 {
      used[k] = gb.read1().reinterpret_as_int()
      rps.use_delta = 0
      if used[k] == 0 {
        rps.use_delta = gb.read1().reinterpret_as_int()
      }
      if used[k] != 0 || rps.use_delta != 0 {
        let delta_poc = if i < rps_ridx.num_delta_pocs {
          delta_rps + rps_ridx.delta_poc[i]
        } else {
          delta_rps
        }
        rps.delta_poc[k] = delta_poc
        if delta_poc < 0 {
          k0 = k0 + 1
        }
        k = k + 1
      }
    }
    if k >= 32 {
      return Err("EINVAL")
    }
    rps.num_delta_pocs = k
    rps.num_negative_pics = k0
    if rps.num_delta_pocs != 0 {
      // insertion sort, exactly as the C (it keeps shifting while smaller)
      for i = 1; i < rps.num_delta_pocs; i = i + 1 {
        let delta_poc = rps.delta_poc[i]
        let u = used[i]
        let mut kk = i - 1
        while kk >= 0 {
          let tmp = rps.delta_poc[kk]
          if delta_poc < tmp {
            rps.delta_poc[kk + 1] = tmp
            used[kk + 1] = used[kk]
            rps.delta_poc[kk] = delta_poc
            used[kk] = u
          }
          kk = kk - 1
        }
      }
    }
    if rps.num_negative_pics >> 1 != 0 {
      let mut kk = rps.num_negative_pics - 1
      for i = 0; i < rps.num_negative_pics >> 1; i = i + 1 {
        let delta_poc = rps.delta_poc[i]
        let u = used[i]
        rps.delta_poc[i] = rps.delta_poc[kk]
        used[i] = used[kk]
        rps.delta_poc[kk] = delta_poc
        used[kk] = u
        kk = kk - 1
      }
    }
    let mut mask : UInt32 = 0
    for i = 0; i < 32; i = i + 1 {
      mask = mask | (used[i].reinterpret_as_uint() << i)
    }
    rps.used = mask
  } else {
    let num_negative = gb.read_ue_long().to_int()
    let num_positive = gb.read_ue_long().to_int()
    if num_negative < 0 ||
      num_positive < 0 ||
      num_negative >= hevc_max_refs ||
      num_positive >= hevc_max_refs {
      return Err("EINVAL")
    }
    rps.num_negative_pics = num_negative
    rps.num_delta_pocs = num_negative + num_positive
    if rps.num_delta_pocs != 0 {
      let mut prev = 0
      for i = 0; i < num_negative; i = i + 1 {
        let delta_poc = gb.read_ue_long().to_int() + 1
        if delta_poc < 1 || delta_poc > 32768 {
          return Err("EINVAL")
        }
        prev = prev - delta_poc
        rps.delta_poc[i] = prev
        rps.used = rps.used | (if gb.read1() != 0 { 1U << i } else { 0U })
      }
      prev = 0
      for i = 0; i < num_positive; i = i + 1 {
        let delta_poc = gb.read_ue_long().to_int() + 1
        if delta_poc < 1 || delta_poc > 32768 {
          return Err("EINVAL")
        }
        prev = prev + delta_poc
        rps.delta_poc[num_negative + i] = prev
        rps.used = rps.used |
          (if gb.read1() != 0 { 1U << (num_negative + i) } else { 0U })
      }
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// VUI and scaling lists
// ---------------------------------------------------------------------------

///|
/// `set_default_scaling_list_data`. */
fn set_default_scaling_list_data(sl : HevcScalingList) -> Unit {
  for matrix_id = 0; matrix_id < 6; matrix_id = matrix_id + 1 {
    for i = 0; i < 16; i = i + 1 {
      sl.sl[0][matrix_id][i] = 16
    }
    sl.sl_dc[0][matrix_id] = 16
    sl.sl_dc[1][matrix_id] = 16
  }
  for size_id = 1; size_id < 4; size_id = size_id + 1 {
    for matrix_id = 0; matrix_id < 6; matrix_id = matrix_id + 1 {
      for i = 0; i < 64; i = i + 1 {
        sl.sl[size_id][matrix_id][i] = if matrix_id < 3 {
          default_scaling_list_intra[i]
        } else {
          default_scaling_list_inter[i]
        }
      }
    }
  }
}

///|
/// `scaling_list_data`. */
fn scaling_list_data(
  gb : BitReader,
  sl : HevcScalingList,
  sps : HevcSps,
) -> Result[Unit, String] {
  for size_id = 0; size_id < 4; size_id = size_id + 1 {
    let step = if size_id == 3 { 3 } else { 1 }
    let mut matrix_id = 0
    while matrix_id < 6 {
      let pred_mode = gb.read1() != 0
      if !pred_mode {
        let mut delta = gb.read_ue_long().to_int()
        if delta != 0 {
          delta = delta * step
          if matrix_id < delta {
            return Err("EINVAL")
          }
          let count = if size_id > 0 { 64 } else { 16 }
          for i = 0; i < count; i = i + 1 {
            sl.sl[size_id][matrix_id][i] = sl.sl[size_id][matrix_id - delta][i]
          }
          if size_id > 1 {
            sl.sl_dc[size_id - 2][matrix_id] = sl.sl_dc[size_id - 2][matrix_id -
              delta]
          }
        }
      } else {
        let coef_num = if 1 << (4 + (size_id << 1)) < 64 {
          1 << (4 + (size_id << 1))
        } else {
          64
        }
        let mut next_coef = 8
        if size_id > 1 {
          let dc_minus8 = gb.read_se()
          if dc_minus8 < -7 || dc_minus8 > 247 {
            return Err("EINVAL")
          }
          next_coef = dc_minus8 + 8
          sl.sl_dc[size_id - 2][matrix_id] = next_coef
        }
        for i = 0; i < coef_num; i = i + 1 {
          let pos = if size_id == 0 {
            4 * hevc_diag_scan4x4_y[i] + hevc_diag_scan4x4_x[i]
          } else {
            8 * hevc_diag_scan8x8_y[i] + hevc_diag_scan8x8_x[i]
          }
          let delta = gb.read_se()
          next_coef = (next_coef + 256 + delta) & 0xFF
          sl.sl[size_id][matrix_id][pos] = next_coef
        }
      }
      matrix_id = matrix_id + step
    }
  }
  if sps.chroma_format_idc == 3 {
    for i = 0; i < 64; i = i + 1 {
      sl.sl[3][1][i] = sl.sl[2][1][i]
      sl.sl[3][2][i] = sl.sl[2][2][i]
      sl.sl[3][4][i] = sl.sl[2][4][i]
      sl.sl[3][5][i] = sl.sl[2][5][i]
    }
    sl.sl_dc[1][1] = sl.sl_dc[0][1]
    sl.sl_dc[1][2] = sl.sl_dc[0][2]
    sl.sl_dc[1][4] = sl.sl_dc[0][4]
    sl.sl_dc[1][5] = sl.sl_dc[0][5]
  }
  Ok(())
}

///|
/// `map_pixel_format`: FFmpeg pixel format name plus the derived shifts. */
fn map_pixel_format(sps : HevcSps) -> Result[Unit, String] {
  let chroma = sps.chroma_format_idc
  let depth = sps.bit_depth
  let name = if depth == 8 {
    match chroma {
      0 => "gray"
      1 => "yuv420p"
      2 => "yuv422p"
      3 => "yuv444p"
      _ => ""
    }
  } else if depth == 9 {
    match chroma {
      0 => "gray9le"
      1 => "yuv420p9le"
      2 => "yuv422p9le"
      3 => "yuv444p9le"
      _ => ""
    }
  } else if depth == 10 {
    match chroma {
      0 => "gray10le"
      1 => "yuv420p10le"
      2 => "yuv422p10le"
      3 => "yuv444p10le"
      _ => ""
    }
  } else if depth == 12 {
    match chroma {
      0 => "gray12le"
      1 => "yuv420p12le"
      2 => "yuv422p12le"
      3 => "yuv444p12le"
      _ => ""
    }
  } else {
    ""
  }
  if name == "" {
    return Err("EINVAL")
  }
  sps.pix_fmt = name
  sps.hshift[0] = 0
  sps.vshift[0] = 0
  let hsub = if chroma == 0 || chroma == 3 { 0 } else { 1 }
  let vsub = if chroma == 1 { 1 } else { 0 }
  sps.hshift[1] = hsub
  sps.hshift[2] = hsub
  sps.vshift[1] = vsub
  sps.vshift[2] = vsub
  sps.pixel_shift = depth > 8
  Ok(())
}

///|
/// `decode_vui` (timing/HRD and bitstream restriction; no alternate retry). */
fn decode_vui(gb : BitReader, sps : HevcSps) -> Unit {
  ff_h2645_decode_common_vui_params(gb, sps.vui.common)
  if sps.vui.common.video_signal_type_present_flag != 0 {
    if sps.vui.common.video_full_range_flag != 0 && sps.pix_fmt == "yuv420p" {
      sps.pix_fmt = "yuvj420p"
    }
    if sps.vui.common.colour_description_present_flag != 0 {
      if sps.vui.common.matrix_coeffs == 0 {
        // AVCOL_SPC_RGB
        if sps.pix_fmt == "yuv444p" {
          sps.pix_fmt = "gbrp"
        } else if sps.pix_fmt == "yuv444p10le" {
          sps.pix_fmt = "gbrp10"
        } else if sps.pix_fmt == "yuv444p12le" {
          sps.pix_fmt = "gbrp12"
        }
      }
    }
  }
  sps.vui.neutra_chroma_indication_flag = gb.read1().reinterpret_as_int()
  sps.vui.field_seq_flag = gb.read1().reinterpret_as_int()
  sps.vui.frame_field_info_present_flag = gb.read1().reinterpret_as_int()
  if gb.bits_left() >= 68 && gb.show(21) == 0x100000 {
    sps.vui.default_display_window_flag = 0
  } else {
    sps.vui.default_display_window_flag = gb.read1().reinterpret_as_int()
  }
  if sps.vui.default_display_window_flag != 0 {
    match read_window(gb, sps.chroma_format_idc, sps.width, sps.height) {
      Ok(w) => {
        sps.vui.def_disp_win.left_offset = w.left_offset
        sps.vui.def_disp_win.right_offset = w.right_offset
        sps.vui.def_disp_win.top_offset = w.top_offset
        sps.vui.def_disp_win.bottom_offset = w.bottom_offset
      }
      Err(_) => ()
    }
  }
  sps.vui.vui_timing_info_present_flag = gb.read1().reinterpret_as_int()
  if sps.vui.vui_timing_info_present_flag != 0 {
    sps.vui.vui_num_units_in_tick = gb.read(32).reinterpret_as_int()
    sps.vui.vui_time_scale = gb.read(32).reinterpret_as_int()
    sps.vui.vui_poc_proportional_to_timing_flag = gb
      .read1()
      .reinterpret_as_int()
    if sps.vui.vui_poc_proportional_to_timing_flag != 0 {
      sps.vui.vui_num_ticks_poc_diff_one_minus1 = gb.read_ue_long().to_int()
    }
    sps.vui.vui_hrd_parameters_present_flag = gb.read1().reinterpret_as_int()
    if sps.vui.vui_hrd_parameters_present_flag != 0 {
      let _ = skip_hrd(gb, true, sps.max_sub_layers)
    }
  }
  sps.vui.bitstream_restriction_flag = gb.read1().reinterpret_as_int()
  if sps.vui.bitstream_restriction_flag != 0 {
    sps.vui.tiles_fixed_structure_flag = gb.read1().reinterpret_as_int()
    sps.vui.motion_vectors_over_pic_boundaries_flag = gb
      .read1()
      .reinterpret_as_int()
    sps.vui.restricted_ref_pic_lists_flag = gb.read1().reinterpret_as_int()
    sps.vui.min_spatial_segmentation_idc = gb.read_ue_long().to_int()
    sps.vui.max_bytes_per_pic_denom = gb.read_ue_long().to_int()
    sps.vui.max_bits_per_min_cu_denom = gb.read_ue_long().to_int()
    sps.vui.log2_max_mv_length_horizontal = gb.read_ue_long().to_int()
    sps.vui.log2_max_mv_length_vertical = gb.read_ue_long().to_int()
  }
}

// ---------------------------------------------------------------------------
// VPS / SPS / PPS
// ---------------------------------------------------------------------------

///|
/// `ff_hevc_decode_nal_vps`. */
pub fn ff_hevc_decode_nal_vps(
  gb : BitReader,
  ps : HevcParamSets,
) -> Result[Unit, String] {
  let vps_id = gb.read(4).reinterpret_as_int()
  let (data, data_size) = parameter_set_data_hevc(gb)
  let old_exists = ps.vps_list[vps_id] is Some(_)
  let vps = new_hevc_vps()
  vps.data = data
  vps.data_size = data_size
  vps.vps_id = vps_id
  let base_internal = gb.read1().reinterpret_as_int()
  let base_available = gb.read1().reinterpret_as_int()
  if base_internal == 0 || base_available == 0 {
    return Err("PATCHWELCOME")
  }
  vps.vps_max_layers = gb.read(6).reinterpret_as_int() + 1
  vps.vps_max_sub_layers = gb.read(3).reinterpret_as_int() + 1
  vps.vps_temporal_id_nesting_flag = gb.read1().reinterpret_as_int()
  if gb.read(16) != 0xFFFFU {
    return Err("EINVAL")
  }
  if vps.vps_max_sub_layers > hevc_max_sub_layers {
    return Err("EINVAL")
  }
  let ptl = match parse_ptl(gb, true, vps.vps_max_sub_layers) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  copy_ptl(vps.ptl, ptl)
  vps.vps_sub_layer_ordering_info_present_flag = gb.read1().reinterpret_as_int()
  let start = if vps.vps_sub_layer_ordering_info_present_flag != 0 {
    0
  } else {
    vps.vps_max_sub_layers - 1
  }
  for i = start; i < vps.vps_max_sub_layers; i = i + 1 {
    vps.vps_max_dec_pic_buffering[i] = gb.read_ue_long().to_int() + 1
    vps.vps_num_reorder_pics[i] = gb.read_ue_long().to_int()
    vps.vps_max_latency_increase[i] = gb.read_ue_long().to_int() - 1
    if vps.vps_max_dec_pic_buffering[i] > hevc_max_dpb_size ||
      vps.vps_max_dec_pic_buffering[i] < 1 {
      return Err("EINVAL")
    }
    // C only warns (or errors with AV_EF_EXPLODE) on this; accept it.
  }
  vps.vps_max_layer_id = gb.read(6).reinterpret_as_int()
  vps.vps_num_layer_sets = gb.read_ue_long().to_int() + 1
  if vps.vps_num_layer_sets < 1 ||
    vps.vps_num_layer_sets > 1024 ||
    (vps.vps_num_layer_sets - 1) * (vps.vps_max_layer_id + 1) > gb.bits_left() {
    return Err("EINVAL")
  }
  let mut layer1_id_included : UInt64 = 0UL
  if vps.vps_num_layer_sets > 1 {
    layer1_id_included = read_bits64(gb, vps.vps_max_layer_id + 1)
  }
  if vps.vps_num_layer_sets > 2 {
    gb.skip((vps.vps_num_layer_sets - 2) * (vps.vps_max_layer_id + 1))
  }
  vps.vps_timing_info_present_flag = gb.read1().reinterpret_as_int()
  if vps.vps_timing_info_present_flag != 0 {
    vps.vps_num_units_in_tick = gb.read(32).reinterpret_as_int()
    vps.vps_time_scale = gb.read(32).reinterpret_as_int()
    vps.vps_poc_proportional_to_timing_flag = gb.read1().reinterpret_as_int()
    if vps.vps_poc_proportional_to_timing_flag != 0 {
      vps.vps_num_ticks_poc_diff_one = gb.read_ue_long().to_int() + 1
    }
    vps.vps_num_hrd_parameters = gb.read_ue_long().to_int()
    if vps.vps_num_hrd_parameters < 0 ||
      vps.vps_num_hrd_parameters > vps.vps_num_layer_sets {
      return Err("EINVAL")
    }
    for i = 0; i < vps.vps_num_hrd_parameters; i = i + 1 {
      let _ = gb.read_ue_long() // hrd_layer_set_idx
      let mut common_inf_present = true
      if i > 0 {
        common_inf_present = gb.read1() != 0
      }
      match skip_hrd(gb, common_inf_present, vps.vps_max_sub_layers) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  if vps.vps_max_layers > 1 && gb.read1() != 0 {
    // vps_extension_flag: multilayer / alpha is not modelled.
    return Err("PATCHWELCOME")
  }
  let _ = layer1_id_included
  if gb.bits_left() < 0 && old_exists {
    return Err("EINVAL")
  }
  ps.vps_list[vps_id] = Some(vps)
  Ok(())
}

///|
/// `copy_ptl` (`*dst = *src` for a PTL). */
fn copy_ptl(dst : HevcPtl, src : HevcPtl) -> Unit {
  copy_ptl_common(dst.general_ptl, src.general_ptl)
  for i = 0; i < hevc_max_sub_layers; i = i + 1 {
    copy_ptl_common(dst.sub_layer_ptl[i], src.sub_layer_ptl[i])
    dst.sub_layer_profile_present_flag[i] = src.sub_layer_profile_present_flag[i]
    dst.sub_layer_level_present_flag[i] = src.sub_layer_level_present_flag[i]
  }
}

///|
/// Copy an SPS's `data` bytes (`get_bits_bytesize(gb, 1)` at the NAL start). */
fn parameter_set_data_hevc(gb : BitReader) -> (Bytes, Int32) {
  let n = gb.bytesize(true)
  let limit = if n > 4096 { 4096 } else { n }
  (gb.bytes.clamped_view(start=0, end=limit).to_owned(), limit)
}

///|
/// `ff_hevc_parse_sps` + `ff_hevc_decode_nal_sps`. */
pub fn ff_hevc_decode_nal_sps(
  gb : BitReader,
  ps : HevcParamSets,
  nuh_layer_id : Int32,
  apply_defdispwin : Bool,
) -> Result[Unit, String] {
  let sps = new_hevc_sps()
  let (data, data_size) = parameter_set_data_hevc(gb)
  sps.data = data
  sps.data_size = data_size
  sps.vps_id = gb.read(4).reinterpret_as_int()
  sps.max_sub_layers = gb.read(3).reinterpret_as_int() + 1
  let multi_layer_ext = nuh_layer_id > 0 &&
    sps.max_sub_layers == hevc_max_sub_layers + 1
  if multi_layer_ext {
    return Err("PATCHWELCOME")
  }
  if sps.max_sub_layers > hevc_max_sub_layers {
    return Err("EINVAL")
  }
  let vps_max_sub_layers = match ps.vps_list[sps.vps_id] {
    Some(vps) => vps.vps_max_sub_layers
    None => {
      if sps.vps_id != 0 {
        // C errors when a VPS list was supplied; extradata may lack a VPS.
        return Err("EINVAL")
      }
      sps.max_sub_layers
    }
  }
  if sps.max_sub_layers > vps_max_sub_layers {
    return Err("EINVAL")
  }
  if !multi_layer_ext {
    sps.temporal_id_nesting = gb.read1().reinterpret_as_int()
    let ptl = match parse_ptl(gb, true, sps.max_sub_layers) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    copy_ptl(sps.ptl, ptl)
  }
  let sps_id = gb.read_ue_long().to_int()
  if sps_id < 0 || sps_id >= hevc_max_sps_count {
    return Err("EINVAL")
  }
  sps.chroma_format_idc = gb.read_ue_long().to_int()
  if sps.chroma_format_idc < 0 || sps.chroma_format_idc > 3 {
    return Err("EINVAL")
  }
  if sps.chroma_format_idc == 3 {
    sps.separate_colour_plane = gb.read1().reinterpret_as_int()
  }
  if sps.separate_colour_plane != 0 {
    sps.chroma_format_idc = 0
  }
  sps.width = gb.read_ue_long().to_int()
  sps.height = gb.read_ue_long().to_int()
  if !hevc_image_check_size(sps.width, sps.height) {
    return Err("EINVAL")
  }
  sps.conformance_window = gb.read1().reinterpret_as_int()
  if sps.conformance_window != 0 {
    let w = match
      read_window(gb, sps.chroma_format_idc, sps.width, sps.height) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    sps.pic_conf_win.left_offset = w.left_offset
    sps.pic_conf_win.right_offset = w.right_offset
    sps.pic_conf_win.top_offset = w.top_offset
    sps.pic_conf_win.bottom_offset = w.bottom_offset
  }
  sps.bit_depth = gb.read_ue31() + 8
  if sps.bit_depth < 8 || sps.bit_depth > 16 {
    return Err("EINVAL")
  }
  let bit_depth_chroma = gb.read_ue31() + 8
  if bit_depth_chroma < 8 || bit_depth_chroma > 16 {
    return Err("EINVAL")
  }
  if sps.chroma_format_idc != 0 && bit_depth_chroma != sps.bit_depth {
    return Err("EINVAL")
  }
  sps.bit_depth_chroma = bit_depth_chroma
  sps.output_window.left_offset = sps.pic_conf_win.left_offset
  sps.output_window.right_offset = sps.pic_conf_win.right_offset
  sps.output_window.top_offset = sps.pic_conf_win.top_offset
  sps.output_window.bottom_offset = sps.pic_conf_win.bottom_offset
  match map_pixel_format(sps) {
    Err(e) => return Err(e)
    Ok(_) => ()
  }
  sps.log2_max_poc_lsb = gb.read_ue_long().to_int() + 4
  if sps.log2_max_poc_lsb < 4 || sps.log2_max_poc_lsb > 16 {
    return Err("EINVAL")
  }
  sps.sublayer_ordering_info = gb.read1().reinterpret_as_int()
  let start = if sps.sublayer_ordering_info != 0 {
    0
  } else {
    sps.max_sub_layers - 1
  }
  for i = start; i < sps.max_sub_layers; i = i + 1 {
    sps.max_dec_pic_buffering[i] = gb.read_ue_long().to_int() + 1
    sps.num_reorder_pics[i] = gb.read_ue_long().to_int()
    sps.max_latency_increase[i] = gb.read_ue_long().to_int() - 1
    if sps.max_dec_pic_buffering[i] > hevc_max_dpb_size {
      return Err("EINVAL")
    }
    if sps.num_reorder_pics[i] > sps.max_dec_pic_buffering[i] - 1 {
      if sps.num_reorder_pics[i] > hevc_max_dpb_size - 1 {
        return Err("EINVAL")
      }
      sps.max_dec_pic_buffering[i] = sps.num_reorder_pics[i] + 1
    }
  }
  if sps.sublayer_ordering_info == 0 {
    for i = 0; i < start; i = i + 1 {
      sps.max_dec_pic_buffering[i] = sps.max_dec_pic_buffering[start]
      sps.num_reorder_pics[i] = sps.num_reorder_pics[start]
      sps.max_latency_increase[i] = sps.max_latency_increase[start]
    }
  }
  sps.log2_min_cb_size = gb.read_ue_long().to_int() + 3
  sps.log2_diff_max_min_coding_block_size = gb.read_ue_long().to_int()
  sps.log2_min_tb_size = gb.read_ue_long().to_int() + 2
  sps.log2_diff_max_min_transform_block_size = gb.read_ue_long().to_int()
  sps.log2_max_trafo_size = sps.log2_diff_max_min_transform_block_size +
    sps.log2_min_tb_size
  if sps.log2_min_cb_size < 3 || sps.log2_min_cb_size > 30 {
    return Err("EINVAL")
  }
  if sps.log2_diff_max_min_coding_block_size > 30 {
    return Err("EINVAL")
  }
  if sps.log2_min_tb_size >= sps.log2_min_cb_size || sps.log2_min_tb_size < 2 {
    return Err("EINVAL")
  }
  if sps.log2_diff_max_min_transform_block_size > 30 {
    return Err("EINVAL")
  }
  sps.max_transform_hierarchy_depth_inter = gb.read_ue_long().to_int()
  sps.max_transform_hierarchy_depth_intra = gb.read_ue_long().to_int()
  sps.scaling_list_enabled = gb.read1().reinterpret_as_int()
  if sps.scaling_list_enabled != 0 {
    set_default_scaling_list_data(sps.scaling_list)
    let present = gb.read1() != 0
    if present {
      match scaling_list_data(gb, sps.scaling_list, sps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  sps.amp_enabled = gb.read1().reinterpret_as_int()
  sps.sao_enabled = gb.read1().reinterpret_as_int()
  sps.pcm_enabled = gb.read1().reinterpret_as_int()
  if sps.pcm_enabled != 0 {
    sps.pcm_bit_depth = gb.read(4).reinterpret_as_int() + 1
    sps.pcm_bit_depth_chroma = gb.read(4).reinterpret_as_int() + 1
    sps.pcm_log2_min_cb_size = gb.read_ue_long().to_int() + 3
    sps.pcm_log2_max_cb_size = sps.pcm_log2_min_cb_size +
      gb.read_ue_long().to_int()
    if sps.pcm_bit_depth > sps.bit_depth ||
      sps.pcm_bit_depth_chroma > sps.bit_depth {
      return Err("EINVAL")
    }
    sps.pcm_loop_filter_disabled = gb.read1().reinterpret_as_int()
  }
  sps.nb_st_rps = gb.read_ue_long().to_int()
  if sps.nb_st_rps < 0 || sps.nb_st_rps > hevc_max_short_term_rps {
    return Err("EINVAL")
  }
  for i = 0; i < sps.nb_st_rps; i = i + 1 {
    match
      ff_hevc_decode_short_term_rps(
        gb,
        sps.st_rps[i],
        sps.st_rps,
        sps.nb_st_rps,
        i,
        false,
      ) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  sps.long_term_ref_pics_present = gb.read1().reinterpret_as_int()
  if sps.long_term_ref_pics_present != 0 {
    sps.num_long_term_ref_pics_sps = gb.read_ue_long().to_int()
    if sps.num_long_term_ref_pics_sps < 0 ||
      sps.num_long_term_ref_pics_sps > hevc_max_long_term_ref_pics {
      return Err("EINVAL")
    }
    sps.used_by_curr_pic_lt = 0U
    for i = 0; i < sps.num_long_term_ref_pics_sps; i = i + 1 {
      sps.lt_ref_pic_poc_lsb_sps[i] = gb
        .read(sps.log2_max_poc_lsb)
        .reinterpret_as_int()
      sps.used_by_curr_pic_lt = sps.used_by_curr_pic_lt |
        (if gb.read1() != 0 { 1U << i } else { 0U })
    }
  }
  sps.temporal_mvp_enabled = gb.read1().reinterpret_as_int()
  sps.strong_intra_smoothing_enabled = gb.read1().reinterpret_as_int()
  sps.vui.common.sar_num = 0
  sps.vui.common.sar_den = 1
  sps.vui_present = gb.read1().reinterpret_as_int()
  if sps.vui_present != 0 {
    decode_vui(gb, sps)
  }
  sps.extension_present = gb.read1().reinterpret_as_int()
  if sps.extension_present != 0 {
    sps.range_extension = gb.read1().reinterpret_as_int()
    sps.multilayer_extension = gb.read1().reinterpret_as_int()
    sps.sps_3d_extension = gb.read1().reinterpret_as_int()
    sps.scc_extension = gb.read1().reinterpret_as_int()
    gb.skip(4) // sps_extension_4bits
    if sps.range_extension != 0 {
      sps.transform_skip_rotation_enabled = gb.read1().reinterpret_as_int()
      sps.transform_skip_context_enabled = gb.read1().reinterpret_as_int()
      sps.implicit_rdpcm_enabled = gb.read1().reinterpret_as_int()
      sps.explicit_rdpcm_enabled = gb.read1().reinterpret_as_int()
      sps.extended_precision_processing = gb.read1().reinterpret_as_int()
      sps.intra_smoothing_disabled = gb.read1().reinterpret_as_int()
      sps.high_precision_offsets_enabled = gb.read1().reinterpret_as_int()
      sps.persistent_rice_adaptation_enabled = gb.read1().reinterpret_as_int()
      sps.cabac_bypass_alignment_enabled = gb.read1().reinterpret_as_int()
    }
    if sps.multilayer_extension != 0 {
      let _ = gb.read1() // inter_view_mv_vert_constraint_flag
    }
    if sps.sps_3d_extension != 0 {
      for i = 0; i <= 1; i = i + 1 {
        let _ = gb.read1() // iv_di_mc_enabled_flag
        let _ = gb.read1() // iv_mv_scal_enabled_flag
        if i == 0 {
          let _ = gb.read_ue_long() // log2_ivmc_sub_pb_size_minus3
          let _ = gb.read1() // iv_res_pred_enabled_flag
          let _ = gb.read1() // depth_ref_enabled_flag
          let _ = gb.read1() // vsp_mc_enabled_flag
          let _ = gb.read1() // dbbp_enabled_flag
        } else {
          let _ = gb.read1() // tex_mc_enabled_flag
          let _ = gb.read_ue_long() // log2_ivmc_sub_pb_size_minus3
          let _ = gb.read1() // intra_contour_enabled_flag
          let _ = gb.read1() // intra_dc_only_wedge_enabled_flag
          let _ = gb.read1() // cqt_cu_part_pred_enabled_flag
          let _ = gb.read1() // inter_dc_only_enabled_flag
          let _ = gb.read1() // skip_intra_enabled_flag
        }
      }
    }
    if sps.scc_extension != 0 {
      sps.curr_pic_ref_enabled = gb.read1().reinterpret_as_int()
      sps.palette_mode_enabled = gb.read1().reinterpret_as_int()
      if sps.palette_mode_enabled != 0 {
        sps.palette_max_size = gb.read_ue()
        sps.delta_palette_max_predictor_size = gb.read_ue()
        sps.palette_predictor_initializers_present = gb
          .read1()
          .reinterpret_as_int()
        if sps.palette_predictor_initializers_present != 0 {
          sps.sps_num_palette_predictor_initializers = gb.read_ue() + 1
          if sps.sps_num_palette_predictor_initializers < 1 ||
            sps.sps_num_palette_predictor_initializers >
            hevc_max_palette_predictor_size {
            return Err("EINVAL")
          }
          let num_comps = if sps.chroma_format_idc == 0 { 1 } else { 3 }
          for comp = 0; comp < num_comps; comp = comp + 1 {
            let depth = if comp == 0 {
              sps.bit_depth
            } else {
              sps.bit_depth_chroma
            }
            for i = 0; i < sps.sps_num_palette_predictor_initializers; i = i + 1 {
              sps.sps_palette_predictor_initializer[comp][i] = gb
                .read(depth)
                .reinterpret_as_int()
            }
          }
        }
      }
      sps.motion_vector_resolution_control_idc = gb.read(2).reinterpret_as_int()
      sps.intra_boundary_filtering_disabled = gb.read1().reinterpret_as_int()
    }
  }
  if apply_defdispwin {
    sps.output_window.left_offset = sps.output_window.left_offset +
      sps.vui.def_disp_win.left_offset
    sps.output_window.right_offset = sps.output_window.right_offset +
      sps.vui.def_disp_win.right_offset
    sps.output_window.top_offset = sps.output_window.top_offset +
      sps.vui.def_disp_win.top_offset
    sps.output_window.bottom_offset = sps.output_window.bottom_offset +
      sps.vui.def_disp_win.bottom_offset
  }
  let ow = sps.output_window
  if ow.left_offset < 0 ||
    ow.right_offset < 0 ||
    ow.top_offset < 0 ||
    ow.bottom_offset < 0 ||
    ow.left_offset + ow.right_offset >= sps.width ||
    ow.top_offset + ow.bottom_offset >= sps.height {
    sps.output_window.left_offset = 0
    sps.output_window.right_offset = 0
    sps.output_window.top_offset = 0
    sps.output_window.bottom_offset = 0
    sps.pic_conf_win.left_offset = 0
    sps.pic_conf_win.right_offset = 0
    sps.pic_conf_win.top_offset = 0
    sps.pic_conf_win.bottom_offset = 0
  }
  sps.log2_ctb_size = sps.log2_min_cb_size +
    sps.log2_diff_max_min_coding_block_size
  sps.log2_min_pu_size = sps.log2_min_cb_size - 1
  if sps.log2_ctb_size > hevc_max_log2_ctb_size || sps.log2_ctb_size < 4 {
    return Err("EINVAL")
  }
  sps.ctb_width = (sps.width + (1 << sps.log2_ctb_size) - 1) >>
    sps.log2_ctb_size
  sps.ctb_height = (sps.height + (1 << sps.log2_ctb_size) - 1) >>
    sps.log2_ctb_size
  sps.ctb_size = sps.ctb_width * sps.ctb_height
  sps.min_cb_width = sps.width >> sps.log2_min_cb_size
  sps.min_cb_height = sps.height >> sps.log2_min_cb_size
  sps.min_tb_width = sps.width >> sps.log2_min_tb_size
  sps.min_tb_height = sps.height >> sps.log2_min_tb_size
  sps.min_pu_width = sps.width >> sps.log2_min_pu_size
  sps.min_pu_height = sps.height >> sps.log2_min_pu_size
  sps.tb_mask = (1 << (sps.log2_ctb_size - sps.log2_min_tb_size)) - 1
  sps.qp_bd_offset = 6 * (sps.bit_depth - 8)
  if (sps.width & ((1 << sps.log2_min_cb_size) - 1)) != 0 ||
    (sps.height & ((1 << sps.log2_min_cb_size) - 1)) != 0 {
    return Err("EINVAL")
  }
  if sps.max_transform_hierarchy_depth_inter >
    sps.log2_ctb_size - sps.log2_min_tb_size ||
    sps.max_transform_hierarchy_depth_intra >
    sps.log2_ctb_size - sps.log2_min_tb_size {
    return Err("EINVAL")
  }
  if sps.log2_max_trafo_size > sps.log2_ctb_size || sps.log2_max_trafo_size > 5 {
    return Err("EINVAL")
  }
  if gb.bits_left() < 0 {
    return Err("EINVAL")
  }
  ps.sps_list[sps_id] = Some(sps)
  Ok(())
}

///|
/// `pps_range_extensions`. */
fn pps_range_extensions(
  gb : BitReader,
  pps : HevcPps,
  sps : HevcSps,
) -> Result[Unit, String] {
  if pps.transform_skip_enabled_flag != 0 {
    pps.log2_max_transform_skip_block_size = gb.read_ue31() + 2
  }
  pps.cross_component_prediction_enabled_flag = gb.read1().reinterpret_as_int()
  pps.chroma_qp_offset_list_enabled_flag = gb.read1().reinterpret_as_int()
  if pps.chroma_qp_offset_list_enabled_flag != 0 {
    pps.diff_cu_chroma_qp_offset_depth = gb.read_ue31()
    pps.chroma_qp_offset_list_len_minus1 = gb.read_ue31()
    if pps.chroma_qp_offset_list_len_minus1 < 0 ||
      pps.chroma_qp_offset_list_len_minus1 > 5 {
      return Err("EINVAL")
    }
    for i = 0; i <= pps.chroma_qp_offset_list_len_minus1; i = i + 1 {
      pps.cb_qp_offset_list[i] = gb.read_se()
      pps.cr_qp_offset_list[i] = gb.read_se()
    }
  }
  pps.log2_sao_offset_scale_luma = gb.read_ue31()
  pps.log2_sao_offset_scale_chroma = gb.read_ue31()
  let max_luma = if sps.bit_depth - 10 > 0 { sps.bit_depth - 10 } else { 0 }
  let max_chroma = if sps.bit_depth_chroma - 10 > 0 {
    sps.bit_depth_chroma - 10
  } else {
    0
  }
  if pps.log2_sao_offset_scale_luma < 0 ||
    pps.log2_sao_offset_scale_luma > max_luma ||
    pps.log2_sao_offset_scale_chroma < 0 ||
    pps.log2_sao_offset_scale_chroma > max_chroma {
    return Err("EINVAL")
  }
  Ok(())
}

///|
/// `pps_scc_extension`. */
fn pps_scc_extension(
  gb : BitReader,
  pps : HevcPps,
  sps : HevcSps,
) -> Result[Unit, String] {
  pps.pps_curr_pic_ref_enabled_flag = gb.read1().reinterpret_as_int()
  pps.residual_adaptive_colour_transform_enabled_flag = gb
    .read1()
    .reinterpret_as_int()
  if pps.residual_adaptive_colour_transform_enabled_flag != 0 {
    pps.pps_slice_act_qp_offsets_present_flag = gb.read1().reinterpret_as_int()
    pps.pps_act_y_qp_offset = gb.read_se() - 5
    pps.pps_act_cb_qp_offset = gb.read_se() - 5
    pps.pps_act_cr_qp_offset = gb.read_se() - 3
    if pps.pps_act_y_qp_offset <= -12 ||
      pps.pps_act_y_qp_offset >= 12 ||
      pps.pps_act_cb_qp_offset <= -12 ||
      pps.pps_act_cb_qp_offset >= 12 ||
      pps.pps_act_cr_qp_offset <= -12 ||
      pps.pps_act_cr_qp_offset >= 12 {
      return Err("EINVAL")
    }
  }
  pps.pps_palette_predictor_initializers_present_flag = gb
    .read1()
    .reinterpret_as_int()
  if pps.pps_palette_predictor_initializers_present_flag != 0 {
    pps.pps_num_palette_predictor_initializers = gb.read_ue()
    if pps.pps_num_palette_predictor_initializers < 0 ||
      pps.pps_num_palette_predictor_initializers >
      hevc_max_palette_predictor_size {
      return Err("EINVAL")
    }
    if pps.pps_num_palette_predictor_initializers > 0 {
      pps.monochrome_palette_flag = gb.read1().reinterpret_as_int()
      pps.luma_bit_depth_entry = gb.read_ue31() + 8
      if pps.luma_bit_depth_entry != sps.bit_depth {
        return Err("EINVAL")
      }
      if pps.monochrome_palette_flag == 0 {
        pps.chroma_bit_depth_entry = gb.read_ue31() + 8
        if pps.chroma_bit_depth_entry != sps.bit_depth_chroma {
          return Err("EINVAL")
        }
      }
      let num_comps = if pps.monochrome_palette_flag != 0 { 1 } else { 3 }
      for comp = 0; comp < num_comps; comp = comp + 1 {
        let depth = if comp == 0 {
          pps.luma_bit_depth_entry
        } else {
          pps.chroma_bit_depth_entry
        }
        for i = 0; i < pps.pps_num_palette_predictor_initializers; i = i + 1 {
          pps.pps_palette_predictor_initializer[comp][i] = gb
            .read(depth)
            .reinterpret_as_int()
        }
      }
    }
  }
  Ok(())
}

///|
/// `ff_hevc_decode_nal_pps`. */

///|
/// `setup_pps` (ps.c): uniform tile sizes and the CTB raster/tile-scan maps. */
fn hevc_setup_pps_tiles(pps : HevcPps, sps : HevcSps) -> Unit {
  let ncols = pps.num_tile_columns
  let nrows = pps.num_tile_rows
  let w = sps.ctb_width
  let h = sps.ctb_height
  if pps.uniform_spacing_flag != 0 {
    pps.column_width.clear()
    pps.row_height.clear()
    for i in 0..<ncols {
      pps.column_width.push((i + 1) * w / ncols - i * w / ncols)
    }
    for i in 0..<nrows {
      pps.row_height.push((i + 1) * h / nrows - i * h / nrows)
    }
  }
  pps.col_bd.clear()
  pps.col_bd.push(0)
  for i in 0..<ncols {
    pps.col_bd.push(pps.col_bd[i] + pps.column_width[i])
  }
  pps.row_bd.clear()
  pps.row_bd.push(0)
  for i in 0..<nrows {
    pps.row_bd.push(pps.row_bd[i] + pps.row_height[i])
  }
  pps.col_idxX.clear()
  let mut j = 0
  for i in 0..<w {
    if i > pps.col_bd[j] {
      j = j + 1
    }
    pps.col_idxX.push(j)
  }
  let ctbs = w * h
  pps.ctb_addr_rs_to_ts.clear()
  pps.ctb_addr_ts_to_rs.clear()
  pps.tile_id.clear()
  for _ in 0..<ctbs {
    pps.ctb_addr_rs_to_ts.push(0)
    pps.ctb_addr_ts_to_rs.push(0)
    pps.tile_id.push(0)
  }
  for rs in 0..<ctbs {
    let tb_x = rs % w
    let tb_y = rs / w
    let mut tile_x = 0
    let mut tile_y = 0
    for i in 0..<ncols {
      if tb_x < pps.col_bd[i + 1] {
        tile_x = i
        break
      }
    }
    for i in 0..<nrows {
      if tb_y < pps.row_bd[i + 1] {
        tile_y = i
        break
      }
    }
    let mut val = 0
    for i in 0..<tile_x {
      val = val + pps.row_height[tile_y] * pps.column_width[i]
    }
    for i in 0..<tile_y {
      val = val + w * pps.row_height[i]
    }
    val = val +
      (tb_y - pps.row_bd[tile_y]) * pps.column_width[tile_x] +
      tb_x -
      pps.col_bd[tile_x]
    pps.ctb_addr_rs_to_ts[rs] = val
    pps.ctb_addr_ts_to_rs[val] = rs
  }
  let mut tile = 0
  for ty in 0..<nrows {
    for tx in 0..<ncols {
      for y in pps.row_bd[ty]..<pps.row_bd[ty + 1] {
        for x in pps.col_bd[tx]..<pps.col_bd[tx + 1] {
          pps.tile_id[pps.ctb_addr_rs_to_ts[y * w + x]] = tile
        }
      }
      tile = tile + 1
    }
  }
}

///|
pub fn ff_hevc_decode_nal_pps(
  gb : BitReader,
  ps : HevcParamSets,
) -> Result[Unit, String] {
  let pps_id = gb.read_ue_long().to_int()
  if pps_id < 0 || pps_id >= hevc_max_pps_count {
    return Err("EINVAL")
  }
  let (data, data_size) = parameter_set_data_hevc(gb)
  let pps = new_hevc_pps()
  pps.data = data
  pps.data_size = data_size
  pps.pps_id = pps_id
  pps.sps_id = gb.read_ue_long().to_int()
  if pps.sps_id < 0 || pps.sps_id >= hevc_max_sps_count {
    return Err("EINVAL")
  }
  let sps = match ps.sps_list[pps.sps_id] {
    Some(s) => s
    None => return Err("EINVAL")
  }
  pps.dependent_slice_segments_enabled_flag = gb.read1().reinterpret_as_int()
  pps.output_flag_present_flag = gb.read1().reinterpret_as_int()
  pps.num_extra_slice_header_bits = gb.read(3).reinterpret_as_int()
  pps.sign_data_hiding_flag = gb.read1().reinterpret_as_int()
  pps.cabac_init_present_flag = gb.read1().reinterpret_as_int()
  pps.num_ref_idx_l0_default_active = gb.read_ue31() + 1
  pps.num_ref_idx_l1_default_active = gb.read_ue31() + 1
  if pps.num_ref_idx_l0_default_active < 1 ||
    pps.num_ref_idx_l0_default_active >= hevc_max_refs ||
    pps.num_ref_idx_l1_default_active < 1 ||
    pps.num_ref_idx_l1_default_active >= hevc_max_refs {
    return Err("EINVAL")
  }
  pps.pic_init_qp_minus26 = gb.read_se()
  pps.constrained_intra_pred_flag = gb.read1().reinterpret_as_int()
  pps.transform_skip_enabled_flag = gb.read1().reinterpret_as_int()
  pps.cu_qp_delta_enabled_flag = gb.read1().reinterpret_as_int()
  if pps.cu_qp_delta_enabled_flag != 0 {
    pps.diff_cu_qp_delta_depth = gb.read_ue_long().to_int()
  }
  if pps.diff_cu_qp_delta_depth < 0 ||
    pps.diff_cu_qp_delta_depth > sps.log2_diff_max_min_coding_block_size {
    return Err("EINVAL")
  }
  pps.cb_qp_offset = gb.read_se()
  if pps.cb_qp_offset < -12 || pps.cb_qp_offset > 12 {
    return Err("EINVAL")
  }
  pps.cr_qp_offset = gb.read_se()
  if pps.cr_qp_offset < -12 || pps.cr_qp_offset > 12 {
    return Err("EINVAL")
  }
  pps.pic_slice_level_chroma_qp_offsets_present_flag = gb
    .read1()
    .reinterpret_as_int()
  pps.weighted_pred_flag = gb.read1().reinterpret_as_int()
  pps.weighted_bipred_flag = gb.read1().reinterpret_as_int()
  pps.transquant_bypass_enable_flag = gb.read1().reinterpret_as_int()
  pps.tiles_enabled_flag = gb.read1().reinterpret_as_int()
  pps.entropy_coding_sync_enabled_flag = gb.read1().reinterpret_as_int()
  if pps.tiles_enabled_flag != 0 {
    let cols = gb.read_ue()
    let rows = gb.read_ue()
    if cols < 0 || cols >= sps.ctb_width || rows < 0 || rows >= sps.ctb_height {
      return Err("EINVAL")
    }
    pps.num_tile_columns = cols + 1
    pps.num_tile_rows = rows + 1
    pps.uniform_spacing_flag = gb.read1().reinterpret_as_int()
    if pps.uniform_spacing_flag == 0 {
      let mut sum = 0L
      for i = 0; i < pps.num_tile_columns - 1; i = i + 1 {
        let w = gb.read_ue_long().reinterpret_as_int64() + 1L
        pps.column_width.push(w.to_int())
        sum = sum + w
      }
      if sum >= sps.ctb_width.to_int64() {
        return Err("EINVAL")
      }
      pps.column_width.push((sps.ctb_width.to_int64() - sum).to_int())
      sum = 0L
      for i = 0; i < pps.num_tile_rows - 1; i = i + 1 {
        let h = gb.read_ue_long().reinterpret_as_int64() + 1L
        pps.row_height.push(h.to_int())
        sum = sum + h
      }
      if sum >= sps.ctb_height.to_int64() {
        return Err("EINVAL")
      }
      pps.row_height.push((sps.ctb_height.to_int64() - sum).to_int())
    }
    pps.loop_filter_across_tiles_enabled_flag = gb.read1().reinterpret_as_int()
  }
  pps.seq_loop_filter_across_slices_enabled_flag = gb
    .read1()
    .reinterpret_as_int()
  pps.deblocking_filter_control_present_flag = gb.read1().reinterpret_as_int()
  if pps.deblocking_filter_control_present_flag != 0 {
    pps.deblocking_filter_override_enabled_flag = gb
      .read1()
      .reinterpret_as_int()
    pps.disable_dbf = gb.read1().reinterpret_as_int()
    if pps.disable_dbf == 0 {
      let beta = gb.read_se()
      let tc = gb.read_se()
      if beta < -6 || beta > 6 || tc < -6 || tc > 6 {
        return Err("EINVAL")
      }
      pps.beta_offset = 2 * beta
      pps.tc_offset = 2 * tc
    }
  }
  pps.scaling_list_data_present_flag = gb.read1().reinterpret_as_int()
  if pps.scaling_list_data_present_flag != 0 {
    set_default_scaling_list_data(pps.scaling_list)
    match scaling_list_data(gb, pps.scaling_list, sps) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
  }
  pps.lists_modification_present_flag = gb.read1().reinterpret_as_int()
  let log2_merge = gb.read_ue_long().to_int()
  if log2_merge < 0 || log2_merge > sps.log2_ctb_size {
    return Err("EINVAL")
  }
  pps.log2_parallel_merge_level = log2_merge + 2
  pps.slice_header_extension_present_flag = gb.read1().reinterpret_as_int()
  pps.pps_extension_present_flag = gb.read1().reinterpret_as_int()
  if pps.pps_extension_present_flag != 0 {
    pps.pps_range_extensions_flag = gb.read1().reinterpret_as_int()
    pps.pps_multilayer_extension_flag = gb.read1().reinterpret_as_int()
    pps.pps_3d_extension_flag = gb.read1().reinterpret_as_int()
    pps.pps_scc_extension_flag = gb.read1().reinterpret_as_int()
    gb.skip(4) // pps_extension_4bits
    if pps.pps_multilayer_extension_flag != 0 || pps.pps_3d_extension_flag != 0 {
      return Err("PATCHWELCOME")
    }
    if sps.ptl.general_ptl.profile_idc >= av_profile_hevc_rext &&
      pps.pps_range_extensions_flag != 0 {
      match pps_range_extensions(gb, pps, sps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
    if pps.pps_scc_extension_flag != 0 {
      match pps_scc_extension(gb, pps, sps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  if gb.bits_left() < 0 {
    // C only warns here.
  }
  hevc_setup_pps_tiles(pps, sps)
  ps.pps_list[pps_id] = Some(pps)
  Ok(())
}

///|
/// `ff_hevc_compute_poc2`. */
pub fn ff_hevc_compute_poc2(
  log2_max_poc_lsb : Int32,
  poc_tid0 : Int32,
  poc_lsb : Int32,
  nal_unit_type : Int32,
) -> Int32 {
  let max_poc_lsb = 1 << log2_max_poc_lsb
  let prev_poc_lsb = poc_tid0 % max_poc_lsb
  let prev_poc_msb = poc_tid0 - prev_poc_lsb
  let mut poc_msb = prev_poc_msb
  if poc_lsb < prev_poc_lsb && prev_poc_lsb - poc_lsb >= max_poc_lsb / 2 {
    poc_msb = prev_poc_msb + max_poc_lsb
  } else if poc_lsb > prev_poc_lsb && poc_lsb - prev_poc_lsb > max_poc_lsb / 2 {
    poc_msb = prev_poc_msb - max_poc_lsb
  }
  // HEVC_NAL_BLA_W_LP / BLA_W_RADL / BLA_N_LP = 16/17/18
  if nal_unit_type == 16 || nal_unit_type == 17 || nal_unit_type == 18 {
    poc_msb = 0
  }
  poc_msb + poc_lsb
}

// ---------------------------------------------------------------------------
// extradata
// ---------------------------------------------------------------------------

///|
/// `ff_hevc_decode_extradata` results. */
pub struct HevcExtradataInfo {
  is_nalff : Bool
  nal_length_size : Int32
}

///|
/// Decode VPS/SPS/PPS NALs from an extradata packet (SEI is skipped). */
fn hevc_decode_extradata_nals(
  pkt : H2645Packet,
  ps : HevcParamSets,
  apply_defdispwin : Bool,
) -> Result[Unit, String] {
  for i = 0; i < pkt.nals.length(); i = i + 1 {
    let nal = pkt.nals[i]
    if nal.nal_type == hevc_nal_vps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      match ff_hevc_decode_nal_vps(gb, ps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    } else if nal.nal_type == hevc_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      match ff_hevc_decode_nal_sps(gb, ps, nal.nuh_layer_id, apply_defdispwin) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    } else if nal.nal_type == hevc_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(16)
      match ff_hevc_decode_nal_pps(gb, ps) {
        Err(e) => return Err(e)
        Ok(_) => ()
      }
    }
  }
  Ok(())
}

///|
/// `ff_hevc_decode_extradata`: accepts an `hvcC` record or Annex B data.
pub fn ff_hevc_decode_extradata(
  data : Bytes,
  ps : HevcParamSets,
  apply_defdispwin : Bool,
) -> Result[HevcExtradataInfo, String] {
  if data.length() >= 23 &&
    (
      data[0] == b'\x01' ||
      (data[0] == b'\x00' && (data[1] != b'\x00' || data[2] > b'\x01'))
    ) {
    let mut p = 21
    let nal_len_size = (data[p].to_int() & 3) + 1
    p = p + 1
    let num_arrays = data[p].to_int()
    p = p + 1
    for _ in 0..<num_arrays {
      if p + 3 > data.length() {
        return Err("EINVAL")
      }
      p = p + 1 // array_completeness + NAL_unit_type
      let cnt = (data[p].to_int() << 8) | data[p + 1].to_int()
      p = p + 2
      for _ in 0..<cnt {
        if p + 2 > data.length() {
          return Err("EINVAL")
        }
        let nalsize = ((data[p].to_int() << 8) | data[p + 1].to_int()) + 2
        if nalsize > data.length() - p {
          return Err("EINVAL")
        }
        let chunk = data.clamped_view(start=p, end=p + nalsize).to_owned()
        let pkt = match ff_h2645_packet_split(chunk, 2, Hevc, true) {
          Err(e) => return Err(e)
          Ok(v) => v
        }
        match hevc_decode_extradata_nals(pkt, ps, apply_defdispwin) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
        p = p + nalsize
      }
    }
    Ok({ is_nalff: true, nal_length_size: nal_len_size, })
  } else {
    let pkt = match ff_h2645_packet_split(data, 0, Hevc, false) {
      Err(e) => return Err(e)
      Ok(v) => v
    }
    match hevc_decode_extradata_nals(pkt, ps, apply_defdispwin) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    Ok({ is_nalff: false, nal_length_size: 0, })
  }
}
