///|
/// MoonBit port of the VP9 frame header from FFmpeg 9.0.2
/// `libavcodec/vp9.c` (`decode_frame_header`, `read_colorspace_details`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: the complete uncompressed header (marker/profile, show-existing,
/// key/intra/inter frame fields, loop filter, quantization, segmentation,
/// tile layout and the compressed-header size), the arithmetic-coded header
/// prefix (marker, transform mode, transform/skip probability updates and all
/// coefficient/mode/MV update syntax), and tile-size splitting.  Pixel
/// reconstruction is out of scope.
///
/// Inter-frame dimensions are normally inherited from a reference frame.  Use
/// `vp9_parse_frame_header_with_refs` / `vp9_parse_packet_with_refs` and pass
/// the eight reference slots when that is the case; the no-refs entry points
/// return a partial header (`complete == false`) for such frames.  Probability
/// contexts are not persisted across frames: the syntax is consumed exactly,
/// but inter-frame inherited loop-filter/segmentation/coefficient probabilities
/// use the keyframe defaults instead of the previous frame's values.

///|
pub struct Vp9SegmentationFeature {
  mut q_enabled : Bool
  mut q_value : Int32
  mut lf_enabled : Bool
  mut lf_value : Int32
  mut ref_enabled : Bool
  mut ref_value : Int32
  mut skip_enabled : Bool
}

///|
pub struct Vp9Segmentation {
  mut enabled : Bool
  mut update_map : Bool
  mut update_data : Bool
  mut temporal : Bool
  mut absolute_vals : Bool
  tree_probs : Array[Int32]
  pred_probs : Array[Int32]
  features : Array[Vp9SegmentationFeature]
}

///|
fn vp9_default_segmentation() -> Vp9Segmentation {
  let features : Array[Vp9SegmentationFeature] = []
  for _ in 0..<8 {
    features.push({
      q_enabled: false,
      q_value: 0,
      lf_enabled: false,
      lf_value: 0,
      ref_enabled: false,
      ref_value: 0,
      skip_enabled: false,
    })
  }
  {
    enabled: false,
    update_map: false,
    update_data: false,
    temporal: false,
    absolute_vals: false,
    tree_probs: [255, 255, 255, 255, 255, 255, 255],
    pred_probs: [255, 255, 255],
    features,
  }
}

///|
pub struct Vp9FrameHeader {
  mut profile : Int32
  mut keyframe : Bool
  mut show_existing_frame : Bool
  /// 0-based index when `show_existing_frame` is set, else -1.
  mut frame_to_show : Int32
  mut show_frame : Bool
  mut error_resilient : Bool
  mut intra_only : Bool
  mut bit_depth : Int32
  mut color_space : Int32
  mut color_range : Int32
  mut chroma_subsampling_x : Bool
  mut chroma_subsampling_y : Bool
  mut width : Int32
  mut height : Int32
  mut render_width : Int32
  mut render_height : Int32
  mut refresh_frame_flags : Int32
  ref_indices : Array[Int32]
  ref_sign_biases : Array[Bool]
  /// Index into `ref_indices` whose size was inherited, or -1 for an explicit
  /// frame size.
  mut frame_size_from_ref : Int32
  /// `reset_frame_context` (0..3); 0 for keyframes and error-resilient frames.
  mut resetctx : Int32
  /// `refresh_frame_context` (0/1).
  mut refreshctx : Int32
  /// `frame_parallel_decoding_mode` (0/1).
  mut parallelmode : Int32
  mut frame_context_idx : Int32
  mut filter_level : Int32
  mut filter_sharpness : Int32
  mut lf_delta_enabled : Bool
  mut lf_delta_updated : Bool
  lf_ref_deltas : Array[Int32]
  lf_mode_deltas : Array[Int32]
  mut base_q_idx : Int32
  mut ydc_qdelta : Int32
  mut uvdc_qdelta : Int32
  mut uvac_qdelta : Int32
  mut lossless : Bool
  segmentation : Vp9Segmentation
  mut log2_tile_cols : Int32
  mut log2_tile_rows : Int32
  mut tile_cols : Int32
  mut tile_rows : Int32
  mut uncompressed_header_size : Int32
  mut compressed_header_size : Int32
  mut header_size : Int32
  /// True once the uncompressed header and tile layout have been parsed.
  mut complete : Bool
  /// `TxfmMode`: 0=4x4, 1=8x8, 2=16x16, 3=32x32, 4=switchable; -1 until the
  /// arithmetic-coded header is parsed.
  mut tx_mode : Int32
  tx8p : Array[Int32]
  tx16p : Array[Array[Int32]]
  tx32p : Array[Array[Int32]]
  skip_probs : Array[Int32]
  mut high_precision_mvs : Bool
  /// 0..3, or 4 for `FILTER_SWITCHABLE`; -1 for intra frames.
  mut filter_mode : Int32
  mut allow_comp_inter : Bool
  /// 0=single ref, 1=compound ref, 2=switchable; -1 for intra frames.
  mut comp_pred_mode : Int32
  mut fix_comp_ref : Int32
  var_comp_refs : Array[Int32]
}

