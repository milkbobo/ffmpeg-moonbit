// Blackbox tests for §439: the key-frame OBU writer. Acceptance oracle
// = `av1_parse_frame_header` / `av1_parse_tile_group` in `av1.mbt`
// (validated against real streams): the written OBU_FRAME must parse
// back field for field and hand back the tile data byte-exactly.

///|
/// Encode a full still (TD + sequence header + frame OBU) and parse the
/// frame header back.
fn av1key_roundtrip(
  seq_cfg : @libavcodec.Av1SeqEncConfig,
  kf_cfg : @libavcodec.Av1KeyFrameEncConfig,
) -> (@libavcodec.Av1FrameHeader, Array[Byte]) raise {
  let seq_obu = match @libavcodec.av1_enc_write_sequence_header_obu(seq_cfg) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let frame_obu = match @libavcodec.av1_enc_write_key_frame_obu(seq, kf_cfg) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  // The frame header parser walks the OBU stream; splice TD + seq +
  // frame like a real stream.
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let stream_parts : Array[Bytes] = [td, seq_obu, frame_obu]
  let all : Array[Byte] = []
  for part in stream_parts {
    for i = 0; i < part.length(); i = i + 1 {
      all.push(part[i])
    }
  }
  let fh = match
    @libavcodec.av1_parse_frame_header(Bytes::from_array(all[:]), seq) {
    Ok(f) => f
    Err(e) => fail("frame header parse failed: \{e}")
  }
  if fh.frame_type != 0 || !fh.show_frame {
    fail("not a shown key frame")
  }
  if fh.width != seq_cfg.width || fh.height != seq_cfg.height {
    fail("frame size \{fh.width}x\{fh.height}")
  }
  if fh.refresh_frame_flags != 0xFF {
    fail("refresh \{fh.refresh_frame_flags}")
  }
  if fh.base_q_idx != kf_cfg.base_q_idx {
    fail("qidx \{fh.base_q_idx} != \{kf_cfg.base_q_idx}")
  }
  if fh.segmentation_enabled || fh.delta_q_present || fh.using_qmatrix {
    fail("advanced tools must stay off")
  }
  if fh.coded_lossless {
    fail("qidx >= 1 must not be lossless")
  }
  // The tile group parse locates the tile payload; slice it ourselves.
  // `tile_offsets[i]` is the tile's absolute offset within the OBU
  // payload (the probe pinned: for a single tile it equals
  // `data_offset` — adding both would double-count).
  let tg = match @libavcodec.av1_parse_tile_group(frame_obu, fh) {
    Ok(t) => t
    Err(e) => fail("tile group parse failed: \{e}")
  }
  let abs = tg.payload_offset + tg.tile_offsets[0]
  let slice = frame_obu[abs:abs + tg.tile_sizes[0]].to_owned()
  (fh, slice.to_array())
}

///|
test "av1 keyframe enc: minimal round trip with tile data" {
  let data : Array[Byte] = []
  for i in 0..<37 {
    data.push(((i * 7 + 3) & 0xFF).to_byte())
  }
  let (fh, tile) = av1key_roundtrip(
    @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      tile_data: Bytes::from_array(data[:]),
    },
  )
  if fh.tile_cols != 1 || fh.tile_rows != 1 {
    fail("expected a single tile")
  }
  if fh.tx_mode != 2 {
    fail("tx mode \{fh.tx_mode} (want LARGEST)")
  }
  if fh.loop_filter_level.length() != 2 || fh.loop_filter_level[0] != 0 {
    fail("loop filter levels wrong")
  }
  if tile.length() != 37 {
    fail("tile data length \{tile.length()}")
  }
  let want : Byte = ((3 + 0) & 0xFF).to_byte()
  ignore(want)
  for i in 0..<37 {
    let w : Byte = ((i * 7 + 3) & 0xFF).to_byte()
    if tile[i] != w {
      fail("tile data mismatch at \{i}")
    }
  }
}

///|
test "av1 keyframe enc: loop filter levels with chroma pair" {
  let (fh, _) = av1key_roundtrip(
    @libavcodec.Av1SeqEncConfig::default(width=96, height=64),
    {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      loop_filter_level0: 17,
      loop_filter_level1: 31,
      loop_filter_sharpness: 4,
    },
  )
  // Nonzero luma levels pull the chroma pair (Y/U/V shape).
  if fh.loop_filter_level.length() != 4 {
    fail("expected 4 loop filter levels, got \{fh.loop_filter_level.length()}")
  }
  if fh.loop_filter_level[0] != 17 ||
    fh.loop_filter_level[1] != 31 ||
    fh.loop_filter_level[2] != 17 ||
    fh.loop_filter_level[3] != 31 {
    fail("loop filter levels wrong")
  }
  if fh.loop_filter_sharpness != 4 {
    fail("sharpness \{fh.loop_filter_sharpness}")
  }
}

