// Blackbox tests for §446a: the inter-frame OBU writer. Acceptance
// oracle = `av1_parse_frame_header` / `av1_parse_tile_group` /
// `av1_extract_tiles` in `av1.mbt`: the written OBU_FRAME must parse
// back field for field and hand back the tile data byte-exactly.

///|
/// Encode a full inter frame (TD + sequence header + frame OBU) and
/// parse the frame header back.
fn av1inter_roundtrip(
  seq_cfg : @libavcodec.Av1SeqEncConfig,
  it_cfg : @libavcodec.Av1InterFrameEncConfig,
) -> (@libavcodec.Av1FrameHeader, Array[Byte]) raise {
  let seq_obu = match @libavcodec.av1_enc_write_sequence_header_obu(seq_cfg) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let frame_obu = match @libavcodec.av1_enc_write_inter_frame_obu(seq, it_cfg) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  // Splice TD + seq + frame like a real stream.
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
    Err(e) => fail("inter frame header parse failed: \{e}")
  }
  let tg = match @libavcodec.av1_parse_tile_group(frame_obu, fh) {
    Ok(t) => t
    Err(e) => fail("tile group parse failed: \{e}")
  }
  let abs = tg.payload_offset + tg.tile_offsets[0]
  let slice = frame_obu[abs:abs + tg.tile_sizes[0]].to_owned()
  (fh, slice.to_array())
}

///|
test "av1 inter enc: minimal inter header round trip" {
  let data : Array[Byte] = []
  for i in 0..<37 {
    data.push(((i * 7 + 3) & 0xFF).to_byte())
  }
  let (fh, tile) = av1inter_roundtrip(
    @libavcodec.Av1SeqEncConfig::default(width=64, height=64),
    {
      ..@libavcodec.Av1InterFrameEncConfig::default(),
      tile_data: Bytes::from_array(data[:]),
    },
  )
  if fh.frame_type != @libavcodec.av1_frame_inter || !fh.show_frame {
    fail("not a shown inter frame")
  }
  if fh.showable_frame || fh.error_resilient_mode || fh.disable_cdf_update {
    fail("showable/error-resilient/cdf flags wrong")
  }
  if fh.allow_intrabc {
    fail("intrabc must stay off")
  }
  if fh.width != 64 || fh.height != 64 || fh.upscaled_width != 64 {
    fail("frame size \{fh.width}x\{fh.height}")
  }
  if fh.frame_size_override_flag || fh.use_superres {
    fail("frame size must come from the sequence")
  }
  if fh.refresh_frame_flags != 1 {
    fail("refresh \{fh.refresh_frame_flags}")
  }
  if fh.primary_ref_frame != 7 {
    fail("primary ref \{fh.primary_ref_frame}")
  }
  if fh.ref_frame_idx.length() != 7 {
    fail("ref count \{fh.ref_frame_idx.length()}")
  }
  for i in 0..<7 {
    if fh.ref_frame_idx[i] != 0 {
      fail("ref[\{i}] = \{fh.ref_frame_idx[i]}")
    }
  }
  if fh.allow_high_precision_mv ||
    fh.is_motion_mode_switchable ||
    fh.use_ref_frame_mvs {
    fail("mv precision/motion-mode/ref-mvs flags wrong")
  }
  if fh.interpolation_filter != 0 {
    fail("interpolation filter \{fh.interpolation_filter}")
  }
  if fh.reference_select || fh.skip_mode_enabled || fh.allow_warped_motion {
    fail("compound/skip/warp must stay off")
  }
  if fh.is_global.length() != 7 || fh.gm_types.length() != 7 {
    fail("gm arrays wrong size")
  }
  for i in 0..<7 {
    if fh.is_global[i] || fh.gm_types[i] != 0 {
      fail("gm[\{i}] not identity")
    }
  }
  if fh.tx_mode != 2 || fh.reduced_tx_set {
    fail("tx mode \{fh.tx_mode} reduced \{fh.reduced_tx_set}")
  }
  if fh.disable_frame_end_update_cdf {
    fail("frame-end CDF update flag")
  }
  if fh.base_q_idx != 100 {
    fail("qidx \{fh.base_q_idx}")
  }
  if fh.segmentation_enabled ||
    fh.delta_q_present ||
    fh.using_qmatrix ||
    fh.coded_lossless {
    fail("advanced tools must stay off")
  }
  if fh.loop_filter_level.length() != 2 || fh.loop_filter_level[0] != 0 {
    fail("loop filter levels wrong")
  }
  if fh.tile_cols != 1 || fh.tile_rows != 1 {
    fail("expected a single tile")
  }
  if tile.length() != 37 {
    fail("tile data length \{tile.length()}")
  }
  for i in 0..<37 {
    let w : Byte = ((i * 7 + 3) & 0xFF).to_byte()
    if tile[i] != w {
      fail("tile data mismatch at \{i}")
    }
  }
}