///|
fn vp9_default_header() -> Vp9FrameHeader {
  {
    profile: 0,
    keyframe: false,
    show_existing_frame: false,
    frame_to_show: -1,
    show_frame: true,
    error_resilient: false,
    intra_only: false,
    bit_depth: 8,
    color_space: 0,
    color_range: 0,
    chroma_subsampling_x: true,
    chroma_subsampling_y: true,
    width: 0,
    height: 0,
    render_width: 0,
    render_height: 0,
    refresh_frame_flags: 0,
    ref_indices: [],
    ref_sign_biases: [],
    frame_size_from_ref: -1,
    resetctx: 0,
    refreshctx: 0,
    parallelmode: 0,
    frame_context_idx: 0,
    filter_level: 0,
    filter_sharpness: 0,
    lf_delta_enabled: false,
    lf_delta_updated: false,
    lf_ref_deltas: [1, 0, -1, -1],
    lf_mode_deltas: [0, 0],
    base_q_idx: 0,
    ydc_qdelta: 0,
    uvdc_qdelta: 0,
    uvac_qdelta: 0,
    lossless: false,
    segmentation: vp9_default_segmentation(),
    log2_tile_cols: 0,
    log2_tile_rows: 0,
    tile_cols: 1,
    tile_rows: 1,
    uncompressed_header_size: 0,
    compressed_header_size: 0,
    header_size: 0,
    complete: false,
    tx_mode: -1,
    tx8p: [100, 66],
    tx16p: [[20, 152], [15, 101]],
    tx32p: [[3, 136, 37], [5, 52, 13]],
    skip_probs: [192, 128, 64],
    high_precision_mvs: false,
    filter_mode: -1,
    allow_comp_inter: false,
    comp_pred_mode: -1,
    fix_comp_ref: -1,
    var_comp_refs: [],
  }
}

///|
let vp9_sync_code : Int32 = 0x498342

///|
/// `read_colorspace_details`. */
fn vp9_read_colorspace_details(br : BitReader, h : Vp9FrameHeader) -> Bool {
  let mut bits = 0
  if h.profile >= 2 {
    bits = 1 + br.read(1).reinterpret_as_int()
  }
  h.bit_depth = match bits {
    0 => 8
    1 => 10
    2 => 12
    _ => 8
  }
  h.color_space = br.read(3).reinterpret_as_int()
  if h.color_space != 7 {
    // not RGB
    h.color_range = br.read(1).reinterpret_as_int()
    if h.profile == 1 || h.profile == 3 {
      h.chroma_subsampling_x = br.read(1) != 0
      h.chroma_subsampling_y = br.read(1) != 0
      if h.bit_depth == 8 && h.chroma_subsampling_x && h.chroma_subsampling_y {
        // 8-bit 4:2:0 is not allowed in profiles 1/3.
        return false
      }
      if br.read(1) != 0 {
        // Reserved bit must be zero.
        return false
      }
    } else {
      h.chroma_subsampling_x = true
      h.chroma_subsampling_y = true
    }
  } else {
    h.color_range = 1
    h.chroma_subsampling_x = false
    h.chroma_subsampling_y = false
  }
  true
}