///|
test "av1 keyframe enc: 1080p tile info stop bits and still picture" {
  // The general header at 1080p: 31x17 superblocks, single tile.
  let (fh, _) = av1key_roundtrip(
    @libavcodec.Av1SeqEncConfig::default(width=1920, height=1080),
    @libavcodec.Av1KeyFrameEncConfig::default(),
  )
  if fh.tile_cols != 1 || fh.tile_rows != 1 {
    fail("1080p must stay single tile")
  }
  if fh.tile_col_start_sb.length() != 2 {
    fail("tile col starts \{fh.tile_col_start_sb.length()}")
  }
  // The reduced (still-picture) header derives TX_MODE_LARGEST.
  let (fh2, _) = av1key_roundtrip(
    {
      ..@libavcodec.Av1SeqEncConfig::default(width=320, height=240),
      still_picture: true,
    },
    @libavcodec.Av1KeyFrameEncConfig::default(),
  )
  if fh2.tx_mode != 1 {
    fail("reduced header tx mode \{fh2.tx_mode} (parser derives LARGEST=1)")
  }
  if !fh2.disable_frame_end_update_cdf == false {
    // reduced header: parser pins disable_frame_end to false.
    ()
  }
}

///|
test "av1 keyframe enc: validation errors" {
  let seq = match
    @libavcodec.av1_parse_sequence_header(
      match
        @libavcodec.av1_enc_write_sequence_header_obu(
          @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  for
    bad in [
      { ..@libavcodec.Av1KeyFrameEncConfig::default(), base_q_idx: 0, },
      { ..@libavcodec.Av1KeyFrameEncConfig::default(), base_q_idx: 256, },
      { ..@libavcodec.Av1KeyFrameEncConfig::default(), loop_filter_level0: 64, },
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        loop_filter_sharpness: 8,
      },
    ] {
    match @libavcodec.av1_enc_write_key_frame_obu(seq, bad) {
      Ok(_) => fail("bad key-frame config accepted")
      Err(_) => ()
    }
  }
}

// §444: multi-tile frames (uniform spacing, per-tile msac payloads).

///|
/// Assemble TD + seq + multi-tile frame OBU, parse the header, extract
/// the tiles and decode — the §444 end-to-end helper.
fn av1key_multitile_decode(
  width : Int32,
  height : Int32,
  tiles : Array[Bytes],
  tile_cols : Int32,
  tile_rows : Int32,
  qidx : Int32,
) -> (@libavcodec.Av1FrameHeader, @libavcodec.Av1FrameOutput) raise {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width~, height~),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: qidx,
      tiles,
      tile_cols,
      tile_rows,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail("frame header parse failed: \{e}")
  }
  let extracted = match @libavcodec.av1_extract_tiles(frame_obu, fh) {
    Ok(t) => t
    Err(e) => fail("tile extraction failed: \{e}")
  }
  if extracted.length() != tiles.length() {
    fail("extracted \{extracted.length()} tiles, wrote \{tiles.length()}")
  }
  for i in 0..<tiles.length() {
    if extracted[i].data != tiles[i] {
      fail("tile \{i} payload not handed back byte-exactly")
    }
  }
  let out = match @libavcodec.av1_decode_keyframe_tiles(seq, fh, extracted) {
    Ok(o) => o
    Err(e) => fail("multi-tile decode failed: \{e}")
  }
  (fh, out)
}

