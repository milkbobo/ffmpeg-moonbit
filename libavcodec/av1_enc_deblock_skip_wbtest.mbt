///|
/// §468d: deblocking on the SKIP-MIXED inter path (§458/§460).
///
/// This path decides per superblock whether to code a residual or a
/// GLOBALMV/NEWMV skip. The mask builder must therefore see the frame's
/// real per-SB skip flags: a skipped superblock has no residual, so its
/// inner transform edges are omitted. Getting that wrong desynchronises
/// the encoder's filtered reconstruction from the decoder's.

///|
fn dbs_src(w : Int32, h : Int32, salt : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let base = if (x / 16 + y / 16) % 2 == 0 { 118 } else { 126 }
      p[y * w + x] = base + (x * 7 + y * 3 + salt * 5) % 5
    }
  }
  p
}

///|
test "av1 enc deblock skip-mixed: baseline lf=0 is already exact" {
  // Establish that the skip-mixed path itself is exact before any
  // filtering — otherwise a filter mismatch would be misattributed.
  let w = 128
  let h = 64
  let cw = 64
  let ch = 32
  let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
  let dec = Av1Decoder::new()
  let src0 : Av1EncPlanes = {
    y: dbs_src(w, h, 1),
    y_stride: w,
    u: dbs_src(cw, ch, 2),
    uv_stride: cw,
    v: dbs_src(cw, ch, 3),
  }
  let (pkt0, _) = match enc.encode_frame(src0, base_q_idx=100) {
    Ok(v) => v
    Err(e) => fail("key: \{e}")
  }
  let _ = match dec.decode_packet(pkt0) {
    Ok(Some(f)) => f
    Ok(None) => fail("key hidden")
    Err(e) => fail("key decode: \{e}")
  }
  let src1 : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for y in 0..<h {
    for x in 0..<w {
      let ov = (x * 7 + y * 3) % 7 - 3
      let v = if x < 64 {
        src0.y[y * w + x] + ov
      } else {
        src0.y[y * w + (x + 4) % w] + ov
      }
      src1[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
    }
  }
  let src1p : Av1EncPlanes = {
    y: src1,
    y_stride: w,
    u: dbs_src(cw, ch, 6),
    uv_stride: cw,
    v: dbs_src(cw, ch, 7),
  }
  let (pkt1, exp1) = match
    enc.encode_frame(src1p, base_q_idx=100, skip_sad_pct=100, skip_uniform=true) {
    Ok(v) => v
    Err(e) => fail("inter: \{e}")
  }
  let got = match dec.decode_packet(pkt1) {
    Ok(Some(f)) => f
    Ok(None) => fail("inter hidden")
    Err(e) => fail("inter decode: \{e}")
  }
  let mut yd = 0
  for y in 0..<h {
    for x in 0..<w {
      if got.y[y * got.y_stride + x] != exp1.y[y * w + x] {
        yd = yd + 1
      }
    }
  }
  println("skip-mixed lf=0 baseline: Y=\{yd}")
  if yd != 0 {
    fail("skip-mixed baseline (lf=0) is not exact: Y=\{yd}")
  }
}

///|
test "av1 enc deblock skip-mixed: probe whether decoder filters a skip frame" {
  let w = 128
  let h = 64
  let cw = 64
  let ch = 32
  // Two encodes of the same skip-mixed inter frame: lf=0 and lf=32. If the
  // DECODER filters, its outputs must differ.
  let run = fn(lf : Int32) -> Av1FrameOutput raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let dec = Av1Decoder::new()
    let src0 : Av1EncPlanes = {
      y: dbs_src(w, h, 1),
      y_stride: w,
      u: dbs_src(cw, ch, 2),
      uv_stride: cw,
      v: dbs_src(cw, ch, 3),
    }
    let (pkt0, _) = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let _ = match dec.decode_packet(pkt0) {
      Ok(Some(f)) => f
      Ok(None) => fail("key hidden")
      Err(e) => fail("key decode: \{e}")
    }
    let src1 : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let ov = (x * 7 + y * 3) % 7 - 3
        let v = if x < 64 {
          src0.y[y * w + x] + ov
        } else {
          src0.y[y * w + (x + 4) % w] + ov
        }
        src1[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
      }
    }
    let src1p : Av1EncPlanes = {
      y: src1,
      y_stride: w,
      u: dbs_src(cw, ch, 6),
      uv_stride: cw,
      v: dbs_src(cw, ch, 7),
    }
    let (pkt1, _) = match
      enc.encode_frame(
        src1p,
        base_q_idx=100,
        skip_sad_pct=100,
        skip_uniform=true,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("lf=\{lf}: \{e}")
    }
    match dec.decode_packet(pkt1) {
      Ok(Some(f)) => f
      Ok(None) => fail("hidden")
      Err(e) => fail("decode lf=\{lf}: \{e}")
    }
  }
  let off = run(0)
  let on = run(32)
  let mut diff = 0
  for y in 0..<h {
    for x in 0..<w {
      if off.y[y * off.y_stride + x] != on.y[y * on.y_stride + x] {
        diff = diff + 1
      }
    }
  }
  println("PROBE decoder deblock on skip frame: \{diff} pixels differ")
}

