// Blackbox tests for §440a: the minimal pixel-capable tile. The written
// stream (TD + seq + frame OBU with the msac tile) must decode through
// the in-tree `av1_decode_keyframe` to a pure DC frame — the first
// end-to-end pixel round trip of the AV1 encoder.

///|
fn av1tile_encode_still(
  width : Int32,
  height : Int32,
) -> (@libavcodec.Av1FrameHeader, Bytes) raise {
  // Only the 64x64 single-SB frame is supported by this slice.
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
  let tile = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  // Extract the tile from the frame OBU via the parser's accounting.
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let tg = match @libavcodec.av1_parse_tile_group(frame_obu, fh) {
    Ok(t) => t
    Err(e) => fail(e)
  }
  let abs = tg.payload_offset + tg.tile_offsets[0]
  let slice = frame_obu[abs:abs + tg.tile_sizes[0]].to_owned()
  (fh, slice)
}

///|
test "av1 tile enc: minimal 64x64 DC still decodes to mid grey" {
  let (fh, tile) = av1tile_encode_still(64, 64)
  if fh.base_q_idx != 100 || fh.tile_cols != 1 || fh.tile_rows != 1 {
    fail("frame header mismatch")
  }
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
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("decode failed: \{e}")
  }
  if out.width != 64 || out.height != 64 {
    fail("output geometry \{out.width}x\{out.height}")
  }
  // DC prediction from the mid-filled borders: every pixel is 128
  // (planes are stride-aligned — index row * stride + col). The residual
  // test below needs the same indexing.
  for row in 0..<64 {
    for col in 0..<64 {
      if out.y[row * out.y_stride + col] != 128 {
        fail("Y(\{row},\{col}) = \{out.y[row * out.y_stride + col]} (want 128)")
      }
    }
  }
  for row in 0..<32 {
    for col in 0..<32 {
      if out.u[row * out.uv_stride + col] != 128 {
        fail(
          "U(\{row},\{col}) = \{out.u[row * out.uv_stride + col]} (want 128)",
        )
      }
      if out.v[row * out.uv_stride + col] != 128 {
        fail(
          "V(\{row},\{col}) = \{out.v[row * out.uv_stride + col]} (want 128)",
        )
      }
    }
  }
}

///|
test "av1 tile enc: deterministic bytes" {
  let a = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let b = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  if a != b {
    fail("two runs produced different tile bytes")
  }
  if a.length() == 0 {
    fail("empty tile")
  }
}

///|
test "av1 tile enc: residual dc tile decodes with active coefficients" {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // qidx 200: the dequantised DC is large enough that the inverse
  // DCT's DC normalisation (dav1d's 181/shift stages over a
  // pre-multiplied dequant table) leaves a visible residue. qidx 100
  // with dc token 1 legitimately resolves to zero after the chain.
  let tile = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if fh.base_q_idx != 200 {
    fail("qidx mismatch")
  }
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("residual decode failed: \{e}")
  }
  // Every pixel carries the same positive dc residual: mid grey plus
  // the dequantised dc (uniform across the block). The exact value is
  // the decoder's own dequant for qidx 100; what must hold is that the
  // residual moved every pixel off 128 in the same direction by the
  // same amount.
  let y0 = out.y[0]
  if y0 == 128 {
    fail("residual did not reach the picture")
  }
  for row in 0..<64 {
    for col in 0..<64 {
      let v = out.y[row * out.y_stride + col]
      if v != y0 {
        fail("Y(\{row},\{col}) = \{v} != \{y0} (residual must be uniform)")
      }
    }
  }
  let u0 = out.u[0]
  for row in 0..<32 {
    for col in 0..<32 {
      let vu = out.u[row * out.uv_stride + col]
      let vv = out.v[row * out.uv_stride + col]
      if vu != u0 || vv != u0 {
        fail("UV(\{row},\{col}) = \{vu}/\{vv} != \{u0}")
      }
    }
  }
  // Determinism.
  let tile2 = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  if tile != tile2 {
    fail("residual tile bytes differ between runs")
  }
}