///|
test "av1 inter enc: refresh flags, ref slots, loop filter pair" {
  let (fh, _) = av1inter_roundtrip(
    @libavcodec.Av1SeqEncConfig::default(width=96, height=64),
    {
      ..@libavcodec.Av1InterFrameEncConfig::default(),
      base_q_idx: 173,
      refresh_frame_flags: 129, // 0x81: slots 0 and 7
      ref_frame_idx: [2, 2, 3, 3, 4, 4, 5],
      loop_filter_level0: 17,
      loop_filter_level1: 31,
      loop_filter_sharpness: 4,
    },
  )
  if fh.refresh_frame_flags != 129 {
    fail("refresh \{fh.refresh_frame_flags}")
  }
  let want = [2, 2, 3, 3, 4, 4, 5]
  for i in 0..<7 {
    if fh.ref_frame_idx[i] != want[i] {
      fail("ref[\{i}] = \{fh.ref_frame_idx[i]} want \{want[i]}")
    }
  }
  if fh.base_q_idx != 173 {
    fail("qidx \{fh.base_q_idx}")
  }
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
test "av1 inter enc: multi-tile grid round trip" {
  let seq_cfg = @libavcodec.Av1SeqEncConfig::default(width=128, height=64)
  let seq_obu = match @libavcodec.av1_enc_write_sequence_header_obu(seq_cfg) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let t0 : Array[Byte] = []
  for i in 0..<11 {
    t0.push((i & 0xFF).to_byte())
  }
  let t1 : Array[Byte] = []
  for i in 0..<13 {
    t1.push(((i + 40) & 0xFF).to_byte())
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_inter_frame_obu(seq, {
      ..@libavcodec.Av1InterFrameEncConfig::default(),
      tiles: [Bytes::from_array(t0[:]), Bytes::from_array(t1[:])],
      tile_cols: 2,
      tile_rows: 1,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
    Ok(f) => f
    Err(e) => fail("inter frame header parse failed: \{e}")
  }
  if fh.tile_cols != 2 || fh.tile_rows != 1 {
    fail("grid \{fh.tile_cols}x\{fh.tile_rows}")
  }
  if fh.tile_size_bytes_minus1 != 0 {
    fail("size bytes minus1 \{fh.tile_size_bytes_minus1}")
  }
  if fh.context_update_tile_id != 0 {
    fail("context update id \{fh.context_update_tile_id}")
  }
  let extracted = match @libavcodec.av1_extract_tiles(frame_obu, fh) {
    Ok(t) => t
    Err(e) => fail("tile extraction failed: \{e}")
  }
  if extracted.length() != 2 {
    fail("extracted \{extracted.length()} tiles")
  }
  if extracted[0].data != Bytes::from_array(t0[:]) ||
    extracted[1].data != Bytes::from_array(t1[:]) {
    fail("tile payloads not handed back byte-exactly")
  }
}

///|
/// §446b: encode key + all-GLOBALMV inter frames, decode both through
/// the session driver, return both pictures.
fn av1inter_globalmv_decode(
  width : Int32,
  height : Int32,
  key_tiles : Array[Bytes],
  tile_cols : Int32,
  tile_rows : Int32,
) -> (@libavcodec.Av1FrameOutput, @libavcodec.Av1FrameOutput) raise {
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
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: key_tiles,
      tile_cols,
      tile_rows,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // The encoder's reference-store mirror: the key frame refreshed all
  // eight slots (refresh_frame_flags = 0xFF, order hints off).
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, width, height, 255)
  let it_obu = match
    @libavcodec.av1_enc_write_globalmv_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let pkt2 : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt2.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(pkt2[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  (kf, it)
}

///|
/// Compare two decoded pictures plane by plane (stride-aware).
fn av1inter_expect_same(
  a : @libavcodec.Av1FrameOutput,
  b : @libavcodec.Av1FrameOutput,
) -> Unit raise {
  if a.width != b.width || a.height != b.height {
    fail("geometry \{a.width}x\{a.height} vs \{b.width}x\{b.height}")
  }
  let cw = if a.ss_h != 0 { (a.width + 1) >> 1 } else { a.width }
  let ch = if a.ss_v != 0 { (a.height + 1) >> 1 } else { a.height }
  for y in 0..<a.height {
    for x in 0..<a.width {
      if a.y[y * a.y_stride + x] != b.y[y * b.y_stride + x] {
        fail(
          "Y(\{y},\{x}) \{a.y[y * a.y_stride + x]} != \{b.y[y * b.y_stride + x]}",
        )
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if a.u[y * a.uv_stride + x] != b.u[y * b.uv_stride + x] ||
        a.v[y * a.uv_stride + x] != b.v[y * b.uv_stride + x] {
        fail("UV(\{y},\{x}) differs")
      }
    }
  }
}

///|
test "av1 inter enc: globalmv static frame copies the reference" {
  // 128x64: two SBs side by side, two key tiles (residual left, skip
  // right) so the copied picture is two-toned — a wrong block offset
  // cannot pass.
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let (kf, it) = av1inter_globalmv_decode(128, 64, [t_res, t_skip], 2, 1)
  // Sanity: the key picture carries both tones.
  let v0 = kf.y[0]
  if v0 == 128 {
    fail("residual tile did not reach the key picture")
  }
  if kf.y[kf.y_stride + 64] != 128 {
    fail("skip half of the key picture is not 128")
  }
  av1inter_expect_same(kf, it)
}

///|
test "av1 inter enc: globalmv multi-row and multi-bank frames" {
  // 64x128 (two SB rows: above-bank persistence across rows) and
  // 128x128 (four SBs: two above banks and two rows).
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let (kf1, it1) = av1inter_globalmv_decode(64, 128, [t_res, t_skip], 1, 2)
  av1inter_expect_same(kf1, it1)
  let (kf2, it2) = av1inter_globalmv_decode(
    128,
    128,
    [t_res, t_skip, t_skip, t_skip],
    2,
    2,
  )
  av1inter_expect_same(kf2, it2)
}

///|
/// §447a: encode key + uniform-translation inter frames, decode both.
fn av1inter_translated_decode(
  width : Int32,
  height : Int32,
  key_tiles : Array[Bytes],
  tile_cols : Int32,
  tile_rows : Int32,
  dy : Int32,
  dx : Int32,
) -> (@libavcodec.Av1FrameOutput, @libavcodec.Av1FrameOutput) raise {
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
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: key_tiles,
      tile_cols,
      tile_rows,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, width, height, 255)
  let it_obu = match
    @libavcodec.av1_enc_write_translated_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
      mv_y=dy,
      mv_x=dx,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let pkt2 : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt2.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(pkt2[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  (kf, it)
}

///|
/// Assert the inter picture equals the clamp-shifted reference (the
/// full-pel MC is a clamped copy — av1_mc_sample), luma always, chroma
/// only when both shifts are even (odd shifts filter chroma).
fn av1inter_expect_translated(
  kf : @libavcodec.Av1FrameOutput,
  it : @libavcodec.Av1FrameOutput,
  dy : Int32,
  dx : Int32,
  chroma_too~ : Bool = true,
) -> Unit raise {
  fn clamp(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  let w = kf.width
  let h = kf.height
  let mut moved = 0
  for y in 0..<h {
    for x in 0..<w {
      let sy = clamp(y + dy, h)
      let sx = clamp(x + dx, w)
      let want = kf.y[sy * kf.y_stride + sx]
      if it.y[y * it.y_stride + x] != want {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want \{want} (shift \{dy},\{dx})",
        )
      }
      if want != kf.y[y * kf.y_stride + x] {
        moved = moved + 1
      }
    }
  }
  if moved == 0 {
    fail("translation invisible: the key picture must be two-toned")
  }
  if chroma_too {
    let cw = if kf.ss_h != 0 { (w + 1) >> 1 } else { w }
    let ch = if kf.ss_v != 0 { (h + 1) >> 1 } else { h }
    for y in 0..<ch {
      for x in 0..<cw {
        let sy = clamp(y + dy / 2, ch)
        let sx = clamp(x + dx / 2, cw)
        if it.u[y * it.uv_stride + x] != kf.u[sy * kf.uv_stride + sx] ||
          it.v[y * it.uv_stride + x] != kf.v[sy * kf.uv_stride + sx] {
          fail("UV(\{y},\{x}) differs from the clamped shift")
        }
      }
    }
  }
}

///|
test "av1 inter enc: newmv translated frame, even shifts exact" {
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  // (dy,dx) = (2,4): mags 16 = class0(up=1) and 32 = class1(bit=1) —
  // both NEWMV component shapes on the first block; the rest of the
  // blocks ride NEARESTMV against the published target.
  let (kf, it) = av1inter_translated_decode(
    128,
    64,
    [t_res, t_skip],
    2,
    1,
    2,
    4,
  )
  av1inter_expect_translated(kf, it, 2, 4)
  // Negative direction: signs and mirrored clamping.
  let (kf2, it2) = av1inter_translated_decode(
    64,
    128,
    [t_res, t_skip],
    1,
    2,
    -4,
    -2,
  )
  av1inter_expect_translated(kf2, it2, -4, -2)
}

///|
test "av1 inter enc: newmv translated frame, odd shift luma exact" {
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  // (dy,dx) = (7,-5): mags 56/40 → class 2 with two coded bits each.
  // Odd shifts filter chroma (mv>>4 fractional), so only luma matches
  // the clamped copy.
  let (kf, it) = av1inter_translated_decode(
    128,
    64,
    [t_res, t_skip],
    2,
    1,
    7,
    -5,
  )
  av1inter_expect_translated(kf, it, 7, -5, chroma_too=false)
}

///|
/// §447b: the skip=0 zero-residual variant must decode to the same
/// clamped-shift picture while carrying strictly more symbols.
fn av1inter_skip0_decode(
  width : Int32,
  height : Int32,
  key_tiles : Array[Bytes],
  tile_cols : Int32,
  tile_rows : Int32,
  dy : Int32,
  dx : Int32,
) -> (@libavcodec.Av1FrameOutput, @libavcodec.Av1FrameOutput, Bytes, Bytes) raise {
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
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: key_tiles,
      tile_cols,
      tile_rows,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Two inter frames from the same reference: skip=1 (§447a) and
  // skip=0 zero-residual (§447b).
  let refs1 = @libavcodec.av1_refmvs_reference_store_new()
  refs1.refresh_without_mvs(0, width, height, 255)
  let skip1 = match
    @libavcodec.av1_enc_write_translated_inter_frame_obu(
      seq,
      refs1,
      base_q_idx=200,
      mv_y=dy,
      mv_x=dx,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let refs0 = @libavcodec.av1_refmvs_reference_store_new()
  refs0.refresh_without_mvs(0, width, height, 255)
  let skip0 = match
    @libavcodec.av1_enc_write_translated_inter_frame_obu(
      seq,
      refs0,
      base_q_idx=200,
      mv_y=dy,
      mv_x=dx,
      skip=false,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let pkt2 : Array[Byte] = []
  for part in [td, skip0] {
    for i = 0; i < part.length(); i = i + 1 {
      pkt2.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(pkt2[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter frame hidden")
    Err(e) => fail("skip=0 inter decode: \{e}")
  }
  (kf, it, skip1, skip0)
}

///|
test "av1 inter enc: skip0 zero residual walks the var-tx chain" {
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let (kf, it, skip1, skip0) = av1inter_skip0_decode(
    128,
    64,
    [t_res, t_skip],
    2,
    1,
    2,
    4,
  )
  // Same reconstruction: the all-skip coefficients add nothing.
  av1inter_expect_translated(kf, it, 2, 4)
  // But strictly more syntax: the streams must differ and skip=0 must
  // not be shorter (var-tx split bool + 3 all_skip bools per block).
  if skip0 == skip1 {
    fail("skip=0 stream identical to skip=1 — residual symbols missing")
  }
  if skip0.length() < skip1.length() {
    fail("skip=0 stream shorter than skip=1")
  }
  // Two SB rows: the per-row l mirror resets stay in lockstep.
  let (kf2, it2, _, skip0b) = av1inter_skip0_decode(
    64,
    128,
    [t_res, t_skip],
    1,
    2,
    -4,
    -2,
  )
  av1inter_expect_translated(kf2, it2, -4, -2)
  if skip0b.length() == 0 {
    fail("empty skip0 stream")
  }
}

///|
test "av1 inter enc: me picks shifts and dc tokens carry offsets" {
  let w = 64
  let h = 128
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // The key's top superblock carries the §443 structured tile (dc 1 +
  // ac at scan 1,2,3,7 — a strictly non-uniform quadrant), the bottom
  // stays the flat skip tile. Structure makes the shift's SAD minimum
  // unique; flat content makes any offset-vs-tone alignment exploit
  // possible, so the offset frame never runs ME.
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = match
    @libavcodec.av1_enc_write_ac_token_tile(
      toks_spec,
      signs_spec,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: [t_ac, t_skip],
      tile_cols: 1,
      tile_rows: 2,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Sanity: the key's top SB is structured (the shift needs a unique
  // SAD minimum) — one non-uniform quadrant is enough.
  let mut vmin = 255
  let mut vmax = 0
  for row in 0..<32 {
    for col in 0..<32 {
      let v = kf.y[row * kf.y_stride + col]
      if v < vmin {
        vmin = v
      }
      if v > vmax {
        vmax = v
      }
    }
  }
  if vmin == vmax {
    fail("key top SB stayed uniform — ME would be ambiguous")
  }
  // The dc-only level for the INTER transform size: the me/dc tile
  // codes luma at TX_64X64, whose dequant/itx gain differs from the
  // split tile's TX_32X32 — calibrate on a 64x64 residual key decoded
  // through the same path (the level is per (qidx, token, tx size)).
  let cal_seq = match
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
  let t_res64 = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let cal_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(cal_seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tile_data: t_res64,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let cal = match
    @libavcodec.av1_decode_keyframe(
      cal_seq,
      match @libavcodec.av1_parse_frame_header(cal_obu, cal_seq) {
        Ok(f) => f
        Err(e) => fail(e)
      },
      t_res64,
    ) {
    Ok(o) => o
    Err(e) => fail(e)
  }
  let delta = cal.y[0] - 128
  if delta == 0 {
    fail("calibrated dc level is zero — token sanity failed")
  }
  fn clamp(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  // ---- Frame A: ME over the pure clamped shift (2, 0), no offsets.
  let src : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      if y < 64 {
        src[y * w + x] = kf.y[clamp(y + 2, h) * kf.y_stride + x]
      } else {
        src[y * w + x] = kf.y[y * kf.y_stride + x]
      }
    }
  }
  let (mvy, mvx) = match
    @libavcodec.av1_enc_me_fullpel_sad(src, w, kf.y, kf.y_stride, w, h, range=8) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if mvy[0] != 2 || mvx[0] != 0 {
    fail("me SB0: (\{mvy[0]},\{mvx[0]}) want (2,0)")
  }
  if mvy[1] != 0 || mvx[1] != 0 {
    fail("me SB1: (\{mvy[1]},\{mvx[1]}) want (0,0)")
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let toks0 : FixedArray[Int32] = [0, 0]
  let signs0 : FixedArray[Int32] = [0, 0]
  let it_obu = match
    @libavcodec.av1_enc_write_me_dc_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
      mvs_y=mvy,
      mvs_x=mvx,
      dc_toks=toks0,
      dc_signs=signs0,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("me inter frame hidden")
    Err(e) => fail("me inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      let got = it.y[y * it.y_stride + x]
      if got != src[y * w + x] {
        fail("Y(\{y},\{x}) = \{got} want \{src[y * w + x]}")
      }
    }
  }
  // ---- Frame B: the dc token on a static frame (mvs handed in, no ME
  // — a uniform offset on flat content would be SAD-ambiguous).
  for sgn in [0, 1] {
    let decb = @libavcodec.Av1Decoder::new()
    match decb.decode_packet(Bytes::from_array(key_pkt[:])) {
      Ok(Some(_)) => ()
      Ok(None) => fail("key frame hidden (session \{sgn})")
      Err(e) => fail("key decode (session \{sgn}): \{e}")
    }
    let refsb = @libavcodec.av1_refmvs_reference_store_new()
    refsb.refresh_without_mvs(0, w, h, 255)
    let mvs0 : FixedArray[Int32] = [0, 0]
    let toksb : FixedArray[Int32] = [1, 0]
    let signsb : FixedArray[Int32] = [sgn, 0]
    let obu = match
      @libavcodec.av1_enc_write_me_dc_inter_frame_obu(
        seq,
        refsb,
        base_q_idx=200,
        mvs_y=mvs0,
        mvs_x=mvs0,
        dc_toks=toksb,
        dc_signs=signsb,
      ) {
      Ok(b) => b
      Err(e) => fail(e)
    }
    let pkt : Array[Byte] = []
    for part in [td, obu] {
      for i = 0; i < part.length(); i = i + 1 {
        pkt.push(part[i])
      }
    }
    let out = match decb.decode_packet(Bytes::from_array(pkt[:])) {
      Ok(Some(f)) => f
      Ok(None) => fail("dc inter frame hidden (sign \{sgn})")
      Err(e) => fail("dc inter decode (sign \{sgn}): \{e}")
    }
    // SB0: the whole structured prediction lifted (or lowered) by the
    // level; SB1: untouched.
    for y in 0..<64 {
      for x in 0..<w {
        let base = kf.y[y * kf.y_stride + x]
        let v = if sgn == 0 { base + delta } else { base - delta }
        let want = if v < 0 { 0 } else if v > 255 { 255 } else { v }
        let got = out.y[y * out.y_stride + x]
        if got != want {
          fail(
            "sign \{sgn} Y(\{y},\{x}) = \{got} want \{want} (base \{base}, delta \{delta})",
          )
        }
      }
    }
    for y in 64..<h {
      for x in 0..<w {
        if out.y[y * out.y_stride + x] != kf.y[y * kf.y_stride + x] {
          fail("sign \{sgn} SB1 modified by the SB0 token")
        }
      }
    }
  }
}

///|
test "av1 inter enc: subpel8 uniform half-pel shift matches MC" {
  let w = 64
  let h = 64
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let t_res = match
    @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tile_data: t_res,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Encode a half-pel shift inter frame: mv = 4/8 pel down, 0 right.
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let it_obu = match
    @libavcodec.av1_enc_write_subpel_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
      mv_y8=4,
      mv_x8=0,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("subpel inter frame hidden")
    Err(e) => fail("subpel inter decode: \{e}")
  }
  // Oracle: the decoder's own MC kernel at the same position/phase —
  // 64x64 luma block, mv (4, 0) in 1/8 pel, EIGHTTAP (filter2d = 0).
  let pred = @libavcodec.av1_enc_mc_predict(
    kf.y,
    kf.y_stride,
    kf.width,
    kf.height,
    kf.width,
    kf.height,
    0,
    0,
    16,
    16,
    4,
    0,
    0,
    0,
    0,
    8,
  )
  for y in 0..<h {
    for x in 0..<w {
      if it.y[y * it.y_stride + x] != pred[y * w + x] {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want MC \{pred[y * w + x]}",
        )
      }
    }
  }
}

///|
test "av1 inter enc: halfpel ME refines integer search" {
  let w = 64
  let h = 64
  // Reference: a sharp horizontal step at y = 32 (half-pel shifts move
  // the step edge measurably; a flat field would make every candidate
  // tie at zero cost and the refinement must then keep the integer MV).
  let refimg = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      refimg[y * w + x] = if y < 32 { 60 } else { 200 }
    }
  }
  // Source: the reference prediction at a true half-pel shift — the
  // decoder's own MC kernel at mv8 = (-4, 0) (clamp model alone cannot
  // represent the 8-tap output; the kernel-scoring refine matches it
  // by construction). The integer grid cannot represent this shift, so
  // the refinement must win over (0,0) on the y axis.
  let src = @libavcodec.av1_enc_mc_predict(
    refimg, w, w, h, w, h, 0, 0, 16, 16, -4, 0, 0, 0, 0, 8,
  )
  let (mvy, mvx) = match
    @libavcodec.av1_enc_me_fullpel_sad(src, w, refimg, w, w, h, range=4) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if mvy[0] != 0 || mvx[0] != 0 {
    fail(
      "integer search found (\{mvy[0]},\{mvx[0]}) — expected the (0,0) fallback on a half-pel-only shift",
    )
  }
  let (ry, rx) = match
    @libavcodec.av1_enc_me_subpel_refine(src, w, refimg, w, w, h, mvy, mvx) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if ry[0] != -4 || rx[0] != 0 {
    fail("halfpel refine found (\{ry[0]},\{rx[0]}) want (-4,0)")
  }
  // Flat content: every candidate ties; the refinement keeps (0,0).
  let flat = FixedArray::make(w * h, 100)
  let (fy, fx) = match
    @libavcodec.av1_enc_me_subpel_refine(
      flat,
      w,
      flat,
      w,
      w,
      h,
      FixedArray::make(1, 0),
      FixedArray::make(1, 0),
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if fy[0] != 0 || fx[0] != 0 {
    fail(
      "flat refine moved to (\{fy[0]},\{fx[0]}) — ties must keep the integer MV",
    )
  }
}

///|
test "av1 inter enc: me8 frame reproduces kernel half-pel shift" {
  let w = 64
  let h = 64
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Structured key content: the §443 ac token tile (a strictly
  // non-uniform quadrant — the half-pel phase is distinguishable).
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = match
    @libavcodec.av1_enc_write_ac_token_tile(
      toks_spec,
      signs_spec,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tile_data: t_ac,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Source: the key predicted at half-pel (4, 0) by the decoder's own
  // MC kernel — the exact image the inter frame must reproduce.
  let src = @libavcodec.av1_enc_mc_predict(
    kf.y,
    kf.y_stride,
    kf.width,
    kf.height,
    kf.width,
    kf.height,
    0,
    0,
    16,
    16,
    4,
    0,
    0,
    0,
    0,
    8,
  )
  // ME: the integer search lands somewhere nearby, the refine must hit
  // the exact phase (kernel-scored SAD 0).
  let (mvy, mvx) = match
    @libavcodec.av1_enc_me_fullpel_sad(src, w, kf.y, kf.y_stride, w, h, range=4) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let (ry, rx) = match
    @libavcodec.av1_enc_me_subpel_refine(
      src,
      w,
      kf.y,
      kf.y_stride,
      w,
      h,
      mvy,
      mvx,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if ry[0] != 4 || rx[0] != 0 {
    fail("refine found (\{ry[0]},\{rx[0]}) want (4,0)")
  }
  // Encode: me8 frame, zero dc tokens — reconstruction is pure MC.
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let toks0 : FixedArray[Int32] = [0]
  let signs0 : FixedArray[Int32] = [0]
  let it_obu = match
    @libavcodec.av1_enc_write_me8_dc_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
      mvs_y8=ry,
      mvs_x8=rx,
      dc_toks=toks0,
      dc_signs=signs0,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("me8 inter frame hidden")
    Err(e) => fail("me8 inter decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if it.y[y * it.y_stride + x] != src[y * w + x] {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want \{src[y * w + x]}",
        )
      }
    }
  }
}

///|
test "av1 inter enc: me res frame carries the quantized residual" {
  let w = 64
  let h = 128
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Two stacked tiles: the top SB carries the §443 AC-structured tile
  // (a non-uniform quadrant — row-to-row variation in the tens pins the
  // shift), the bottom stays the flat skip tile.
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = match
    @libavcodec.av1_enc_write_ac_token_tile(
      toks_spec,
      signs_spec,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: [t_ac, t_skip],
      tile_cols: 1,
      tile_rows: 2,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  fn clamp(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  // Source: the key shifted (2, 0) plus an x-only overlay ramp — it
  // adds the same magnitude to every candidate shift (no dy bias), so
  // the key's structure alone pins the MV, and the overlay is exactly
  // what the transform chain's residual must carry.
  let src : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = kf.y[clamp(y + 2, h) * kf.y_stride + x]
      let ov = x * 7 % 24 - 12
      let s = v + ov
      src[y * w + x] = if s < 0 { 0 } else if s > 255 { 255 } else { s }
    }
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (it_obu, expected, mvy8) = match
    @libavcodec.av1_enc_write_me_res_inter_frame_obu(
      seq,
      refs,
      src,
      w,
      kf.y,
      kf.y_stride,
      base_q_idx=100,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  // ME found the shift on the structured top SB (the y = 64 boundary
  // pins dy; dx stays 0 by the tie-break on x-uniform content). The
  // quarter-pel stage (§454) may land a quarter step off the true
  // 2-pel shift: the x-only overlay ramp is a column signal, and the
  // half-pel x-blend genuinely tracks it better than the identity
  // (SAD(16,-4) < SAD(16,0) by measurement), so the strictly-better
  // walk can end within a quarter-pel of (16,0). Exactness below is
  // the content-independent assertion.
  if mvy8[0] < 14 || mvy8[0] > 18 {
    fail("me mv8 = (\{mvy8[0]}) want 16±2 (quarter neighborhood)")
  }
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("me res frame hidden")
    Err(e) => fail("me res decode: \{e}")
  }
  // THE assertion: the decode realizes exactly the predicted
  // reconstruction (pred + itx(dequant(tokens))).
  for y in 0..<h {
    for x in 0..<w {
      let got = it.y[y * it.y_stride + x]
      if got != expected[y * w + x] {
        fail("Y(\{y},\{x}) = \{got} want expected \{expected[y * w + x]}")
      }
    }
  }
  // Quality: the residual helped — the reconstruction tracks the source
  // strictly better than the bare predictions (per-SB MC at the found
  // integer shifts).
  let mut sad_res = 0L
  let mut sad_pred = 0L
  for sby in 0..<2 {
    let pred = @libavcodec.av1_enc_mc_predict(
      kf.y,
      kf.y_stride,
      kf.width,
      kf.height,
      kf.width,
      kf.height,
      0,
      sby * 16,
      16,
      16,
      mvy8[sby],
      0,
      0,
      0,
      0,
      8,
    )
    for y in 0..<64 {
      for x in 0..<w {
        let gy = sby * 64 + y
        let s = src[gy * w + x]
        let d1 = expected[gy * w + x] - s
        let d2 = pred[y * w + x] - s
        sad_res += if d1 < 0 { -d1.to_int64() } else { d1.to_int64() }
        sad_pred += if d2 < 0 { -d2.to_int64() } else { d2.to_int64() }
      }
    }
  }
  if sad_res >= sad_pred {
    fail("residual did not help: sad(res) \{sad_res} >= sad(pred) \{sad_pred}")
  }
}

///|
test "av1 inter enc: me res skeleton with zero residual" {
  let w = 64
  let h = 128
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: [t_skip, t_skip],
      tile_cols: 1,
      tile_rows: 2,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  // Source: exactly the MC prediction at the integer shift (2, 0) —
  // zero residual, every leaf quantizes to all_skip.
  let src : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for sby in 0..<2 {
    let pred = @libavcodec.av1_enc_mc_predict(
      kf.y,
      kf.y_stride,
      kf.width,
      kf.height,
      kf.width,
      kf.height,
      0,
      sby * 16,
      16,
      16,
      16,
      0,
      0,
      0,
      0,
      8,
    )
    for y in 0..<64 {
      for x in 0..<w {
        src[(sby * 64 + y) * w + x] = pred[y * w + x]
      }
    }
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (it_obu, expected, mvy8) = match
    @libavcodec.av1_enc_write_me_res_inter_frame_obu(
      seq,
      refs,
      src,
      w,
      kf.y,
      kf.y_stride,
      base_q_idx=100,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  ignore(mvy8)
  // Flat content: every shift ties, the ME keeps (0,0) — the residual
  // is still exactly zero (src == MC at any shift on a flat key).
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("frame hidden")
    Err(e) => fail("decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if it.y[y * it.y_stride + x] != src[y * w + x] {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want \{src[y * w + x]}",
        )
      }
    }
  }
  ignore(expected)
}

///|

///|
test "av1 inter enc: quantized leaf token chain via key-frame path" {
  let w = 32
  // A synthetic residual: the overlay pattern plus a boundary step.
  let res : FixedArray[Int32] = FixedArray::make(1024, 0)
  for y in 0..<32 {
    for x in 0..<32 {
      let ov = x * 7 % 24 - 12
      let step = if y >= 16 { 40 } else { 0 }
      res[y * 32 + x] = ov + step
    }
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
  // Bisect the chain: each spec stage must decode to its own recon.
  let stages : Array[(String, FixedArray[Int32], FixedArray[Int32])] = [
    (
      "dc1",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g
      },
    ),
    (
      "dc1+ac7@1023",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[1023] = 7
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[1023] = 1
        g
      },
    ),
    (
      "dc1+ac20@64",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[64] = 20
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[64] = 1
        g
      },
    ),
    (
      "dc1+ac20@64+ac7@1023",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[64] = 20
        t[1023] = 7
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[64] = 1
        g[1023] = 1
        g
      },
    ),
    (
      "dc1+ac200@100",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[100] = 200
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[100] = 1
        g
      },
    ),
    (
      "dc1+ac200@100+ac7@1023",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[100] = 200
        t[1023] = 7
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[100] = 1
        g[1023] = 1
        g
      },
    ),
    (
      "dc1+ac3000@500",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[500] = 3000
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[500] = 1
        g
      },
    ),
    (
      "dc1+ac3000@500+ac7@1023",
      {
        let t = FixedArray::make(1024, 0)
        t[0] = 1
        t[500] = 3000
        t[1023] = 7
        t
      },
      {
        let g = FixedArray::make(1024, 0)
        g[500] = 1
        g[1023] = 1
        g
      },
    ),
  ]
  for stage in stages {
    let name = stage.0
    let toks = stage.1
    let signs = stage.2
    let (delta, raw00) = @libavcodec.av1_enc_debug_recon_leaf32(
      toks, signs, 100,
    )
    ignore(raw00)
    let tile = match
      @libavcodec.av1_enc_write_ac_token_tile(toks, signs, base_q_idx=100) {
      Ok(b) => b
      Err(e) => fail("\{name}: tile write failed: \{e}")
    }
    let frame_obu = match
      @libavcodec.av1_enc_write_key_frame_obu(seq, {
        ..@libavcodec.Av1KeyFrameEncConfig::default(),
        base_q_idx: 100,
        tile_data: tile,
      }) {
      Ok(b) => b
      Err(e) => fail("\{name}: frame write failed: \{e}")
    }
    let fh = match @libavcodec.av1_parse_frame_header(frame_obu, seq) {
      Ok(f) => f
      Err(e) => fail("\{name}: header parse failed: \{e}")
    }
    let out = match @libavcodec.av1_decode_keyframe(seq, fh, tile) {
      Ok(o) => o
      Err(e) => fail("\{name}: key decode failed: \{e}")
    }
    for y in 0..<32 {
      for x in 0..<32 {
        let want = 128 + delta[y * 32 + x]
        let got = out.y[y * out.y_stride + x]
        if want >= 0 && want <= 255 && got != want {
          fail("\{name}: mismatch at (\{y},\{x}): \{got} want \{want}")
        }
      }
    }
  }
  // Diagnostics: quantize an overlay-style residual via the wrapper.
  let ores : FixedArray[Int32] = FixedArray::make(1024, 0)
  for y in 0..<32 {
    for x in 0..<32 {
      ores[y * 32 + x] = x * 7 % 24 - 12
    }
  }
  let (_, _, odelta) = @libavcodec.av1_enc_debug_quantize_leaf32(ores, 100)
  let mut osad : Int64 = 0L
  for i in 0..<1024 {
    let d = odelta[i] - ores[i]
    osad += if d < 0 { -d.to_int64() } else { d.to_int64() }
  }
  if osad > 4096 * 4 {
    fail("overlay quantize error too big: \{osad}")
  }
  // The full handcrafted spec (large golomb tokens, saturation).
  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks[0] = 17
  toks[3] = 5
  toks[63] = 14
  toks[64] = 20
  toks[100] = 200
  toks[500] = 3000
  toks[1023] = 7
  signs[0] = 1
  signs[3] = 1
  signs[64] = 1
  signs[500] = 1
  let (delta, raw00) = @libavcodec.av1_enc_debug_recon_leaf32(toks, signs, 100)
  ignore(raw00)
  let n_tok = 7
  let max_tok = 3000
  // Encode the spec through the §443 key-frame tile (block 0 = the
  // TX_32X32 token chain; DC_PRED from the fresh border) and decode.
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
    @libavcodec.av1_enc_write_ac_token_tile(toks, signs, base_q_idx=100) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let frame_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 100,
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
    Err(e) => fail("key decode: \{e}")
  }
  // Block 0's reconstruction = 128 (fresh DC prediction) + the itx
  // delta — must match the wrapper's exact reconstruction.
  for y in 0..<32 {
    for x in 0..<32 {
      let want = 128 + delta[y * 32 + x]
      let got = out.y[y * out.y_stride + x]
      if got < 0 || got > 255 {
        // the decoder clamps; compare only in-range expectations
        if want >= 0 && want <= 255 && got != want {
          fail(
            "token chain mismatch (\{n_tok} toks, max \{max_tok}) at (\{y},\{x}): \{got} want \{want}",
          )
        }
      } else if got != want {
        fail(
          "token chain mismatch (\{n_tok} toks, max \{max_tok}) at (\{y},\{x}): \{got} want \{want}",
        )
      }
    }
  }
  ignore(w)
}

///|

///|
test "av1 inter enc: me res420 carries chroma residuals too" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Key: the structured AC tile on top, flat skip below — the y = 64
  // boundary pins the shift in luma; the chroma planes are flat (the
  // overlay provides their residual).
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = match
    @libavcodec.av1_enc_write_ac_token_tile(
      toks_spec,
      signs_spec,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: [t_ac, t_skip],
      tile_cols: 1,
      tile_rows: 2,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  fn clamp(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  // Source: the key shifted (2, 0) with an x-only overlay per plane
  // (no dy bias; the overlay is what each plane's residual carries).
  let src_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let src_u : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let src_v : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = kf.y[clamp(y + 2, h) * kf.y_stride + x]
      let s = v + (x * 7 % 24 - 12)
      src_y[y * w + x] = if s < 0 { 0 } else if s > 255 { 255 } else { s }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      let u = kf.u[y * kf.uv_stride + x]
      let vv = kf.v[y * kf.uv_stride + x]
      let su = u + (x * 5 % 16 - 8)
      let sv = vv + ((x * 11 + 3) % 18 - 9)
      src_u[y * cw + x] = if su < 0 { 0 } else if su > 255 { 255 } else { su }
      src_v[y * cw + x] = if sv < 0 { 0 } else if sv > 255 { 255 } else { sv }
    }
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (it_obu, exp_y, exp_u, exp_v) = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs,
      src_y,
      w,
      src_u,
      cw,
      src_v,
      kf.y,
      kf.y_stride,
      kf.u,
      kf.uv_stride,
      kf.v,
      base_q_idx=80,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = match dec.decode_packet(Bytes::from_array(it_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("me res420 frame hidden")
    Err(e) => fail("me res420 decode: \{e}")
  }
  // Exactness on all three planes.
  for y in 0..<h {
    for x in 0..<w {
      let got = it.y[y * it.y_stride + x]
      if got != exp_y[y * w + x] {
        fail("Y(\{y},\{x}) = \{got} want \{exp_y[y * w + x]}")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      let gu = it.u[y * it.uv_stride + x]
      let gv = it.v[y * it.uv_stride + x]
      if gu != exp_u[y * cw + x] {
        fail("U(\{y},\{x}) = \{gu} want \{exp_u[y * cw + x]}")
      }
      if gv != exp_v[y * cw + x] {
        fail("V(\{y},\{x}) = \{gv} want \{exp_v[y * cw + x]}")
      }
    }
  }
  // Quality: per plane the residual helped over the bare prediction
  // (MC at the found shift).
  let mut sad_y_res = 0L
  let mut sad_y_pred = 0L
  let mut sad_u_res = 0L
  let mut sad_u_pred = 0L
  for sby in 0..<2 {
    let pred = @libavcodec.av1_enc_mc_predict(
      kf.y,
      kf.y_stride,
      kf.width,
      kf.height,
      kf.width,
      kf.height,
      0,
      sby * 16,
      16,
      16,
      16,
      0,
      0,
      0,
      0,
      8,
    )
    let predu = @libavcodec.av1_enc_mc_predict(
      kf.u,
      kf.uv_stride,
      w,
      h,
      w,
      h,
      0,
      sby * 16,
      16,
      16,
      16,
      0,
      1,
      1,
      0,
      8,
    )
    for y in 0..<64 {
      for x in 0..<w {
        let gy = sby * 64 + y
        let d1 = exp_y[gy * w + x] - src_y[gy * w + x]
        let d2 = pred[y * w + x] - src_y[gy * w + x]
        sad_y_res += if d1 < 0 { -d1.to_int64() } else { d1.to_int64() }
        sad_y_pred += if d2 < 0 { -d2.to_int64() } else { d2.to_int64() }
      }
    }
    for y in 0..<32 {
      for x in 0..<cw {
        let gy = sby * 32 + y
        let d1 = exp_u[gy * cw + x] - src_u[gy * cw + x]
        let d2 = predu[y * 32 + x] - src_u[gy * cw + x]
        sad_u_res += if d1 < 0 { -d1.to_int64() } else { d1.to_int64() }
        sad_u_pred += if d2 < 0 { -d2.to_int64() } else { d2.to_int64() }
      }
    }
  }
  if sad_y_res >= sad_y_pred {
    fail("luma residual did not help: \{sad_y_res} >= \{sad_y_pred}")
  }
  // The chroma overlay (+-8) is small relative to the quantization
  // noise at qidx 80 — assert the residual is not catastrophically
  // worse (the exactness assertion above is the strong check).
  if sad_u_res > sad_u_pred * 3 / 2 + 4096 {
    fail("chroma residual far worse: \{sad_u_res} vs \{sad_u_pred}")
  }
}

///|

///|
test "av1 inter enc: multi-frame reference chain (key + 2 inter)" {
  let w = 64
  let h = 128
  let cw = 32
  let ch = 64
  let seq_obu = match
    @libavcodec.av1_enc_write_sequence_header_obu(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(seq_obu) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = match
    @libavcodec.av1_enc_write_ac_token_tile(
      toks_spec,
      signs_spec,
      base_q_idx=200,
    ) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let t_skip = match @libavcodec.av1_enc_write_minimal_tile(base_q_idx=200) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let kf_obu = match
    @libavcodec.av1_enc_write_key_frame_obu(seq, {
      ..@libavcodec.Av1KeyFrameEncConfig::default(),
      base_q_idx: 200,
      tiles: [t_ac, t_skip],
      tile_cols: 1,
      tile_rows: 2,
    }) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = match dec.decode_packet(Bytes::from_array(key_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("key frame hidden")
    Err(e) => fail("key decode: \{e}")
  }
  fn clamp(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  // ---- Frame 1: the key shifted (2, 0) + x-only luma/chroma overlays.
  let src1_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let src1_u : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let src1_v : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let s = kf.y[clamp(y + 2, h) * kf.y_stride + x] + (x * 7 % 24 - 12)
      src1_y[y * w + x] = if s < 0 { 0 } else if s > 255 { 255 } else { s }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      let su = kf.u[y * kf.uv_stride + x] + (x * 5 % 16 - 8)
      let sv = kf.v[y * kf.uv_stride + x] + ((x * 11 + 3) % 18 - 9)
      src1_u[y * cw + x] = if su < 0 { 0 } else if su > 255 { 255 } else { su }
      src1_v[y * cw + x] = if sv < 0 { 0 } else if sv > 255 { 255 } else { sv }
    }
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let (f1_obu, exp1_y, exp1_u, exp1_v) = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs,
      src1_y,
      w,
      src1_u,
      cw,
      src1_v,
      kf.y,
      kf.y_stride,
      kf.u,
      kf.uv_stride,
      kf.v,
      base_q_idx=80,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let f1_pkt : Array[Byte] = []
  for part in [td, f1_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      f1_pkt.push(part[i])
    }
  }
  let f1 = match dec.decode_packet(Bytes::from_array(f1_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("frame 1 hidden")
    Err(e) => fail("frame 1 decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if f1.y[y * f1.y_stride + x] != exp1_y[y * w + x] {
        fail("F1 Y(\{y},\{x}) diverged")
      }
    }
  }
  // ---- Frame 2: the frame-1 RECONSTRUCTION shifted (0, +4) plus a
  // second overlay — the reference is slot 0 (frame 1's decoded
  // picture), exercising the reference chain.
  let src2_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  let src2_u : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  let src2_v : FixedArray[Int32] = FixedArray::make(cw * ch, 0)
  for y in 0..<h {
    for x in 0..<w {
      let s = exp1_y[clamp(y - 4, h) * w + x] + ((y * 3 + x) % 20 - 10)
      src2_y[y * w + x] = if s < 0 { 0 } else if s > 255 { 255 } else { s }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      let su = exp1_u[clamp(y - 2, ch) * cw + x] + (y * 3 % 14 - 7)
      let sv = exp1_v[clamp(y - 2, ch) * cw + x] + (y * 5 % 14 - 7)
      src2_u[y * cw + x] = if su < 0 { 0 } else if su > 255 { 255 } else { su }
      src2_v[y * cw + x] = if sv < 0 { 0 } else if sv > 255 { 255 } else { sv }
    }
  }
  // The encoder's reference = frame 1's reconstruction (the entry
  // returned it; the decoder's slot 0 holds the decoded equivalent —
  // validated above).
  let (f2_obu, exp2_y, exp2_u, exp2_v) = match
    @libavcodec.av1_enc_write_me_res420_inter_frame_obu(
      seq,
      refs,
      src2_y,
      w,
      src2_u,
      cw,
      src2_v,
      exp1_y,
      w,
      exp1_u,
      cw,
      exp1_v,
      base_q_idx=80,
      range=8,
    ) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let f2_pkt : Array[Byte] = []
  for part in [td, f2_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      f2_pkt.push(part[i])
    }
  }
  let f2 = match dec.decode_packet(Bytes::from_array(f2_pkt[:])) {
    Ok(Some(f)) => f
    Ok(None) => fail("frame 2 hidden")
    Err(e) => fail("frame 2 decode: \{e}")
  }
  for y in 0..<h {
    for x in 0..<w {
      if f2.y[y * f2.y_stride + x] != exp2_y[y * w + x] {
        fail(
          "F2 Y(\{y},\{x}) = \{f2.y[y * f2.y_stride + x]} want \{exp2_y[y * w + x]}",
        )
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if f2.u[y * f2.uv_stride + x] != exp2_u[y * cw + x] ||
        f2.v[y * f2.uv_stride + x] != exp2_v[y * cw + x] {
        fail("F2 UV(\{y},\{x}) diverged")
      }
    }
  }
  // Quality: frame 2's residual helped over its own prediction (the
  // ME-predicted MC from frame 1's reconstruction at the found shift).
  let mut sad2_res = 0L
  let mut sad2_pred = 0L
  for y in 0..<h {
    for x in 0..<w {
      let sy = clamp(y - 4, h)
      let d1 = exp2_y[y * w + x] - src2_y[y * w + x]
      let d2 = exp1_y[sy * w + x] - src2_y[y * w + x]
      sad2_res += if d1 < 0 { -d1.to_int64() } else { d1.to_int64() }
      sad2_pred += if d2 < 0 { -d2.to_int64() } else { d2.to_int64() }
    }
  }
  if sad2_res >= sad2_pred {
    fail("frame 2 residual did not help: \{sad2_res} >= \{sad2_pred}")
  }
}

///|

///|
test "av1 inter enc: newmv rejects out-of-range shifts" {
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
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, 64, 64, 255)
  match
    @libavcodec.av1_enc_write_translated_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
      mv_y=2000,
      mv_x=0,
    ) {
    Ok(_) => fail("out-of-range mv accepted")
    Err(_) => ()
  }
}

///|
test "av1 inter enc: globalmv rejects non-64 geometry" {
  let seq = match
    @libavcodec.av1_parse_sequence_header(
      match
        @libavcodec.av1_enc_write_sequence_header_obu(
          @libavcodec.Av1SeqEncConfig::default(width=96, height=64),
        ) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, 96, 64, 255)
  match
    @libavcodec.av1_enc_write_globalmv_inter_frame_obu(
      seq,
      refs,
      base_q_idx=200,
    ) {
    Ok(_) => fail("non-64-multiple geometry accepted")
    Err(_) => ()
  }
}

///|
test "av1 inter enc: validation errors" {
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
  let ok_tile : Bytes = b"\x01\x02\x03"
  for
    bad in [
      { ..@libavcodec.Av1InterFrameEncConfig::default(), base_q_idx: 0, },
      { ..@libavcodec.Av1InterFrameEncConfig::default(), base_q_idx: 256, },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        refresh_frame_flags: -1,
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        refresh_frame_flags: 256,
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        ref_frame_idx: [0, 0, 0, 0, 0, 0],
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        ref_frame_idx: [0, 0, 0, 0, 0, 0, 8],
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        ref_frame_idx: [0, 0, 0, 0, 0, 0, -1],
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        loop_filter_level0: 64,
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        tiles: [ok_tile, ok_tile],
        tile_cols: 1,
        tile_rows: 1,
      },
      {
        ..@libavcodec.Av1InterFrameEncConfig::default(),
        tiles: [ok_tile],
        tile_cols: 2,
        tile_rows: 1,
      },
    ] {
    match @libavcodec.av1_enc_write_inter_frame_obu(seq, bad) {
      Ok(_) => fail("bad inter config accepted")
      Err(_) => ()
    }
  }
  // The still-picture (reduced) sequence is intra-only: reject outright.
  let sp_seq = match
    @libavcodec.av1_parse_sequence_header(
      match
        @libavcodec.av1_enc_write_sequence_header_obu({
          ..@libavcodec.Av1SeqEncConfig::default(width=64, height=64),
          still_picture: true,
        }) {
        Ok(b) => b
        Err(e) => fail(e)
      },
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  match
    @libavcodec.av1_enc_write_inter_frame_obu(
      sp_seq,
      @libavcodec.Av1InterFrameEncConfig::default(),
    ) {
    Ok(_) => fail("still-picture inter frame accepted")
    Err(_) => ()
  }
}

///|
/// §454 quarter-pel refinement: when the source IS the kernel's
/// prediction at a quarter phase, the SAD at the true phase is 0 and
/// nothing can beat it — the two-stage walk must land exactly there
/// (axial, diagonal, and half+quarter composition), and flat content
/// must stay at the integer MV.
test "av1 inter enc: subpel ME finds quarter phases exactly" {
  let w = 64
  let h = 64
  // A smooth structured reference (gradients + bounded overlay).
  let refimg : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = 96 + (y * 13 + x * 5) % 64
      let ov = (x * 7 + y * 3) % 20 - 10
      refimg[y * w + x] = base + ov
    }
  }
  fn kernel_src(mv_y8 : Int32, mv_x8 : Int32) -> FixedArray[Int32] {
    let pred = @libavcodec.av1_enc_mc_predict(
      refimg, w, w, h, w, h, 0, 0, 16, 16, mv_y8, mv_x8, 0, 0, 0, 8,
    )
    let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        out[y * w + x] = pred[y * 64 + x]
      }
    }
    out
  }
  let zero : FixedArray[Int32] = FixedArray::make(1, 0)
  for phase in [(2, 0), (0, 2), (2, -2), (-2, 2), (6, 0), (0, -6), (6, 6)] {
    let src = kernel_src(phase.0, phase.1)
    let (ry, rx) = @libavcodec.av1_enc_me_subpel_refine(
      src, w, refimg, w, w, h, zero, zero,
    ).unwrap()
    if ry[0] != phase.0 || rx[0] != phase.1 {
      fail("phase (\{phase.0},\{phase.1}): refine gave (\{ry[0]},\{rx[0]})")
    }
  }
  // Flat content: every candidate ties at SAD 0 — stays integer.
  let flat : FixedArray[Int32] = FixedArray::make(w * h, 128)
  let refflat : FixedArray[Int32] = FixedArray::make(w * h, 128)
  let (fy, fx) = @libavcodec.av1_enc_me_subpel_refine(
    flat, w, refflat, w, w, h, zero, zero,
  ).unwrap()
  if fy[0] != 0 || fx[0] != 0 {
    fail("flat refine moved to (\{fy[0]},\{fx[0]})")
  }
}

