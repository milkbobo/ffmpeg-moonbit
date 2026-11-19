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
  // §460: the same frames with a per-frame chroma bias and chroma SAO on —
  // the Cb/Cr band offsets ride the bitstream (slice_sao_chroma_flag = 1).
  let biased : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  for k, f in frames {
    let cb : Int32 = k * 4
    let uk = plane(w >> 1, h >> 1, fn(i, j) {
      (f.1[j * (w >> 1) + i] + cb) & 255
    })
    let vk = plane(w >> 1, h >> 1, fn(i, j) {
      (f.2[j * (w >> 1) + i] - cb) & 255
    })
    biased.push((f.0, uk, vk))
  }
  let csao = match
    @libavcodec.hevc_encode_sequence(
      biased,
      width=w,
      height=h,
      crf=28.0,
      b_slices=true,
      sao_chroma=true,
    ) {
    Ok(s) => s
    Err(e) => fail("encode csao: \{e}")
  }
  let csao_path = dir + "/csao_ipb.265"
  @fs.write_bytes_to_file(csao_path, csao.annexb)
  println("wrote \{csao_path} (\{csao.annexb.length()} bytes)")
  // §461: 1-pixel horizontal stripes (phase-shifted in frame 2) with both
  // SAO flags on — the edge-offset candidates compete with the bands.
  let stripe = fn(
    phase : Int32,
  ) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
    let y = plane(w, h, fn(_i, j) {
      if ((j + phase) & 1) == 0 {
        172
      } else {
        84
      }
    })
    let c = plane(w >> 1, h >> 1, fn(_i, _j) { 128 })
    (y, c, c)
  }
  let eosao = match
    @libavcodec.hevc_encode_sequence(
      [stripe(0), stripe(1)],
      width=w,
      height=h,
      qp=38,
      sao_chroma=true,
      sao_eo=true,
    ) {
    Ok(s) => s
    Err(e) => fail("encode eosao: \{e}")
  }
  let eosao_path = dir + "/eosao_seq.265"
  @fs.write_bytes_to_file(eosao_path, eosao.annexb)
  println("wrote \{eosao_path} (\{eosao.annexb.length()} bytes)")
  // §462: the first four frames through the streaming ABR controller at a
  // tight budget (target 60 kbit/s at 30 fps, flat qp 22).
  let abr_enc = match
    @libavcodec.HevcStreamEncoder::open(
      width=w,
      height=h,
      qp=22,
      b_slices=true,
      target_bitrate=60000,
      fps=30,
    ) {
    Ok(e) => e
    Err(e) => fail("abr open: \{e}")
  }
  let first4b : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  for i in 0..<4 {
    first4b.push(frames[i])
  }
  let abr_parts : Array[Bytes] = []
  for f in first4b {
    match abr_enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in abr_enc.drain() {
          abr_parts.push(au)
        }
      Err(e) => fail("abr push: \{e}")
    }
  }
  match abr_enc.finish() {
    Ok(tail) =>
      for au in tail {
        abr_parts.push(au)
      }
    Err(e) => fail("abr finish: \{e}")
  }
  let abr_total : Array[Byte] = []
  for p2 in abr_parts {
    for b in p2 {
      abr_total.push(b)
    }
  }
  let abr_stream = Bytes::from_array(abr_total)
  let abr_path = dir + "/abr_ipb.265"
  @fs.write_bytes_to_file(abr_path, abr_stream)
  println("wrote \{abr_path} (\{abr_stream.length()} bytes)")
}
