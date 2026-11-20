///|
/// AV1 key-frame header + frame OBU writer (§439) — the write-side twin
/// of `av1_parse_frame_header`'s key-frame branch (spec 5.9.x /
/// libavformat av1.c bit order) restricted to the capability set the
/// §438b sequence writer emits: profile 0, inter tools off, CDEF/LR
/// off, film grain off, one operating point with chosen screen-content
/// and integer-MV selectors (2/2). The frame OBU is OBU_FRAME (type 6):
/// uncompressed header, byte-aligned, then the tile group (one tile —
/// no tg bits, no size prefix for the last tile).

///|
/// The writer-facing key-frame configuration.
pub(all) struct Av1KeyFrameEncConfig {
  /// Base qindex 1..255 (0 would be lossless and drop loop_filter from
  /// the header; the writer rejects 0 to keep one header shape).
  base_q_idx : Int32
  /// Loop filter levels for the Y planes (0..63). U/V inherit the
  /// spec's "chroma levels present only when luma is nonzero" shape:
  /// both zero keeps the header minimal.
  loop_filter_level0 : Int32
  loop_filter_level1 : Int32
  /// Loop sharpness 0..7.
  loop_filter_sharpness : Int32
  /// The tile's entropy payload (the msac-coded tile data) — the legacy
  /// §439 single-tile slot, used when `tiles` is empty.
  tile_data : Bytes
  /// §444 multi-tile payloads in raster order (tile row by tile row);
  /// must hold exactly `tile_cols * tile_rows` entries. A single entry
  /// keeps the legacy single-tile shape (no tg bits, no size prefixes).
  tiles : Array[Bytes]
  /// Tile grid (uniform spacing, powers of two). 1x1 with empty `tiles`
  /// reproduces the §439 frame.
  tile_cols : Int32
  tile_rows : Int32
}

///|
/// Default key-frame configuration: qindex 100 (a mid-quality still),
/// loop filter off, empty tile.
pub fn Av1KeyFrameEncConfig::default() -> Av1KeyFrameEncConfig {
  {
    base_q_idx: 100,
    loop_filter_level0: 0,
    loop_filter_level1: 0,
    loop_filter_sharpness: 0,
    tile_data: b"",
    tiles: [],
    tile_cols: 1,
    tile_rows: 1,
  }
}

///|
/// The writer-facing inter-frame configuration (§446). Restricted to
/// the §438b sequence's capability set: no order hints, single-size
/// frames, superres/CDEF/LR/warp/film-grain off — so the header keeps
/// one fixed shape around the configurable fields.
pub(all) struct Av1InterFrameEncConfig {
  /// Base qindex 1..255 (0 would be lossless and drop loop_filter
  /// from the header; the writer rejects 0 to keep one header shape).
  base_q_idx : Int32
  /// Loop filter levels for the Y planes (0..63). U/V inherit the
  /// spec's "chroma levels present only when luma is nonzero" shape:
  /// both zero keeps the header minimal.
  loop_filter_level0 : Int32
  loop_filter_level1 : Int32
  /// Loop sharpness 0..7.
  loop_filter_sharpness : Int32
  /// refresh_frame_flags (0..255): bit i refreshes reference slot i
  /// with this frame's reconstruction. Default 1 = slot 0 (LAST).
  refresh_frame_flags : Int32
  /// ref_frame_idx: the 7 per-frame reference slots (LAST..ALTREF,
  /// each 0..7 into the 8 reference frames). The minimal inter path
  /// points all seven at the same slot (single LAST reference).
  ref_frame_idx : Array[Int32]
  /// The tile's entropy payload — the legacy single-tile slot, used
  /// when `tiles` is empty.
  tile_data : Bytes
  /// Multi-tile payloads in raster order; must hold exactly
  /// `tile_cols * tile_rows` entries.
  tiles : Array[Bytes]
  /// Tile grid (uniform spacing, powers of two). 1x1 with empty
  /// `tiles` reproduces the single-tile shape.
  tile_cols : Int32
  tile_rows : Int32
  /// allow_high_precision_mv: enables the mv components' hp bits, so
  /// odd 1/8-pel phases become codable (decoder mv_prec = hp<<1|1).
  allow_high_precision : Bool
}

