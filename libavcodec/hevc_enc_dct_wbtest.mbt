// 白盒：正向变换/量化与解码器逆链路的往返误差界。

///|
/// 确定性伪随机（线性同余），夹具可复现。
fn abs_int(v : Int32) -> Int32 {
  if v < 0 {
    -v
  } else {
    v
  }
}

///|
fn hevc_enc_test_rand(seed : Int32, n : Int32) -> Array[Int32] {
  let mut s = seed
  let out : Array[Int32] = []
  for _ in 0..<n {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF
    out.push((s >> 16) % 512 - 256)
  }
  out
}

///|
test "hevc enc dct: fdct -> decoder idct round-trip error bound" {
  // 无量化的纯变换往返：fdct 的 dq 域输出直接喂解码器 idct，误差应有界。
  for n in [4, 8, 16, 32] {
    let vals = hevc_enc_test_rand(7, n * n)
    let r : FixedArray[Int32] = FixedArray::make(n * n, 0)
    for i in 0..<(n * n) {
      r[i] = vals[i]
    }
    let dq = hevc_enc_fdct(r, n)
    let coeffs : Array[Int32] = Array::make(n * n, 0)
    for i in 0..<(n * n) {
      coeffs[i] = dq[i]
    }
    match
      hevc_idct(
        coeffs,
        match n {
          4 => 2
          8 => 3
          16 => 4
          _ => 5
        },
        n,
        8,
      ) {
      Ok(_) => ()
      Err(e) => fail("\{e}")
    }
    // 误差界：DC 路径的 (dq+1)>>1 折算 + 全 IDCT 的移位链，实测 < 8/样本。
    let mut max_err = 0
    for i in 0..<(n * n) {
      let d = coeffs[i] - r[i]
      let a = if d < 0 { -d } else { d }
      if a > max_err {
        max_err = a
      }
    }
    assert_true(max_err <= 8)
  }
}

///|
test "hevc enc dct: fdct DC-only matches the decoder DC path" {
  // 常数块 → 仅 DC 非零；解码器 max_xy==0 走 idct_dc，往返须近似恒等。
  for n in [4, 8, 16, 32] {
    let r : FixedArray[Int32] = FixedArray::make(n * n, 37)
    let dq = hevc_enc_fdct(r, n)
    let mut ac_nonzero = false
    for i in 1..<(n * n) {
      if dq[i] != 0 {
        ac_nonzero = true
      }
    }
    assert_true(!ac_nonzero)
    let coeffs : Array[Int32] = Array::make(n * n, 0)
    for i in 0..<(n * n) {
      coeffs[i] = dq[i]
    }
    match
      hevc_idct_dc(
        coeffs,
        match n {
          4 => 2
          8 => 3
          16 => 4
          _ => 5
        },
        8,
      ) {
      Ok(_) => ()
      Err(e) => fail("\{e}")
    }
    for i in 0..<(n * n) {
      assert_true(abs_int(coeffs[i] - 37) <= 2)
    }
  }
}

///|
test "hevc enc quant: quantise -> dequantise round-trips within one step" {
  // level = (|dq| * 2^(bd+log2-9) + rnd) / scale 的逆应还原到同一 dq。
  for qp in [0, 12, 26, 39, 51] {
    let vals = hevc_enc_test_rand(qp + 1, 64)
    let log2 = 3
    let bd = 8
    let scale = hevc_level_scale[qp % 6] << (qp / 6)
    let shift = bd + log2 - 5
    for k in 0..<64 {
      let dq = vals[k]
      let level = hevc_enc_quant_val(dq, qp, log2, bd)
      let dq2 = (
          level.to_int64() * scale.to_int64() * 16L + (1L << (shift - 1))
        ) >>
        shift
      let err = abs_int((dq2 - dq.to_int64()).to_int())
      // 一个量化步长以内（跨零处允许半个步长）。
      assert_true(err <= scale >> 2)
    }
  }
}

///|
test "hevc enc fdst4: 4x4 DST round-trip through the decoder kernel" {
  let vals = hevc_enc_test_rand(99, 16)
  let r : FixedArray[Int32] = FixedArray::make(16, 0)
  for i in 0..<16 {
    r[i] = vals[i]
  }
  let dq = hevc_enc_fdst4(r)
  let coeffs : Array[Int32] = Array::make(16, 0)
  for i in 0..<16 {
    coeffs[i] = dq[i]
  }
  hevc_transform_4x4_luma(coeffs, 8)
  let mut max_err = 0
  for i in 0..<16 {
    let d = coeffs[i] - r[i]
    let a = if d < 0 { -d } else { d }
    if a > max_err {
      max_err = a
    }
  }
  assert_true(max_err <= 8)
}
