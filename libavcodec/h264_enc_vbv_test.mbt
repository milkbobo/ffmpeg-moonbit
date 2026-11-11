// Blackbox tests for the CPB-constrained (VBV/CBR) rate control (§391):
// opt-in byte compatibility, SPS VUI/HRD and buffering-period/picture-timing
// SEI syntax, NAL/AU layout, the leaky-bucket invariant with filler-data
// NALs, per-picture QP adaptation, the reconstruction invariant through both
// entropy coders, and docker ffmpeg arbitration.

// ---------------------------------------------------------------------------
// Annex B / RBSP helpers (the encoder always emits 4-byte start codes)
// ---------------------------------------------------------------------------

///|
/// Split an Annex B stream into `(nal_unit_type, start, end)` records; the
/// offsets cover the whole NAL including its 4-byte start code.
fn vbv_nals(stream : Bytes) -> Array[(Int32, Int32, Int32)] {
  let n = stream.length()
  let starts : Array[Int32] = []
  let mut i = 0
  while i + 3 < n {
    if stream[i].to_int() == 0 &&
      stream[i + 1].to_int() == 0 &&
      stream[i + 2].to_int() == 0 &&
      stream[i + 3].to_int() == 1 {
      starts.push(i)
      i = i + 4
    } else {
      i = i + 1
    }
  }
  let out : Array[(Int32, Int32, Int32)] = []
  for k, s in starts {
    let e = if k + 1 < starts.length() { starts[k + 1] } else { n }
    out.push((stream[s + 4].to_int() & 0x1F, s, e))
  }
  out
}

///|
/// Undo emulation prevention (`00 00 03 -> 00 00`).
fn vbv_unescape(raw : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut zeros = 0
  for i = 0; i < raw.length(); i = i + 1 {
    let b = raw[i].to_int() & 0xFF
    if zeros >= 2 && b == 3 {
      zeros = 0
    } else {
      out.push(raw[i])
      zeros = if b == 0 { zeros + 1 } else { 0 }
    }
  }
  Bytes::from_array(out[:])
}

///|
/// One NAL's RBSP payload (no start code, no NAL header), unescaped.
fn vbv_nal_payload(stream : Bytes, nal : (Int32, Int32, Int32)) -> Bytes {
  let (_, s, e) = nal
  let out : Array[Byte] = []
  for i = s + 5; i < e; i = i + 1 {
    out.push(stream[i])
  }
  vbv_unescape(Bytes::from_array(out[:]))
}

///|
/// `(payload_type, unescaped_payload)` of a type-6 SEI NAL (one message per
/// NAL in this encoder). The whole RBSP is unescaped first because
/// emulation-prevention bytes make raw payload offsets unusable.
fn vbv_sei_message(
  stream : Bytes,
  nal : (Int32, Int32, Int32),
) -> (Int32, Bytes) {
  let (_, s, e) = nal
  let raw : Array[Byte] = []
  for i = s + 5; i < e; i = i + 1 {
    raw.push(stream[i])
  }
  let rbsp = vbv_unescape(Bytes::from_array(raw[:]))
  let payload_type = rbsp[0].to_int() & 0xFF
  let size = rbsp[1].to_int() & 0xFF
  let out : Array[Byte] = []
  for i = 2; i < 2 + size && i < rbsp.length(); i = i + 1 {
    out.push(rbsp[i])
  }
  (payload_type, Bytes::from_array(out[:]))
}

// ---------------------------------------------------------------------------
// RBSP bit reader and SPS VUI/HRD parser
// ---------------------------------------------------------------------------

///|
struct VbvBits {
  data : Bytes
  mut pos : Int32
}

///|
fn VbvBits::new(data : Bytes) -> VbvBits {
  { data, pos: 0, }
}

///|
fn VbvBits::bit(self : VbvBits) -> Int32 raise {
  if self.pos >= self.data.length() * 8 {
    fail(
      "vbv: RBSP overread at bit \{self.pos} of \{self.data.length() * 8} (len \{self.data.length()})",
    )
  }
  let b = self.data[self.pos / 8].to_int() & 0xFF
  let v = (b >> (7 - self.pos % 8)) & 1
  self.pos = self.pos + 1
  v
}

///|
fn VbvBits::u(self : VbvBits, n : Int32) -> Int32 raise {
  let mut v = 0
  for _i = 0; _i < n; _i = _i + 1 {
    v = (v << 1) | self.bit()
  }
  v
}

///|
fn VbvBits::ue(self : VbvBits) -> Int32 raise {
  let mut zeros = 0
  while self.bit() == 0 {
    zeros = zeros + 1
    if zeros > 31 {
      fail("vbv: malformed Exp-Golomb code")
    }
  }
  if zeros == 0 {
    return 0
  }
  (1 << zeros) - 1 + self.u(zeros)
}

