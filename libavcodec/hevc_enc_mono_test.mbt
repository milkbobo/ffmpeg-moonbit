///|
/// HEVC encoder monochrome black-box arbitration. The 64x64 two-frame
/// monochrome I/P stream (empty chroma planes, Rext monochrome profile);
/// FFmpeg 9.0.2 decodes it as gray with zero warnings and the raw-HEVC
/// framemd5 values are pinned below. The local round-trip is pinned by
/// hevc_enc_mono_wbtest.
///
/// Regenerate the stream with:
/// `moon run --target wasm-gc cmd/generate-hevc-mono <existing scratch dir>`,
/// then decode `mono_ip.265` using the linuxserver/ffmpeg:9.0.2 image with
/// `-hide_banner -loglevel error -xerror -f framemd5 -`.

///|
fn hevc_enc_mono_test_md5(data : Bytes) -> String {
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
test "hevc enc mono: ffmpeg two-frame framemd5 pins" {
  let w = 64
  let h = 64
  let clamp = fn(v : Int32, n : Int32) -> Int32 {
    if v < 0 {
      0
    } else if v >= n {
      n - 1
    } else {
      v
    }
  }
  let plane = fn(f : (Int32, Int32) -> Int32) -> FixedArray[Int32] {
    let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
    for j in 0..<h {
      for i in 0..<w {
        out[j * w + i] = f(i, j)
      }
    }
    out
  }
  let empty : FixedArray[Int32] = FixedArray::make(0, 0)
  let y0 = plane(fn(i, j) { (i * 11 + j * 7 + 30) & 255 })
  let seq = match
    @libavcodec.hevc_encode_sequence(
      [
        (y0, empty, empty.copy()),
        (
          plane(fn(i, j) { y0[clamp(j + 3, h) * w + clamp(i + 5, w)] }),
          empty,
          empty.copy(),
        ),
      ],
      width=w,
      height=h,
      qp=26,
      chroma_format_idc=0,
    ) {
    Ok(s) => s
    Err(e) => fail("mono encode: \{e}")
  }
  let decoded = match
    @libavcodec.ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("mono decode: \{e}")
  }
  let pins = [
    "e9e605002e93cff46c0d4fd266db85cb", "834f9effbdbf7bb071ecca653a1f677f",
  ]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(decoded[k].poc(), k)
    // yuvp over a monochrome frame emits the luma plane only (4096 bytes),
    // exactly FFmpeg's gray framemd5 size.
    let yuv = decoded[k].yuvp(8)
    assert_eq(yuv.length(), 4096)
    assert_eq(hevc_enc_mono_test_md5(yuv), pins[k])
  }
}