///|
/// Default inter configuration: qindex 100, loop filter off, refresh
/// slot 0, all seven ref_frame_idx entries on slot 0, empty tile.
pub fn Av1InterFrameEncConfig::default() -> Av1InterFrameEncConfig {
  {
    base_q_idx: 100,
    loop_filter_level0: 0,
    loop_filter_level1: 0,
    loop_filter_sharpness: 0,
    refresh_frame_flags: 1,
    ref_frame_idx: [0, 0, 0, 0, 0, 0, 0],
    tile_data: b"",
    tiles: [],
    tile_cols: 1,
    tile_rows: 1,
    allow_high_precision: false,
  }
}

///|
/// Small frame-geometry helper shared with the parser's tile_info:
/// superblock columns/rows for the frame (spec 5.9.14).
fn av1_enc_frame_sb(
  seq : Av1SequenceParameters,
  width : Int32,
  height : Int32,
) -> (Int32, Int32) {
  let mi_cols = 2 * ((width + 7) >> 3)
  let mi_rows = 2 * ((height + 7) >> 3)
  let sb_cols = if seq.use_128x128_superblock {
    (mi_cols + 31) >> 5
  } else {
    (mi_cols + 15) >> 4
  }
  let sb_rows = if seq.use_128x128_superblock {
    (mi_rows + 31) >> 5
  } else {
    (mi_rows + 15) >> 4
  }
  (sb_cols, sb_rows)
}

///|
/// `av1_tile_log2` mirror (block_size_to_tile_log2 in the spec): the
/// smallest exponent with `1 << shift >= target`.
fn av1_enc_tile_log2(blk_size : Int32, target : Int32) -> Int32 {
  let mut k = 0
  while blk_size << k < target {
    k = k + 1
  }
  k
}

///|
/// Uniform tile_info (spec 5.9.14), shared by the key and inter frame
/// writers: grid validation, the increment bits following the parser's
/// `while level < max && read1()` loops (each 1 climbs one level, a 0
/// stops the walk, no bit at all when the level already sits at max),
/// then context_update_tile_id and the size-field width.
fn av1_enc_write_tile_info(
  r : H264Rbsp,
  seq : Av1SequenceParameters,
  tile_cols : Int32,
  tile_rows : Int32,
  tile_size_bytes~ : Int32 = 1,
) -> Result[Unit, String] {
  r.put_bit(1) // uniform_tile_spacing_flag
  let (sb_cols, sb_rows) = av1_enc_frame_sb(seq, seq.width, seq.height)
  let sb_size = if seq.use_128x128_superblock { 7 } else { 6 }
  let max_tile_width_sb = 4096 >> sb_size
  let max_tile_area_sb = 9437184 >> (2 * sb_size)
  let min_log2_cols = av1_enc_tile_log2(max_tile_width_sb, sb_cols)
  let max_log2_cols = av1_enc_tile_log2(
    1,
    if sb_cols < 64 {
      sb_cols
    } else {
      64
    },
  )
  let max_log2_rows = av1_enc_tile_log2(
    1,
    if sb_rows < 64 {
      sb_rows
    } else {
      64
    },
  )
  let min_log2_area = av1_enc_tile_log2(max_tile_area_sb, sb_cols * sb_rows)
  let min_log2_tiles = if min_log2_cols > min_log2_area {
    min_log2_cols
  } else {
    min_log2_area
  }
  // §444: the requested grid in log2, validated against the bounds and
  // against the uniform derivation (the parser recomputes the tile
  // count from the even division and rejects mismatches).
  let log2_cols = av1_enc_tile_log2(1, tile_cols)
  let log2_rows = av1_enc_tile_log2(1, tile_rows)
  if 1 << log2_cols != tile_cols || 1 << log2_rows != tile_rows {
    return Err("av1 enc: tile_cols/tile_rows must be powers of two")
  }
  if log2_cols < min_log2_cols || log2_cols > max_log2_cols {
    return Err(
      "av1 enc: tile_cols \{tile_cols} out of range for width \{seq.width}",
    )
  }
  let min_log2_rows = if min_log2_tiles - log2_cols > 0 {
    min_log2_tiles - log2_cols
  } else {
    0
  }
  if log2_rows < min_log2_rows || log2_rows > max_log2_rows {
    return Err(
      "av1 enc: tile_rows \{tile_rows} out of range for height \{seq.height}",
    )
  }
  let width_sb = 1 + ((sb_cols - 1) >> log2_cols)
  let height_sb = 1 + ((sb_rows - 1) >> log2_rows)
  if (sb_cols + width_sb - 1) / width_sb != tile_cols ||
    (sb_rows + height_sb - 1) / height_sb != tile_rows {
    return Err(
      "av1 enc: uniform spacing does not give the requested \{tile_cols}x\{tile_rows} grid",
    )
  }
  let mut lvl = min_log2_cols
  while lvl < log2_cols {
    r.put_bit(1)
    lvl = lvl + 1
  }
  if lvl < max_log2_cols {
    r.put_bit(0) // stop incrementing tile cols
  }
  let mut lvl_r = min_log2_rows
  while lvl_r < log2_rows {
    r.put_bit(1)
    lvl_r = lvl_r + 1
  }
  if lvl_r < max_log2_rows {
    r.put_bit(0) // stop incrementing tile rows
  }
  if log2_cols > 0 || log2_rows > 0 {
    r.put(0, log2_cols + log2_rows) // context_update_tile_id = 0
    r.put(tile_size_bytes - 1, 2) // tile_size_bytes_minus1
  }
  Ok(())
}

