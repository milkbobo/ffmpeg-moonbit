///|
/// HEVC P-slice encoder, black-box arbitration: the pure-MoonBit I+P stream is
/// decoded by reference FFmpeg 9.0.2 (`framemd5` of the rawvideo yuv420p
/// output, pinned below) and by this repository's own decoder — both must
/// agree byte-for-byte. The frame generator is recorded in
/// `scripts/generate_hevc_p_vectors.mbtx` (4 frames, 64x64, qp 26, frame k
/// shifted by (4k, 2k) from the gradient seed).
///
/// Pin regeneration: run that generator, decode `p_i.265` with
/// `docker run --rm --network none -v <dir>:/work --entrypoint ffmpeg
/// linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -xerror
/// -i /work/p_i.265 -f framemd5 -`, then use the four `hash` fields.

///|
fn hevc_enc_p_make_plane(
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
fn hevc_enc_p_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_p_md5(data : Bytes) -> String {
  let md5 = @libavutil.av_md5_alloc()
  @libavutil.av_md5_init(md5)
  @libavutil.av_md5_update(md5, data, data.length())
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_final(md5, digest)
  let h = "0123456789abcdef"
  let mut out = ""
  for b in digest {
    let v = b.to_int()
    out = out +
      h.get_char((v >> 4) & 15).unwrap().to_string() +
      h.get_char(v & 15).unwrap().to_string()
  }
  out
}

///|
fn hevc_enc_p_arb_frames() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_p_make_plane(w, h, fn(i, j) { (i * 3 + j * 2 + 40) & 255 })
  let u0 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 5 + j * 3) & 255 })
  let v0 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 7 + j) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_p_make_plane(w, h, fn(i, j) {
      y0[hevc_enc_p_clamp(j + dy, h) * w + hevc_enc_p_clamp(i + dx, w)]
    })
    let uk = hevc_enc_p_make_plane(32, 32, fn(i, j) {
      u0[hevc_enc_p_clamp(j + dy, 32) * 32 + hevc_enc_p_clamp(i + dx, 32)]
    })
    let vk = hevc_enc_p_make_plane(32, 32, fn(i, j) {
      v0[hevc_enc_p_clamp(j + dy, 32) * 32 + hevc_enc_p_clamp(i + dx, 32)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
test "hevc enc p: ffmpeg arbitration framemd5 pins" {
  let frames = hevc_enc_p_arb_frames()
  let seq = match
    @libavcodec.hevc_encode_sequence(frames, width=64, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let pins = [
    "5339917ee1981843254cc740e4d00157", "5d67d379e920e467241e0219b3e020dc", "8caabf3aeaa269c6fa3d10dce5a6b37d",
    "14cd0ecf168b8310fd83e4f26c38b04b",
  ]
  // Decode order equals the display order for this I/P-only stream.
  let decoded = match @libavcodec.ff_hevc_decode_frames(seq.annexb, false, 0) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    let md5 = hevc_enc_p_md5(decoded[k].yuvp(8))
    assert_eq(md5, pins[k])
  }
  // The encoder's own reconstruction must be byte-identical to the decoder's
  // output for every frame (including all P pictures).
  for k in 0..<seq.frames.length() {
    let f = seq.frames[k]
    let pic = decoded[k].pic
    if !f.is_idr {
      assert_eq(f.poc, k)
    }
    for i in 0..<(f.width * f.height) {
      assert_eq(f.recon_y[i], pic.y[i])
    }
    for i in 0..<((f.width >> 1) * (f.height >> 1)) {
      assert_eq(f.recon_u[i], pic.cb[i])
      assert_eq(f.recon_v[i], pic.cr[i])
    }
  }
}

///|
/// P slice whose RD decision selects intra CUs (frame 1 is unrelated new
/// content). FFmpeg 9.0.2 framemd5 pins for the two frames:
/// `2c22b1c1db90c212edc036dfff2cb2ff` / `a36cb10d0d9d443b8015a33253cd99d7`.
test "hevc enc p: intra-CU mode ffmpeg arbitration" {
  let w = 64
  let h = 64
  let y0 = hevc_enc_p_make_plane(w, h, fn(i, j) { (i * 3 + j * 2) & 255 })
  let y1 = hevc_enc_p_make_plane(w, h, fn(i, j) {
    (255 - i * 4 - j * 7 + (if (i / 8 + j / 8) % 2 == 0 { 40 } else { 0 })) &
    255
  })
  let u0 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 7 + j * 3) & 255 })
  let v0 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 11 + j) & 255 })
  let u1 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 13 + j * 5) & 255 })
  let v1 = hevc_enc_p_make_plane(32, 32, fn(i, j) { (i * 3 + j * 17) & 255 })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
    (y1, u1, v1),
  ]
  let seq = match
    @libavcodec.hevc_encode_sequence(frames, width=w, height=h, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  let decoded = match @libavcodec.ff_hevc_decode_frames(seq.annexb, false, 0) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  let pins = [
    "a979107f1dc0c9579bbe3c2ec8a1bb18", "ac475a20c09ffb1993a9a2905730e8df",
  ]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(hevc_enc_p_md5(decoded[k].yuvp(8)), pins[k])
  }
}
