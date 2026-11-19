///|
/// HEVC 4:4:4 (Range Extensions) encoder black-box arbitration. The streams are
/// produced by `cmd/generate-hevc-422` and decoded by reference FFmpeg 9.0.2 as
/// `yuv444p`; the framemd5 values of that rawvideo output are pinned below and
/// must match this repository's own decoder byte-for-byte.
///
/// Pin regeneration:
/// `moon run --target wasm-gc cmd/generate-hevc-422 <existing scratch dir>`,
/// then for each stream
/// `docker run --rm --network none -v <dir>:/w --entrypoint ffmpeg
///  linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -xerror
///  -i /w/<stream>.265 -f framemd5 -`.
/// FFmpeg reporting 12288 bytes for 64x64 confirms the yuv444p layout
/// (64*64*3).

///|
fn hevc_enc_444_test_plane(
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
fn hevc_enc_444_test_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_444_test_md5(data : Bytes) -> String {
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
/// The 8-bit 4:4:4 seed frame used by `cmd/generate-hevc-422`.
fn hevc_enc_444_test_seed() -> (
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
) {
  let w = 64
  let h = 64
  let y = hevc_enc_444_test_plane(w, h, fn(i, j) { (i * 6 + j * 4 + 30) & 255 })
  let u = hevc_enc_444_test_plane(w, h, fn(i, j) { (i * 8 + j * 6 + 70) & 255 })
  let v = hevc_enc_444_test_plane(w, h, fn(i, j) {
    (i * 4 + j * 12 + 150) & 255
  })
  (y, u, v)
}

///|
test "hevc enc 444: ffmpeg I-frame framemd5 pin" {
  let (y, u, v) = hevc_enc_444_test_seed()
  let frame = match
    @libavcodec.hevc_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=64,
      qp=26,
      chroma_format_idc=3,
    ) {
    Ok(f) => f
    Err(e) => fail("encode: \{e}")
  }
  let decoded = match
    @libavcodec.ff_hevc_decode_frames(frame.annexb, false, 0) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  assert_eq(decoded.length(), 1)
  assert_eq(
    hevc_enc_444_test_md5(decoded[0].yuvp(8)),
    "d120074228e928227abd8aad38d1f444",
  )
}

///|
test "hevc enc 444: ffmpeg I/P framemd5 pins" {
  let (y, u, v) = hevc_enc_444_test_seed()
  let w = 64
  let h = 64
  let dx = 4
  let dy = 2
  let yk = hevc_enc_444_test_plane(w, h, fn(i, j) {
    y[hevc_enc_444_test_clamp(j + dy, h) * w +
    hevc_enc_444_test_clamp(i + dx, w)]
  })
  let uk = hevc_enc_444_test_plane(w, h, fn(i, j) {
    u[hevc_enc_444_test_clamp(j + dy, h) * w +
    hevc_enc_444_test_clamp(i + dx, w)]
  })
  let vk = hevc_enc_444_test_plane(w, h, fn(i, j) {
    v[hevc_enc_444_test_clamp(j + dy, h) * w +
    hevc_enc_444_test_clamp(i + dx, w)]
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
    (yk, uk, vk),
  ]
  let seq = match
    @libavcodec.hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=3,
    ) {
    Ok(s) => s
    Err(e) => fail("encode: \{e}")
  }
  let pins = [
    "d120074228e928227abd8aad38d1f444", "d2709c85f193d1cc3a0fa4b1c43ab9e0",
  ]
  let decoded = match @libavcodec.ff_hevc_decode_frames(seq.annexb, false, 0) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(hevc_enc_444_test_md5(decoded[k].yuvp(8)), pins[k])
  }
  // The encoder's local reconstruction must match the decoder for both frames.
  for k in 0..<seq.frames.length() {
    let f = seq.frames[k]
    let pic = decoded[k].pic
    for i in 0..<(f.width * f.height) {
      assert_eq(f.recon_y[i], pic.y[i])
      assert_eq(f.recon_u[i], pic.cb[i])
      assert_eq(f.recon_v[i], pic.cr[i])
    }
  }
}
