///|
/// HEVC 12-bit (Range Extensions) encoder black-box arbitration. The 64x64
/// I/P/B stream contains 12-bit-only sample values and fractional-pel motion.
/// FFmpeg 9.0.2 decodes it as yuv420p12le under the Rext profile; the raw-HEVC
/// decode-order framemd5 values are pinned below. POC coverage in display
/// order is checked by hevc_enc_12bit_wbtest.mbt.
///
/// Regenerate the stream with:
/// `moon run --target wasm-gc cmd/generate-hevc-12bit <existing scratch dir>`,
/// then decode `main12_ipb.265` using the linuxserver/ffmpeg:9.0.2 image with
/// `-hide_banner -loglevel error -xerror -f framemd5 -`.

///|
fn hevc_enc_12bit_test_plane(
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
fn hevc_enc_12bit_test_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_12bit_test_frames() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_12bit_test_plane(w, h, fn(i, j) {
    (i * 51 + j * 37 + 2048) & 4095
  })
  let u0 = hevc_enc_12bit_test_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 67 + j * 43 + 1200) & 4095
  })
  let v0 = hevc_enc_12bit_test_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 29 + j * 73 + 2800) & 4095
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_12bit_test_plane(w, h, fn(i, j) {
      y0[hevc_enc_12bit_test_clamp(j + dy, h) * w +
      hevc_enc_12bit_test_clamp(i + dx, w)]
    })
    let uk = hevc_enc_12bit_test_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_12bit_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_12bit_test_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_12bit_test_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_12bit_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_12bit_test_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  frames
}

///|
fn hevc_enc_12bit_test_md5(data : Bytes) -> String {
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
test "hevc enc 12bit: ffmpeg I/P/B framemd5 pins" {
  let seq = match
    @libavcodec.hevc_encode_sequence(
      hevc_enc_12bit_test_frames(),
      width=64,
      height=64,
      qp=26,
      b_slices=true,
      bit_depth=12,
    ) {
    Ok(s) => s
    Err(e) => fail("12-bit encode: \{e}")
  }
  let decoded = match
    @libavcodec.ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("12-bit decode: \{e}")
  }
  // Decode order is POC 0/2/1/3 (I, P, B, P); FFmpeg framemd5 follows it.
  let pins = [
    "692d2ea8220b68a8bb80edb0c5a9ce4a", "42a798df129a2e6537937b291f6000f8", "1befb89dd7c6b45095fe184f6bf7932d",
    "fda6dc07783d5c6e07a29a25c4e4f0ea",
  ]
  let expected_pocs = [0, 2, 1, 3]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(decoded[k].poc(), expected_pocs[k])
    assert_eq(hevc_enc_12bit_test_md5(decoded[k].yuvp(12)), pins[k])
  }
}