///|
/// `get_sbits_inv`: magnitude first, sign bit at the end.
fn vp9_read_sbits_inv(br : BitReader, n : Int32) -> Int32 {
  let value = br.read(n).reinterpret_as_int()
  if br.read1() != 0 {
    -value
  } else {
    value
  }
}

///|
/// `decode012`.
fn vp9_decode012(br : BitReader) -> Int32 {
  if br.read1() == 0 {
    0
  } else {
    br.read1().reinterpret_as_int() + 1
  }
}

///|
fn vp9_read_lf_delta(br : BitReader, h : Vp9FrameHeader) -> Unit {
  h.lf_delta_enabled = br.read1() != 0
  if h.lf_delta_enabled {
    h.lf_delta_updated = br.read1() != 0
    if h.lf_delta_updated {
      for i in 0..<4 {
        if br.read1() != 0 {
          h.lf_ref_deltas[i] = vp9_read_sbits_inv(br, 6)
        }
      }
      for i in 0..<2 {
        if br.read1() != 0 {
          h.lf_mode_deltas[i] = vp9_read_sbits_inv(br, 6)
        }
      }
    }
  } else {
    h.lf_delta_updated = false
  }
}

///|
fn vp9_read_segmentation(br : BitReader, h : Vp9FrameHeader) -> Unit {
  let seg = h.segmentation
  seg.enabled = br.read1() != 0
  if !seg.enabled {
    seg.update_map = false
    seg.update_data = false
    seg.temporal = false
    return
  }
  seg.update_map = br.read1() != 0
  if seg.update_map {
    for i in 0..<7 {
      seg.tree_probs[i] = if br.read1() != 0 {
        br.read(8).reinterpret_as_int()
      } else {
        255
      }
    }
    seg.temporal = br.read1() != 0
    if seg.temporal {
      for i in 0..<3 {
        seg.pred_probs[i] = if br.read1() != 0 {
          br.read(8).reinterpret_as_int()
        } else {
          255
        }
      }
    } else {
      for i in 0..<3 {
        seg.pred_probs[i] = 255
      }
    }
  }
  seg.update_data = br.read1() != 0
  if seg.update_data {
    seg.absolute_vals = br.read1() != 0
    for i in 0..<8 {
      let feat = seg.features[i]
      feat.q_enabled = br.read1() != 0
      if feat.q_enabled {
        feat.q_value = vp9_read_sbits_inv(br, 8)
      }
      feat.lf_enabled = br.read1() != 0
      if feat.lf_enabled {
        feat.lf_value = vp9_read_sbits_inv(br, 6)
      }
      feat.ref_enabled = br.read1() != 0
      if feat.ref_enabled {
        feat.ref_value = br.read(2).reinterpret_as_int()
      }
      feat.skip_enabled = br.read1() != 0
    }
  }
}

///|
/// `tile_info` from `vp9.c`, including the legacy `max` computation.
fn vp9_read_tile_info(br : BitReader, h : Vp9FrameHeader) -> Unit {
  let sb_cols = (h.width + 63) >> 6
  let sb_rows = (h.height + 63) >> 6
  let mut log2_cols = 0
  while sb_cols > 64 << log2_cols {
    log2_cols = log2_cols + 1
  }
  let mut max = 0
  while sb_cols >> max >= 4 {
    max = max + 1
  }
  max = if max > 0 { max - 1 } else { 0 }
  while max > log2_cols {
    if br.read1() != 0 {
      log2_cols = log2_cols + 1
    } else {
      break
    }
  }
  h.log2_tile_cols = log2_cols
  h.log2_tile_rows = vp9_decode012(br)
  h.tile_cols = 1 << log2_cols
  h.tile_rows = 1 << h.log2_tile_rows
  // sb_rows is kept for parity with the C; the actual tile row partition is
  // recomputed from it by the pixel decoder.
  ignore(sb_rows)
}

