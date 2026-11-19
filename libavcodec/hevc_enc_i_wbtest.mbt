// 白盒：HEVC intra 编码器全链路 round-trip——编码器局部重建必须与
// 自家 HEVC 解码器的输出逐字节一致。编码器现在开启去块（§452），因此
// 解码侧也必须应用环路滤波，两边才在同一个重建域里比较。

///|
fn hevc_enc_make_plane(
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
fn hevc_enc_roundtrip(
  y : FixedArray[Int32],
  u : FixedArray[Int32],
  v : FixedArray[Int32],
  w : Int32,
  h : Int32,
  qp : Int32,
) -> Unit raise {
  let frame = match hevc_encode_intra_frame(y, u, v, width=w, height=h, qp~) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  let pic = match ff_hevc_decode_intra_frame(frame.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("decode: \{e}")
  }
  let pw = frame.width
  let ph = frame.height
  for i in 0..<(pw * ph) {
    if pic.y[i] != frame.recon_y[i] {
      fail(
        "y mismatch at (\{i % pw},\{i / pw}) qp=\{qp}: dec=\{pic.y[i]} enc=\{frame.recon_y[i]}",
      )
    }
  }
  let cw = pw >> 1
  let ch = ph >> 1
  for i in 0..<(cw * ch) {
    if pic.cb[i] != frame.recon_u[i] {
      fail(
        "u mismatch at (\{i % cw},\{i / cw}) qp=\{qp}: dec=\{pic.cb[i]} enc=\{frame.recon_u[i]}",
      )
    }
    if pic.cr[i] != frame.recon_v[i] {
      fail(
        "v mismatch at (\{i % cw},\{i / cw}) qp=\{qp}: dec=\{pic.cr[i]} enc=\{frame.recon_v[i]}",
      )
    }
  }
}

///|
test "hevc enc i: 64x64 gradient qp26 round-trip" {
  let y = hevc_enc_make_plane(64, 64, fn(i, j) { i * 3 + j * 2 + 128 })
  let u = hevc_enc_make_plane(32, 32, fn(i, _) { (i * 2) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(_, _) { 128 })
  hevc_enc_roundtrip(y, u, v, 64, 64, 26)
}

///|
test "hevc enc i: flat frame round-trip" {
  let y : FixedArray[Int32] = FixedArray::make(64 * 64, 128)
  let u : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  let v : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  hevc_enc_roundtrip(y, u, v, 64, 64, 26)
}

///|
test "hevc enc i: per-ctb steps round-trip" {
  // 每个 32x32 CTB 一个恒值（CB 跨度触发 CU 分裂决策的平滑路径）。
  let y = hevc_enc_make_plane(64, 64, fn(i, j) {
    [128, 136, 120, 132][(j >> 5) * 2 + (i >> 5)]
  })
  let u : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  let v : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  hevc_enc_roundtrip(y, u, v, 64, 64, 26)
}

///|
test "hevc enc i: checkerboard texture qp18 round-trip" {
  let y = hevc_enc_make_plane(64, 64, fn(i, j) {
    if (i / 4 + j / 4) % 2 == 0 {
      100
    } else {
      180
    }
  })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 7 + j * 5) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(i, _) { (255 - i * 3) & 255 })
  hevc_enc_roundtrip(y, u, v, 64, 64, 18)
}

///|
test "hevc enc i: noise texture qp40 round-trip" {
  let vals = hevc_enc_test_rand(555, 64 * 64)
  let y : FixedArray[Int32] = FixedArray::make(64 * 64, 0)
  for i in 0..<(64 * 64) {
    y[i] = 128 + vals[i] / 4
  }
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 11 + j * 13) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(_, j) { (j * 29) & 255 })
  hevc_enc_roundtrip(y, u, v, 64, 64, 40)
}

///|
test "hevc enc i: odd size 50x36 crops via conformance window" {
  // 非整 CTB 尺寸：编码器填充到 32 的倍数 + conformance window 裁剪。
  let y = hevc_enc_make_plane(50, 36, fn(i, j) { i * 2 + j * 3 + 96 })
  let u = hevc_enc_make_plane(25, 18, fn(i, _) { (i * 4) & 255 })
  let v = hevc_enc_make_plane(25, 18, fn(_, j) { (j * 8) & 255 })
  let frame = match
    hevc_encode_intra_frame(y, u, v, width=50, height=36, qp=26) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  assert_true(frame.width == 64 && frame.height == 64)
  let pic = match ff_hevc_decode_intra_frame(frame.annexb, false, 0) {
    Ok(p) => p
    Err(e) => fail("decode: \{e}")
  }
  // 解码输出经 conformance window 裁剪后与重建的可见区一致——解码器返回
  // 的 HevcPicture 是整幅填充图，这里直接对全图比对（重建含填充区）。
  for i in 0..<(64 * 64) {
    if pic.y[i] != frame.recon_y[i] {
      fail("y mismatch at \{i}: dec=\{pic.y[i]} enc=\{frame.recon_y[i]}")
    }
  }
}

