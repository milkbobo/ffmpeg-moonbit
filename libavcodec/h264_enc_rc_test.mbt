// Blackbox tests for the two-pass average-bitrate rate control
// (`target_bytes`): convergence under the target, monotonic response,
// per-picture QPs (slice_qp_delta) through both entropy coders, the
// reconstruction invariant, and docker ffmpeg arbitration.

///|
/// Textured moving content, 64x48: gradient + 4x4 checkerboard + a roaming
/// bordered box, with drifting chroma - every picture has real residual at
/// every QP, so the stream size responds smoothly to the quantiser.
fn h264_rc_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 64
  let h = 48
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 3 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f * 5) & 0xFF
        if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
          s = (s + 40) & 0xFF
        }
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        let border = col == bx || col == bx + 15 || row == by || row == by + 15
        if inbox && border {
          s = 40
        } else if inbox {
          s = 220
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f) & 0x3F) + 96).to_byte())
        v.push((((row + f * 2) & 0x3F) + 96).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
fn h264_rc_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
/// Sum of absolute luma error of the unfiltered decode against the source
/// over the whole sequence - the quality side of the monotonicity checks.
fn h264_rc_sad(
  frames : Array[(Bytes, Bytes, Bytes)],
  stream : Bytes,
) -> Int32 raise {
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail("decode failed: \{e}")
  }
  if dec.length() != frames.length() {
    fail("expected \{frames.length()} frames, got \{dec.length()}")
  }
  let mut sum = 0
  for f, pic in dec {
    let (y, _, _) = frames[f]
    for row = 0; row < 48; row = row + 1 {
      for col = 0; col < 64; col = col + 1 {
        let d = y[row * 64 + col].to_int() - pic.y[row * pic.ystride + col]
        sum = sum + (if d < 0 { -d } else { d })
      }
    }
  }
  sum
}

///|
/// The encoder's per-picture reconstruction must equal the decoder's
/// unfiltered output with the rate-chosen QPs in force (slice_qp_delta
/// feeding the decoder's quantiser, chroma QP per picture, CABAC state
/// initialisation at the picture QP).
fn h264_rc_recon_invariant(
  name : String,
  stream : Bytes,
  recon : Array[Bytes],
  n : Int32,
) -> Unit raise {
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail("\{name}: decode failed: \{e}")
  }
  if dec.length() != n {
    fail("\{name}: expected \{n} frames, got \{dec.length()}")
  }
  if recon.length() != n - 1 {
    fail("\{name}: expected \{n - 1} P reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264_rc_md5(r) != h264_rc_md5(dec[i + 1].yuvp()) {
      fail("\{name} P frame \{i + 1}: encoder reconstruction != decoder")
    }
  }
}

