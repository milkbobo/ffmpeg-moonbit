///|
/// HRD field-by-field cross-check between the pure MoonBit encoder's
/// VBV/CBR line and a real libx264 `nal-hrd=cbr` stream (§401).
///
/// Both streams are parsed with this package's own parameter-set and SEI
/// decoders (`ff_h264_decode_seq_parameter_set`, `h264_sei_decode`,
/// `sei_process_picture_timing`) — the same code paths a conforming
/// decoder runs — and every HRD-relevant field is compared for semantic
/// agreement:
///
/// - SPS VUI HRD: presence, NAL-only, single CPB, `cbr_flag`,
///   declared rate/size reconstructed from
///   `(value_minus1 + 1) << (6/4 + scale)`.
/// - Timing info: `num_units_in_tick`/`time_scale`/`fixed_frame_rate`
///   and the frame rate implied by the picture-timing delay step.
/// - buffering_period SEI: initial CPB fullness in 90 kHz units.
/// - picture_timing SEI: per-picture `cpb_removal_delay` (strictly
///   increasing, constant step) and `dpb_output_delay`.
///
/// Both streams must then satisfy the same CPB leaky-bucket invariant,
/// replayed purely from their own extracted declarations: declared
/// rate/size from the SPS VUI, initial fullness from buffering_period,
/// per-picture arrival windows from the pic_timing delay deltas. No FFI
/// anywhere — the whole file runs on the wasm target; the libx264
/// reference stream is the base64 fixture `sei_hrd_b64` from
/// `h264_sei_realdata_wbtest.mbt` (same package, test build).
///
/// The two fixtures were produced with the *same nominal VBV parameters*
/// (200 kbit/s max rate, 200 kbit buffer, 30 fps), which makes the
/// declared fields numerically comparable rather than merely structural.

///|
/// Annex B splitter covering both start-code lengths: this repository's
/// encoder emits 4-byte codes, libx264 emits 3-byte ones. Returns
/// `(nal_type, leading_zeros_boundary, header_byte, end_boundary)` per NAL.
fn hrd_nals(stream : Bytes) -> Array[(Int32, Int32, Int32, Int32)] {
  let n = stream.length()
  let out : Array[(Int32, Int32, Int32, Int32)] = []
  let mut i = 0
  while i + 3 < n {
    if stream[i].to_int() == 0 &&
      stream[i + 1].to_int() == 0 &&
      stream[i + 2].to_int() == 1 {
      let mut s = i
      while s > 0 && stream[s - 1].to_int() == 0 {
        s = s - 1
      }
      let ty = stream[i + 3].to_int() & 0x1F
      if out.length() > 0 {
        let last = out[out.length() - 1]
        out[out.length() - 1] = (last.0, last.1, last.2, s)
      }
      out.push((ty, s, i + 3, n))
      i = i + 3
    } else {
      i = i + 1
    }
  }
  out
}

///|
fn hrd_count(nals : Array[(Int32, Int32, Int32, Int32)], ty : Int32) -> Int32 {
  let mut n = 0
  for nal in nals {
    if nal.0 == ty {
      n = n + 1
    }
  }
  n
}

///|
/// Strip emulation-prevention bytes from a raw NAL payload slice.
fn hrd_unescape(raw : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut zeros = 0
  for i in 0..<raw.length() {
    let b = raw[i].to_int() & 0xFF
    if zeros >= 2 && b == 3 {
      zeros = 0
      continue
    }
    if b == 0 {
      zeros = zeros + 1
    } else {
      zeros = 0
    }
    out.push(raw[i])
  }
  Bytes::from_array(out[:])
}

///|
/// Unescaped RBSP payload of a NAL, past its one-byte header.
fn hrd_rbsp(stream : Bytes, nal : (Int32, Int32, Int32, Int32)) -> Bytes {
  let (_, _, p, e) = nal
  hrd_unescape(stream[p + 1:e].to_owned())
}

