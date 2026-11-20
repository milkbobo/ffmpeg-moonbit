///|
/// §468 step 1: the loop-filter levels now reach the frame header, so a
/// decoder that honours them produces a DIFFERENT picture than with
/// deblocking off. This pins the header path independently of the
/// encoder-side filter (step 2), which is not implemented yet.
///
/// The encoder's expected planes stay unfiltered in this step, so the
/// frame's usual "decode == expected" contract intentionally does not
/// hold here — that is why this test compares two decodes against each
/// other instead of against `expected`.
test "av1 loop filter: levels reach the decoder" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  // Blocky content with SMALL steps: deblocking only smooths gentle edges
  // (the filter gates on |p0-q0| against a limit derived from the level),
  // so a hard 160-value step would correctly not be filtered at all.
  let src_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = if (x / 16 + y / 16) % 2 == 0 { 120 } else { 128 }
      src_y[y * w + x] = base + (x * 3 + y * 5) % 5
    }
  }
  let src_u : FixedArray[Int32] = FixedArray::make(cw * ch, 128)
  let src_v : FixedArray[Int32] = FixedArray::make(cw * ch, 128)
  let decode_with = fn(lf : Int32) -> Av1FrameOutput raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src : Av1EncPlanes = {
      y: src_y,
      y_stride: w,
      u: src_u,
      uv_stride: cw,
      v: src_v,
    }
    let (pkt, _) = match
      enc.encode_frame(
        src,
        base_q_idx=100,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("encode lf=\{lf}: \{e}")
    }
    let dec = Av1Decoder::new()
    match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("hidden")
      Err(e) => fail("decode lf=\{lf}: \{e}")
    }
  }
  let off = decode_with(0)
  let on = decode_with(32)
  let mut diff = 0
  for y in 0..<h {
    for x in 0..<w {
      if off.y[y * off.y_stride + x] != on.y[y * on.y_stride + x] {
        diff = diff + 1
      }
    }
  }
  println("loop filter lf=32 vs lf=0: differing luma pixels = \{diff}")
  if diff == 0 {
    fail("loop-filter level did not reach the decoder (no pixels changed)")
  }
}

///|
/// Sharpness must also reach the header (it changes the filter response).
test "av1 loop filter: sharpness reaches the decoder" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = if (x / 16 + y / 16) % 2 == 0 { 118 } else { 126 }
      src_y[y * w + x] = base + (x * 7 + y * 3) % 5
    }
  }
  let src_u : FixedArray[Int32] = FixedArray::make(cw * ch, 128)
  let src_v : FixedArray[Int32] = FixedArray::make(cw * ch, 128)
  let decode_with = fn(sharp : Int32) -> Av1FrameOutput raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src : Av1EncPlanes = {
      y: src_y,
      y_stride: w,
      u: src_u,
      uv_stride: cw,
      v: src_v,
    }
    let (pkt, _) = match
      enc.encode_frame(
        src,
        base_q_idx=100,
        loop_filter_level0=32,
        loop_filter_level1=32,
        loop_filter_sharpness=sharp,
      ) {
      Ok(v) => v
      Err(e) => fail("encode sharp=\{sharp}: \{e}")
    }
    let dec = Av1Decoder::new()
    match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("hidden")
      Err(e) => fail("decode sharp=\{sharp}: \{e}")
    }
  }
  let s0 = decode_with(0)
  let s7 = decode_with(7)
  let mut diff = 0
  for y in 0..<h {
    for x in 0..<w {
      if s0.y[y * s0.y_stride + x] != s7.y[y * s7.y_stride + x] {
        diff = diff + 1
      }
    }
  }
  println("loop filter sharp=7 vs sharp=0: differing luma pixels = \{diff}")
  if diff == 0 {
    fail("sharpness did not reach the decoder (no pixels changed)")
  }
}

///|
/// Default (no loop-filter arguments) must be byte-identical to the
/// pre-§468 behaviour, i.e. lf=0 explicitly.
test "av1 loop filter: default matches explicit lf=0" {
  let w = 64
  let h = 64
  let cw = 32
  let ch = 32
  let src_y : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    src_y[i] = 80 + i * 7 % 96
  }
  let src_u = FixedArray::make(cw * ch, 128)
  let src_v = FixedArray::make(cw * ch, 128)
  let encode = fn(explicit : Bool) -> Bytes raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src : Av1EncPlanes = {
      y: src_y,
      y_stride: w,
      u: src_u,
      uv_stride: cw,
      v: src_v,
    }
    let r = if explicit {
      enc.encode_frame(
        src,
        base_q_idx=100,
        loop_filter_level0=0,
        loop_filter_level1=0,
      )
    } else {
      enc.encode_frame(src, base_q_idx=100)
    }
    let (pkt, _) = match r {
      Ok(v) => v
      Err(e) => fail("encode: \{e}")
    }
    pkt
  }
  let a = encode(false)
  let b = encode(true)
  if a.length() != b.length() {
    fail("default vs explicit lf=0 length differs")
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("default vs explicit lf=0 byte \{i} differs")
    }
  }
}