///|
test "av1 enc deblock skip-mixed: decode equals expected with lf on" {
  let w = 128
  let h = 64
  let cw = 64
  let ch = 32
  for lf in [8, 32, 63] {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let dec = Av1Decoder::new()
    let src0 : Av1EncPlanes = {
      y: dbs_src(w, h, 1),
      y_stride: w,
      u: dbs_src(cw, ch, 2),
      uv_stride: cw,
      v: dbs_src(cw, ch, 3),
    }
    let (pkt0, _) = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let _ = match dec.decode_packet(pkt0) {
      Ok(Some(f)) => f
      Ok(None) => fail("key hidden")
      Err(e) => fail("key decode: \{e}")
    }
    // A source with one static half (skips) and one moving half
    // (residual): the frame then mixes skip=1 and skip=0 superblocks.
    let src1 : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let ov = (x * 7 + y * 3) % 7 - 3
        let v = if x < 64 {
          // static: the key reconstruction plus a tiny overlay
          src0.y[y * w + x] + ov
        } else {
          // moving: a horizontal shift
          src0.y[y * w + (x + 4) % w] + ov
        }
        src1[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
      }
    }
    let src1p : Av1EncPlanes = {
      y: src1,
      y_stride: w,
      u: dbs_src(cw, ch, 6),
      uv_stride: cw,
      v: dbs_src(cw, ch, 7),
    }
    let (pkt1, exp1) = match
      enc.encode_frame(
        src1p,
        base_q_idx=100,
        skip_sad_pct=100,
        skip_uniform=true,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("skip-mixed lf=\{lf}: \{e}")
    }
    let got = match dec.decode_packet(pkt1) {
      Ok(Some(f)) => f
      Ok(None) => fail("inter hidden")
      Err(e) => fail("inter decode lf=\{lf}: \{e}")
    }
    let mut yd = 0
    let mut uvd = 0
    for y in 0..<h {
      for x in 0..<w {
        if got.y[y * got.y_stride + x] != exp1.y[y * w + x] {
          yd = yd + 1
        }
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        if got.u[y * got.uv_stride + x] != exp1.u[y * cw + x] {
          uvd = uvd + 1
        }
        if got.v[y * got.uv_stride + x] != exp1.v[y * cw + x] {
          uvd = uvd + 1
        }
      }
    }
    println("skip-mixed lf=\{lf}: Y=\{yd} UV=\{uvd}")
    if yd != 0 || uvd != 0 {
      fail("skip-mixed lf=\{lf}: decode != expected (Y=\{yd} UV=\{uvd})")
    }
  }
}