///|
/// quantization_params (spec 5.9.11), shared: base_q_idx validation +
/// bits, U/V delta-present flags with V inheriting U
/// (separate_uv_delta_q = 0 in the sequence), qmatrix off.
fn av1_enc_write_quant_params(
  r : H264Rbsp,
  seq : Av1SequenceParameters,
  base_q_idx : Int32,
) -> Result[Unit, String] {
  if base_q_idx < 1 || base_q_idx > 255 {
    return Err("av1 enc: base_q_idx must be 1..=255 (0 is lossless)")
  }
  r.put(base_q_idx, 8)
  r.put_bit(0) // DeltaQYDc present = 0
  if !seq.monochrome {
    r.put_bit(0)
    r.put_bit(0)
  }
  r.put_bit(0) // using_qmatrix
  Ok(())
}

///|
/// loop_filter_params (spec 5.9.12), shared: level validation, the
/// chroma pair riding only on a nonzero luma level, deltas off. Only
/// called for non-lossless frames (base_q_idx >= 1 keeps the section).
fn av1_enc_write_lf_params(
  r : H264Rbsp,
  seq : Av1SequenceParameters,
  level0 : Int32,
  level1 : Int32,
  sharpness : Int32,
) -> Result[Unit, String] {
  for lf in [level0, level1] {
    if lf < 0 || lf > 63 {
      return Err("av1 enc: loop filter level must be 0..=63")
    }
  }
  if sharpness < 0 || sharpness > 7 {
    return Err("av1 enc: loop filter sharpness must be 0..=7")
  }
  r.put(level0, 6)
  r.put(level1, 6)
  // Chroma levels ride only when a luma level is nonzero.
  if !seq.monochrome && (level0 != 0 || level1 != 0) {
    r.put(level0, 6)
    r.put(level1, 6)
  }
  r.put(sharpness, 3)
  r.put_bit(0) // loop_filter_delta_enabled
  Ok(())
}