///|
struct VbvSpsInfo {
  profile_idc : Int32
  level_idc : Int32
  num_units_in_tick : Int32
  time_scale : Int32
  fixed_frame_rate : Bool
  nal_hrd : Bool
  cpb_cnt_minus1 : Int32
  bit_rate_scale : Int32
  cpb_size_scale : Int32
  bit_rate_value_minus1 : Int32
  cpb_size_value_minus1 : Int32
  cbr_flag : Bool
  initial_cpb_removal_delay_length : Int32
  cpb_removal_delay_length : Int32
  dpb_output_delay_length : Int32
  time_offset_length : Int32
  vcl_hrd : Bool
  low_delay : Bool
  bitstream_restriction : Bool
  max_num_reorder_frames : Int32
  max_dec_frame_buffering : Int32
}

///|
/// Parse the SPS up to and including the VUI's HRD and bitstream
/// restriction. Enough of the spec's SPS syntax to reach the VUI in the
/// streams this encoder emits (4:2:0, frame_mbs_only, no scaling lists).
fn vbv_parse_sps(rbsp : Bytes) -> VbvSpsInfo raise {
  let b = VbvBits::new(rbsp)
  let profile_idc = b.u(8)
  ignore(b.u(8)) // constraint_set flags + reserved bits
  let level_idc = b.u(8)
  ignore(b.ue()) // seq_parameter_set_id
  let high = profile_idc == 100 ||
    profile_idc == 110 ||
    profile_idc == 122 ||
    profile_idc == 244 ||
    profile_idc == 44 ||
    profile_idc == 83 ||
    profile_idc == 86 ||
    profile_idc == 118 ||
    profile_idc == 128 ||
    profile_idc == 138 ||
    profile_idc == 139 ||
    profile_idc == 134 ||
    profile_idc == 135
  if high {
    let chroma_format_idc = b.ue()
    if chroma_format_idc == 3 {
      ignore(b.bit()) // separate_colour_plane_flag
    }
    ignore(b.ue()) // bit_depth_luma_minus8
    ignore(b.ue()) // bit_depth_chroma_minus8
    ignore(b.bit()) // qpprime_y_zero_transform_bypass_flag
    if b.bit() == 1 {
      fail("vbv: scaling matrices not expected")
    }
  }
  ignore(b.ue()) // log2_max_frame_num_minus4
  let poc_type = b.ue()
  if poc_type == 0 {
    ignore(b.ue()) // log2_max_pic_order_cnt_lsb_minus4
  } else if poc_type == 1 {
    ignore(b.bit()) // delta_pic_order_always_zero_flag
    ignore(b.ue()) // offset_for_non_ref_pic (se, same code length)
    ignore(b.ue()) // offset_for_top_to_bottom_field
    let cycle = b.ue()
    for _i = 0; _i < cycle; _i = _i + 1 {
      ignore(b.ue())
    }
  }
  ignore(b.ue()) // max_num_ref_frames
  ignore(b.bit()) // gaps_in_frame_num_value_allowed_flag
  ignore(b.ue()) // pic_width_in_mbs_minus1
  ignore(b.ue()) // pic_height_in_map_units_minus1
  let frame_mbs_only = b.bit()
  if frame_mbs_only == 0 {
    ignore(b.bit()) // mb_adaptive_frame_field_flag
  }
  ignore(b.bit()) // direct_8x8_inference_flag
  if b.bit() == 1 {
    ignore(b.ue()) // frame_crop_left_offset
    ignore(b.ue()) // frame_crop_right_offset
    ignore(b.ue()) // frame_crop_top_offset
    ignore(b.ue()) // frame_crop_bottom_offset
  }
  if b.bit() == 0 {
    fail("vbv: SPS has no VUI")
  }
  ignore(b.bit()) // aspect_ratio_info_present_flag
  ignore(b.bit()) // overscan_info_present_flag
  ignore(b.bit()) // video_signal_type_present_flag
  ignore(b.bit()) // chroma_loc_info_present_flag
  let mut num_units_in_tick = 0
  let mut time_scale = 0
  let mut fixed_frame_rate = false
  if b.bit() == 1 {
    num_units_in_tick = b.u(32)
    time_scale = b.u(32)
    fixed_frame_rate = b.bit() == 1
  }
  let nal_hrd = b.bit() == 1
  let mut cpb_cnt_minus1 = -1
  let mut bit_rate_scale = -1
  let mut cpb_size_scale = -1
  let mut bit_rate_value_minus1 = -1
  let mut cpb_size_value_minus1 = -1
  let mut cbr_flag = false
  let mut initial_cpb_removal_delay_length = 0
  let mut cpb_removal_delay_length = 0
  let mut dpb_output_delay_length = 0
  let mut time_offset_length = 0
  if nal_hrd {
    cpb_cnt_minus1 = b.ue()
    bit_rate_scale = b.u(4)
    cpb_size_scale = b.u(4)
    for i = 0; i <= cpb_cnt_minus1; i = i + 1 {
      let br = b.ue()
      let cs = b.ue()
      let cbr = b.bit() == 1
      if i == 0 {
        bit_rate_value_minus1 = br
        cpb_size_value_minus1 = cs
        cbr_flag = cbr
      }
    }
    initial_cpb_removal_delay_length = b.u(5) + 1
    cpb_removal_delay_length = b.u(5) + 1
    dpb_output_delay_length = b.u(5) + 1
    time_offset_length = b.u(5)
  }
  let vcl_hrd = b.bit() == 1
  if vcl_hrd {
    fail("vbv: VCL HRD not expected")
  }
  let mut low_delay = false
  if nal_hrd || vcl_hrd {
    low_delay = b.bit() == 1
  }
  ignore(b.bit()) // pic_struct_present_flag
  let bitstream_restriction = b.bit() == 1
  let mut max_num_reorder_frames = -1
  let mut max_dec_frame_buffering = -1
  if bitstream_restriction {
    ignore(b.bit()) // motion_vectors_over_pic_boundaries_flag
    ignore(b.ue()) // max_bytes_per_pic_denom
    ignore(b.ue()) // max_bits_per_mb_denom
    ignore(b.ue()) // log2_max_mv_length_horizontal
    ignore(b.ue()) // log2_max_mv_length_vertical
    max_num_reorder_frames = b.ue()
    max_dec_frame_buffering = b.ue()
  }
  {
    profile_idc,
    level_idc,
    num_units_in_tick,
    time_scale,
    fixed_frame_rate,
    nal_hrd,
    cpb_cnt_minus1,
    bit_rate_scale,
    cpb_size_scale,
    bit_rate_value_minus1,
    cpb_size_value_minus1,
    cbr_flag,
    initial_cpb_removal_delay_length,
    cpb_removal_delay_length,
    dpb_output_delay_length,
    time_offset_length,
    vcl_hrd,
    low_delay,
    bitstream_restriction,
    max_num_reorder_frames,
    max_dec_frame_buffering,
  }
}