///|
/// Resolve an inter frame's size from its reference slot when present.
fn vp9_read_inter_size(
  br : BitReader,
  h : Vp9FrameHeader,
  ref_widths : Array[Int32],
  ref_heights : Array[Int32],
) -> Unit {
  h.frame_size_from_ref = -1
  for i in 0..<3 {
    if br.read1() != 0 {
      h.frame_size_from_ref = i
      let ref_idx = h.ref_indices[i]
      if ref_idx >= 0 && ref_idx < ref_widths.length() {
        h.width = ref_widths[ref_idx]
        h.height = ref_heights[ref_idx]
      }
      break
    }
  }
  if h.frame_size_from_ref < 0 {
    h.width = br.read(16).reinterpret_as_int() + 1
    h.height = br.read(16).reinterpret_as_int() + 1
  }
}

///|
fn vp9_parse_frame_header_impl(
  data : Bytes,
  ref_widths : Array[Int32],
  ref_heights : Array[Int32],
) -> Result[Vp9FrameHeader, String] {
  if data.length() < 1 {
    return Err("vp9: empty frame")
  }
  let br = BitReader::new(data)
  if br.read(2) != 2U {
    return Err("vp9: invalid frame marker")
  }
  let h = vp9_default_header()
  h.profile = br.read(1).reinterpret_as_int() |
    (br.read(1).reinterpret_as_int() << 1)
  if h.profile == 3 {
    h.profile = h.profile + br.read(1).reinterpret_as_int()
  }
  if h.profile > 3 {
    return Err("vp9: unsupported profile")
  }
  if br.read(1) != 0 {
    h.show_existing_frame = true
    h.frame_to_show = br.read(3).reinterpret_as_int()
    return Ok(h)
  }
  h.keyframe = br.read(1) == 0
  h.show_frame = br.read(1) != 0
  h.error_resilient = br.read(1) != 0

  if h.keyframe {
    if br.read(24).reinterpret_as_int() != vp9_sync_code {
      return Err("vp9: invalid sync code")
    }
    if !vp9_read_colorspace_details(br, h) {
      return Err("vp9: reserved profile colour bit")
    }
    h.refresh_frame_flags = 0xFF
    h.width = br.read(16).reinterpret_as_int() + 1
    h.height = br.read(16).reinterpret_as_int() + 1
    if br.read1() != 0 {
      h.render_width = br.read(16).reinterpret_as_int() + 1
      h.render_height = br.read(16).reinterpret_as_int() + 1
    }
  } else {
    if !h.show_frame {
      h.intra_only = br.read1() != 0
    }
    // This field precedes the sync code for intra-only frames.
    h.resetctx = if h.error_resilient {
      0
    } else {
      br.read(2).reinterpret_as_int()
    }
    if h.intra_only {
      if br.read(24).reinterpret_as_int() != vp9_sync_code {
        return Err("vp9: invalid sync code")
      }
      if h.profile >= 1 {
        if !vp9_read_colorspace_details(br, h) {
          return Err("vp9: reserved profile colour bit")
        }
      } else {
        h.chroma_subsampling_x = true
        h.chroma_subsampling_y = true
        h.bit_depth = 8
        h.color_space = 1
        h.color_range = 0
      }
      h.refresh_frame_flags = br.read(8).reinterpret_as_int()
      h.width = br.read(16).reinterpret_as_int() + 1
      h.height = br.read(16).reinterpret_as_int() + 1
      if br.read1() != 0 {
        h.render_width = br.read(16).reinterpret_as_int() + 1
        h.render_height = br.read(16).reinterpret_as_int() + 1
      }
    } else {
      h.refresh_frame_flags = br.read(8).reinterpret_as_int()
      for _ in 0..<3 {
        h.ref_indices.push(br.read(3).reinterpret_as_int())
        let sign = br.read1() != 0 && !h.error_resilient
        h.ref_sign_biases.push(sign)
      }
      vp9_read_inter_size(br, h, ref_widths, ref_heights)
      if br.read1() != 0 {
        h.render_width = br.read(16).reinterpret_as_int() + 1
        h.render_height = br.read(16).reinterpret_as_int() + 1
      }
      h.high_precision_mvs = br.read1() != 0
      h.filter_mode = if br.read1() != 0 {
        4
      } else {
        br.read(2).reinterpret_as_int()
      }
      h.allow_comp_inter = h.ref_sign_biases[0] != h.ref_sign_biases[1] ||
        h.ref_sign_biases[0] != h.ref_sign_biases[2]
      if h.allow_comp_inter {
        if h.ref_sign_biases[0] == h.ref_sign_biases[1] {
          h.fix_comp_ref = 2
          h.var_comp_refs.push(0)
          h.var_comp_refs.push(1)
        } else if h.ref_sign_biases[0] == h.ref_sign_biases[2] {
          h.fix_comp_ref = 1
          h.var_comp_refs.push(0)
          h.var_comp_refs.push(2)
        } else {
          h.fix_comp_ref = 0
          h.var_comp_refs.push(1)
          h.var_comp_refs.push(2)
        }
      }
    }
  }

  h.refreshctx = if h.error_resilient {
    0
  } else {
    br.read1().reinterpret_as_int()
  }
  h.parallelmode = if h.error_resilient {
    1
  } else {
    br.read1().reinterpret_as_int()
  }
  h.frame_context_idx = br.read(2).reinterpret_as_int()
  if h.keyframe || h.intra_only {
    // libvpx ignores this field in key/intra frames; FFmpeg mirrors that.
    h.frame_context_idx = 0
  }

  if h.keyframe || h.error_resilient || h.intra_only {
    h.lf_ref_deltas[0] = 1
    h.lf_ref_deltas[1] = 0
    h.lf_ref_deltas[2] = -1
    h.lf_ref_deltas[3] = -1
    h.lf_mode_deltas[0] = 0
    h.lf_mode_deltas[1] = 0
    for i in 0..<8 {
      let feat = h.segmentation.features[i]
      feat.q_enabled = false
      feat.q_value = 0
      feat.lf_enabled = false
      feat.lf_value = 0
      feat.ref_enabled = false
      feat.ref_value = 0
      feat.skip_enabled = false
    }
  }
  h.filter_level = br.read(6).reinterpret_as_int()
  h.filter_sharpness = br.read(3).reinterpret_as_int()
  vp9_read_lf_delta(br, h)

  h.base_q_idx = br.read(8).reinterpret_as_int()
  h.ydc_qdelta = if br.read1() != 0 { vp9_read_sbits_inv(br, 4) } else { 0 }
  h.uvdc_qdelta = if br.read1() != 0 { vp9_read_sbits_inv(br, 4) } else { 0 }
  h.uvac_qdelta = if br.read1() != 0 { vp9_read_sbits_inv(br, 4) } else { 0 }
  h.lossless = h.base_q_idx == 0 &&
    h.ydc_qdelta == 0 &&
    h.uvdc_qdelta == 0 &&
    h.uvac_qdelta == 0

  vp9_read_segmentation(br, h)

  // Tile-info syntax needs sb_cols.  For inter frames whose size comes from a
  // reference, callers without the reference dimensions cannot locate the
  // compressed header.
  if h.width <= 0 || h.height <= 0 {
    return Ok(h)
  }
  vp9_read_tile_info(br, h)
  h.compressed_header_size = br.read(16).reinterpret_as_int()
  h.uncompressed_header_size = (br.count() + 7) / 8
  h.header_size = h.uncompressed_header_size + h.compressed_header_size
  br.align()
  if h.uncompressed_header_size > data.length() {
    return Err("vp9: uncompressed header exceeds packet")
  }
  h.complete = true
  Ok(h)
}

