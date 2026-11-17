// Blackbox tests for §434: encoder-side explicit weighted prediction for B
// slices (`weighted_bipred_idc = 1`). The decoder already applies explicit
// L0/L1 weights in `h264_b_compensate`; this slice fits both tables in the
// encoder, writes them in every B slice header, and mirrors the same weights
// in the encoder's private MC paths. Default-off streams are byte-identical.

///|
fn h264wb_fade_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let cw = w / 2
  let ch = h / 2
  for k in 0..<n {
    let gain = 32 - 2 * k
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    for row in 0..<h {
      for col in 0..<w {
        let base = (col * 3 + row * 5 + col * row % 17 * 2) % 170 + 60
        y[row * w + col] = (base * gain / 32).to_byte()
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        let ub = 96 + (col * 5 + row * 3) % 48
        let vb = 150 - (col * 3 + row * 5) % 40
        u[row * cw + col] = (ub * gain / 32).to_byte()
        v[row * cw + col] = (vb * gain / 32).to_byte()
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
/// Byte offset just past the next Annex B start code at or after `from`.
fn h264wb_next_start(s : Bytes, from : Int32) -> Int32 {
  let len = s.length()
  let mut i = from
  while i + 3 <= len {
    if s[i] == b'\x00' && s[i + 1] == b'\x00' {
      if s[i + 2] == b'\x01' {
        return i + 3
      }
      if i + 3 < len && s[i + 2] == b'\x00' && s[i + 3] == b'\x01' {
        return i + 4
      }
    }
    i = i + 1
  }
  -1
}

///|
/// Parse every PPS NAL and return the first `weighted_bipred_idc`.
fn h264wb_weighted_bipred(stream : Bytes) -> Int32 raise {
  let ps = @libavcodec.new_h264_param_sets()
  let mut pos = h264wb_next_start(stream, 0)
  while pos >= 0 && pos < stream.length() {
    let nal_type = stream[pos] & 0x1f
    let next = h264wb_next_start(stream, pos + 1)
    let end = if next < 0 { stream.length() } else { next - 3 }
    let rbsp = Bytes::from_array(stream.to_array()[pos + 1:end])
    let reader = @libavcodec.BitReader::new(rbsp)
    if nal_type == 7 {
      match @libavcodec.ff_h264_decode_seq_parameter_set(reader, ps, false) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
    } else if nal_type == 8 {
      match
        @libavcodec.ff_h264_decode_picture_parameter_set(
          reader,
          ps,
          rbsp.length() * 8,
        ) {
        Ok(_) =>
          for pps_opt in ps.pps_list {
            match pps_opt {
              Some(pps) => return pps.weighted_bipred_idc
              None => ()
            }
          }
        Err(e) => fail(e)
      }
    }
    pos = next
  }
  fail("no PPS NAL found")
}

///|
fn h264wb_eq(a : Bytes, b : Bytes) -> Bool {
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
/// A moving bright box sweeps right across a dim gradient: the B pictures
/// between two P anchors straddle the box, so list 0 and list 1 are genuinely
/// different predictors and the fitted weights are exercised on both lists.
fn h264wb_moving_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let cw = w / 2
  let ch = h / 2
  for f in 0..<n {
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    let bx = f * 8 % (w - 24)
    for row in 0..<h {
      for col in 0..<w {
        let base = (col + row * 2) % 64 + 32
        let val = if col >= bx && col < bx + 24 { base + 120 } else { base }
        y[row * w + col] = val.to_byte()
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        u[row * cw + col] = (96 + (col + f) % 32).to_byte()
        v[row * ch + col] = (128 + (row + f) % 32).to_byte()
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

// 1. Default off: the opt-in parameter is byte-identical to omitting it, and
//    the PPS keeps `weighted_bipred_idc = 0`.

///|
test "h264 enc weightp-b: default off is byte-identical" {
  let frames = h264wb_fade_fixture(64, 48, 6)
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      weightp_b=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let implicit = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_true(h264wb_eq(off, implicit))
  assert_eq(h264wb_weighted_bipred(off), 0)
}

// 2. Opt in: the PPS flag flips to 1, the stream stays decodable, the B
//    macroblocks are exercised, and the encoder reconstruction still equals
//    the decoder's filtered output (the weight table round-trips exactly).

///|
test "h264 enc weightp-b: PPS flag and decoder reconstruction (cavlc)" {
  let frames = h264wb_moving_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      weightp_b=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(h264wb_weighted_bipred(stream), 1)
  if stats.b_mbs <= 0 {
    fail("no B macroblocks coded")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 decoded frames, got \{dec.length()}")
  }
  if recon.length() != 5 {
    fail("expected 5 recons, got \{recon.length()}")
  }
  for i in 0..<recon.length() {
    let r = dec[i + 1]
    let src = recon[i]
    for row = 0; row < 64; row = row + 1 {
      for col = 0; col < 96; col = col + 1 {
        if src[row * 96 + col] != r.y[row * r.ystride + col].to_byte() {
          fail("weighted B recon mismatch at slot \{i}, \{row},\{col}")
        }
      }
    }
  }
}

// 3. CABAC path: the same opt-in flips the flag and decodes cleanly.

///|
test "h264 enc weightp-b: cabac round trip" {
  let frames = h264wb_moving_fixture(80, 48, 6)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=80,
      height=48,
      qp=24,
      b_slices=true,
      weightp_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_eq(h264wb_weighted_bipred(stream), 1)
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("cabac weighted B: expected 6 decoded frames")
  }
}

// 4. Streaming equals batch with the same flags (the table fit is per
//    picture and deterministic in both paths).

///|
test "h264 enc weightp-b: streaming equals batch" {
  let frames = h264wb_moving_fixture(64, 48, 6)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      weightp_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      weightp_b=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let se = enc
  let aus : Array[Bytes] = []
  for (y, u, v) in frames {
    match se.push_frame(y, u, v) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in se.drain() {
      aus.push(au)
    }
  }
  match se.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  let tail_bytes : Array[Byte] = []
  for au in aus {
    for b in au {
      tail_bytes.push(b)
    }
  }
  assert_true(h264wb_eq(batch, Bytes::from_array(tail_bytes[:])))
}

// 5. The weights actually change the coded stream versus the neutral path on
//    a fade (the fit leaves the identity table).

///|
test "h264 enc weightp-b: fade stream differs from neutral" {
  let frames = h264wb_fade_fixture(64, 48, 6)
  let on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      weightp_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_false(h264wb_eq(on, off))
}

// 6. weightp-b with b_slices off is accepted and changes nothing (no B
//    pictures exist to carry a table).

///|
test "h264 enc weightp-b: ignored when b slices off" {
  let frames = h264wb_fade_fixture(64, 48, 4)
  let on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
      weightp_b=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  assert_true(h264wb_eq(on, off))
  assert_eq(h264wb_weighted_bipred(on), 0)
}