///|
fn vbv_sps_info(
  stream : Bytes,
  nals : Array[(Int32, Int32, Int32)],
) -> VbvSpsInfo raise {
  for nal in nals {
    if nal.0 == 7 {
      return vbv_parse_sps(vbv_nal_payload(stream, nal))
    }
  }
  fail("vbv: no SPS NAL")
}

// ---------------------------------------------------------------------------
// Access-unit grouping and the CPB leaky-bucket check
// ---------------------------------------------------------------------------

///|
/// Access-unit byte sizes. A new AU starts at the first non-filler NAL after
/// the previous AU's VCL NAL; filler-data NALs stay in the AU whose slice
/// they pad.
fn vbv_au_sizes(nals : Array[(Int32, Int32, Int32)]) -> Array[Int32] {
  let out : Array[Int32] = []
  if nals.length() == 0 {
    return out
  }
  let mut cur_start = nals[0].1
  let mut seen_vcl = false
  for nal in nals {
    let (ty, s, _) = nal
    let is_vcl = ty == 1 || ty == 5
    if seen_vcl && ty != 12 {
      out.push(s - cur_start)
      cur_start = s
      seen_vcl = false
    }
    if is_vcl {
      seen_vcl = true
    }
  }
  out.push(nals[nals.length() - 1].2 - cur_start)
  out
}

///|
/// Replay the decoder's CPB model over the actual AU sizes (filler
/// included): every removal must fit, and the post-removal buffer plus one
/// frame of arrivals must stay inside the declared CPB. Returns
/// `(total_bits, final_fullness)`.
fn vbv_cpb_check(
  name : String,
  sizes : Array[Int32],
  maxrate : Int32,
  bufsize : Int32,
  fps : Int32,
  init_pct : Int32,
) -> (Int32, Int32) raise {
  let rate = maxrate / 64 * 64
  let csize = bufsize / 16 * 16
  let rate_bits = rate / fps
  let init_bits = csize * init_pct / 100
  let mut fullness = init_bits
  let mut total = 0
  for f, size in sizes {
    let bits = size * 8
    total = total + bits
    if bits > fullness {
      fail(
        "\{name}: AU \{f} underflows the CPB: \{bits} bits vs \{fullness} buffered",
      )
    }
    let after = fullness - bits
    if after + rate_bits > csize {
      fail(
        "\{name}: AU \{f} overflows the CPB: \{after} + \{rate_bits} > \{csize}",
      )
    }
    fullness = after + rate_bits
  }
  (total, fullness)
}

///|
fn vbv_bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn vbv_filler_nals(
  nals : Array[(Int32, Int32, Int32)],
) -> Array[(Int32, Int32, Int32)] {
  let out : Array[(Int32, Int32, Int32)] = []
  for nal in nals {
    if nal.0 == 12 {
      out.push(nal)
    }
  }
  out
}