///|
/// Parse a VP9 uncompressed frame header.  For inter frames whose size is
/// inherited from a reference frame this returns `complete == false`; pass the
/// reference sizes to `vp9_parse_frame_header_with_refs` to finish the header.
pub fn vp9_parse_frame_header(data : Bytes) -> Result[Vp9FrameHeader, String] {
  vp9_parse_frame_header_impl(data, [], [])
}

///|
/// Parse a VP9 uncompressed frame header using eight reference-frame sizes.
pub fn vp9_parse_frame_header_with_refs(
  data : Bytes,
  ref_widths : Array[Int32],
  ref_heights : Array[Int32],
) -> Result[Vp9FrameHeader, String] {
  vp9_parse_frame_header_impl(data, ref_widths, ref_heights)
}

///|
/// Consume one `if (vpx_rac_get_prob_branchy(&c, 252)) update_prob(...)` pair.
fn vp9_consume_prob_update(c : Vp9RangeDecoder) -> Unit {
  if vp9_rac_get_prob(c, 252) != 0 {
    ignore(vp9_rac_update_prob(c, 128))
  }
}

///|
fn vp9_consume_coef_updates(c : Vp9RangeDecoder, h : Vp9FrameHeader) -> Unit {
  for i in 0..<4 {
    if vp9_rac_get_prob(c, 128) != 0 {
      for _j in 0..<2 {
        for _k in 0..<2 {
          for l in 0..<6 {
            for m in 0..<6 {
              // DC has only three probabilities.
              if !(l == 0 && m >= 3) {
                for _n in 0..<3 {
                  if vp9_rac_get_prob(c, 252) != 0 {
                    ignore(vp9_rac_update_prob(c, 128))
                  }
                }
              }
            }
          }
        }
      }
    }
    if h.tx_mode == i {
      break
    }
  }
}