///|
/// §455 high-precision mvs: odd 1/8-pel components become codable —
/// the uniform skip frame at an eighth-pel target decodes pixel-exact
/// against the decoder's own MC kernel, and hp=0 still rejects odd
/// targets.
test "av1 inter enc: hp uniform eighth-pel shift matches MC" {
  let w = 64
  let h = 64
  let seq_obu = @libavcodec.av1_enc_write_sequence_header_obu(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  ).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(seq_obu).unwrap()
  let t_res = @libavcodec.av1_enc_write_minimal_residual_tile(base_q_idx=200).unwrap()
  let kf_obu = @libavcodec.av1_enc_write_key_frame_obu(seq, {
    ..@libavcodec.Av1KeyFrameEncConfig::default(),
    base_q_idx: 200,
    tile_data: t_res,
  }).unwrap()
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = dec.decode_packet(Bytes::from_array(key_pkt[:])).unwrap().unwrap()
  // hp = 0 must reject the odd component outright.
  let refs0 = @libavcodec.av1_refmvs_reference_store_new()
  refs0.refresh_without_mvs(0, w, h, 255)
  let rejected = @libavcodec.av1_enc_write_subpel_inter_frame_obu(
    seq,
    refs0,
    base_q_idx=200,
    mv_y8=1,
    mv_x8=0,
  )
  assert_eq(rejected is Err(_), true)
  // hp = 1 codes the eighth-pel phase.
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let it_obu = @libavcodec.av1_enc_write_subpel_inter_frame_obu(
    seq,
    refs,
    base_q_idx=200,
    mv_y8=1,
    mv_x8=0,
    hp=true,
  ).unwrap()
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = dec.decode_packet(Bytes::from_array(it_pkt[:])).unwrap().unwrap()
  let pred = @libavcodec.av1_enc_mc_predict(
    kf.y,
    kf.y_stride,
    kf.width,
    kf.height,
    kf.width,
    kf.height,
    0,
    0,
    16,
    16,
    1,
    0,
    0,
    0,
    0,
    8,
  )
  for y in 0..<h {
    for x in 0..<w {
      if it.y[y * it.y_stride + x] != pred[y * w + x] {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want MC \{pred[y * w + x]}",
        )
      }
    }
  }
}

