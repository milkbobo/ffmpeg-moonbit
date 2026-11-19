///|
/// HEVC 4:2:2 (Range Extensions) encoder black-box arbitration. The streams are
/// produced by `cmd/generate-hevc-422` and decoded by reference FFmpeg 9.0.2 as
/// `yuv422p` / `yuv422p10le`; the framemd5 values of that rawvideo output are
/// pinned below and must match this repository's own decoder byte-for-byte.
///
/// Pin regeneration:
/// `moon run --target wasm-gc cmd/generate-hevc-422 <existing scratch dir>`,
/// then for each stream
/// `docker run --rm --network none -v <dir>:/w --entrypoint ffmpeg
///  linuxserver/ffmpeg:9.0.2 -hide_banner -loglevel error -xerror
///  -i /w/<stream>.265 -f framemd5 -`.
/// FFmpeg reporting 8192 bytes for 64x64 (8-bit) confirms the yuv422p layout:
/// 64*64 + 2 * 32*64, and 16384 for the 10-bit stream.

///|
fn hevc_enc_422_test_plane(
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
fn hevc_enc_422_test_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_422_test_md5(data : Bytes) -> String {
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
/// The 8-bit 4:2:2 seed frame used by `cmd/generate-hevc-422`.
fn hevc_enc_422_test_seed() -> (
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
) {
  let w = 64
  let h = 64
  let cw = w / 2
  let ch = h
  let y = hevc_enc_422_test_plane(w, h, fn(i, j) { (i * 5 + j * 3 + 40) & 255 })
  let u = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
    (i * 9 + j * 5 + 20) & 255
  })
  let v = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
    (i * 3 + j * 11 + 90) & 255
  })
  (y, u, v)
}

///|
test "hevc enc 422: ffmpeg I-frame framemd5 pin" {
  let (y, u, v) = hevc_enc_422_test_seed()
  let frame = match
    @libavcodec.hevc_encode_intra_frame(
      y,
      u,
      v,
      width=64,
      height=64,
      qp=26,
      chroma_format_idc=2,
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
    hevc_enc_422_test_md5(decoded[0].yuvp(8)),
    "a4b6e1166c3120c855472b55c8440fcb",
  )
}

///|
test "hevc enc 422: ffmpeg I/P framemd5 pins" {
  let (y, u, v) = hevc_enc_422_test_seed()
  let w = 64
  let h = 64
  let cw = w / 2
  let ch = h
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y, u, v),
  ]
  for k in 1..<2 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_422_test_plane(w, h, fn(i, j) {
      y[hevc_enc_422_test_clamp(j + dy, h) * w +
      hevc_enc_422_test_clamp(i + dx, w)]
    })
    let uk = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
      u[hevc_enc_422_test_clamp(j + dy, ch) * cw +
      hevc_enc_422_test_clamp(i + dx, cw)]
    })
    let vk = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
      v[hevc_enc_422_test_clamp(j + dy, ch) * cw +
      hevc_enc_422_test_clamp(i + dx, cw)]
    })
    frames.push((yk, uk, vk))
  }
  let seq = match
    @libavcodec.hevc_encode_sequence(
      frames,
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=2,
    ) {
    Ok(s) => s
    Err(e) => fail("encode: \{e}")
  }
  let pins = [
    "a4b6e1166c3120c855472b55c8440fcb", "a9960e5db6869f77e887e909d7e95d2c",
  ]
  let decoded = match @libavcodec.ff_hevc_decode_frames(seq.annexb, false, 0) {
    Ok(d) => d
    Err(e) => fail("decode: \{e}")
  }
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(hevc_enc_422_test_md5(decoded[k].yuvp(8)), pins[k])
  }
  // The encoder's local reconstruction must match the decoder for both frames,
  // including the inter picture's chroma planes.
  for k in 0..<seq.frames.length() {
    let f = seq.frames[k]
    let pic = decoded[k].pic
    for i in 0..<(f.width * f.height) {
      assert_eq(f.recon_y[i], pic.y[i])
    }
    for i in 0..<(cw * ch) {
      assert_eq(f.recon_u[i], pic.cb[i])
      assert_eq(f.recon_v[i], pic.cr[i])
    }
  }
}

///|
test "hevc enc 422: ffmpeg 10-bit framemd5 pin" {
  let w = 64
  let h = 64
  let cw = w / 2
  let ch = h
  let y = hevc_enc_422_test_plane(w, h, fn(i, j) {
    (i * 21 + j * 13 + 512) & 1023
  })
  let u = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
    (i * 11 + j * 17 + 300) & 1023
  })
  let v = hevc_enc_422_test_plane(cw, ch, fn(i, j) {
    (i * 7 + j * 19 + 700) & 1023
  })
  let frame = match
    @libavcodec.hevc_encode_intra_frame(
      y,
      u,
      v,
      width=w,
      height=h,
      qp=26,
      bit_depth=10,
      chroma_format_idc=2,
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
    hevc_enc_422_test_md5(decoded[0].yuvp(10)),
    "9e431e626bb8971de4cdfd92aea50aee",
  )
}
