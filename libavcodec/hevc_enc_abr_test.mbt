///|
/// HEVC streaming ABR black-box arbitration. The 64x64 four-frame B-schedule
/// stream comes out of the §462 controller at a tight budget (target
/// 60 kbit/s at 30 fps, flat qp 22); FFmpeg 9.0.2 decodes it with zero
/// warnings and the raw-HEVC decode-order framemd5 values are pinned below.
///
/// Regenerate the stream with:
/// `moon run --target wasm-gc cmd/generate-hevc-crf <existing scratch dir>`,
/// then decode `abr_ipb.265` using the linuxserver/ffmpeg:9.0.2 image with
/// `-hide_banner -loglevel error -xerror -f framemd5 -`.

///|
fn hevc_enc_abr_test_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_abr_test_md5(data : Bytes) -> String {
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
test "hevc enc abr: ffmpeg four-frame B-schedule framemd5 pins" {
  let w = 64
  let h = 64
  let plane = fn(
    pw : Int32,
    ph : Int32,
    f : (Int32, Int32) -> Int32,
  ) -> FixedArray[Int32] {
    let out : FixedArray[Int32] = FixedArray::make(pw * ph, 0)
    for j in 0..<ph {
      for i in 0..<pw {
        out[j * pw + i] = f(i, j)
      }
    }
    out
  }
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
      y0[hevc_enc_abr_test_clamp(j + dy, h) * w +
      hevc_enc_abr_test_clamp(i + dx, w)]
    })
    let uk = plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_abr_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_abr_test_clamp(i + dx, w >> 1)]
    })
    let vk = plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_abr_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_abr_test_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  let enc = match
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
  let parts : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) =>
        for au in enc.drain() {
          parts.push(au)
        }
      Err(e) => fail("abr push: \{e}")
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        parts.push(au)
      }
    Err(e) => fail("abr finish: \{e}")
  }
  let total : Array[Byte] = []
  for p in parts {
    for b in p {
      total.push(b)
    }
  }
  let decoded = match
    @libavcodec.ff_hevc_decode_frames_ex(
      Bytes::from_array(total),
      false,
      0,
      true,
    ) {
    Ok(d) => d
    Err(e) => fail("abr decode: \{e}")
  }
  // Decode order is POC 0/2/1/3 (I, P, B, P).
  let pins = [
    "564d84ed6dbda85eaf6aa9aaf2c35202", "51f8f0b4873ebfceab44757c5df962b4", "e5f4cd35d761e065998b6aae4f0d8357",
    "0db1e6a0db7ac4fe8defb6d240d0bfcc",
  ]
  let expected_pocs = [0, 2, 1, 3]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(decoded[k].poc(), expected_pocs[k])
    assert_eq(hevc_enc_abr_test_md5(decoded[k].yuvp(8)), pins[k])
  }
}