///|
fn vp9_consume_inter_mode_updates(
  c : Vp9RangeDecoder,
  h : Vp9FrameHeader,
) -> Unit {
  for _i in 0..<7 {
    for _j in 0..<3 {
      vp9_consume_prob_update(c)
    }
  }
  if h.filter_mode == 4 {
    for _i in 0..<4 {
      for _j in 0..<2 {
        vp9_consume_prob_update(c)
      }
    }
  }
  for _i in 0..<4 {
    vp9_consume_prob_update(c)
  }
  if h.allow_comp_inter {
    h.comp_pred_mode = vp9_rac_get_bool(c)
    if h.comp_pred_mode != 0 {
      h.comp_pred_mode = h.comp_pred_mode + vp9_rac_get_bool(c)
    }
    if h.comp_pred_mode == 2 {
      for _i in 0..<5 {
        vp9_consume_prob_update(c)
      }
    }
  } else {
    h.comp_pred_mode = 0
  }
  if h.comp_pred_mode != 1 {
    for _i in 0..<5 {
      vp9_consume_prob_update(c)
      vp9_consume_prob_update(c)
    }
  }
  if h.comp_pred_mode != 0 {
    for _i in 0..<5 {
      vp9_consume_prob_update(c)
    }
  }
  for _i in 0..<4 {
    for _j in 0..<9 {
      vp9_consume_prob_update(c)
    }
  }
  for _i in 0..<4 {
    for _j in 0..<4 {
      for _k in 0..<3 {
        vp9_consume_prob_update(c)
      }
    }
  }
  for _i in 0..<3 {
    if vp9_rac_get_prob(c, 252) != 0 {
      ignore(vp9_rac_get_uint(c, 7))
    }
  }
  for _i in 0..<2 {
    if vp9_rac_get_prob(c, 252) != 0 {
      ignore(vp9_rac_get_uint(c, 7))
    }
    for _j in 0..<10 {
      if vp9_rac_get_prob(c, 252) != 0 {
        ignore(vp9_rac_get_uint(c, 7))
      }
    }
    if vp9_rac_get_prob(c, 252) != 0 {
      ignore(vp9_rac_get_uint(c, 7))
    }
    for _j in 0..<10 {
      if vp9_rac_get_prob(c, 252) != 0 {
        ignore(vp9_rac_get_uint(c, 7))
      }
    }
  }
  for _i in 0..<2 {
    for _j in 0..<2 {
      for _k in 0..<3 {
        if vp9_rac_get_prob(c, 252) != 0 {
          ignore(vp9_rac_get_uint(c, 7))
        }
      }
    }
    for _j in 0..<3 {
      if vp9_rac_get_prob(c, 252) != 0 {
        ignore(vp9_rac_get_uint(c, 7))
      }
    }
  }
  if h.high_precision_mvs {
    for _i in 0..<2 {
      if vp9_rac_get_prob(c, 252) != 0 {
        ignore(vp9_rac_get_uint(c, 7))
      }
      if vp9_rac_get_prob(c, 252) != 0 {
        ignore(vp9_rac_get_uint(c, 7))
      }
    }
  }
}