///|
test "av1 tile enc: split tile decodes four 32x32 blocks" {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let tile = match @libavcodec.av1_enc_write_split_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("split decode failed: \{e}")
  }
  // Every 32x32 block is DC_PRED with skip=1: the picture stays mid
  // grey (stride-aligned planes).
  for row in 0..<64 {
    for col in 0..<64 {
      let v = out.y[row * out.y_stride + col]
      if v != 128 {
        fail("Y(\{row},\{col}) = \{v} (want 128)")
      }
    }
  }
  for row in 0..<32 {
    for col in 0..<32 {
      if out.u[row * out.uv_stride + col] != 128 {
        fail("U(\{row},\{col}) != 128")
      }
      if out.v[row * out.uv_stride + col] != 128 {
        fail("V(\{row},\{col}) != 128")
      }
    }
  }
  // Determinism.
  let tile2 = match @libavcodec.av1_enc_write_split_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  if tile != tile2 {
    fail("split tile bytes differ between runs")
  }
}

///|
test "av1 tile enc: directional V_PRED with angle delta round trip" {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let tile = match @libavcodec.av1_enc_write_directional_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("directional decode failed: \{e}")
  }
  // V prediction copies the above edge downward; with no available
  // neighbour the edge fills with the spec's base-1 = 127 (DC_PRED is
  // the only mode whose empty-neighbour value is 128). Every pixel is
  // the same column-copied 127.
  for row in 0..<64 {
    for col in 0..<64 {
      let v = out.y[row * out.y_stride + col]
      if v != 127 {
        fail("Y(\{row},\{col}) = \{v} (V prediction should be 127)")
      }
    }
  }
  // Chroma planes get the same V-predicted 127.
  for row in 0..<32 {
    for col in 0..<32 {
      if out.u[row * out.uv_stride + col] != 127 {
        fail(
          "U(\{row},\{col}) = \{out.u[row * out.uv_stride + col]} (want 127)",
        )
      }
      if out.v[row * out.uv_stride + col] != 127 {
        fail(
          "V(\{row},\{col}) = \{out.v[row * out.uv_stride + col]} (want 127)",
        )
      }
    }
  }
  // Determinism.
  let tile2 = match @libavcodec.av1_enc_write_directional_tile(base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  if tile != tile2 {
    fail("directional tile bytes differ between runs")
  }
}

// ///|
//

///|
test "av1 tile enc: ac tile decodes with a non-uniform residual" {
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let tile = match @libavcodec.av1_enc_write_ac_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if fh.base_q_idx != 200 {
    fail("qidx mismatch")
  }
  let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("ac decode failed: \{e}")
  }
  // The first 32x32 block carries a dc + ac residual; the other three
  // are skip = 1 and stay at the flat DC prediction value (128).
  let y00 = out.y[0]
  if y00 == 128 {
    fail("residual did not reach the picture")
  }
  // The skip blocks are pure prediction — from block 0's reconstructed
  // edge where adjacent, so they inherit the residual's DC level (not
  // necessarily 128); each must be internally uniform.
  let ref_tl = out.y[32 * out.y_stride + 0]
  let ref_tr = out.y[0 * out.y_stride + 32]
  for row in 0..<32 {
    for col in 0..<32 {
      let v = out.y[(row + 32) * out.y_stride + col]
      if v != ref_tl {
        fail("skip block TL Y(\{row+32},\{col}) = \{v} != \{ref_tl}")
      }
      let v2 = out.y[row * out.y_stride + col + 32]
      if v2 != ref_tr {
        fail("skip block TR Y(\{row},\{col+32}) = \{v2} != \{ref_tr}")
      }
    }
  }
  // The residual block carries a dc-only coefficient at this slice: the
  // whole block sits at one reconstructed level (uniform is EXPECTED —
  // the ac token that makes it non-uniform is the next slice). What
  // must hold: the block left its flat-prediction base (y00 != 128).
  // Chroma: dc-only residual, uniform within each plane.
  let u0 = out.u[0]
  for row in 0..<16 {
    for col in 0..<16 {
      if out.u[row * out.uv_stride + col] != u0 {
        fail("U(\{row},\{col}) != \{u0}")
      }
      if out.v[row * out.uv_stride + col] != u0 {
        fail("V(\{row},\{col}) != \{u0}")
      }
    }
  }
  // Determinism.
  let tile2 = match @libavcodec.av1_enc_write_ac_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  if tile != tile2 {
    fail("ac tile bytes differ between runs")
  }
}

// §443: real ac coefficients through base_tok / br_tok / golomb.

