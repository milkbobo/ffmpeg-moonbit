// Blackbox tests for the streaming H.264 encoder (`§394`): frames pushed
// one at a time in display order must produce a byte-identical stream to
// the batch entries (flat QP I/P for both entropies, and the B schedule),
// access units must appear exactly when their references complete, and
// the guards (geometry, no second frame after finish semantics) hold.

///|
fn h264s_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 5 % (w - 16)
    let by = f * 3 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 2 + row * 3 + f) & 0xFF
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
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
fn h264s_concat(aus : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for au in aus {
    for i = 0; i < au.length(); i = i + 1 {
      out.push(au[i])
    }
  }
  Bytes::from_array(out[:])
}

///|
fn h264s_bytes_eq(a : Bytes, b : Bytes) -> Bool {
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
test "h264 stream: byte-identical to batch (cavlc I/P)" {
  let frames = h264s_fixture(96, 64, 6)
  let batch = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=24) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  let streamed = h264s_concat(aus)
  if !h264s_bytes_eq(streamed, batch) {
    fail(
      "streamed \{streamed.length()} B differs from batch \{batch.length()} B",
    )
  }
}

///|
test "h264 stream: byte-identical to batch (cabac I/P)" {
  let frames = h264s_fixture(96, 64, 5)
  let batch = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=26, cabac=true) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  let streamed = h264s_concat(aus)
  if !h264s_bytes_eq(streamed, batch) {
    fail(
      "streamed \{streamed.length()} B differs from batch \{batch.length()} B",
    )
  }
}

///|
test "h264 stream: byte-identical to batch (b schedule)" {
  let frames = h264s_fixture(96, 64, 7)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        aus.push(au)
      }
    Err(e) => fail(e)
  }
  let streamed = h264s_concat(aus)
  if !h264s_bytes_eq(streamed, batch) {
    fail(
      "streamed \{streamed.length()} B differs from batch \{batch.length()} B",
    )
  }
}

///|
test "h264 stream: access units appear when references complete" {
  let frames = h264s_fixture(96, 64, 6)
  // I/P schedule: one access unit per frame.
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=24) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for i, f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    if enc.drain().length() != 1 {
      fail("I/P push \{i} did not yield exactly one access unit")
    }
  }
  // B schedule: the IDR yields one, every odd position buffers (zero) and
  // every even position yields the P-B pair (two).
  let benc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=24,
      b_slices=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for i, f in frames {
    match benc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    let n = benc.drain().length()
    let want = if i == 0 { 1 } else if i % 2 == 1 { 0 } else { 2 }
    if n != want {
      fail("B push \{i} yielded \{n} access units, want \{want}")
    }
  }
  // The trailing odd position flushes as its own P access unit.
  match benc.finish() {
    Ok(tail) =>
      if tail.length() != 1 {
        fail("finish yielded \{tail.length()} access units, want 1")
      }
    Err(e) => fail(e)
  }
}

///|
test "h264 stream: reconstructions match the batch recons" {
  let frames = h264s_fixture(96, 64, 5)
  let batch_recon : Array[Bytes] = []
  match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      recon=batch_recon,
    ) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=96, height=64, qp=24) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    ignore(enc.drain())
  }
  if enc.recons.length() != batch_recon.length() {
    fail("recon count mismatch")
  }
  for i = 0; i < batch_recon.length(); i = i + 1 {
    if !h264s_bytes_eq(enc.recons[i], batch_recon[i]) {
      fail("recon \{i} differs from batch")
    }
  }
}

///|
test "h264 stream: decodes and rejects bad input" {
  let frames = h264s_fixture(64, 48, 4)
  let enc = match
    @libavcodec.H264StreamEncoder::open(width=64, height=48, qp=26) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let aus : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      aus.push(au)
    }
  }
  let dec = match
    @libavcodec.h264_decode_annexb_frames(h264s_concat(aus), false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 4 {
    fail("expected 4 frames, got \{dec.length()}")
  }
  // Wrong plane size is rejected.
  match enc.push_frame(frames[0].0, frames[0].1, b"\x00") {
    Err(_) => ()
    Ok(_) => fail("bad plane size accepted")
  }
  match @libavcodec.H264StreamEncoder::open(width=0, height=48) {
    Err(_) => ()
    Ok(_) => fail("zero width accepted")
  }
}