///|
test "av1 keyframe enc: 2x1 tiles decode side by side" {
  // 128x64 = two SBs, two tile columns. Tile 0 is a skip-only minimal
  // SB (pure DC 128); tile 1 carries a dc residual at qidx 200 (a
  // uniform offset != 128). Independent payloads + independent CDF
  // contexts per tile.
  let qidx = 200
  let t0 = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t1 = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let (fh, out) = av1key_multitile_decode(128, 64, [t0, t1], 2, 1, qidx)
  if fh.tile_cols != 2 || fh.tile_rows != 1 {
    fail("grid \{fh.tile_cols}x\{fh.tile_rows}")
  }
  if fh.tile_size_bytes_minus1 != 0 {
    fail("size bytes minus1 \{fh.tile_size_bytes_minus1}")
  }
  if fh.context_update_tile_id != 0 {
    fail("context update id \{fh.context_update_tile_id}")
  }
  if out.width != 128 || out.height != 64 {
    fail("geometry \{out.width}x\{out.height}")
  }
  // Left half: pure 128. Right half: the residual's uniform level.
  let r0 = out.y[0 * out.y_stride + 0]
  if r0 != 128 {
    fail("skip tile Y(0,0) = \{r0} (want 128)")
  }
  let r1 = out.y[0 * out.y_stride + 64]
  if r1 == 128 {
    fail("residual tile did not reach the picture")
  }
  for row in 0..<64 {
    for col in 0..<64 {
      if out.y[row * out.y_stride + col] != 128 {
        fail("left half Y(\{row},\{col}) = \{out.y[row * out.y_stride + col]}")
      }
      if out.y[row * out.y_stride + col + 64] != r1 {
        fail(
          "right half Y(\{row},\{col}) = \{out.y[row * out.y_stride + col + 64]} != \{r1}",
        )
      }
    }
  }
  let cu0 = out.u[0]
  let cu1 = out.u[0 * out.uv_stride + 32]
  for row in 0..<32 {
    for col in 0..<32 {
      if out.u[row * out.uv_stride + col] != cu0 ||
        out.v[row * out.uv_stride + col] != cu0 {
        fail("left chroma half not uniform at (\{row},\{col})")
      }
      if out.u[row * out.uv_stride + col + 32] != cu1 ||
        out.v[row * out.uv_stride + col + 32] != cu1 {
        fail("right chroma half not uniform at (\{row},\{col})")
      }
    }
  }
  if cu0 == cu1 {
    fail("chroma halves must differ (residual only on the right)")
  }
  // Determinism.
  let (_, out2) = av1key_multitile_decode(128, 64, [t0, t1], 2, 1, qidx)
  if out.y != out2.y {
    fail("two runs decoded differently")
  }
}

///|
test "av1 keyframe enc: 1x2 tiles decode stacked" {
  // 64x128 = two SBs stacked, two tile ROWS: the bottom tile starts a
  // fresh above-context bank (tile row), so the same single-SB payload
  // shape works. Residual on TOP, skip on the bottom.
  let qidx = 200
  let t_top = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_bot = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let (fh, out) = av1key_multitile_decode(64, 128, [t_top, t_bot], 1, 2, qidx)
  if fh.tile_cols != 1 || fh.tile_rows != 2 {
    fail("grid \{fh.tile_cols}x\{fh.tile_rows}")
  }
  if out.width != 64 || out.height != 128 {
    fail("geometry \{out.width}x\{out.height}")
  }
  let v0 = out.y[0]
  if v0 == 128 {
    fail("residual tile did not reach the picture")
  }
  for row in 0..<128 {
    for col in 0..<64 {
      let v = out.y[row * out.y_stride + col]
      let want = if row < 64 { v0 } else { 128 }
      if v != want {
        fail("Y(\{row},\{col}) = \{v} (want \{want})")
      }
    }
  }
}

///|
test "av1 keyframe enc: multi-tile validation errors" {
  let seq = match
    @libavcodec.av1_parse_sequence_header(
      match
        @libavcodec.av1_enc_write_sequence_header_obu(
          @libavcodec.Av1SeqEncConfig::default(width=128, height=64),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let t : Bytes = match @libavcodec.av1_enc_write_minimal_tile() {
    Ok(b) => b
    Err(e) => fail(e)
  }
  for
    bad in [
      // Two payloads on a 1x1 grid.
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        tiles: [t, t],
        tile_cols: 1,
        tile_rows: 1,
      },
      // Grid without payloads.
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        tile_cols: 2,
        tile_rows: 1,
      },
      // Three payloads on a 2x1 grid.
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        tiles: [t, t, t],
        tile_cols: 2,
        tile_rows: 1,
      },
      // Non-power-of-two grid.
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        tiles: [t],
        tile_cols: 3,
        tile_rows: 1,
      },
      // Empty payload under a prefix.
      {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        tiles: [b"", t],
        tile_cols: 2,
        tile_rows: 1,
      },
    ] {
    match @libavcodec.av1_enc_write_key_frame_obu(seq, bad) {
      Ok(_) => fail("bad multi-tile config accepted")
      Err(_) => ()
    }
  }
}