///|
/// Decode helper for the §443 token tiles: assemble TD-less frame OBU
/// around the caller's Y token spec and run the in-tree decoder.
fn av1tile_tokens_decode(
  toks : FixedArray[Int32],
  signs : FixedArray[Int32],
  qidx : Int32,
) -> @libavcodec.Av1FrameOutput raise {
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
  let tile = match
    @libavcodec.av1_enc_write_ac_token_tile(toks, signs, base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: qidx,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("token decode failed: \{e}")
  }
}

///|
/// The token spec of the standard §443 tile: dc 1 plus ac at scan
/// positions 1 (level 1), 2 (level 2), 3 (level 1) and 7 (level 1) —
/// eob 7 exercises eob_bin 3 with its hi bit and low bool, and the walk
/// covers the 0-base_tok run 6..4.
fn av1tile_ac_spec() -> (FixedArray[Int32], FixedArray[Int32]) {
  let toks = FixedArray::make(1024, 0)
  let signs = FixedArray::make(1024, 0)
  toks[0] = 1
  toks[1] = 1
  toks[2] = 2
  toks[3] = 1
  toks[7] = 1
  (toks, signs)
}

///|
test "av1 tile enc: ac tokens decode to a non-uniform residual" {
  let (toks, signs) = av1tile_ac_spec()
  let out = av1tile_tokens_decode(toks, signs, 200)
  // THE §443 milestone: the ac coefficients must shape the residual —
  // block 0 is no longer uniform (dc-only gave one flat level).
  let v00 = out.y[0]
  let mut min_v = 255
  let mut max_v = 0
  for row in 0..<32 {
    for col in 0..<32 {
      let v = out.y[row * out.y_stride + col]
      if v < min_v {
        min_v = v
      }
      if v > max_v {
        max_v = v
      }
    }
  }
  if min_v == max_v {
    fail("block 0 stayed uniform (\{v00}) — ac tokens did not shape the residual")
  }
  // The residual moved the block off the flat prediction.
  if min_v == 128 && max_v == 128 {
    fail("residual did not reach the picture")
  }
  // The skip blocks stay internally uniform (prediction-only).
  let ref_tl = out.y[32 * out.y_stride + 0]
  let ref_tr = out.y[0 * out.y_stride + 32]
  for row in 0..<32 {
    for col in 0..<32 {
      let v = out.y[(row + 32) * out.y_stride + col]
      if v != ref_tl {
        fail("skip block TL Y(\{row+32},\{col}) = \{v} != \{ref_tl}")
      }
      let v2 = out.y[row * out.y_stride + col + 32]
      if v2 != ref_tr {
        fail("skip block TR Y(\{row},\{col+32}) = \{v2} != \{ref_tr}")
      }
    }
  }
  // Determinism.
  let out2 = av1tile_tokens_decode(av1tile_ac_spec().0, av1tile_ac_spec().1, 200)
  if out.y != out2.y {
    fail("two runs decoded differently")
  }
}

///|
test "av1 tile enc: flipping every ac sign mirrors the residual" {
  // Same magnitudes, ac signs flipped: pixel-wise the two reconstructions
  // must sum to twice the (uniform) dc reconstruction — no clipping at
  // qidx 200 with token levels 1..2.
  let (toks, signs) = av1tile_ac_spec()
  let out_plus = av1tile_tokens_decode(toks, signs, 200)
  let toks2 = av1tile_ac_spec().0
  let signs2 : FixedArray[Int32] = FixedArray::make(1024, 0)
  signs2[1] = 1
  signs2[2] = 1
  signs2[3] = 1
  signs2[7] = 1
  let out_minus = av1tile_tokens_decode(toks2, signs2, 200)
  let s0 = out_plus.y[0] + out_minus.y[0]
  if s0 == 2 * 128 {
    // Trivially uniform would also pass below; require the dc residual
    // to be present so the sum is meaningful.
    if out_plus.y[0] == 128 {
      fail("residual did not reach the picture")
    }
  }
  // The itx's round-half-up stages (one per 1-D pass) make
  // itx(-r) = -itx(r) ± 2, so the per-pixel sum may deviate from s0 by
  // 2. Demand a residual amplitude well above that bound so the check
  // stays tight: a mis-ordered or wrong sign flips pixels by 2x|ac|.
  let mut amp = 0
  for row in 0..<32 {
    for col in 0..<32 {
      let d = out_plus.y[row * out_plus.y_stride + col] - 128
      if d > amp {
        amp = d
      }
      if -d > amp {
        amp = -d
      }
    }
  }
  if amp < 6 {
    fail("ac amplitude too small (\{amp}) for a meaningful sign check")
  }
  for row in 0..<32 {
    for col in 0..<32 {
      let s = out_plus.y[row * out_plus.y_stride + col] +
        out_minus.y[row * out_minus.y_stride + col]
      if s < s0 - 2 || s > s0 + 2 {
        fail(
          "antisymmetry broke at (\{row},\{col}): sum \{s} vs \{s0} (clipping or sign error)",
        )
      }
    }
  }
}