///|
/// The skip-mixed path with lf on must actually differ from lf off
/// (otherwise the test above could pass without the filter running).
test "av1 enc deblock skip-mixed: the filter changes the reconstruction" {
  let w = 128
  let h = 64
  let cw = 64
  let ch = 32
  let run = fn(lf : Int32) -> Av1EncPlanes raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src0 : Av1EncPlanes = {
      y: dbs_src(w, h, 1),
      y_stride: w,
      u: dbs_src(cw, ch, 2),
      uv_stride: cw,
      v: dbs_src(cw, ch, 3),
    }
    let _ = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let src1 : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let ov = (x * 7 + y * 3) % 7 - 3
        let v = if x < 64 {
          src0.y[y * w + x] + ov
        } else {
          src0.y[y * w + (x + 4) % w] + ov
        }
        src1[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
      }
    }
    let src1p : Av1EncPlanes = {
      y: src1,
      y_stride: w,
      u: dbs_src(cw, ch, 6),
      uv_stride: cw,
      v: dbs_src(cw, ch, 7),
    }
    let (_, exp) = match
      enc.encode_frame(
        src1p,
        base_q_idx=100,
        skip_sad_pct=100,
        skip_uniform=true,
        loop_filter_level0=lf,
        loop_filter_level1=lf,
      ) {
      Ok(v) => v
      Err(e) => fail("lf=\{lf}: \{e}")
    }
    exp
  }
  let off = run(0)
  let on = run(32)
  let mut diff = 0
  let mut sum_off = 0
  let mut sum_on = 0
  for i in 0..<(w * h) {
    sum_off = sum_off + off.y[i]
    sum_on = sum_on + off.y[i]
    if off.y[i] != on.y[i] {
      diff = diff + 1
    }
  }
  ignore(sum_off)
  ignore(sum_on)
  println("skip-mixed deblock changed \{diff} luma pixels")
  if diff == 0 {
    fail("skip-mixed deblocking did not change the reconstruction")
  }
}

///|
/// Default lf=0 on the skip path must stay byte-identical.
test "av1 enc deblock skip-mixed: default lf=0 unchanged" {
  let w = 128
  let h = 64
  let cw = 64
  let ch = 32
  let run = fn(explicit : Bool) -> Bytes raise {
    let enc = Av1Encoder::new(Av1SeqEncConfig::default(width=w, height=h))
    let src0 : Av1EncPlanes = {
      y: dbs_src(w, h, 1),
      y_stride: w,
      u: dbs_src(cw, ch, 2),
      uv_stride: cw,
      v: dbs_src(cw, ch, 3),
    }
    let _ = match enc.encode_frame(src0, base_q_idx=100) {
      Ok(v) => v
      Err(e) => fail("key: \{e}")
    }
    let src1 : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let ov = (x * 7 + y * 3) % 7 - 3
        let v = if x < 64 {
          src0.y[y * w + x] + ov
        } else {
          src0.y[y * w + (x + 4) % w] + ov
        }
        src1[y * w + x] = if v < 0 { 0 } else if v > 255 { 255 } else { v }
      }
    }
    let src1p : Av1EncPlanes = {
      y: src1,
      y_stride: w,
      u: dbs_src(cw, ch, 6),
      uv_stride: cw,
      v: dbs_src(cw, ch, 7),
    }
    let r = if explicit {
      enc.encode_frame(
        src1p,
        base_q_idx=100,
        skip_sad_pct=100,
        skip_uniform=true,
        loop_filter_level0=0,
        loop_filter_level1=0,
      )
    } else {
      enc.encode_frame(
        src1p,
        base_q_idx=100,
        skip_sad_pct=100,
        skip_uniform=true,
      )
    }
    let (pkt, _) = match r {
      Ok(v) => v
      Err(e) => fail("inter: \{e}")
    }
    pkt
  }
  let a = run(false)
  let b = run(true)
  if a.length() != b.length() {
    fail("default vs explicit lf=0 skip-mixed length differs")
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("default vs explicit lf=0 skip-mixed byte \{i} differs")
    }
  }
}
