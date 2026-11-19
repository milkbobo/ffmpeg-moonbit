///|
/// HEVC streaming encoder black-box arbitration. The 64x64 five-frame CRF
/// stream (odd length — the §459 B schedule) comes out of
/// `HevcStreamEncoder` push by push; FFmpeg 9.0.2 decodes it with zero
/// warnings and the raw-HEVC decode-order framemd5 values are pinned below.
/// Byte equality with the batch entry is pinned by hevc_enc_stream_wbtest.
///
/// Regenerate the stream with:
/// `moon run --target wasm-gc cmd/generate-hevc-crf <existing scratch dir>`,
/// then decode `crf28_ipb5_stream.265` using the linuxserver/ffmpeg:9.0.2
/// image with `-hide_banner -loglevel error -xerror -f framemd5 -`.

///|
fn hevc_enc_stream_test_plane(
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
fn hevc_enc_stream_test_clamp(v : Int32, n : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= n {
    n - 1
  } else {
    v
  }
}

///|
fn hevc_enc_stream_test_frames() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let w = 64
  let h = 64
  let y0 = hevc_enc_stream_test_plane(w, h, fn(i, j) {
    (i * 13 + j * 9 + 128) & 255
  })
  let u0 = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 17 + j * 11 + 44) & 255
  })
  let v0 = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
    (i * 7 + j * 19 + 188) & 255
  })
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = [
    (y0, u0, v0),
  ]
  for k in 1..<4 {
    let dx = k * 4
    let dy = k * 2
    let yk = hevc_enc_stream_test_plane(w, h, fn(i, j) {
      y0[hevc_enc_stream_test_clamp(j + dy, h) * w +
      hevc_enc_stream_test_clamp(i + dx, w)]
    })
    let uk = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
      u0[hevc_enc_stream_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_stream_test_clamp(i + dx, w >> 1)]
    })
    let vk = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
      v0[hevc_enc_stream_test_clamp(j + dy, h >> 1) * (w >> 1) +
      hevc_enc_stream_test_clamp(i + dx, w >> 1)]
    })
    frames.push((yk, uk, vk))
  }
  let y5 = hevc_enc_stream_test_plane(w, h, fn(i, j) {
    y0[hevc_enc_stream_test_clamp(j + 10, h) * w +
    hevc_enc_stream_test_clamp(i + 20, w)]
  })
  let u5 = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
    u0[hevc_enc_stream_test_clamp(j + 10, h >> 1) * (w >> 1) +
    hevc_enc_stream_test_clamp(i + 20, w >> 1)]
  })
  let v5 = hevc_enc_stream_test_plane(w >> 1, h >> 1, fn(i, j) {
    v0[hevc_enc_stream_test_clamp(j + 10, h >> 1) * (w >> 1) +
    hevc_enc_stream_test_clamp(i + 20, w >> 1)]
  })
  frames.push((y5, u5, v5))
  frames
}

///|
fn hevc_enc_stream_test_md5(data : Bytes) -> String {
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
test "hevc enc stream: ffmpeg five-frame CRF framemd5 pins" {
  let enc = match
    @libavcodec.HevcStreamEncoder::open(
      width=64,
      height=64,
      crf=28.0,
      b_slices=true,
    ) {
    Ok(e) => e
    Err(e) => fail("stream open: \{e}")
  }
  let parts : Array[Bytes] = []
  for f in hevc_enc_stream_test_frames() {
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
  let stream = Bytes::from_array(total)
  let decoded = match
    @libavcodec.ff_hevc_decode_frames_ex(stream, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("stream decode: \{e}")
  }
  // Decode order is POC 0/2/1/4/3 (I, P, B, P, B); FFmpeg framemd5 follows
  // it. The first three pictures share the pinned 4-frame stream's MD5s.
  let pins = [
    "c6111e30fdd6fedd991b7f65c8155a95", "e3e97fe5425cf3dd3b86c0464082ab19", "bd7123fb72320e6e4b2e691f8310b99a",
    "d38ddbc3685d721f7bbc0286ed75002c", "7e6eceb2ac22ce95fe7b9a74f6ab2028",
  ]
  let expected_pocs = [0, 2, 1, 4, 3]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(decoded[k].poc(), expected_pocs[k])
    assert_eq(hevc_enc_stream_test_md5(decoded[k].yuvp(8)), pins[k])
  }
}
