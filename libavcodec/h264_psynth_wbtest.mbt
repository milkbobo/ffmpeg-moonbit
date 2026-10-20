///|
/// End-to-end CABAC P-slice test with fully synthetic streams: a
/// hand-written SPS, one CAVLC PPS and one CABAC PPS, an `I_PCM` IDR frame
/// (trivially encodable, exact pixels — and the first vector coverage of the
/// `I_PCM` path) and a CABAC P frame (P_L0_16x16, zero residual, integer MV
/// (-8,-8)) encoded with a mirror of the reference CABAC encoder from
/// `cabac_wbtest.mbt`. The decoded P frame must equal the reference
/// translated by the motion vector (with the border replication of
/// `ff_emulated_edge_mc`), pinning down the whole chain: skip/type/mvd
/// contexts, MV prediction, motion compensation and the DPB entry point.

///|
/// Exp-Golomb ue(v) writer. */
fn psyn_put_ue(bw : BitWriter, v : Int32) -> Unit {
  let v1 = v + 1
  let mut nbits = 0
  let mut t = v1
  while t > 1 {
    nbits = nbits + 1
    t = t / 2
  }
  for _i = 0; _i < nbits; _i = _i + 1 {
    bw.put_bit(0)
  }
  bw.put(v1.reinterpret_as_uint(), nbits + 1)
}

///|
/// Exp-Golomb se(v) writer. */
fn psyn_put_se(bw : BitWriter, v : Int32) -> Unit {
  if v > 0 {
    psyn_put_ue(bw, 2 * v - 1)
  } else {
    psyn_put_ue(bw, -2 * v)
  }
}

///|
/// u(n) writer. */
fn psyn_put_u(bw : BitWriter, n : Int32, v : Int32) -> Unit {
  bw.put(v.reinterpret_as_uint(), n)
}

///|
/// The exact `I_PCM` pixel pattern: non-flat along both axes so that a
/// wrong motion vector cannot produce a passing pixel comparison. */
fn psyn_luma(x : Int32, y : Int32) -> Int32 {
  (3 * x + 5 * y + 17) & 0xFF
}

///|
fn psyn_cb(x : Int32, y : Int32) -> Int32 {
  (2 * x + 3 * y + 70) & 0xFF
}

///|
fn psyn_cr(x : Int32, y : Int32) -> Int32 {
  (4 * x + y + 130) & 0xFF
}

///|
/// Reference CABAC encoder (mirror of `cabac_wbtest.mbt`). */
struct PsynEnc {
  mut low : Int32
  mut range : Int32
  mut outstanding : Int32
  bits : Array[Int32]
}

///|
fn psyn_enc_new() -> PsynEnc {
  { low: 0, range: 0x1FE, outstanding: 0, bits: [], }
}

///|
fn psyn_put_bit(c : PsynEnc, b : Int32) -> Unit {
  c.bits.push(b)
  while c.outstanding > 0 {
    c.bits.push(1 - b)
    c.outstanding = c.outstanding - 1
  }
}

///|
fn psyn_renorm(c : PsynEnc) -> Unit {
  while c.range < 0x100 {
    if c.low < 0x100 {
      psyn_put_bit(c, 0)
    } else if c.low < 0x200 {
      c.outstanding = c.outstanding + 1
      c.low = c.low - 0x100
    } else {
      psyn_put_bit(c, 1)
      c.low = c.low - 0x200
    }
    c.range = c.range + c.range
    c.low = c.low + c.low
  }
}

///|
fn psyn_put_cabac(
  c : PsynEnc,
  state : Array[Int32],
  ctx : Int32,
  bit : Int32,
) -> Unit {
  let s = [state[ctx]]
  let range_lps = h264_cabac_lps_range(c.range, s[0])
  if bit == (s[0] & 1) {
    c.range = c.range - range_lps
    s[0] = h264_cabac_mlps_state(s[0])
  } else {
    c.low = c.low + (c.range - range_lps)
    c.range = range_lps
    s[0] = h264_cabac_tables[h264_cabac_mlps_state_offset + 127 - s[0]]
  }
  state[ctx] = s[0]
  psyn_renorm(c)
}