///|
/// Every filler NAL is `start code + 0x0c + (0xFF ... 0xFF) + 0x80`, and its
/// full byte length is what the CPB bookkeeping charged.
fn vbv_check_filler_layout(
  stream : Bytes,
  fillers : Array[(Int32, Int32, Int32)],
) -> Int32 raise {
  let mut total = 0
  for nal in fillers {
    let (_, s, e) = nal
    let len = e - s
    total = total + len
    if len < 6 {
      fail("vbv: filler NAL only \{len} bytes")
    }
    if stream[s + 4].to_int() != 0x0C {
      fail("vbv: filler NAL header \{stream[s + 4].to_int()}")
    }
    for i = s + 5; i < e - 1; i = i + 1 {
      if stream[i].to_int() != 0xFF {
        fail("vbv: filler payload byte \{i - s} is not 0xFF")
      }
    }
    if stream[e - 1].to_int() != 0x80 {
      fail("vbv: filler payload lacks rbsp trailing bits")
    }
  }
  total
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

///|
test "h264 aud: delimiters, byte compatibility and CPB accounting" {
  let frames = h264_rc_fixture(5)
  for cabac in [false, true] {
    for vbv in [false, true] {
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let rate = if vbv { 100000 } else { 0 }
      let size = if vbv { 32000 } else { 0 }
      let fps = if vbv { 30 } else { 0 }
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          aud=true,
          vbv_maxrate=rate,
          vbv_bufsize=size,
          fps~,
          recon~,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=64,
          height=48,
          aud=true,
          vbv_maxrate=rate,
          vbv_bufsize=size,
          fps~,
          recon~,
          stats~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      let nals = vbv_nals(stream)
      let stripped : Array[Byte] = []
      let sizes : Array[Int32] = []
      let mut start = 0
      let mut count = 0
      for (ty, s, e) in nals {
        if ty == 9 {
          if count > 0 {
            sizes.push(s - start)
          }
          start = s
          assert_eq(e - s, 6)
          assert_eq(stream[s + 4].to_int(), 9)
          assert_eq(
            stream[s + 5].to_int(),
            if count == 0 {
              0x10
            } else {
              0x30
            },
          )
          count += 1
        } else {
          for i in s..<e {
            stripped.push(stream[i])
          }
        }
      }
      sizes.push(stream.length() - start)
      assert_eq(count, 5)
      assert_eq(nals[0].0, 9)
      h264_rc_recon_invariant("AUD", stream, recon, 5)
      if vbv {
        ignore(vbv_cpb_check("AUD", sizes, rate, size, fps, 90))
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
      } else {
        let plain = match
          (if cabac {
            @libavcodec.h264_encode_frames_cabac(frames, width=64, height=48)
          } else {
            @libavcodec.h264_encode_frames(frames, width=64, height=48)
          }) {
          Ok(s) => s
          Err(e) => fail(e)
        }
        assert_true(vbv_bytes_eq(plain, Bytes::from_array(stripped[:])))
      }
    }
  }
}

///|
/// The CPB mode is opt-in: absent/zero VBV arguments and a non-default
/// `vbv_init` leave the flat-QP streams byte-identical.
test "h264 vbv: opt-in leaves flat streams byte-identical" {
  let frames = h264_rc_fixture(5)
  let flat = match
    @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if flat.length() != 2615 {
    fail("flat CAVLC length changed: \{flat.length()}")
  }
  if h264_rc_md5(flat) != "866d5978ff005edd1c8741abf92554f5" {
    fail("flat CAVLC bytes changed: \{h264_rc_md5(flat)}")
  }
  let flatc = match
    @libavcodec.h264_encode_frames_cabac(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if flatc.length() != 2351 {
    fail("flat CABAC length changed: \{flatc.length()}")
  }
  if h264_rc_md5(flatc) != "45d3adc1a3a368bd11c863cec9eece15" {
    fail("flat CABAC bytes changed: \{h264_rc_md5(flatc)}")
  }
  // Explicit zero parameters and a non-default init percentage (ignored
  // while VBV is off) must not perturb the flat path.
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=0,
      vbv_bufsize=0,
      fps=0,
      vbv_init=40,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if !vbv_bytes_eq(off, flat) {
    fail("zero VBV parameters changed the flat CAVLC stream")
  }
  let offc = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=0,
      vbv_bufsize=0,
      fps=0,
      vbv_init=40,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if !vbv_bytes_eq(offc, flatc) {
    fail("zero VBV parameters changed the flat CABAC stream")
  }
}

///|
fn vbv_check_layout_common(
  name : String,
  stream : Bytes,
  profile_idc : Int32,
) -> Array[(Int32, Int32, Int32)] raise {
  let nals = vbv_nals(stream)
  let expected = [7, 8, 6, 6, 5, 6, 1, 6, 1, 6, 1, 6, 1]
  if nals.length() != expected.length() {
    fail("\{name}: expected \{expected.length()} NALs, got \{nals.length()}")
  }
  for i, nal in nals {
    if nal.0 != expected[i] {
      fail("\{name}: NAL \{i} type \{nal.0}, expected \{expected[i]}")
    }
  }
  // Each SEI NAL is `type + size + payload + rbsp_trailing_bits`; the
  // trailing byte is a separate byte and must not be folded into
  // payload_size (FFmpeg strips it before parsing the payload). Emulation
  // prevention may insert 0x03 bytes, so compare the unescaped RBSP.
  for nal in nals {
    if nal.0 == 6 {
      let out : Array[Byte] = []
      for i = nal.1 + 5; i < nal.2; i = i + 1 {
        out.push(stream[i])
      }
      let rbsp = vbv_unescape(Bytes::from_array(out[:]))
      let size = rbsp[1].to_int() & 0xFF
      if rbsp.length() != 2 + size + 1 {
        fail(
          "\{name}: SEI RBSP length \{rbsp.length()}, expected \{2 + size + 1} for payload_size \{size}",
        )
      }
      if rbsp[rbsp.length() - 1].to_int() != 0x80 {
        fail("\{name}: SEI NAL missing trailing 0x80")
      }
    }
  }
  let sps = vbv_sps_info(stream, nals)
  if sps.profile_idc != profile_idc {
    fail("\{name}: profile_idc \{sps.profile_idc}, expected \{profile_idc}")
  }
  if sps.level_idc != 30 {
    fail("\{name}: level_idc \{sps.level_idc}, expected 30")
  }
  if sps.num_units_in_tick != 1 || sps.time_scale != 60 {
    fail(
      "\{name}: timing \{sps.num_units_in_tick}/\{sps.time_scale}, expected 1/60",
    )
  }
  if !sps.fixed_frame_rate {
    fail("\{name}: fixed_frame_rate_flag is clear")
  }
  if !sps.nal_hrd || sps.vcl_hrd {
    fail("\{name}: expected NAL HRD only")
  }
  if sps.cpb_cnt_minus1 != 0 || !sps.cbr_flag {
    fail("\{name}: expected one CBR CPB")
  }
  if sps.bit_rate_scale != 0 || sps.cpb_size_scale != 0 {
    fail("\{name}: HRD scales must be zero")
  }
  if sps.bit_rate_value_minus1 != 1561 || sps.cpb_size_value_minus1 != 1999 {
    fail(
      "\{name}: HRD rate/size \{sps.bit_rate_value_minus1}/\{sps.cpb_size_value_minus1}, expected 1561/1999",
    )
  }
  if sps.initial_cpb_removal_delay_length != 24 ||
    sps.cpb_removal_delay_length != 16 ||
    sps.dpb_output_delay_length != 4 ||
    sps.time_offset_length != 0 {
    fail("\{name}: unexpected HRD delay lengths")
  }
  if sps.low_delay {
    fail("\{name}: low_delay_hrd_flag set")
  }
  if !sps.bitstream_restriction ||
    sps.max_num_reorder_frames != 0 ||
    sps.max_dec_frame_buffering != 1 {
    fail("\{name}: unexpected bitstream restrictions")
  }
  // Buffering period: initial delay + offset covers one second at 90 kHz.
  let bp = vbv_sei_message(stream, nals[2])
  if bp.0 != 0 {
    fail("\{name}: first SEI type \{bp.0}, expected buffering_period")
  }
  let bp_bits = VbvBits::new(bp.1)
  if bp_bits.ue() != 0 {
    fail("\{name}: buffering_period sps id != 0")
  }
  let init_delay = bp_bits.u(24)
  let init_offset = bp_bits.u(24)
  if init_delay != 25928 || init_offset != 64072 {
    fail(
      "\{name}: buffering period \{init_delay}/\{init_offset}, expected 25928/64072",
    )
  }
  // Picture timing on the IDR and the four P pictures, two clocks apart.
  let pt_indices = [3, 5, 7, 9, 11]
  for f, idx in pt_indices {
    let pt = vbv_sei_message(stream, nals[idx])
    if pt.0 != 1 {
      fail("\{name}: SEI \{idx} type \{pt.0}, expected pic_timing")
    }
    let pb = VbvBits::new(pt.1)
    let delay = pb.u(16)
    if delay != f * 2 {
      fail(
        "\{name}: picture \{f} cpb_removal_delay \{delay}, expected \{f * 2}",
      )
    }
    if pb.u(4) != 0 {
      fail("\{name}: picture \{f} dpb_output_delay != 0")
    }
  }
  nals
}

///|
test "h264 vbv: CAVLC SPS VUI/HRD, SEI and NAL layout" {
  let frames = h264_rc_fixture(5)
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=100000,
      vbv_bufsize=32000,
      fps=30,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let nals = vbv_check_layout_common("cavlc", stream, 66)
  for q in stats.frame_qps {
    if q != 26 {
      fail("cavlc: filler-free stream changed QP to \{q}")
    }
  }
  if stats.vbv_fills != 0 || stats.vbv_filler_bytes != 0 {
    fail("cavlc: unexpected fillers")
  }
  if stats.vbv_bits != stream.length().to_int64() * 8L {
    fail("cavlc: vbv_bits does not match the stream size")
  }
  let sizes = vbv_au_sizes(nals)
  if sizes.length() != 5 {
    fail("cavlc: expected 5 access units, got \{sizes.length()}")
  }
  let (total, fullness) = vbv_cpb_check("cavlc", sizes, 100000, 32000, 30, 90)
  if total != stream.length() * 8 || total != 21672 {
    fail("cavlc: AU bits \{total}, stream \{stream.length() * 8}")
  }
  if fullness > 32000 {
    fail("cavlc: CPB overflowed to \{fullness}")
  }
  // Deterministic: a second encode is byte-identical.
  let again = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=100000,
      vbv_bufsize=32000,
      fps=30,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if !vbv_bytes_eq(again, stream) {
    fail("cavlc: VBV encode is not deterministic")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail("cavlc: decode failed: \{e}")
  }
  if dec.length() != 5 {
    fail("cavlc: decoded \{dec.length()} frames, expected 5")
  }
}

///|
test "h264 vbv: CABAC SPS VUI/HRD, SEI and NAL layout" {
  let frames = h264_rc_fixture(5)
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=100000,
      vbv_bufsize=32000,
      fps=30,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let nals = vbv_check_layout_common("cabac", stream, 77)
  for q in stats.frame_qps {
    if q != 26 {
      fail("cabac: filler-free stream changed QP to \{q}")
    }
  }
  if stats.vbv_fills != 0 || stats.vbv_filler_bytes != 0 {
    fail("cabac: unexpected fillers")
  }
  let sizes = vbv_au_sizes(nals)
  let (total, fullness) = vbv_cpb_check("cabac", sizes, 100000, 32000, 30, 90)
  if total != stream.length() * 8 || total != 19560 {
    fail("cabac: AU bits \{total}, stream \{stream.length() * 8}")
  }
  if fullness > 32000 {
    fail("cabac: CPB overflowed to \{fullness}")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail("cabac: decode failed: \{e}")
  }
  if dec.length() != 5 {
    fail("cabac: decoded \{dec.length()} frames, expected 5")
  }
}

///|
test "h264 vbv: filler NALs keep the CPB full at CBR" {
  let frames = h264_rc_fixture(5)
  for mode in ["cavlc", "cabac"] {
    let stats = @libavcodec.H264EncStats::new()
    let stream = match mode {
      "cavlc" =>
        match
          @libavcodec.h264_encode_frames(
            frames,
            width=64,
            height=48,
            qp=26,
            vbv_maxrate=200000,
            vbv_bufsize=60000,
            fps=30,
            stats~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
      _ =>
        match
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=64,
            height=48,
            qp=26,
            vbv_maxrate=200000,
            vbv_bufsize=60000,
            fps=30,
            stats~,
          ) {
          Ok(s) => s
          Err(e) => fail(e)
        }
    }
    let nals = vbv_nals(stream)
    let fillers = vbv_filler_nals(nals)
    if fillers.length() == 0 || stats.vbv_fills == 0 {
      fail("\{mode}: expected filler NALs")
    }
    if fillers.length() != stats.vbv_fills {
      fail(
        "\{mode}: \{fillers.length()} filler NALs vs stats \{stats.vbv_fills}",
      )
    }
    let filler_bytes = vbv_check_filler_layout(stream, fillers)
    if filler_bytes != stats.vbv_filler_bytes {
      fail(
        "\{mode}: filler bytes \{filler_bytes} vs stats \{stats.vbv_filler_bytes}",
      )
    }
    if stats.vbv_bits != stream.length().to_int64() * 8L {
      fail("\{mode}: vbv_bits \{stats.vbv_bits} != stream bits")
    }
    let sizes = vbv_au_sizes(nals)
    if sizes.length() != 5 {
      fail("\{mode}: expected 5 access units, got \{sizes.length()}")
    }
    // Every non-filler byte of an AU is inside exactly one AU, and the
    // replay with filler traffic must never underflow or overflow.
    let (total, fullness) = vbv_cpb_check(mode, sizes, 200000, 60000, 30, 90)
    if total != stream.length() * 8 {
      fail("\{mode}: AU sum \{total} != stream bits \{stream.length() * 8}")
    }
    let csize = 60000
    if fullness > csize || fullness < csize - 7 {
      fail("\{mode}: final CB fullness \{fullness}, expected ~\{csize}")
    }
    // Filler keeps the delivered rate at the declared CBR rate: the
    // cumulative traffic is one buffer short of the arrivals.
    let expected = 60000 * 90 / 100 + 5 * (200000 / 30) - csize
    if total < expected || total > expected + 7 {
      fail("\{mode}: CBR traffic \{total} bits, expected ~\{expected}")
    }
    if stats.frame_qps.length() != 5 {
      fail("\{mode}: frame_qps not reported per picture")
    }
    for q in stats.frame_qps {
      if q != 26 {
        fail("\{mode}: buffer-rich stream changed QP to \{q}")
      }
    }
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(f) => f
      Err(e) => fail("\{mode}: decode failed: \{e}")
    }
    if dec.length() != 5 {
      fail("\{mode}: decoded \{dec.length()} frames, expected 5")
    }
  }
}

///|
test "h264 vbv: tight buffer raises per-picture QPs; recon invariant" {
  let frames = h264_rc_fixture(5)
  // CAVLC: pictures 3 and 4 cannot fit at QP 26, the solver coarsens them.
  let stats_c = @libavcodec.H264EncStats::new()
  let recon_c : Array[Bytes] = []
  let cavlc = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=60000,
      vbv_bufsize=12000,
      fps=30,
      stats=stats_c,
      recon=recon_c,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let expected_c = [26, 26, 26, 33, 35]
  if stats_c.frame_qps.length() != expected_c.length() {
    fail("cavlc: frame_qps length \{stats_c.frame_qps.length()}")
  }
  for i, q in stats_c.frame_qps {
    if q != expected_c[i] {
      fail(
        "cavlc: QPs \{Repr(stats_c.frame_qps)}, expected \{Repr(expected_c)}",
      )
    }
  }
  if stats_c.vbv_fills != 0 || stats_c.vbv_filler_bytes != 0 {
    fail("cavlc: tight buffer should not need filler")
  }
  if cavlc.length() != 2339 ||
    h264_rc_md5(cavlc) != "db436cd55d911f3ec7a63dea7462418a" {
    fail("cavlc: tight-buffer stream drifted: \{h264_rc_md5(cavlc)}")
  }
  h264_rc_recon_invariant("vbv-cavlc-tight", cavlc, recon_c, 5)
  let sizes_c = vbv_au_sizes(vbv_nals(cavlc))
  let (_, full_c) = vbv_cpb_check(
    "vbv-cavlc-tight", sizes_c, 60000, 12000, 30, 90,
  )
  if full_c > 12000 {
    fail("cavlc: tight-buffer CPB overflowed to \{full_c}")
  }
  // CABAC adapts differently (one trailing picture needs a coarser QP).
  let stats_k = @libavcodec.H264EncStats::new()
  let recon_k : Array[Bytes] = []
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=60000,
      vbv_bufsize=12000,
      fps=30,
      stats=stats_k,
      recon=recon_k,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let expected_k = [26, 26, 26, 26, 31]
  if stats_k.frame_qps.length() != expected_k.length() {
    fail("cabac: frame_qps length \{stats_k.frame_qps.length()}")
  }
  for i, q in stats_k.frame_qps {
    if q != expected_k[i] {
      fail(
        "cabac: QPs \{Repr(stats_k.frame_qps)}, expected \{Repr(expected_k)}",
      )
    }
  }
  h264_rc_recon_invariant("vbv-cabac-tight", cabac, recon_k, 5)
  let sizes_k = vbv_au_sizes(vbv_nals(cabac))
  let (_, full_k) = vbv_cpb_check(
    "vbv-cabac-tight", sizes_k, 60000, 12000, 30, 90,
  )
  if full_k > 12000 {
    fail("cabac: tight-buffer CPB overflowed to \{full_k}")
  }
}

///|
test "h264 vbv: parameter validation and mode exclusivity" {
  let frames = h264_rc_fixture(2)
  let cases : Array[(String, Result[Bytes, String])] = []
  // Missing any of the three required parameters.
  cases.push(
    (
      "missing bufsize",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        fps=30,
      ),
    ),
  )
  cases.push(
    (
      "missing fps",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=32000,
      ),
    ),
  )
  cases.push(
    (
      "below resolution",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=32,
        vbv_bufsize=32000,
        fps=30,
      ),
    ),
  )
  cases.push(
    (
      "buffer smaller than a picture",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=16,
        fps=30,
      ),
    ),
  )
  // 3376 bits holds the 3332-bit nominal picture but leaves less than the
  // six-byte filler NAL's 48 bits of slack: CBR could not be honoured.
  cases.push(
    (
      "buffer without filler slack",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=3376,
        fps=30,
      ),
    ),
  )
  cases.push(
    (
      "rate below a bit per picture",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=32000,
        fps=1000000000,
      ),
    ),
  )
  cases.push(
    (
      "fps out of range",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=32000,
        fps=1000000001,
      ),
    ),
  )
  cases.push(
    (
      "init zero",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=64,
        vbv_bufsize=80,
        fps=2,
        vbv_init=1,
      ),
    ),
  )
  cases.push(
    (
      "init above 100",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        vbv_maxrate=100000,
        vbv_bufsize=32000,
        fps=30,
        vbv_init=101,
      ),
    ),
  )
  cases.push(
    (
      "target plus vbv",
      @libavcodec.h264_encode_frames(
        frames,
        width=64,
        height=48,
        qp=26,
        target_bytes=4000,
        vbv_maxrate=100000,
        vbv_bufsize=32000,
        fps=30,
      ),
    ),
  )
  for c in cases {
    let (name, result) = c
    match result {
      Ok(_) => fail("vbv error case accepted: \{name}")
      Err(_) => ()
    }
  }
  // target_bytes alone still works, and vbv_init alone is ignored.
  let target = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=4000,
      vbv_init=40,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if target.length() == 0 {
    fail("target_bytes path produced an empty stream")
  }
  // The CABAC entry shares the same validation.
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=4000,
      vbv_maxrate=100000,
      vbv_bufsize=32000,
      fps=30,
    ) {
    Ok(_) => fail("cabac accepted target_bytes + vbv")
    Err(_) => ()
  }
  match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=100000,
      vbv_bufsize=32000,
    ) {
    Ok(_) => fail("cabac accepted missing fps")
    Err(_) => ()
  }
}

