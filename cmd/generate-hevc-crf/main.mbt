///|
/// Generate the pure-MoonBit HEVC CRF I/P/B streams for black-box arbitration.
/// Usage: moon run cmd/generate-hevc-crf <existing scratch dir>
///
/// Writes `crf28_ipb.265` (4 frames, batch entry; display order I0, B1, P2,
/// P3) and `crf28_ipb5_stream.265` (5 frames — an odd length, the §459 B
/// schedule — through `HevcStreamEncoder`, byte-equal to the batch entry).
/// Decode with FFmpeg 9.0.2 and `-f framemd5 -` to regenerate the reference
/// hashes in `libavcodec/hevc_enc_crf_test.mbt` and
/// `libavcodec/hevc_enc_stream_test.mbt`.

///|
fn plane(
  w : Int32,
  h : Int32,
  f : (Int32, Int32) -> Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for j in 0..<h {
    for i in 0..<w {
      out[j * w + i] = f(i, j)
    }
  }
  out
}

///|
fn clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn main raise {
  let args = @env.args()
  guard args.length() == 2 else {
    fail("usage: generate-hevc-crf <existing scratch dir>")
  }
  let dir = args[1]
  let w = 64
  let h = 64
  // The classic 8-bit gradient + translation vector (same samples as the
  // Main10 generator, & 255 instead of & 1023).
  let y0 = plane(w, h, fn(i, j) { (i * 13 + j * 9 + 128) & 255 })
  let u0 = plane(w >> 1, h >> 1, fn(i, j) { (i * 17 + j * 11 + 44) & 255 })
  let v0 = plane(w >> 1, h >> 1, fn(i, j) { (i * 7 + j * 19 + 188) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = plane(w, h, fn(i, j) {
      y0[clamp(j + dy, h) * w + clamp(i + dx, w)]
    })
    let uk = plane(w >> 1, h >> 1, fn(i, j) {
      u0[clamp(j + dy, h >> 1) * (w >> 1) + clamp(i + dx, w >> 1)]
    })
    let vk = plane(w >> 1, h >> 1, fn(i, j) {
      v0[clamp(j + dy, h >> 1) * (w >> 1) + clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  // One more translation frame so the odd-length §459 schedule (5 frames)
  // can be arbitrated through the streaming encoder.
  let y5 = plane(w, h, fn(i, j) { y0[clamp(j + 10, h) * w + clamp(i + 20, w)] })
  let u5 = plane(w >> 1, h >> 1, fn(i, j) {
    u0[clamp(j + 10, h >> 1) * (w >> 1) + clamp(i + 20, w >> 1)]
  })
  let v5 = plane(w >> 1, h >> 1, fn(i, j) {
    v0[clamp(j + 10, h >> 1) * (w >> 1) + clamp(i + 20, w >> 1)]
  })
  frames.push((y5, u5, v5))
  // The pinned 4-frame batch stream (hevc_enc_crf_test.mbt's MD5s).
  let first4 : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  for i in 0..<4 {
    first4.push(frames[i])
  }
  let seq = match
    @libavcodec.hevc_encode_sequence(
      first4,
      width=w,
      height=h,
      crf=28.0,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail("encode: \{e}")
  }
  let stream_path = dir + "/crf28_ipb.265"
  @fs.write_bytes_to_file(stream_path, seq.annexb)
  println("wrote \{stream_path} (\{seq.annexb.length()} bytes)")
  for f in seq.frames {
    println(
      "frame poc=\{f.poc} slice=\{f.slice_type} bytes=\{f.annexb.length()}",
    )
  }
  // §459: the same five frames through the streaming encoder (all of them,
  // odd length) — byte-equal to the batch entry by contract.
  let batch5 = match
    @libavcodec.hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      crf=28.0,
      b_slices=true,
    ) {
    Ok(s) => s.annexb
    Err(e) => fail("encode5: \{e}")
  }
  let enc = match
    @libavcodec.HevcStreamEncoder::open(
      width=w,
      height=h,
      crf=28.0,
      b_slices=true,
    ) {
    Ok(e) => e
    Err(e) => fail("stream open: \{e}")
  }
  let parts : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in enc.drain() {
          parts.push(au)
        }
      Err(e) => fail("stream push: \{e}")
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        parts.push(au)
      }
    Err(e) => fail("stream finish: \{e}")
  }
  let total : Array[Byte] = []
  for p in parts {
    for b in p {
      total.push(b)
    }
  }
  let streamed = Bytes::from_array(total)
  if streamed != batch5 {
    fail("streaming output differs from the batch entry")
  }
  let stream5_path = dir + "/crf28_ipb5_stream.265"
  @fs.write_bytes_to_file(stream5_path, streamed)
  println("wrote \{stream5_path} (\{streamed.length()} bytes, == batch5)")
}