///|
/// Parse the arithmetic-coded header and fill transform mode and updated
/// transform/skip probabilities.  Other probability updates are consumed but
/// not persisted (the syntax is independent of their values).
fn vp9_parse_compressed_header(
  data : Bytes,
  h : Vp9FrameHeader,
) -> Result[Unit, String] {
  let c = match
    vp9_rac_init(data, h.uncompressed_header_size, h.compressed_header_size) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if vp9_rac_get_prob(c, 128) != 0 {
    return Err("vp9: marker bit was set")
  }
  if h.lossless {
    h.tx_mode = 0
  } else {
    h.tx_mode = vp9_rac_get_uint(c, 2)
    if h.tx_mode == 3 {
      h.tx_mode = h.tx_mode + vp9_rac_get_bool(c)
    }
    if h.tx_mode == 4 {
      for i in 0..<2 {
        if vp9_rac_get_prob(c, 252) != 0 {
          h.tx8p[i] = vp9_rac_update_prob(c, h.tx8p[i])
        }
      }
      for i in 0..<2 {
        for j in 0..<2 {
          if vp9_rac_get_prob(c, 252) != 0 {
            h.tx16p[i][j] = vp9_rac_update_prob(c, h.tx16p[i][j])
          }
        }
      }
      for i in 0..<2 {
        for j in 0..<3 {
          if vp9_rac_get_prob(c, 252) != 0 {
            h.tx32p[i][j] = vp9_rac_update_prob(c, h.tx32p[i][j])
          }
        }
      }
    }
  }
  vp9_consume_coef_updates(c, h)
  for i in 0..<3 {
    if vp9_rac_get_prob(c, 252) != 0 {
      h.skip_probs[i] = vp9_rac_update_prob(c, h.skip_probs[i])
    }
  }
  if !h.keyframe && !h.intra_only {
    vp9_consume_inter_mode_updates(c, h)
  }
  Ok(())
}

///|
/// One tile's byte range inside a packet.
pub struct Vp9Tile {
  row : Int32
  col : Int32
  offset : Int32
  size : Int32
}

///|
/// Parsed packet structure: header plus tile byte ranges.
pub struct Vp9PacketInfo {
  header : Vp9FrameHeader
  tiles : Array[Vp9Tile]
  /// Byte offset of the first tile payload.
  tile_data_offset : Int32
  /// Uncompressed + arithmetic-coded header bytes.
  header_size : Int32
}