///|
/// External arbitration (docker ffmpeg 9.0.2): the CBR stream with filler
/// NALs and the tight-buffer stream with adaptive QPs both decode with zero
/// warnings, and every deblocked frame matches this repository's decoder
/// byte-for-byte (the pinned MD5s are ffmpeg's framemd5 values).
test "h264 vbv: ffmpeg-arbitrated CBR and tight-buffer streams" {
  let frames = h264_rc_fixture(5)
  let stats_c = @libavcodec.H264EncStats::new()
  let cavlc = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=200000,
      vbv_bufsize=60000,
      fps=30,
      stats=stats_c,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  ignore(stats_c)
  let mut dump1 = ""
  for i = 0; i < cavlc.length(); i = i + 1 {
    dump1 = dump1 + (cavlc[i].to_int() & 0xFF).to_string() + ","
  }
  println("VBVARB:\{dump1}")
  let filtered = match @libavcodec.h264_decode_annexb_frames(cavlc, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins1 = [
    "e2a551ec3d95aa8b253a7a27b596645d", "3072f737b2d0c3470fce540c377dd594", "35ded9aab6ea3979fafc1007bc7aabae",
    "e135e4b7af460ca5f69457c87b81b52c", "7dc50b8cf30ade5ded4d3244f9a7e858",
  ]
  for i, f in filtered {
    inspect(h264_rc_md5(f.yuvp()), content=pins1[i])
  }
  let stats_k = @libavcodec.H264EncStats::new()
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=60000,
      vbv_bufsize=12000,
      fps=30,
      stats=stats_k,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  ignore(stats_k)
  let mut dump2 = ""
  for i = 0; i < cabac.length(); i = i + 1 {
    dump2 = dump2 + (cabac[i].to_int() & 0xFF).to_string() + ","
  }
  println("VBVCARB:\{dump2}")
  let filtered2 = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins2 = [
    "d5774463aab20d0e320a5ca12872e5b0", "1325d8176f00f65e947c3a83f90f5247", "12bb8f28b87273891bf367cc3092f565",
    "6bed03421e929ac0321bc2519617917c", "82e2124dbb8cd290cd16584c6c62c6e3",
  ]
  for i, f in filtered2 {
    inspect(h264_rc_md5(f.yuvp()), content=pins2[i])
  }
}

///|
test "h264 aq strength: ABR and VBV searches preserve strong AQ" {
  let frames = h264_aq_fixture(3)
  for cabac in [false, true] {
    for vbv in [false, true] {
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let target = if vbv { 0 } else { 1200 }
      let maxrate = if vbv { 100000 } else { 0 }
      let bufsize = if vbv { 32000 } else { 0 }
      let fps = if vbv { 30 } else { 0 }
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          aq=true,
          aq_strength=6,
          target_bytes=target,
          vbv_maxrate=maxrate,
          vbv_bufsize=bufsize,
          fps~,
          recon~,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=64,
          height=48,
          aq=true,
          aq_strength=6,
          target_bytes=target,
          vbv_maxrate=maxrate,
          vbv_bufsize=bufsize,
          fps~,
          recon~,
          stats~,
        )
      }
      let stream = match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
      h264_rc_recon_invariant("strong AQ rate control", stream, recon, 3)
      assert_true(stats.dqp_mbs > 0)
      if vbv {
        ignore(
          vbv_cpb_check(
            "strong AQ",
            vbv_au_sizes(vbv_nals(stream)),
            maxrate,
            bufsize,
            fps,
            90,
          ),
        )
        assert_eq(stats.vbv_bits, stream.length().to_int64() * 8L)
      } else {
        assert_true(stream.length() <= target)
      }
    }
  }
}