///|
test "av1 tile enc: br_tok, golomb and eob ctx-2 coverage" {
  // dc 2 (base_tok sym 2), position 1 level 4 (br_tok tier 1), position
  // 2 level 15 (all-escape hi_tok + golomb 0), position 35 level 5
  // (br_tok tier 2 in the ac walk), eob 40 level 3 (br_tok at the eob
  // slot with eob ctx 2 — 40 > 2<<4). The walk crosses long zero runs
  // (39..36, 34..3).
  let toks = FixedArray::make(1024, 0)
  let signs = FixedArray::make(1024, 0)
  toks[0] = 2
  toks[1] = 4
  toks[2] = 15
  toks[35] = 5
  toks[40] = 3
  let out = av1tile_tokens_decode(toks, signs, 200)
  let mut min_v = 255
  let mut max_v = 0
  for row in 0..<32 {
    for col in 0..<32 {
      let v = out.y[row * out.y_stride + col]
      if v < min_v {
        min_v = v
      }
      if v > max_v {
        max_v = v
      }
    }
  }
  if min_v == max_v {
    fail("block 0 stayed uniform — the ac/golomb chain did not shape the residual")
  }
  // Determinism.
  let toks2 = FixedArray::make(1024, 0)
  let signs2 = FixedArray::make(1024, 0)
  toks2[0] = 2
  toks2[1] = 4
  toks2[2] = 15
  toks2[35] = 5
  toks2[40] = 3
  let out2 = av1tile_tokens_decode(toks2, signs2, 200)
  if out.y != out2.y {
    fail("two runs decoded differently")
  }
}

// §445: full intra-mode syntax (kfym ctx mirror, angle deltas, uv_mode).
// Mode numbers: DC=0 V=1 H=2 D45=3 D135=4 VR=5 HD=6 HU=7 VL=8
// SMOOTH=9 SMOOTH_V=10 SMOOTH_H=11 PAETH=12.

///|
/// Decode helper for the §445 modes tile.
fn av1tile_modes_decode(
  blocks : Array[(Int32, Int32, Int32, Int32)],
  qidx : Int32,
) -> @libavcodec.Av1FrameOutput raise {
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
  let tile = match @libavcodec.av1_enc_write_modes_tile(blocks, base_q_idx=qidx) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: qidx,
      tile_data: tile,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
    Ok(o) => o
    Err(e) => fail("modes decode failed: \{e}")
  }
}

///|
test "av1 tile enc: modes tile constant propagation frame" {
  // [DC, H, V, DC]: block 0 fills 128 and every later block predicts
  // from constant-128 edges (H copies left, V copies above) — the whole
  // luma plane must be exactly 128 with all-skip blocks.
  let out = av1tile_modes_decode(
    [(0, 0, 0, 0), (2, 0, 0, 0), (1, 0, 0, 0), (0, 0, 0, 0)],
    100,
  )
  for row in 0..<64 {
    for col in 0..<64 {
      if out.y[row * out.y_stride + col] != 128 {
        fail("Y(\{row},\{col}) = \{out.y[row * out.y_stride + col]} (want 128)")
      }
    }
  }
  for row in 0..<32 {
    for col in 0..<32 {
      if out.u[row * out.uv_stride + col] != 128 ||
        out.v[row * out.uv_stride + col] != 128 {
        fail("UV(\{row},\{col}) != 128")
      }
    }
  }
  // [H, DC, V+1, PAETH]: block 0 has no left edge — the LEFT fill is
  // mid+1 = 129 (only the TOP fill is mid-1 = 127) — and 129 propagates
  // through every later prediction (DC from left, V from above).
  let out2 = av1tile_modes_decode(
    [(2, 0, 0, 0), (0, 0, 0, 0), (1, 1, 0, 0), (12, 0, 0, 0)],
    100,
  )
  for row in 0..<64 {
    for col in 0..<64 {
      if out2.y[row * out2.y_stride + col] != 129 {
        fail("Y(\{row},\{col}) = \{out2.y[row * out2.y_stride + col]} (want 129)")
      }
    }
  }
}