///|
fn vp9_parse_packet_impl(
  data : Bytes,
  ref_widths : Array[Int32],
  ref_heights : Array[Int32],
) -> Result[Vp9PacketInfo, String] {
  let h = match vp9_parse_frame_header_impl(data, ref_widths, ref_heights) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  if h.show_existing_frame {
    return Ok({ header: h, tiles: [], tile_data_offset: 0, header_size: 0, })
  }
  if !h.complete {
    return Err("vp9: inter frame size requires reference dimensions")
  }
  if h.uncompressed_header_size + h.compressed_header_size > data.length() {
    return Err("vp9: compressed header exceeds packet")
  }
  match vp9_parse_compressed_header(data, h) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let header_end = h.uncompressed_header_size + h.compressed_header_size
  let tiles : Array[Vp9Tile] = []
  let mut pos = header_end
  let mut size = data.length() - pos
  let tile_count = h.tile_cols * h.tile_rows
  let mut index = 0
  for row in 0..<h.tile_rows {
    for col in 0..<h.tile_cols {
      let is_last = index == tile_count - 1
      let tile_size = if is_last {
        size
      } else {
        if size < 4 {
          return Err("vp9: truncated tile size")
        }
        let v = (data[pos].to_int() << 24) |
          (data[pos + 1].to_int() << 16) |
          (data[pos + 2].to_int() << 8) |
          data[pos + 3].to_int()
        pos = pos + 4
        size = size - 4
        v
      }
      if tile_size < 1 || tile_size > size {
        return Err("vp9: invalid tile size")
      }
      tiles.push({ row, col, offset: pos, size: tile_size, })
      pos = pos + tile_size
      size = size - tile_size
      index = index + 1
    }
  }
  Ok({
    header: h,
    tiles,
    tile_data_offset: header_end,
    header_size: header_end,
  })
}

///|
/// Parse a complete VP9 packet.  Inter frames need reference dimensions; use
/// `vp9_parse_packet_with_refs` for those.
pub fn vp9_parse_packet(data : Bytes) -> Result[Vp9PacketInfo, String] {
  vp9_parse_packet_impl(data, [], [])
}

///|
/// Parse a complete VP9 packet using eight reference-frame sizes.
pub fn vp9_parse_packet_with_refs(
  data : Bytes,
  ref_widths : Array[Int32],
  ref_heights : Array[Int32],
) -> Result[Vp9PacketInfo, String] {
  vp9_parse_packet_impl(data, ref_widths, ref_heights)
}

///|
/// Split a VP9 superframe packet (`libavcodec/bsf/vp9_superframe_split.c`).
/// A trailing index of `1 + (marker & 7)` frames with `1 + ((marker >> 3) & 3)`
/// bytes per length is recognized when both the first and last index bytes
/// equal the marker (`0b110xxxxx`). Non-superframe input is returned as one
/// frame with `is_superframe == false`.
pub struct Vp9Superframe {
  is_superframe : Bool
  frames : Array[Bytes]
}

///|
pub fn vp9_split_superframe(data : Bytes) -> Result[Vp9Superframe, String] {
  if data.length() == 0 {
    return Ok({ is_superframe: false, frames: [data], })
  }
  let marker = data[data.length() - 1].to_int()
  if (marker & 0xE0) != 0xC0 {
    return Ok({ is_superframe: false, frames: [data], })
  }
  let length_size = 1 + ((marker >> 3) & 0x3)
  let nb_frames = 1 + (marker & 0x7)
  let idx_size = 2 + nb_frames * length_size
  if data.length() < idx_size ||
    data[data.length() - idx_size].to_int() != marker {
    return Ok({ is_superframe: false, frames: [data], })
  }
  let idx_start = data.length() - idx_size + 1
  let sizes : Array[Int32] = []
  let mut total = 0
  for i in 0..<nb_frames {
    let mut size = 0
    for j in 0..<length_size {
      size = size | (data[idx_start + i * length_size + j].to_int() << (j * 8))
    }
    if size <= 0 {
      return Err("vp9: invalid superframe size")
    }
    total = total + size
    sizes.push(size)
  }
  if total > data.length() - idx_size {
    return Err("vp9: superframe sizes exceed packet")
  }
  let frames : Array[Bytes] = []
  let mut off = 0
  for size in sizes {
    frames.push(data[off:off + size].to_owned())
    off = off + size
  }
  Ok({ is_superframe: true, frames, })
}