///|
/// §455: the hp stage-3 refinement finds eighth phases exactly (src =
/// the kernel's prediction at the true phase → SAD 0), and the hp=0
/// refine can only return even components.
test "av1 inter enc: hp refine finds eighth phases exactly" {
  let w = 64
  let h = 64
  let refimg : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = 96 + (y * 13 + x * 5) % 64
      let ov = (x * 7 + y * 3) % 20 - 10
      refimg[y * w + x] = base + ov
    }
  }
  fn kernel_src(mv_y8 : Int32, mv_x8 : Int32) -> FixedArray[Int32] {
    let pred = @libavcodec.av1_enc_mc_predict(
      refimg, w, w, h, w, h, 0, 0, 16, 16, mv_y8, mv_x8, 0, 0, 0, 8,
    )
    let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        out[y * w + x] = pred[y * 64 + x]
      }
    }
    out
  }
  let zero : FixedArray[Int32] = FixedArray::make(1, 0)
  // Odd axial/diagonal, odd+quarter, and odd+half compositions.
  for phase in [(1, 0), (0, 1), (1, -1), (5, 0), (1, 4)] {
    let src = kernel_src(phase.0, phase.1)
    let (ry, rx) = @libavcodec.av1_enc_me_subpel_refine(
      src,
      w,
      refimg,
      w,
      w,
      h,
      zero,
      zero,
      hp=true,
    ).unwrap()
    if ry[0] != phase.0 || rx[0] != phase.1 {
      fail("phase (\{phase.0},\{phase.1}): hp refine gave (\{ry[0]},\{rx[0]})")
    }
    // Without hp the same source refines to an even neighbor.
    let (ey, ex) = @libavcodec.av1_enc_me_subpel_refine(
      src, w, refimg, w, w, h, zero, zero,
    ).unwrap()
    if ey[0] % 2 != 0 || ex[0] % 2 != 0 {
      fail("hp-off refine returned odd (\{ey[0]},\{ex[0]})")
    }
  }
}