///|
/// Access-unit byte sizes for CPB accounting: a new AU starts at the first
/// non-filler NAL after the previous AU's VCL NAL; filler-data NALs stay in
/// the AU whose slice they pad.
fn hrd_au_sizes(nals : Array[(Int32, Int32, Int32, Int32)]) -> Array[Int32] {
  let out : Array[Int32] = []
  if nals.length() == 0 {
    return out
  }
  let mut cur_start = nals[0].1
  let mut seen_vcl = false
  for nal in nals {
    let (ty, s, _, _) = nal
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
  out.push(nals[nals.length() - 1].3 - cur_start)
  out
}

///|
/// Everything the HRD cross-check needs from one stream.
struct HrdInfo {
  /// Declared bit rate / CPB size in bits (reconstructed from the SPS VUI
  /// HRD scales and minus-one values).
  declared_rate : Int64
  declared_size : Int64
  cpb_removal_delay_length : Int32
  initial_cpb_removal_delay_length : Int32
  dpb_output_delay_length : Int32
  time_offset_length : Int32
  num_units_in_tick : Int32
  time_scale : Int32
  fixed_frame_rate : Bool
  /// buffering_period initial delay, 90 kHz units (-1 when absent).
  bp_delay : Int32
  /// picture_timing `cpb_removal_delay` per picture, decode order.
  pt_removal : Array[Int32]
  /// picture_timing `dpb_output_delay` per picture.
  pt_dpb : Array[Int32]
}

///|
fn hrd_check(ok : Bool, msg : String) -> Unit raise {
  if !ok {
    fail(msg)
  }
}

///|
/// Parse one Annex B stream into `HrdInfo` with the package's own
/// parameter-set and SEI decoders.
fn hrd_parse(stream : Bytes, name : String) -> HrdInfo raise {
  let nals = hrd_nals(stream)
  hrd_check(hrd_count(nals, 7) >= 1, "\{name}: no SPS found")
  hrd_check(hrd_count(nals, 8) >= 1, "\{name}: no PPS found")
  hrd_check(
    nals[0].0 == 7,
    "\{name}: stream does not start with an SPS (ty=\{nals[0].0})",
  )
  // x264 repeats SPS/PPS at every IDR (`b_repeat_headers` defaults on), so
  // every SPS instance must carry identical payload — the parameter set
  // parsed from the first one describes the whole stream.
  let first_sps = hrd_rbsp(stream, nals[0])
  for nal in nals {
    if nal.0 == 7 {
      let rbsp = hrd_rbsp(stream, nal)
      hrd_check(
        rbsp.length() == first_sps.length(),
        "\{name}: repeated SPS differs in size (\{rbsp.length()} vs \{first_sps.length()})",
      )
      for i in 0..<rbsp.length() {
        hrd_check(
          rbsp[i] == first_sps[i],
          "\{name}: repeated SPS differs at byte \{i}",
        )
      }
    }
  }
  let ps = new_h264_param_sets()
  let mut sps : H264Sps? = None
  for nal in nals {
    if nal.0 == 7 {
      match
        ff_h264_decode_seq_parameter_set(
          BitReader::new(hrd_rbsp(stream, nal)),
          ps,
          false,
        ) {
        Ok(_) => ()
        Err(e) => fail("\{name}: SPS parse failed: \{e}")
      }
      sps = ps.sps_list[0]
      break
    }
  }
  let sps = match sps {
    Some(s) => s
    None => fail("\{name}: SPS did not register")
  }
  hrd_check(
    sps.nal_hrd_parameters_present_flag == 1,
    "\{name}: nal_hrd_parameters_present_flag=\{sps.nal_hrd_parameters_present_flag}",
  )
  hrd_check(
    sps.vcl_hrd_parameters_present_flag == 0,
    "\{name}: unexpected VCL HRD",
  )
  hrd_check(sps.cpb_cnt == 1, "\{name}: cpb_cnt=\{sps.cpb_cnt}")
  hrd_check(
    (sps.cpr_flag & 1U) == 1U,
    "\{name}: cbr_flag[0]=\{sps.cpr_flag & 1U}, expected CBR",
  )
  let rate = sps.bit_rate_value[0].to_int64() << (6 + sps.bit_rate_scale)
  let csize = sps.cpb_size_value[0].to_int64() << (4 + sps.cpb_size_scale)
  // Walk the SEI NALs; buffering_period needs the SPS in `ps` first.
  let sei = new_h264_sei_context()
  let mut bp_delay = -1
  let pt_removal : Array[Int32] = []
  let pt_dpb : Array[Int32] = []
  for nal in nals {
    if nal.0 == 6 {
      // Reset the present flags so they describe *this* NAL only (the C
      // decoder's per-picture ff_h264_sei_uninit); otherwise a user-data NAL
      // would re-report the previous picture_timing's stashed payload.
      sei.sei_uninit()
      match sei.h264_sei_decode(hrd_rbsp(stream, nal), ps) {
        Ok(_) => ()
        Err(e) => fail("\{name}: SEI decode failed: \{e}")
      }
      if sei.buffering_period.present == 1 && bp_delay < 0 {
        bp_delay = sei.buffering_period.initial_cpb_removal_delay[0]
      }
      if sei.picture_timing.present == 1 {
        match sei.sei_process_picture_timing(sps) {
          Ok(_) => ()
          Err(e) => fail("\{name}: pic_timing parse failed: \{e}")
        }
        pt_removal.push(sei.picture_timing.cpb_removal_delay)
        pt_dpb.push(sei.picture_timing.dpb_output_delay)
      }
    }
  }
  {
    declared_rate: rate,
    declared_size: csize,
    cpb_removal_delay_length: sps.cpb_removal_delay_length,
    initial_cpb_removal_delay_length: sps.initial_cpb_removal_delay_length,
    dpb_output_delay_length: sps.dpb_output_delay_length,
    time_offset_length: sps.time_offset_length,
    num_units_in_tick: sps.num_units_in_tick,
    time_scale: sps.time_scale,
    fixed_frame_rate: sps.fixed_frame_rate_flag == 1,
    bp_delay,
    pt_removal,
    pt_dpb,
  }
}

///|
/// The delay-width fields are a writer's choice (this encoder: 24/16/4/0;
/// x264: 19/5/23/0); the only requirement is that each stream's own values
/// fit its declared widths.
fn hrd_check_widths(name : String, info : HrdInfo) -> Unit raise {
  hrd_check(
    info.bp_delay < (1 << info.initial_cpb_removal_delay_length),
    "\{name}: buffering_period delay \{info.bp_delay} overflows its \{info.initial_cpb_removal_delay_length}-bit field",
  )
  for d in info.pt_removal {
    hrd_check(
      d < (1 << info.cpb_removal_delay_length),
      "\{name}: cpb_removal_delay \{d} overflows its \{info.cpb_removal_delay_length}-bit field",
    )
  }
  for d in info.pt_dpb {
    hrd_check(
      d < (1 << info.dpb_output_delay_length),
      "\{name}: dpb_output_delay \{d} overflows its \{info.dpb_output_delay_length}-bit field",
    )
  }
}

///|
/// Frame rate implied by the pic_timing delay step and the VUI clock
/// (`removal interval = step * num_units_in_tick / time_scale` seconds).
fn hrd_implied_fps(info : HrdInfo) -> Int64 {
  if info.pt_removal.length() < 2 {
    return 0L
  }
  let step = (info.pt_removal[1] - info.pt_removal[0]).to_int64()
  if step <= 0L || info.num_units_in_tick <= 0 {
    return 0L
  }
  info.time_scale.to_int64() / (step * info.num_units_in_tick.to_int64())
}

///|
/// Replay the CPB leaky-bucket invariant from the stream's own declarations:
/// the first AU (and every later one, filler included) must be fully
/// buffered at its removal time, and one arrival window of post-removal
/// fill must fit inside the declared CPB. `tol` absorbs the encoder-side
/// rounding that a declared-granule reconstruction cannot see.
fn hrd_cpb_replay(
  name : String,
  sizes : Array[Int32],
  info : HrdInfo,
  tol : Int64,
) -> Unit raise {
  let n = sizes.length()
  hrd_check(
    info.pt_removal.length() == n,
    "\{name}: \{info.pt_removal.length()} pic_timing SEIs vs \{n} AUs",
  )
  hrd_check(info.bp_delay > 0, "\{name}: buffering_period initial delay absent")
  let init = info.bp_delay.to_int64() * info.declared_rate / 90000L
  hrd_check(
    init <= info.declared_size + tol,
    "\{name}: initial fullness \{init} exceeds the CPB \{info.declared_size}+\{tol}",
  )
  let mut fullness = init
  for i = 0; i < n; i = i + 1 {
    let bits = sizes[i].to_int64() * 8L
    hrd_check(
      bits <= fullness,
      "\{name}: AU \{i} underflows the CPB: \{bits} bits vs \{fullness} buffered",
    )
    let after = fullness - bits
    if i + 1 < n {
      let ticks = (info.pt_removal[i + 1] - info.pt_removal[i]).to_int64()
      hrd_check(
        ticks > 0L,
        "\{name}: AU \{i} removal delay \{info.pt_removal[i + 1]} <= \{info.pt_removal[i]}",
      )
      let fill = info.declared_rate *
        ticks *
        info.num_units_in_tick.to_int64() /
        info.time_scale.to_int64()
      hrd_check(
        after + fill <= info.declared_size + tol,
        "\{name}: AU \{i} overflows the CPB: \{after}+\{fill} > \{info.declared_size}+\{tol}",
      )
      fullness = after + fill
    }
  }
}

///|
/// Deterministic 64x48 yuv420p clip (moving texture: ME has real work, and
/// at the declared 200 kbit/s the CBR filler logic is exercised).
fn hrd_fixture() -> Array[(Bytes, Bytes, Bytes)] {
  let w = 64
  let h = 48
  let cw = w / 2
  let ch = h / 2
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<4 {
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    for row in 0..<h {
      for col in 0..<w {
        let s = (col * 2 + row * 3 + f * 7) & 0xFF
        y[row * w + col] = s.to_byte()
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        u[row * cw + col] = (((col + f) & 0x3F) + 96).to_byte()
        v[row * cw + col] = (((row + f * 2) & 0x3F) + 96).to_byte()
      }
    }
    frames.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  frames
}

///|
test "hrd: MoonBit CBR stream HRD fields and CPB invariant" {
  let stats = H264EncStats::new()
  let stream = match
    h264_encode_frames(
      hrd_fixture(),
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=200000,
      vbv_bufsize=200000,
      fps=30,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let info = hrd_parse(stream, "moonbit")
  // Declared VBV: 200000/64=3125 exact, 200000/16=12500 exact, scale 0.
  guard info.declared_rate == 200000L else {
    fail("moonbit: declared rate \{info.declared_rate}, expected 200000")
  }
  guard info.declared_size == 200000L else {
    fail("moonbit: declared size \{info.declared_size}, expected 200000")
  }
  guard info.initial_cpb_removal_delay_length == 24 &&
    info.cpb_removal_delay_length == 16 &&
    info.dpb_output_delay_length == 4 &&
    info.time_offset_length == 0 else {
    fail(
      "moonbit: HRD delay lengths \{info.initial_cpb_removal_delay_length}/\{info.cpb_removal_delay_length}/\{info.dpb_output_delay_length}/\{info.time_offset_length}",
    )
  }
  guard info.num_units_in_tick == 1 && info.time_scale == 60 else {
    fail(
      "moonbit: timing \{info.num_units_in_tick}/\{info.time_scale}, expected 1/60",
    )
  }
  guard info.fixed_frame_rate else { fail("moonbit: fixed_frame_rate clear") }
  // init fullness = 90% of 200000 = 180000 bits -> 81000 at 90 kHz.
  guard info.bp_delay == 81000 else {
    fail("moonbit: buffering_period delay \{info.bp_delay}, expected 81000")
  }
  guard info.pt_removal.length() == 4 else {
    fail("moonbit: \{info.pt_removal.length()} pic_timing SEIs, expected 4")
  }
  for f, d in info.pt_removal {
    guard d == f * 2 else {
      fail("moonbit: picture \{f} cpb_removal_delay \{d}, expected \{f * 2}")
    }
    guard info.pt_dpb[f] == 0 else {
      fail("moonbit: picture \{f} dpb_output_delay \{info.pt_dpb[f]}")
    }
  }
  let nals = hrd_nals(stream)
  // This encoder writes SPS/PPS once; only x264 repeats them per IDR.
  guard hrd_count(nals, 7) == 1 && hrd_count(nals, 8) == 1 else {
    fail("moonbit: expected one SPS and one PPS")
  }
  guard hrd_count(nals, 12) > 0 else {
    fail("moonbit: CBR fixture must emit filler-data NALs")
  }
  guard stats.vbv_fills == hrd_count(nals, 12) else {
    fail(
      "moonbit: encoder reported \{stats.vbv_fills} fillers, stream has \{hrd_count(nals, 12)}",
    )
  }
  hrd_cpb_replay("moonbit", hrd_au_sizes(nals), info, 0L)
}

///|
test "hrd: real x264 CBR stream parsed by the pure MoonBit parsers" {
  let stream = @libavutil.av_base64_decode(sei_hrd_b64, 8192).unwrap()
  let info = hrd_parse(stream, "x264")
  // x264 quantises to kbit/s; the stream must still declare ~200 kbit/s and
  // a ~200 kbit CPB within one HRD granule of the requested parameters.
  let rate_err = if info.declared_rate > 200000L {
    info.declared_rate - 200000L
  } else {
    200000L - info.declared_rate
  }
  guard rate_err <= 1024L else {
    fail("x264: declared rate \{info.declared_rate}, expected ~200000")
  }
  let size_err = if info.declared_size > 200000L {
    info.declared_size - 200000L
  } else {
    200000L - info.declared_size
  }
  guard size_err <= 1024L else {
    fail("x264: declared size \{info.declared_size}, expected ~200000")
  }
  guard info.bp_delay > 0 else { fail("x264: buffering_period delay absent") }
  // CBR starts with a (near-)full buffer; pic_timing delays step forward.
  guard info.pt_removal.length() == 2 else {
    fail("x264: \{info.pt_removal.length()} pic_timing SEIs, expected 2")
  }
  guard info.pt_removal[1] > info.pt_removal[0] else {
    fail("x264: cpb_removal_delay not increasing")
  }
  guard hrd_implied_fps(info) == 30L else {
    fail(
      "x264: implied frame rate \{hrd_implied_fps(info)}, expected 30 (timing \{info.num_units_in_tick}/\{info.time_scale}, step \{info.pt_removal[1] - info.pt_removal[0]})",
    )
  }
  guard info.fixed_frame_rate else { fail("x264: fixed_frame_rate clear") }
  for d in info.pt_dpb {
    guard d == 0 else {
      fail("x264: baseline stream has dpb_output_delay \{d}")
    }
  }
  let nals = hrd_nals(stream)
  // No filler assertion here: both testsrc2 frames exceed the 200 kbit/s
  // target, so x264's CPB drains without ever needing to pad. The replay
  // below is the real compliance check (no underflow with no filler).
  // One declared-granule tolerance for the encoder's float rounding on the
  // pad boundary.
  hrd_cpb_replay("x264", hrd_au_sizes(nals), info, 1024L)
  hrd_check_widths("x264", info)
}

///|
test "hrd: MoonBit and x264 CBR streams agree field-by-field" {
  let mb_stream = match
    h264_encode_frames(
      hrd_fixture(),
      width=64,
      height=48,
      qp=26,
      vbv_maxrate=200000,
      vbv_bufsize=200000,
      fps=30,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let x_stream = @libavutil.av_base64_decode(sei_hrd_b64, 8192).unwrap()
  let mb = hrd_parse(mb_stream, "moonbit")
  let x = hrd_parse(x_stream, "x264")
  // Same nominal request (200 kbit/s into a 200 kbit CPB at 30 fps), so the
  // declared values agree on both sides — not merely structurally.
  guard mb.declared_rate == x.declared_rate else {
    fail(
      "declared rate \{mb.declared_rate} (moonbit) vs \{x.declared_rate} (x264)",
    )
  }
  guard mb.declared_size == x.declared_size else {
    fail(
      "declared size \{mb.declared_size} (moonbit) vs \{x.declared_size} (x264)",
    )
  }
  guard hrd_implied_fps(mb) == hrd_implied_fps(x) else {
    fail(
      "implied fps \{hrd_implied_fps(mb)} (moonbit) vs \{hrd_implied_fps(x)} (x264)",
    )
  }
  // The delay-width fields legitimately differ (this encoder: 24/16/4/0,
  // x264: 19/5/23/0 — its historic choice); each stream's own values must
  // merely fit its declared widths.
  hrd_check_widths("moonbit", mb)
  hrd_check_widths("x264", x)
  // And both pass the very same invariant, each under its own declarations.
  hrd_cpb_replay("moonbit", hrd_au_sizes(hrd_nals(mb_stream)), mb, 0L)
  hrd_cpb_replay("x264", hrd_au_sizes(hrd_nals(x_stream)), x, 1024L)
}
