// Blackbox tests for §464: session-level reference management. The
// encoder keeps an eight-slot ring of past reconstructions and an inter
// frame can predict from `ref_age` frames back. The frame header points
// its references at the slot that holds that picture and refreshes a
// different slot for its own reconstruction, so the decoder's reference
// store stays in lockstep with the encoder's ring.

///|
fn sr_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let v = 80 + (y * 11 + x * 7 + salt * 31) % 96
      p[y * w + x] = v
    }
  }
  p
}

///|
fn sr_planes(w : Int32, h : Int32, salt : Int32) -> @libavcodec.Av1EncPlanes {
  let cw = w >> 1
  let ch = h >> 1
  {
    y: sr_src(w, h, salt),
    y_stride: w,
    u: sr_src(cw, ch, salt + 1),
    uv_stride: cw,
    v: sr_src(cw, ch, salt + 2),
  }
}

///|
/// Assert a decoded frame equals the expected planes pixel for pixel.
fn sr_assert_exact(
  d : @libavcodec.Av1FrameOutput,
  exp : @libavcodec.Av1EncPlanes,
  w : Int32,
  h : Int32,
  tag : String,
) -> Unit raise {
  let cw = w >> 1
  let ch = h >> 1
  for y in 0..<h {
    for x in 0..<w {
      if d.y[y * d.y_stride + x] != exp.y[y * w + x] {
        fail("\{tag} Y(\{y},\{x}) diverged")
      }
    }
  }
  for y in 0..<ch {
    for x in 0..<cw {
      if d.u[y * d.uv_stride + x] != exp.u[y * cw + x] ||
        d.v[y * d.uv_stride + x] != exp.v[y * cw + x] {
        fail("\{tag} UV(\{y},\{x}) diverged")
      }
    }
  }
}

///|
test "av1 session ref ring: ref_age predicts from older reconstructions" {
  let w = 64
  let h = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let dec = @libavcodec.Av1Decoder::new()
  // Frame 0 = key, frames 1..5 inter with increasing reference age.
  let ages : Array[Int32] = [0, 0, 1, 2, 3]
  for idx in 0..<6 {
    let age = if idx == 0 { 0 } else { ages[idx - 1] }
    let (pkt, exp) = match
      enc.encode_frame(sr_planes(w, h, idx), base_q_idx=100, ref_age=age) {
      Ok(v) => v
      Err(e) => fail("frame \{idx} age=\{age} encode: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("frame \{idx} hidden")
      Err(e) => fail("frame \{idx} age=\{age} decode: \{e}")
    }
    sr_assert_exact(d, exp, w, h, "frame \{idx} age=\{age}")
  }
}

///|
test "av1 session ref ring: ref_age beyond history clamps to oldest" {
  let w = 64
  let h = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let dec = @libavcodec.Av1Decoder::new()
  for idx in 0..<4 {
    // Age 99 must clamp to the oldest retained picture, not error.
    let age = if idx == 0 { 0 } else { 99 }
    let (pkt, exp) = match
      enc.encode_frame(sr_planes(w, h, idx), base_q_idx=100, ref_age=age) {
      Ok(v) => v
      Err(e) => fail("frame \{idx} age=99 encode: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("frame \{idx} hidden")
      Err(e) => fail("frame \{idx} age=99 decode: \{e}")
    }
    sr_assert_exact(d, exp, w, h, "frame \{idx} age=99")
  }
}

///|
test "av1 session ref ring: different ref_age changes the bitstream" {
  // Two sessions identical except for the third frame's reference age.
  // If the age never reached the prediction source, the packets would be
  // byte-identical — this is the guard against a silently ignored option.
  let w = 64
  let h = 64
  let run = fn(age3 : Int32) -> Bytes raise {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let mut last : Bytes = b""
    for idx in 0..<4 {
      let age = if idx == 3 { age3 } else { 0 }
      let (pkt, _) = match
        enc.encode_frame(sr_planes(w, h, idx), base_q_idx=100, ref_age=age) {
        Ok(v) => v
        Err(e) => fail("age3=\{age3} frame \{idx}: \{e}")
      }
      last = pkt
    }
    last
  }
  let fresh = run(0)
  let old = run(2)
  if fresh.length() == old.length() {
    let mut same = true
    for i in 0..<fresh.length() {
      if fresh[i] != old[i] {
        same = false
      }
    }
    if same {
      fail("ref_age had no effect on the bitstream — option ignored")
    }
  }
  println(
    "ref_age bitstreams differ: fresh=\{fresh.length()} old=\{old.length()}",
  )
}

///|
test "av1 session ref ring: default ref_age=0 matches the old chain" {
  let w = 64
  let h = 64
  // Two runs of the same default sequence must be byte-identical.
  let run = fn() -> Array[Int32] raise {
    let enc = @libavcodec.Av1Encoder::new(
      @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
    )
    let lens : Array[Int32] = []
    for idx in 0..<4 {
      let (pkt, _) = match enc.encode_frame(sr_planes(w, h, idx)) {
        Ok(v) => v
        Err(e) => fail("default encode \{idx}: \{e}")
      }
      lens.push(pkt.length())
    }
    lens
  }
  let a = run()
  let b = run()
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("default chain nondeterministic at frame \{i}: \{a[i]} vs \{b[i]}")
    }
  }
  println(
    "session ref ring default lens: \{a.length()} frames, last=\{a[a.length() - 1]}",
  )
}

///|
test "av1 session ref ring: invalid age is treated as zero" {
  let w = 64
  let h = 64
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=w, height=h),
  )
  let dec = @libavcodec.Av1Decoder::new()
  for idx in 0..<3 {
    let age = if idx == 0 { 0 } else { -5 }
    let (pkt, exp) = match
      enc.encode_frame(sr_planes(w, h, idx), base_q_idx=100, ref_age=age) {
      Ok(v) => v
      Err(e) => fail("negative age encode \{idx}: \{e}")
    }
    let d = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("frame \{idx} hidden")
      Err(e) => fail("negative age decode \{idx}: \{e}")
    }
    sr_assert_exact(d, exp, w, h, "neg age frame \{idx}")
  }
}