///|
fn psyn_put_bypass(c : PsynEnc, bit : Int32) -> Unit {
  c.low = c.low + c.low
  if bit != 0 {
    c.low = c.low + c.range
  }
  if c.low < 0x200 {
    psyn_put_bit(c, 0)
  } else if c.low < 0x400 {
    c.outstanding = c.outstanding + 1
    c.low = c.low - 0x200
  } else {
    psyn_put_bit(c, 1)
    c.low = c.low - 0x400
  }
}

///|
fn psyn_terminate(c : PsynEnc, bit : Int32) -> Unit {
  c.range = c.range - 2
  if bit == 0 {
    psyn_renorm(c)
  } else {
    c.low = c.low + c.range
    c.range = 2
    psyn_renorm(c)
    psyn_put_bit(c, c.low >> 9)
    // put_bits(2, ((low >> 7) & 3) | 1)
    let v = ((c.low >> 7) & 3) | 1
    c.bits.push((v >> 1) & 1)
    c.bits.push(v & 1)
  }
}

///|
/// Pack encoder bits like `CabacTestBits::to_bytes` (first bit dropped:
/// the arithmetic encoder's redundant leading zero, see the note there). */
fn psyn_to_bytes(c : PsynEnc) -> Array[Byte] {
  let n = (c.bits.length() - 1 + 7) / 8
  let out : Array[Byte] = Array::make(n + 8, b'\x00')
  for i = 1; i < c.bits.length(); i = i + 1 {
    let j = i - 1
    if c.bits[i] != 0 {
      out[j / 8] = (out[j / 8].to_int() | (1 << (7 - j % 8))).to_byte()
    }
  }
  out
}