///|
test "hevc enc i: qp ladder monotonic bitrate" {
  // 平面渐变 + 纹理混合帧：QP 上升码率必须单调下降。
  let y = hevc_enc_make_plane(64, 64, fn(i, j) {
    let base = i * 2 + j
    if (i / 8 + j / 8) % 2 == 0 {
      base
    } else {
      255 - base
    }
  })
  let u : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  let v : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  let mut prev = -1
  for qp in [10, 20, 30, 40] {
    let frame = match
      hevc_encode_intra_frame(y, u, v, width=64, height=64, qp~) {
      Ok(f) => f
      Err(e) => fail("\{e}")
    }
    let size = frame.annexb.length()
    assert_true(size > 0)
    assert_true(size < 400000)
    if prev > 0 {
      assert_true(size < prev)
    }
    prev = size
    // 每档都 round-trip
    hevc_enc_roundtrip(y, u, v, 64, 64, qp)
  }
}

///|
test "hevc enc i: deterministic double run" {
  let y = hevc_enc_make_plane(64, 64, fn(i, j) { (i * 5 + j * 7) & 255 })
  let u = hevc_enc_make_plane(32, 32, fn(i, j) { (i * 3 + j) & 255 })
  let v = hevc_enc_make_plane(32, 32, fn(_, j) { (j * 17) & 255 })
  let a = match hevc_encode_intra_frame(y, u, v, width=64, height=64, qp=26) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  let b = match hevc_encode_intra_frame(y, u, v, width=64, height=64, qp=26) {
    Ok(f) => f
    Err(e) => fail("\{e}")
  }
  assert_eq(a.annexb.length(), b.annexb.length())
  for i in 0..<a.annexb.length() {
    assert_eq(a.annexb[i], b.annexb[i])
  }
}

///|
test "hevc enc i: 96x48 odd height round-trip" {
  let y = hevc_enc_make_plane(96, 48, fn(i, j) { (i * 3 + j * 5) & 255 })
  let u = hevc_enc_make_plane(48, 24, fn(i, j) { (i + j * 2) & 255 })
  let v = hevc_enc_make_plane(48, 24, fn(i, _) { (i * 9) & 255 })
  hevc_enc_roundtrip(y, u, v, 96, 48, 28)
}

///|
/// §453: SAO must actually be enabled and must actually change the
/// reconstruction. A synthetic -3 bias on the reconstruction is exactly what a
/// luma band-offset decision can undo, so the decided offsets must be nonzero
/// and the encoder's post-SAO reconstruction must differ from the deblocked one.
test "hevc enc i: sao decides real band offsets" {
  let w = 64
  let h = 64
  let y0 : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<w {
    for j in 0..<h {
      y0[j * w + i] = (i * 3 + j * 2 + 40) & 255
    }
  }
  let vps_nal = hevc_enc_nal(hevc_enc_vps(), 32)
  let sps_nal = hevc_enc_nal(hevc_enc_sps(w, h, 0, 0, false), 33)
  let pps_nal = hevc_enc_nal(hevc_enc_pps(26, false), 34)
  let ps = new_hevc_param_sets()
  match
    ff_hevc_decode_extradata(
      hevc_enc_concat([vps_nal, sps_nal, pps_nal]),
      ps,
      true,
    ) {
    Ok(_) => ()
    Err(e) => fail("\{e}")
  }
  let sps = match ps.sps_list[0] {
    Some(s) => s
    None => fail("no sps")
  }
  // The SPS the encoder writes must advertise SAO.
  assert_eq(sps.sao_enabled, 1)
  let sy : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    sy[i] = y0[i]
  }
  let pic = hevc_picture_new(w, h, w >> 1, h >> 1)
  for i in 0..<(w * h) {
    pic.y[i] = y0[i] - 3
  }
  let sao = hevc_enc_sao_decide(sps, sy, pic)
  let mut nonzero = 0
  for ctb in 0..<sps.ctb_size {
    if sao.type_idx[ctb * 3] != 0 {
      nonzero = nonzero + 1
      // Band mode, and the offsets must undo (part of) the -3 bias.
      assert_eq(sao.type_idx[ctb * 3], hevc_sao_band)
      assert_true(sao.offset_val[ctb * 15 + 1] > 0)
    }
  }
  assert_true(nonzero > 0)
  // Applying the decided parameters must move samples toward the source.
  let before : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    before[i] = pic.y[i]
  }
  hevc_sao_apply(
    pic,
    sps,
    match ps.pps_list[0] {
      Some(p) => p
      None => fail("no pps")
    },
    sao,
    Array::make(sps.ctb_size, 1),
    Array::make(sps.ctb_size, 0),
  )
  let mut moved = 0
  let mut closer = 0
  for i in 0..<(w * h) {
    if pic.y[i] != before[i] {
      moved = moved + 1
    }
    let d0 = if before[i] > sy[i] {
      before[i] - sy[i]
    } else {
      sy[i] - before[i]
    }
    let d1 = if pic.y[i] > sy[i] { pic.y[i] - sy[i] } else { sy[i] - pic.y[i] }
    if d1 < d0 {
      closer = closer + 1
    }
  }
  assert_true(moved > 0)
  assert_true(closer > 0)
}