///|
/// §455: me8 with hp — the eighth-pel phase flows from the refine
/// through the tile's hp mv bits to a pixel-exact decode (zero dc
/// tokens, so the reconstruction IS the MC prediction).
test "av1 inter enc: hp me8 frame reproduces kernel eighth-pel shift" {
  let w = 64
  let h = 64
  let seq_obu = @libavcodec.av1_enc_write_sequence_header_obu(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  ).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(seq_obu).unwrap()
  // A structured key (the §443 AC tile): flat content would tie every
  // phase, making the eighth-pel shift unrecoverable.
  let toks_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs_spec : FixedArray[Int32] = FixedArray::make(1024, 0)
  toks_spec[0] = 1
  toks_spec[1] = 1
  toks_spec[2] = 2
  toks_spec[3] = 1
  toks_spec[7] = 1
  let t_ac = @libavcodec.av1_enc_write_ac_token_tile(
    toks_spec,
    signs_spec,
    base_q_idx=200,
  ).unwrap()
  let kf_obu = @libavcodec.av1_enc_write_key_frame_obu(seq, {
    ..@libavcodec.Av1KeyFrameEncConfig::default(),
    base_q_idx: 200,
    tile_data: t_ac,
  }).unwrap()
  let td = @libavcodec.av1_enc_write_temporal_delimiter()
  let key_pkt : Array[Byte] = []
  for part in [td, seq_obu, kf_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      key_pkt.push(part[i])
    }
  }
  let dec = @libavcodec.Av1Decoder::new()
  let kf = dec.decode_packet(Bytes::from_array(key_pkt[:])).unwrap().unwrap()
  // Source: the kernel's prediction of the key at (1, 0) — an exact
  // eighth-pel phase.
  let pred = @libavcodec.av1_enc_mc_predict(
    kf.y,
    kf.y_stride,
    kf.width,
    kf.height,
    kf.width,
    kf.height,
    0,
    0,
    16,
    16,
    1,
    0,
    0,
    0,
    0,
    8,
  )
  let src : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      src[y * w + x] = pred[y * 64 + x]
    }
  }
  let zero_mv : FixedArray[Int32] = FixedArray::make(1, 0)
  let (ry, rx) = @libavcodec.av1_enc_me_subpel_refine(
    src,
    w,
    kf.y,
    kf.y_stride,
    w,
    h,
    zero_mv,
    zero_mv,
    hp=true,
  ).unwrap()
  if ry[0] != 1 || rx[0] != 0 {
    fail("refine gave (\{ry[0]},\{rx[0]}) want (1, 0)")
  }
  let refs = @libavcodec.av1_refmvs_reference_store_new()
  refs.refresh_without_mvs(0, w, h, 255)
  let it_obu = @libavcodec.av1_enc_write_me8_dc_inter_frame_obu(
    seq,
    refs,
    base_q_idx=200,
    mvs_y8=ry,
    mvs_x8=rx,
    dc_toks=FixedArray::make(1, 0),
    dc_signs=FixedArray::make(1, 0),
    hp=true,
  ).unwrap()
  let it_pkt : Array[Byte] = []
  for part in [td, it_obu] {
    for i = 0; i < part.length(); i = i + 1 {
      it_pkt.push(part[i])
    }
  }
  let it = dec.decode_packet(Bytes::from_array(it_pkt[:])).unwrap().unwrap()
  for y in 0..<h {
    for x in 0..<w {
      if it.y[y * it.y_stride + x] != src[y * w + x] {
        fail(
          "Y(\{y},\{x}) = \{it.y[y * it.y_stride + x]} want \{src[y * w + x]}",
        )
      }
    }
  }
}