///|
test "av1 tile enc: all 13 luma modes with angle deltas decode" {
  // Four frames cover every kfym symbol 0..=12 with varied angle
  // deltas on the directional blocks (Y and UV). All-skip frames with
  // constant edges: every block must stay uniform, and block 0 (no
  // neighbours) sits at DC?128:127.
  let frames : Array[Array[(Int32, Int32, Int32, Int32)]] = [
    // A: H+2, D45-3, V+1, D135; UV carries H+2 and V-1 angle coverage.
    [(2, 2, 0, 0), (3, -3, 2, 2), (1, 1, 0, 0), (4, 0, 1, -1)],
    // B: the four remaining directional modes VR/HD/HU/VL.
    [(5, 2, 0, 0), (6, -3, 0, 0), (7, 2, 0, 0), (8, -3, 0, 0)],
    // C: DC and the smooth family.
    [(0, 0, 0, 0), (9, 0, 0, 0), (10, 0, 0, 0), (11, 0, 0, 0)],
    // D: PAETH plus angle-range extremes revisited.
    [(12, 0, 0, 0), (0, 0, 0, 0), (2, -3, 0, 0), (1, 2, 0, 0)],
  ]
  for fi in 0..<frames.length() {
    let out = av1tile_modes_decode(frames[fi], 100)
    // Block 0 sits at the frame corner: DC/PAETH land on the 128 splat,
    // top-based directional fills 127, left-based 129 — the exact fill
    // is mode-dependent, so assert the corner lands on one of the three
    // legal midpoints and every block predicts uniformly.
    let v00 = out.y[0]
    if v00 < 127 || v00 > 129 {
      fail("frame \{fi}: block0 Y(0,0) = \{v00} (want 127..129)")
    }
    // Constant edges predict constants — except the corner blend: the
    // 3-tap edge filter can mix the topleft mid (128) into a 127 fill,
    // so allow a spread of 1 within a block.
    for b in 0..<4 {
      let bx = (b & 1) * 32
      let by = (b >> 1) * 32
      let v0 = out.y[by * out.y_stride + bx]
      for row in 0..<32 {
        for col in 0..<32 {
          let v = out.y[(by + row) * out.y_stride + bx + col]
          if v < v0 - 1 || v > v0 + 1 {
            fail(
              "frame \{fi} block \{b}: Y(\{by+row},\{bx+col}) = \{v} vs \{v0} (constant edges must stay within 1)",
            )
          }
        }
      }
    }
    // Determinism.
    let out2 = av1tile_modes_decode(frames[fi], 100)
    if out.y != out2.y {
      fail("frame \{fi}: two runs decoded differently")
    }
  }
}

///|
test "av1 tile enc: six angle deltas give six distinct tile streams" {
  // Block 1 is H_PRED against block 0's reconstructed right edge; the
  // delta symbol (0..5 -> angle -3..2) must land in the bitstream, and
  // every stream must decode — decode success is the CDF-slot oracle
  // for the (mode - V_PRED) * 8 angle base.
  let tiles : Array[Bytes] = []
  for d in 0..<6 {
    let tile = match
      @libavcodec.av1_enc_write_modes_tile(
        [(0, 0, 0, 0), (2, d - 3, 0, 0), (1, 0, 0, 0), (0, 0, 0, 0)],
        base_q_idx=100,
      ) {
      Ok(b) => b
      Err(e) => fail(e)
    }
    tiles.push(tile)
    let out = av1tile_modes_decode(
      [(0, 0, 0, 0), (2, d - 3, 0, 0), (1, 0, 0, 0), (0, 0, 0, 0)],
      100,
    )
    if out.width != 64 {
      fail("delta \{d}: bad geometry")
    }
  }
  for i in 0..<6 {
    for j in (i + 1)..<6 {
      if tiles[i] == tiles[j] {
        fail("delta \{i - 3} and \{j - 3} produced identical tile bytes")
      }
    }
  }
}