///|
test "h264 rc: CAVLC lands under the target and responds monotonically" {
  let frames = h264_rc_fixture(5)
  let flat = match
    @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let flat_sad = h264_rc_sad(frames, flat)
  let t_small = flat.length() * 60 / 100
  let t_big = flat.length() * 140 / 100
  let stats_s = @libavcodec.H264EncStats::new()
  let recon_s : Array[Bytes] = []
  let small = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=t_small,
      stats=stats_s,
      recon=recon_s,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let stats_b = @libavcodec.H264EncStats::new()
  let big = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=t_big,
      stats=stats_b,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Both land at or under the target, and near it (the dither granularity
  // is one picture's QP step).
  if small.length() > t_small || small.length() * 100 < t_small * 85 {
    fail("small target \{t_small}: size \{small.length()}")
  }
  if big.length() > t_big || big.length() * 100 < t_big * 85 {
    fail("big target \{t_big}: size \{big.length()}")
  }
  // Monotone: smaller budget, smaller stream, worse fidelity.
  if small.length() >= flat.length() || flat.length() >= big.length() {
    fail(
      "sizes not monotone: \{small.length()} / \{flat.length()} / \{big.length()}",
    )
  }
  let small_sad = h264_rc_sad(frames, small)
  let big_sad = h264_rc_sad(frames, big)
  if small_sad <= flat_sad || flat_sad <= big_sad {
    fail("quality not monotone: \{small_sad} / \{flat_sad} / \{big_sad}")
  }
  // The chosen per-picture QPs (deterministic encoder: pinned). The big
  // budget's dither puts the trailing pictures one QP above the rest.
  if stats_s.frame_qps.length() != 5 || stats_b.frame_qps.length() != 5 {
    fail("frame QPs not reported per picture")
  }
  debug_inspect(
    stats_s.frame_qps,
    content=(
      #|[37, 37, 37, 37, 37]
    ),
  )
  debug_inspect(
    stats_b.frame_qps,
    content=(
      #|[20, 20, 20, 20, 21]
    ),
  )
  h264_rc_recon_invariant("cavlc-small", small, recon_s, 5)
}

///|
test "h264 rc: CABAC lands under the target with dithered QPs" {
  let frames = h264_rc_fixture(5)
  let flatc = match
    @libavcodec.h264_encode_frames_cabac(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let target = flatc.length() * 60 / 100
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=target,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stream.length() > target || stream.length() * 100 < target * 85 {
    fail("cabac target \{target}: size \{stream.length()}")
  }
  // I picture keeps the finer QP, the trailing pictures dither up.
  debug_inspect(
    stats.frame_qps,
    content=(
      #|[37, 38, 38, 38, 38]
    ),
  )
  h264_rc_recon_invariant("cabac", stream, recon, 5)
}

///|
/// The search bounds: an impossible budget saturates at the coarsest QP,
/// an unlimited one at the finest - both still legal streams.
test "h264 rc: saturates at the QP bounds" {
  let frames = h264_rc_fixture(3)
  let stats = @libavcodec.H264EncStats::new()
  let recon_tiny : Array[Bytes] = []
  let tiny = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=64,
      stats~,
      recon=recon_tiny,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  for q in stats.frame_qps {
    if q != 51 {
      fail(
        "impossible budget must saturate at QP 51, got \{Repr(stats.frame_qps)}",
      )
    }
  }
  if tiny.length() > 512 {
    fail("QP-51 saturation stream still \{tiny.length()} bytes")
  }
  h264_rc_recon_invariant("saturate-51", tiny, recon_tiny, 3)
  let stats2 = @libavcodec.H264EncStats::new()
  let huge = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=4000000,
      stats=stats2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  for q in stats2.frame_qps {
    if q != 10 {
      fail(
        "unlimited budget must saturate at QP 10, got \{Repr(stats2.frame_qps)}",
      )
    }
  }
  // The finest-QP extreme decodes cleanly too and dwarfs the coarsest.
  match @libavcodec.h264_decode_annexb_frames(huge, true) {
    Ok(f) => if f.length() != 3 { fail("expected 3 frames") }
    Err(e) => fail("QP-10 stream failed to decode: \{e}")
  }
  if huge.length() <= tiny.length() * 4 {
    fail("QP-10 stream \{huge.length()} B vs QP-51 \{tiny.length()} B")
  }
}

///|
/// External arbitration (docker ffmpeg 9.0.2): the rate-controlled streams
/// (per-picture QPs in every slice header) decode with zero warnings and
/// every deblocked frame matches this repository's decoder byte-for-byte.
test "h264 rc: ffmpeg-arbitrated CAVLC and CABAC streams" {
  let frames = h264_rc_fixture(5)
  let flatc = match
    @libavcodec.h264_encode_frames_cabac(frames, width=64, height=48, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let stats_c = @libavcodec.H264EncStats::new()
  let cavlc = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=flatc.length() * 60 / 100,
      stats=stats_c,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let stats_k = @libavcodec.H264EncStats::new()
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      target_bytes=flatc.length() * 60 / 100,
      stats=stats_k,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  ignore(stats_c)
  ignore(stats_k)
  let mut d1 = ""
  for i = 0; i < cavlc.length(); i = i + 1 {
    d1 = d1 + (cavlc[i].to_int() & 0xFF).to_string() + ","
  }
  println("RCARB:\{d1}")
  let filtered = match @libavcodec.h264_decode_annexb_frames(cavlc, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins1 = [
    "4066ce148aa7e45fa58ef43c126ff420", "19474e69984e0fa7fea91a2a84796e72", "9b7d79a0ccec8f155b3f7d925fde70f0",
    "f64428f141b578e506e09d0e29e61039", "b64d40a425f1a97148402626e732ba86",
  ]
  for i, f in filtered {
    inspect(h264_rc_md5(f.yuvp()), content=pins1[i])
  }
  let mut d2 = ""
  for i = 0; i < cabac.length(); i = i + 1 {
    d2 = d2 + (cabac[i].to_int() & 0xFF).to_string() + ","
  }
  println("RCCARB:\{d2}")
  let filtered2 = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins2 = [
    "6cbb109497c9e5e741df6f560bd86e61", "17016af44af83a39a611a7798d9305b2", "70e87b4d7f0d6f202592e5c7eee260e6",
    "b73b57f24e951ac7551c7c6cbf82d76c", "378d4980c759665b22991f6d89e59987",
  ]
  for i, f in filtered2 {
    inspect(h264_rc_md5(f.yuvp()), content=pins2[i])
  }
}

///|
/// Mixed-activity content, 64x48: the left half is a flat plateau whose
/// level drifts per picture, the right half carries gradient +
/// checkerboard texture and a roaming box - per-MB activity spans well
/// beyond the +-25% adaptive-quantisation band in both directions.
fn h264_aq_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 64
  let h = 48
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = 32 + f * 4 % 16
    let by = f * 3 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let s = if col < 32 {
          100 + f * 2
        } else {
          let mut t = (col * 2 + row * 3 + f * 5) & 0xFF
          if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
            t = (t + 40) & 0xFF
          }
          let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
          let border = col == bx ||
            col == bx + 15 ||
            row == by ||
            row == by + 15
          if inbox && border {
            40
          } else if inbox {
            220
          } else {
            t
          }
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f) & 0x3F) + 96).to_byte())
        v.push((((row + f * 2) & 0x3F) + 96).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
/// Adaptive quantisation through the CAVLC writer: with AQ off no
/// `mb_qp_delta` is signalled; with AQ on the mixed-activity fixture drives
/// non-zero deltas that accumulate onto the decoder's running QP (not the
/// slice QP), the encoder reconstruction stays identical to the unfiltered
/// decode, and AQ stacks on the rate-controlled picture QPs.
test "h264 aq: CAVLC macroblock QP deltas ride the running QP" {
  let frames = h264_aq_fixture(4)
  let stats_off = @libavcodec.H264EncStats::new()
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      stats=stats_off,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats_off.dqp_mbs != 0 {
    fail("aq off must not signal any mb_qp_delta")
  }
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.dqp_mbs == 0 {
    fail("aq on must signal mb_qp_delta on mixed activity")
  }
  debug_inspect(stats.dqp_mbs, content="22")
  if h264_rc_md5(stream) == h264_rc_md5(off) {
    fail("aq must change the bitstream")
  }
  h264_rc_recon_invariant("cavlc-aq", stream, recon, 4)
  // AQ stacks on the rate-controlled picture QPs: still under the target,
  // still signalling deltas, still reconstruction-exact.
  let stats_rc = @libavcodec.H264EncStats::new()
  let recon_rc : Array[Bytes] = []
  let target = off.length() * 70 / 100
  let rc = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
      target_bytes=target,
      stats=stats_rc,
      recon=recon_rc,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if rc.length() > target {
    fail("aq+rc over target: \{rc.length()} > \{target}")
  }
  if stats_rc.dqp_mbs == 0 {
    fail("aq+rc must keep signalling deltas")
  }
  h264_rc_recon_invariant("cavlc-aq-rc", rc, recon_rc, 4)
}

///|
/// The CABAC twin: the dqp ladder's zero bin rides `last_qscale_diff` and
/// the mirror's running qscale, so consecutive adjusted macroblocks must
/// not drift the decoder's quantiser.
test "h264 aq: CABAC macroblock QP deltas ride the running QP" {
  let frames = h264_aq_fixture(4)
  let stats_off = @libavcodec.H264EncStats::new()
  let off = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      stats=stats_off,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats_off.dqp_mbs != 0 {
    fail("aq off must not signal any mb_qp_delta")
  }
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.dqp_mbs == 0 {
    fail("aq on must signal mb_qp_delta on mixed activity")
  }
  debug_inspect(stats.dqp_mbs, content="20")
  if h264_rc_md5(stream) == h264_rc_md5(off) {
    fail("aq must change the bitstream")
  }
  h264_rc_recon_invariant("cabac-aq", stream, recon, 4)
  let stats_rc = @libavcodec.H264EncStats::new()
  let recon_rc : Array[Bytes] = []
  let target = off.length() * 70 / 100
  let rc = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
      target_bytes=target,
      stats=stats_rc,
      recon=recon_rc,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if rc.length() > target {
    fail("aq+rc over target: \{rc.length()} > \{target}")
  }
  if stats_rc.dqp_mbs == 0 {
    fail("aq+rc must keep signalling deltas")
  }
  h264_rc_recon_invariant("cabac-aq-rc", rc, recon_rc, 4)
}

///|
/// External arbitration (docker ffmpeg 9.0.2): the adaptive-quantisation
/// streams (per-MB `mb_qp_delta` against the running QP) decode with zero
/// warnings and every deblocked frame matches this repository's decoder
/// byte-for-byte.
test "h264 aq: ffmpeg-arbitrated CAVLC and CABAC streams" {
  let frames = h264_aq_fixture(4)
  let cavlc = match
    @libavcodec.h264_encode_frames(frames, width=64, height=48, qp=26, aq=true) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      aq=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // Both dumps precede every pin assertion so the arbitration harvest sees
  // both streams even while the pins are still placeholders.
  let mut d1 = ""
  for i = 0; i < cavlc.length(); i = i + 1 {
    d1 = d1 + (cavlc[i].to_int() & 0xFF).to_string() + ","
  }
  println("AQARB:\{d1}")
  let mut d2 = ""
  for i = 0; i < cabac.length(); i = i + 1 {
    d2 = d2 + (cabac[i].to_int() & 0xFF).to_string() + ","
  }
  println("AQCARB:\{d2}")
  let filtered = match @libavcodec.h264_decode_annexb_frames(cavlc, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins1 = [
    "ce0e7afa003dc3e3b1ff1d059c2881ba", "0208a80308044b6cfca575383f6f96f9", "33e25d1a78452d138f69b33ca2dac127",
    "f7032eb288f2d2234ed9759bf111ed86",
  ]
  for i, f in filtered {
    inspect(h264_rc_md5(f.yuvp()), content=pins1[i])
  }
  let filtered2 = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins2 = [
    "873a22e67ac6a024cd7613ffe7c52150", "c3415303a9b57054726f29a66f3115e5", "026176483fd929652dc879cee0cb4f21",
    "008d85e1f417fc6c9bf5f4a47ee08aea",
  ]
  for i, f in filtered2 {
    inspect(h264_rc_md5(f.yuvp()), content=pins2[i])
  }
}

///|
/// Per-frame re-sloped diagonal stripes: the gradient direction changes
/// every frame (not a pure translation), so inter prediction cannot
/// follow, while the diagonal 4x4 predictors (DDL/DDR/VL/VR) track the
/// stripes that the 16x16 V/H/DC/Plane modes cannot. Drives Intra4x4 in P
/// slices both with and without transform_8x8_mode_flag.
fn h264_i4_stripe_fixture() -> Array[(Bytes, Bytes, Bytes)] {
  let w = 64
  let h = 48
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<4 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let a = 1 + f % 3
    let b = 1 + f * 2 % 3
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        y.push(((col * a + row * b + f * 13) & 0xFF).to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((96 + ((col + row + f) & 0x1F)).to_byte())
        v.push((160 - ((row + f) & 0x1F)).to_byte())
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
/// Fine checker texture with a roaming hard-edged box: with the 8x8
/// transform enabled the pure-8x8 inter residuals code the 4x4 checker
/// poorly, so six P macroblocks per run flip to Intra_NxN (mb_type 5) —
/// sixteen independently predicted 4x4 blocks. Both entropy coders share
/// the plan decision, so both must agree on the counts and reconstruct
/// exactly what the own decoder produces.
test "h264 i4p: fine texture wins Intra4x4 macroblocks in P slices" {
  let frames = h264_rc_fixture(4)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats.i4p_mbs, content="6")
  debug_inspect(stats.i16_mbs, content="0")
  debug_inspect(stats.i8p_mbs, content="0")
  debug_inspect(stream.length(), content="2624")
  h264_rc_recon_invariant("cavlc-i4p", stream, recon, 4)
  let stats2 = @libavcodec.H264EncStats::new()
  let recon2 : Array[Bytes] = []
  let stream2 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
      stats=stats2,
      recon=recon2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats2.i4p_mbs, content="6")
  debug_inspect(stream2.length(), content="2464")
  h264_rc_recon_invariant("cabac-i4p", stream2, recon2, 4)
}

///|
/// The ffmpeg 9.0.0-series arbitration pins: both entropy coders' I4
/// streams decode (docker ffmpeg 9.0.2, zero stderr warnings) to exactly
/// these filtered frame md5s.
test "h264 i4p: ffmpeg-arbitrated CAVLC and CABAC streams" {
  let frames = h264_rc_fixture(4)
  let cavlc = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let cabac = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let filtered = match @libavcodec.h264_decode_annexb_frames(cavlc, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins1 = [
    "292edd53ff3434561e2e1d737c563c98", "8a7aa2516bb38166b5cd54291b627e5a", "17ad04874b4fa8fd78abad92cac51eec",
    "1ecf97c48d15f640f7cf4e313b64d92e",
  ]
  for i, f in filtered {
    inspect(h264_rc_md5(f.yuvp()), content=pins1[i])
  }
  let filtered2 = match @libavcodec.h264_decode_annexb_frames(cabac, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  // CABAC shares the plan decision, so the reconstructions — and hence the
  // arbitrated md5s — are identical to the CAVLC twin's.
  for i, f in filtered2 {
    inspect(h264_rc_md5(f.yuvp()), content=pins1[i])
  }
}

///|
/// The no-transform-8x8 path: I4 macroblocks in a stream whose PPS has no
/// transform_8x8_mode_flag (no transform_size_8x8_flag bit at all). The
/// stripe fixture's re-sloped gradients defeat motion, and the diagonal
/// detail favours the sixteen 4x4 predictors over the single 16x16 mode —
/// so I4 wins even without the 8x8 transform in the mix. Arbitrated by
/// docker ffmpeg 9.0.2 (zero warnings) against the pins below.
test "h264 i4p: Intra4x4 without the 8x8 transform" {
  let frames = h264_i4_stripe_fixture()
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats.i4p_mbs, content="14")
  debug_inspect(stats.i16_mbs, content="20")
  debug_inspect(stats.i8p_mbs, content="0")
  debug_inspect(stream.length(), content="1119")
  h264_rc_recon_invariant("cavlc-i4p-no8", stream, recon, 4)
  let stats2 = @libavcodec.H264EncStats::new()
  let recon2 : Array[Bytes] = []
  let stream2 = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      stats=stats2,
      recon=recon2,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats2.i4p_mbs, content="14")
  debug_inspect(stream2.length(), content="1010")
  h264_rc_recon_invariant("cabac-i4p-no8", stream2, recon2, 4)
  let filtered = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins = [
    "db4f9f5a354f60a75388bb1762ba6a23", "b424fb90398370e87931cd7accaa10c3", "9ee05f06bfd4eac7e3ad08ca057369f2",
    "d98b68f3f945aa79d407a816d73d6b5c",
  ]
  for i, f in filtered {
    inspect(h264_rc_md5(f.yuvp()), content=pins[i])
  }
  let filtered2 = match @libavcodec.h264_decode_annexb_frames(stream2, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  for i, f in filtered2 {
    inspect(h264_rc_md5(f.yuvp()), content=pins[i])
  }
}

///|
/// `intra4x4_in_p` is independent of `intra_in_p`: with only the former
/// enabled, P slices may pick Intra4x4 while Intra16x16/8x8 stay gated
/// off. Pins the documented field semantics.
test "h264 i4p: intra4x4_in_p is independent of intra_in_p" {
  let frames = h264_i4_stripe_fixture()
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra4x4_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats.i4p_mbs, content="34")
  debug_inspect(stats.i16_mbs, content="0")
  debug_inspect(stats.i8p_mbs, content="0")
  h264_rc_recon_invariant("i4p-indep", stream, recon, 4)
}

///|
/// Stripes plus the 8x8 transform: I8x8, I16x16 and I4x4 all win somewhere
/// in the same stream. I8 winners must raise the running `best_cost`, so a
/// later I4 candidate only takes the macroblock by beating the I8 price —
/// this pins the I8-win/I4-compete chain of `decide_plan`.
test "h264 i4p: stripe with 8x8 mixes I8 and I4 winners" {
  let frames = h264_i4_stripe_fixture()
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      intra4x4_in_p=true,
      dct8x8=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  debug_inspect(stats.i4p_mbs, content="4")
  debug_inspect(stats.i16_mbs, content="14")
  debug_inspect(stats.i8p_mbs, content="16")
  h264_rc_recon_invariant("i4p-mixed", stream, recon, 4)
}

///|
/// The default chain must be byte-identical to the explicit opt-out: with
/// `intra4x4_in_p` absent the encoder emits zero I4 macroblocks and the
/// stream equals the §389-era baseline bit-for-bit.
test "h264 i4p: intra4x4_in_p is opt-in (baseline unchanged)" {
  let frames = h264_rc_fixture(4)
  let stats = @libavcodec.H264EncStats::new()
  let default_stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      dct8x8=true,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i4p_mbs != 0 {
    fail("default chain emitted \{stats.i4p_mbs} I4 macroblocks")
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      intra_in_p=true,
      dct8x8=true,
      intra4x4_in_p=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if default_stream.length() != off.length() {
    fail("default stream length differs from intra4x4_in_p=false")
  }
  for i = 0; i < off.length(); i = i + 1 {
    if default_stream[i] != off[i] {
      fail("default stream byte \{i} differs from intra4x4_in_p=false")
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(default_stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 4 {
    fail("baseline stream failed to decode")
  }
}

///|
test "h264 aq strength: defaults, zero and reconstruction at QP boundaries" {
  let frames = h264_aq_fixture(3)
  for cabac in [false, true] {
    fn encode(
      cabac : Bool,
      aq : Bool,
      strength : Int32,
      qp : Int32,
      recon : Array[Bytes],
      stats : @libavcodec.H264EncStats,
    ) -> Bytes raise {
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          aq~,
          aq_strength=strength,
          qp~,
          recon~,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=64,
          height=48,
          aq~,
          aq_strength=strength,
          qp~,
          recon~,
          stats~,
        )
      }
      match result {
        Ok(s) => s
        Err(e) => fail(e)
      }
    }
    let off = encode(cabac, false, 1, 26, [], @libavcodec.H264EncStats::new())
    let zero_stats = @libavcodec.H264EncStats::new()
    assert_eq(encode(cabac, true, 0, 26, [], zero_stats), off)
    assert_eq(zero_stats.dqp_mbs, 0)
    assert_eq(
      encode(cabac, false, 6, 26, [], @libavcodec.H264EncStats::new()),
      off,
    )
    let default_stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          aq=true,
        )
      } else {
        @libavcodec.h264_encode_frames(frames, width=64, height=48, aq=true)
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_eq(
      encode(cabac, true, 1, 26, [], @libavcodec.H264EncStats::new()),
      default_stream,
    )
    let mut changed = false
    for qp in [0, 26, 51] {
      let recon : Array[Bytes] = []
      let stats = @libavcodec.H264EncStats::new()
      let stream = encode(cabac, true, 6, qp, recon, stats)
      h264_rc_recon_invariant("AQ strength 6", stream, recon, 3)
      if qp == 26 {
        changed = stream != default_stream
        assert_true(stats.dqp_mbs > 0)
      }
    }
    assert_true(changed)
    for strength in [-1, 7, 2147483647] {
      let result = if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          aq_strength=strength,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=64,
          height=48,
          aq_strength=strength,
        )
      }
      assert_true(result is Err(_))
    }
  }
}