///|
/// Assemble an Annex B stream with emulation prevention. */
fn psyn_stream(nals : Array[(Int32, Int32, Array[Byte])]) -> Bytes {
  let out : Array[Byte] = []
  for nal in nals {
    for _k = 0; _k < 4; _k = _k + 1 {
      out.push(if _k == 3 { b'\x01' } else { b'\x00' })
    }
    out.push(((nal.1 << 5) | nal.0).to_byte())
    let mut zeros = 0
    for b in nal.2 {
      if zeros == 2 && (b.to_int() & 0xFF) <= 3 {
        out.push(b'\x03')
        zeros = 0
      }
      out.push(b)
      if b.to_int() == 0 {
        zeros = zeros + 1
      } else {
        zeros = 0
      }
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Byte-align a writer with the rbsp_stop_one_bit. */
fn psyn_align(bw : BitWriter) -> Array[Byte] {
  bw.put_bit(1)
  bw.finish().to_array()
}

///|
/// One PPS with `pps_id` 0 (CAVLC) or 1 (CABAC); everything else shared. */
fn psyn_pps(cabac : Bool) -> Array[Byte] {
  let pps = BitWriter::new()
  psyn_put_ue(pps, if cabac { 1 } else { 0 }) // pps_id
  psyn_put_ue(pps, 0) // sps_id
  pps.put_bit(if cabac { 1 } else { 0 }) // entropy_coding_mode
  pps.put_bit(0) // bottom_field_pic_order_in_frame_present
  psyn_put_ue(pps, 0) // num_slice_groups_minus1
  psyn_put_ue(pps, 0) // num_ref_idx_l0_default_active_minus1
  psyn_put_ue(pps, 0) // num_ref_idx_l1_default_active_minus1
  pps.put_bit(0) // weighted_pred
  psyn_put_u(pps, 2, 0) // weighted_bipred_idc
  psyn_put_se(pps, 0) // pic_init_qp_minus26
  psyn_put_se(pps, 0) // pic_init_qs_minus26
  psyn_put_se(pps, 0) // chroma_qp_index_offset
  pps.put_bit(1) // deblocking_filter_parameters_present
  pps.put_bit(0) // constrained_intra_pred
  pps.put_bit(0) // redundant_pic_cnt_present
  psyn_align(pps)
}

///|
test "h264: synthetic CABAC P frame decodes to the translated I_PCM reference" {
  let mb_w = 4
  let mb_h = 3
  // --- SPS
  let sps = BitWriter::new()
  psyn_put_u(sps, 8, 66) // profile_idc baseline
  psyn_put_u(sps, 8, 0) // constraint flags + reserved
  psyn_put_u(sps, 8, 40) // level
  psyn_put_ue(sps, 0) // sps_id
  psyn_put_ue(sps, 0) // log2_max_frame_num_minus4 -> 4
  psyn_put_ue(sps, 0) // poc_type 0
  psyn_put_ue(sps, 0) // log2_max_poc_lsb_minus4 -> 4
  psyn_put_ue(sps, 1) // max_num_ref_frames
  sps.put_bit(0) // gaps_in_frame_num
  psyn_put_ue(sps, mb_w - 1)
  psyn_put_ue(sps, mb_h - 1)
  sps.put_bit(1) // frame_mbs_only
  sps.put_bit(1) // direct_8x8_inference
  sps.put_bit(0) // frame_cropping
  sps.put_bit(0) // vui_parameters_present
  let sps_rbsp = psyn_align(sps)
  // --- IDR slice: CAVLC (PPS 0), every macroblock I_PCM carrying the
  // exact pattern above.
  let idr = BitWriter::new()
  psyn_put_ue(idr, 0) // first_mb_in_slice
  psyn_put_ue(idr, 7) // slice_type I
  psyn_put_ue(idr, 0) // pps_id (CAVLC)
  psyn_put_u(idr, 4, 0) // frame_num
  psyn_put_ue(idr, 0) // idr_pic_id
  psyn_put_u(idr, 4, 0) // pic_order_cnt_lsb
  idr.put_bit(0) // no_output_of_prior_pics
  idr.put_bit(0) // long_term_reference_flag
  psyn_put_se(idr, 0) // slice_qp_delta
  psyn_put_ue(idr, 1) // disable_deblocking_filter_idc = 1
  for mb = 0; mb < mb_w * mb_h; mb = mb + 1 {
    let mx = mb % mb_w
    let my = mb / mb_w
    psyn_put_ue(idr, 25) // I_PCM
    while idr.nbits != 0 {
      idr.put_bit(0) // pcm_alignment_zero_bit
    }
    for row = 0; row < 16; row = row + 1 {
      for col = 0; col < 16; col = col + 1 {
        psyn_put_u(idr, 8, psyn_luma(mx * 16 + col, my * 16 + row))
      }
    }
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        psyn_put_u(idr, 8, psyn_cb(mx * 8 + col, my * 8 + row))
      }
    }
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        psyn_put_u(idr, 8, psyn_cr(mx * 8 + col, my * 8 + row))
      }
    }
  }
  // rbsp_slice_trailing_bits: the stop bit lets `get_bit_length` strip
  // exactly the trailing zeros, keeping `size_bits` at the end of the PCM
  // data instead of eating the last sample's final bit.
  let idr_rbsp = psyn_align(idr)
  // --- CABAC P slice (PPS 1): every macroblock P_L0_16x16, cbp 0,
  // MV (-8, -8) quarter-pel (= (-2, -2) luma pixels). MB 0 codes
  // mvd (-8, -8) against a (0, 0) prediction; the rest predict (−8, −8)
  // from their neighbours and code mvd 0.
  let hdr = BitWriter::new()
  psyn_put_ue(hdr, 0) // first_mb_in_slice
  psyn_put_ue(hdr, 5) // slice_type P
  psyn_put_ue(hdr, 1) // pps_id (CABAC)
  psyn_put_u(hdr, 4, 1) // frame_num
  psyn_put_u(hdr, 4, 2) // pic_order_cnt_lsb
  hdr.put_bit(0) // num_ref_idx_active_override
  hdr.put_bit(0) // ref_pic_list_modification_flag
  hdr.put_bit(0) // adaptive_ref_pic_marking (nal_ref_idc != 0)
  psyn_put_ue(hdr, 0) // cabac_init_idc
  psyn_put_se(hdr, 0) // slice_qp_delta
  psyn_put_ue(hdr, 1) // disable_deblocking_filter_idc = 1
  while hdr.nbits != 0 {
    hdr.put_bit(1) // cabac_alignment_one_bit
  }
  let hdr_rbsp = hdr.finish().to_array()
  // CABAC MB layer, mirroring `ff_h264_decode_mb_cabac`'s P path. Every
  // context derivation below is the encoder-side twin of the decoder's.
  let enc = psyn_enc_new()
  let states = ff_h264_init_cabac_states(26, 8, 0, 0)
  // |mvd| per macroblock (the `mvd_cache`), for the amvd contexts.
  let mvd_abs : Array[(Int32, Int32)] = Array::make(mb_w * mb_h, (0, 0))
  // cbp of coded macroblocks (all zero here); unavailable neighbours of an
  // inter macroblock count as 0x00F (`fill_decode_caches`).
  for mb = 0; mb < mb_w * mb_h; mb = mb + 1 {
    let mx = mb % mb_w
    let my = mb / mb_w
    // mb_skip_flag: ctx 11 + (left coded non-skip) + 2*(top coded non-skip);
    // every previous macroblock is a coded non-skip P_L0_16x16.
    let mut c = 0
    if mx > 0 {
      c = c + 1
    }
    if my > 0 {
      c = c + 2
    }
    psyn_put_cabac(enc, states, 11 + c, 0)
    // mb_type: 14 -> 0 (P), 15 -> 0, 16 -> 0 => P_L0_16x16
    psyn_put_cabac(enc, states, 14, 0)
    psyn_put_cabac(enc, states, 15, 0)
    psyn_put_cabac(enc, states, 16, 0)
    // mvd for the 16x16 partition at block (0, 0); ref_count == 1 so no
    // ref_idx syntax. amvd: left (block (3, 0)) + top (block (0, 3)) |mvd|,
    // unavailable neighbours contributing 0.
    let lamvd = if mx > 0 { mvd_abs[mb - 1] } else { (0, 0) }
    let tamvd = if my > 0 { mvd_abs[mb - mb_w] } else { (0, 0) }
    let mvd = if mb == 0 { (-8, -8) } else { (0, 0) }
    for pair = 0; pair < 2; pair = pair + 1 {
      let base = if pair == 0 { 40 } else { 47 }
      let amvd = if pair == 0 { lamvd.0 + tamvd.0 } else { lamvd.1 + tamvd.1 }
      let mut ctxi = 0
      if amvd > 2 {
        ctxi = ctxi + 1
      }
      if amvd > 32 {
        ctxi = ctxi + 1
      }
      let comp = if pair == 0 { mvd.0 } else { mvd.1 }
      let mag = if comp < 0 { -comp } else { comp }
      if mag == 0 {
        psyn_put_cabac(enc, states, base + ctxi + 2, 0)
      } else {
        psyn_put_cabac(enc, states, base + ctxi + 2, 1)
        let mut ctxbase = base + 3
        let mut v = 1
        while v < 9 && v < mag {
          psyn_put_cabac(enc, states, ctxbase, 1)
          if v < 4 {
            ctxbase = ctxbase + 1
          }
          v = v + 1
        }
        if v < 9 {
          psyn_put_cabac(enc, states, ctxbase, 0)
        } else {
          // escape path (not exercised by this stream)
          psyn_put_cabac(enc, states, ctxbase, 1)
          let mut k = 3
          let mut rest = mag - 9
          while 1 << k <= rest {
            psyn_put_bypass(enc, 1)
            rest = rest - (1 << k)
            k = k + 1
          }
          psyn_put_bypass(enc, 0)
          while k > 0 {
            k = k - 1
            psyn_put_bypass(enc, (rest >> k) & 1)
          }
        }
        // Sign: a 1 bypass bin selects the negative value
        // (`get_cabac_bypass_sign(cabac, -mvd)`).
        psyn_put_bypass(enc, if comp < 0 { 1 } else { 0 })
      }
    }
    if mb == 0 {
      mvd_abs[mb] = (8, 8)
    }
    // cbp: luma 0 then chroma 0, with `decode_cabac_mb_cbp_luma`'s
    // per-bit neighbourhood contexts (all zero cbp keeps bits 1..3 at
    // ctx 76 once the neighbours are accounted for).
    let cbp_a = if mx > 0 { 0 } else { 0x00F }
    let cbp_b = if my > 0 { 0 } else { 0x00F }
    let mut cbit = 0
    if (cbp_a & 2) == 0 {
      cbit = cbit + 1
    }
    if (cbp_b & 4) == 0 {
      cbit = cbit + 2
    }
    psyn_put_cabac(enc, states, 73 + cbit, 0)
    // bit 1: (cbp & 1) == 0 always here (+1) plus the right 8x8 of the top
    // neighbour.
    cbit = if (cbp_b & 8) == 0 { 3 } else { 1 }
    psyn_put_cabac(enc, states, 73 + cbit, 0)
    // bit 2: the bottom-left 8x8 of the left neighbour and (cbp & 1) == 0.
    cbit = if (cbp_a & 8) == 0 { 3 } else { 2 }
    psyn_put_cabac(enc, states, 73 + cbit, 0)
    psyn_put_cabac(enc, states, 76, 0)
    // chroma: all coded neighbours have chroma cbp 0 and 0x00F has no
    // chroma bits, so ctx 77 with a 0 bin.
    psyn_put_cabac(enc, states, 77, 0)
    psyn_terminate(enc, if mb == mb_w * mb_h - 1 { 1 } else { 0 })
  }
  let p_rbsp = psyn_to_bytes(enc)
  // --- assemble and decode
  let p_nal : Array[Byte] = []
  for b in hdr_rbsp {
    p_nal.push(b)
  }
  for b in p_rbsp {
    p_nal.push(b)
  }
  let data = psyn_stream([
    (7, 3, sps_rbsp),
    (8, 3, psyn_pps(false)),
    (8, 3, psyn_pps(true)),
    (5, 3, idr_rbsp),
    (1, 3, p_nal),
  ])
  let frames = match h264_decode_annexb_frames(data, false) {
    Ok(fs) => fs
    Err(e) => fail("decode failed: \{e}")
  }
  assert_eq(frames.length(), 2)
  let idrf = frames[0]
  let pf = frames[1]
  assert_eq(idrf.width, 64)
  assert_eq(idrf.height, 48)
  // The I_PCM reference is reconstructed exactly.
  for y = 0; y < 48; y = y + 1 {
    for x = 0; x < 64; x = x + 1 {
      assert_eq(idrf.y[y * idrf.ystride + x], psyn_luma(x, y))
    }
  }
  for y = 0; y < 24; y = y + 1 {
    for x = 0; x < 32; x = x + 1 {
      assert_eq(idrf.u[y * idrf.cstride + x], psyn_cb(x, y))
      assert_eq(idrf.v[y * idrf.cstride + x], psyn_cr(x, y))
    }
  }
  // The P frame is the reference translated by the integer MV (-8, -8)
  // quarter-pel = (-2, -2) luma pixels, with `ff_emulated_edge_mc`'s border
  // replication at the left/top frame edges.
  for y = 0; y < 48; y = y + 1 {
    for x = 0; x < 64; x = x + 1 {
      let sx = if x < 2 { 0 } else { x - 2 }
      let sy = if y < 2 { 0 } else { y - 2 }
      assert_eq(pf.y[y * pf.ystride + x], psyn_luma(sx, sy))
    }
  }
  // Chroma: (-8, -8) quarter-pel is a full (-1, -1) chroma displacement.
  for y = 0; y < 24; y = y + 1 {
    for x = 0; x < 32; x = x + 1 {
      let sx = if x < 1 { 0 } else { x - 1 }
      let sy = if y < 1 { 0 } else { y - 1 }
      assert_eq(pf.u[y * pf.cstride + x], psyn_cb(sx, sy))
      assert_eq(pf.v[y * pf.cstride + x], psyn_cr(sx, sy))
    }
  }
}