///|
/// Write the uncompressed key-frame header bits (everything before the
/// tile group, byte-aligned at the end). Mirrors the parser branch for
/// frame_type=KEY, show_frame=1, single tile.
fn av1_enc_write_key_header(
  r : H264Rbsp,
  seq : Av1SequenceParameters,
  config : Av1KeyFrameEncConfig,
  tile_size_bytes~ : Int32 = 1,
) -> Result[Unit, String] {
  // Frame overhead + show_existing + type + show_frame.
  r.put_bit(0) // show_existing_frame = 0
  r.put(0, 2) // frame_type = KEY
  r.put_bit(1) // show_frame = 1
  // error_resilient_mode: forced by key+show (no bit).
  // disable_cdf_update: the encoder keeps CDF adaptation on.
  if !seq.reduced_still_picture_header {
    r.put_bit(0)
  }
  // allow_screen_content_tools: read only when the sequence forces 2
  // (the general header chooses 2; the reduced header leaves force = 0
  // and the frame writes no bit).
  if seq.seq_force_screen_content_tools == 2 {
    r.put_bit(0)
  }
  // force_integer_mv: skipped (allow_sct = 0).
  // frame_size_override_flag: off — frames use the sequence's size.
  if !seq.reduced_still_picture_header {
    r.put_bit(0)
  }
  // refresh_frame_flags = 0xFF, primary_ref = 7: derived, no bits.
  // frame_size(): override off -> seq size, no bits; superres off.
  // render_size: render_and_probe = 0.
  r.put_bit(0)
  // Key-frame branch: allow_intrabc only with screen content (off).
  // disable_frame_end_update_cdf: keep CDF updates between tiles/frames.
  if !seq.reduced_still_picture_header {
    r.put_bit(0)
  }
  match
    av1_enc_write_tile_info(
      r,
      seq,
      config.tile_cols,
      config.tile_rows,
      tile_size_bytes~,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match av1_enc_write_quant_params(r, seq, config.base_q_idx) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // segmentation_params.
  r.put_bit(0) // segmentation_enabled
  // delta_q_params.
  r.put_bit(0) // delta_q_present
  // (delta_lf_params follow delta_q only.)
  match
    av1_enc_write_lf_params(
      r,
      seq,
      config.loop_filter_level0,
      config.loop_filter_level1,
      config.loop_filter_sharpness,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // CDEF/LR: disabled by the sequence header (no bits).
  // tx_mode_select: 1 = TX_MODE_LARGEST for intra frames; the reduced
  // header derives TX_MODE_LARGEST without a bit (parser branch).
  if !seq.reduced_still_picture_header {
    r.put_bit(1)
    // reduced_tx_set: keep the full coefficient set for now.
    r.put_bit(0)
  }
  // skip_mode: not allowed (no order hints/refs). allow_warped and
  // is_global are inter-only. Film grain: disabled by the sequence.
  r.align_zero()
  Ok(())
}

///|
/// Write the uncompressed inter-frame header bits (§446a), the write
/// twin of `av1_parse_frame_header`'s INTER branch restricted to the
/// §438b sequence: show_frame=1, error_resilient=0, frame_size_override
/// =0 (no frame_size_with_refs / explicit sizes), single-size render,
/// allow_high_precision=0, EIGHTTAP (not switchable), motion mode not
/// switchable, no ref mvs, primary_ref=7, segmentation/delta_q/deltas
/// off, TX_MODE_LARGEST with the full tx set, reference_select=0 (no
/// compound/skip mode), no warped motion, all seven global-motion
/// transforms identity.
fn av1_enc_write_inter_header(
  r : H264Rbsp,
  seq : Av1SequenceParameters,
  config : Av1InterFrameEncConfig,
  tile_size_bytes~ : Int32 = 1,
) -> Result[Unit, String] {
  // The §438b sequence shape is required: every gate below assumes it.
  // A still-picture (reduced) header is intra-only by construction.
  if seq.reduced_still_picture_header {
    return Err("av1 enc: inter frames require the general sequence header")
  }
  if seq.frame_id_numbers_present {
    return Err("av1 enc: frame-id sequences unsupported")
  }
  if seq.enable_order_hint {
    return Err("av1 enc: order-hint sequences unsupported by the inter writer")
  }
  if seq.enable_superres || seq.enable_cdef || seq.enable_restoration {
    return Err("av1 enc: superres/CDEF/restoration sequences unsupported")
  }
  if seq.enable_warped_motion {
    return Err("av1 enc: warped-motion sequences unsupported")
  }
  if seq.film_grain_params_present {
    return Err("av1 enc: film-grain sequences unsupported")
  }
  if seq.seq_force_screen_content_tools != 2 || seq.seq_force_integer_mv != 2 {
    return Err(
      "av1 enc: inter frames need the chosen (2/2) screen-content selectors",
    )
  }
  if config.refresh_frame_flags < 0 || config.refresh_frame_flags > 255 {
    return Err("av1 enc: refresh_frame_flags must be 0..=255")
  }
  if config.ref_frame_idx.length() != 7 {
    return Err("av1 enc: ref_frame_idx must have exactly 7 entries")
  }
  for ridx in config.ref_frame_idx {
    if ridx < 0 || ridx > 7 {
      return Err("av1 enc: ref_frame_idx entries must be 0..=7")
    }
  }
  r.put_bit(0) // show_existing_frame = 0
  r.put(av1_frame_inter, 2) // frame_type = INTER
  r.put_bit(1) // show_frame = 1
  // showable_frame: skipped (shown).
  r.put_bit(0) // error_resilient_mode
  r.put_bit(0) // disable_cdf_update
  r.put_bit(0) // allow_screen_content_tools = 0 (sequence forces 2)
  // force_integer_mv: skipped (allow_sct = 0).
  r.put_bit(0) // frame_size_override_flag
  // order_hint: skipped (enable_order_hint = 0).
  r.put(7, 3) // primary_ref_frame = 7 (no primary reference)
  r.put(config.refresh_frame_flags, 8)
  // frame_refs_short_signaling: skipped (no order hints).
  for ridx in config.ref_frame_idx {
    r.put(ridx, 3)
  }
  // frame_size_with_refs found bits: skipped (override = 0) — the
  // frame uses the sequence's size. Explicit sizes skipped likewise.
  // superres: skipped (enable_superres = 0).
  r.put_bit(0) // render_and_frame_size_different
  // Inter branch.
  r.put_bit(if config.allow_high_precision { 1 } else { 0 }) // allow_high_precision_mv (force_integer = 0)
  r.put_bit(0) // is_filter_switchable = 0
  r.put(0, 2) // interpolation_filter = EIGHTTAP
  r.put_bit(0) // is_motion_mode_switchable
  // use_ref_frame_mvs: skipped (enable_order_hint = 0).
  r.put_bit(0) // disable_frame_end_update_cdf
  match
    av1_enc_write_tile_info(
      r,
      seq,
      config.tile_cols,
      config.tile_rows,
      tile_size_bytes~,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match av1_enc_write_quant_params(r, seq, config.base_q_idx) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  r.put_bit(0) // segmentation_enabled
  r.put_bit(0) // delta_q_present
  // (delta_lf_params follow delta_q only.)
  match
    av1_enc_write_lf_params(
      r,
      seq,
      config.loop_filter_level0,
      config.loop_filter_level1,
      config.loop_filter_sharpness,
    ) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // CDEF/LR: disabled by the sequence header (no bits).
  r.put_bit(1) // tx_mode_select: TX_MODE_LARGEST
  r.put_bit(0) // reference_select = 0 (no compound prediction)
  // skip_mode: not allowed (reference_select = 0). allow_warped:
  // rejected above (sequence keeps it off).
  r.put_bit(0) // reduced_tx_set
  for _ in 0..<7 {
    r.put_bit(0) // gm_type = identity for LAST..ALTREF
  }
  // Film grain: disabled by the sequence.
  r.align_zero()
  Ok(())
}

///|
/// Shared OBU_FRAME assembly: resolve the payload list, validate the
/// grid, compute the size-prefix width, run `write_header` (receives
/// the bit writer and the prefix width), then splice the tile group.
/// One tile keeps the §439 shape (no tg bits, the last tile carries no
/// size prefix — the payload tail is the data); 2+ tiles write the
/// §444 shape — tile_start_and_end_present 0, byte alignment, then
/// per-tile size prefixes (tile_size_bytes LE, interleaved with the
/// payloads, last tile unprefixed).
fn av1_enc_assemble_frame_obu(
  write_header : (H264Rbsp, Int32) -> Result[Unit, String],
  tile_data : Bytes,
  tiles : Array[Bytes],
  tile_cols : Int32,
  tile_rows : Int32,
) -> Result[Bytes, String] {
  // Resolve the payload list and validate the grid.
  let payloads : Array[Bytes] = if tiles.length() > 0 {
    tiles
  } else {
    [tile_data]
  }
  let multi = payloads.length() > 1
  if multi {
    if tile_cols < 2 && tile_rows < 2 {
      return Err("av1 enc: multiple tiles require tile_cols/tile_rows > 1")
    }
    if payloads.length() != tile_cols * tile_rows {
      return Err(
        "av1 enc: \{payloads.length()} tiles for a \{tile_cols}x\{tile_rows} grid",
      )
    }
  } else if tile_cols != 1 || tile_rows != 1 {
    return Err("av1 enc: a single tile requires tile_cols = tile_rows = 1")
  }
  // Size-prefix width: the smallest 1..=4 bytes holding every written
  // size_minus_1 (the last tile carries no prefix).
  let mut max_minus1 = 0
  if multi {
    // A prefixed tile cannot be empty (its size_minus_1 must be >= 0);
    // the legacy single-tile path keeps §439's header-only tolerance.
    for i in 0..<payloads.length() {
      if payloads[i].length() == 0 {
        return Err("av1 enc: tile \{i} has an empty payload")
      }
      if i < payloads.length() - 1 {
        let m1 = payloads[i].length() - 1
        if m1 > max_minus1 {
          max_minus1 = m1
        }
      }
    }
  }
  // Shifts stay within 8/16/24 bits (4 bytes hold any Int31 length).
  let mut tile_size_bytes = 1
  while tile_size_bytes < 4 && max_minus1 >= 1 << (8 * tile_size_bytes) {
    tile_size_bytes = tile_size_bytes + 1
  }
  let r = H264Rbsp::new()
  match write_header(r, tile_size_bytes) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if multi {
    r.put_bit(0) // tile_start_and_end_present_flag: whole frame
    r.align_zero()
  }
  let header = r.finish_raw_of()
  let out : Array[Byte] = []
  for b in header {
    out.push(b)
  }
  if multi {
    for i in 0..<payloads.length() {
      if i < payloads.length() - 1 {
        let m1 = payloads[i].length() - 1
        for b in 0..<tile_size_bytes {
          out.push(((m1 >> (8 * b)) & 0xFF).to_byte())
        }
      }
      for b in payloads[i] {
        out.push(b)
      }
    }
  } else {
    for b in payloads[0] {
      out.push(b)
    }
  }
  Ok(av1_enc_obu(6, Bytes::from_array(out[:])))
}

///|
/// The complete OBU_FRAME for a key frame: uncompressed header (byte
/// aligned), then the tile group (see `av1_enc_assemble_frame_obu`).
pub fn av1_enc_write_key_frame_obu(
  seq : Av1SequenceParameters,
  config : Av1KeyFrameEncConfig,
) -> Result[Bytes, String] {
  av1_enc_assemble_frame_obu(
    (r, tile_size_bytes) => {
      av1_enc_write_key_header(r, seq, config, tile_size_bytes~)
    },
    config.tile_data,
    config.tiles,
    config.tile_cols,
    config.tile_rows,
  )
}

///|
/// The complete OBU_FRAME for an inter frame (§446a): uncompressed
/// header (byte aligned), then the tile group — same assembly as key
/// frames.
pub fn av1_enc_write_inter_frame_obu(
  seq : Av1SequenceParameters,
  config : Av1InterFrameEncConfig,
) -> Result[Bytes, String] {
  av1_enc_assemble_frame_obu(
    (r, tile_size_bytes) => {
      av1_enc_write_inter_header(r, seq, config, tile_size_bytes~)
    },
    config.tile_data,
    config.tiles,
    config.tile_cols,
    config.tile_rows,
  )
}

///|
/// The temporal-delimiter OBU (type 2, empty payload) — real AV1
/// streams open every frame with one.
pub fn av1_enc_write_temporal_delimiter() -> Bytes {
  av1_enc_obu(2, b"")
}
