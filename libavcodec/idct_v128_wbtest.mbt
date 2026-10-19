///|
/// Whitebox tests for the SIMD (`@v128`) IDCT (`idct_v128.mbt`).
///
/// The SIMD transform is checked against the same oracle as the scalar port:
/// FFmpeg's double-precision reference `dctref.c`, with the tolerances from
/// `libavcodec/tests/dct.c` (`err_inf <= 1`, `omse <= 0.02`, `|ome| <= 0.0015`).
/// The random coefficient blocks reuse `init_block` / `Lfg` from
/// `idct_wbtest.mbt` (same package). The transpose is checked as an involution.

///| Error statistics of the SIMD 8-bit transform against `dctref`. */
fn idctv128_stats(mode : Int, its : Int) -> (Int, Double, Double) {
  let lfg = lfg_init(1)
  let mut err_inf = 0
  let mut err2 : Int64 = 0
  let mut err_sum : Int64 = 0
  for _it = 0; _it < its; _it = _it + 1 {
    let orig : Array[Int] = Array::make(64, 0)
    init_block(orig, mode, true, lfg, 256)
    let buf = idct_block_to_bytes(orig)
    ff_simple_idct_v128(buf)
    let got = idct_bytes_to_block(buf)
    let refb = dup(orig)
    ff_ref_idct(refb)
    for i = 0; i < 64; i = i + 1 {
      let e = got[i] - refb[i]
      let v = if e < 0 { -e } else { e }
      if v > err_inf {
        err_inf = v
      }
      err2 = err2 + (v * v).to_int64()
      err_sum = err_sum + e.to_int64()
    }
  }
  let d = its.to_double()
  (err_inf, err2.to_double() / d / 64.0, err_sum.to_double() / d / 64.0)
}

test "idct simd: bit-exact with the scalar port for single-coefficient blocks" {
  ff_ref_dct_init()
  // one nonzero coefficient at each of the 64 positions (fully in range, so the
  // scalar DC-only shortcut never applies): the SIMD result is identical.
  for pos = 0; pos < 64; pos = pos + 1 {
    let b : Array[Int] = Array::make(64, 0)
    b[pos] = 100
    let buf = idct_block_to_bytes(b)
    ff_simple_idct_v128(buf)
    let got = idct_bytes_to_block(buf)
    let sc = dup(b)
    ff_simple_idct_int16_8bit(sc)
    assert_eq(got, sc)
  }
}

test "idct simd: 8x8 transpose is an involution" {
  let block : Array[Int] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    block[i] = i * 7 - 100
  }
  let buf = idct_block_to_bytes(block)
  let rows : Array[V128] = []
  for r = 0; r < 8; r = r + 1 {
    rows.push(@v128.v128_load(buf, r * 16))
  }
  let twice = idct_transpose(idct_transpose(rows))
  let out : FixedArray[Byte] = FixedArray::make(128, b'\x00')
  for r = 0; r < 8; r = r + 1 {
    @v128.v128_store(out, r * 16, twice[r])
  }
  assert_eq(idct_bytes_to_block(out), block)
}

test "idct simd: matches the dctref reference within FFmpeg dct.c tolerances" {
  ff_ref_dct_init()
  let its = 2000
  for mode = 0; mode < 3; mode = mode + 1 {
    let (e, m, a) = idctv128_stats(mode, its)
    assert_true(e <= 1)
    assert_true(m <= 0.02)
    assert_true(dabs(a) <= 0.0015)
  }
}

test "idct simd: put variant matches the clipped reference" {
  ff_ref_dct_init()
  // DC-only blocks at several amplitudes
  let mut x = -2048
  while x <= 2048 {
    let block : Array[Int] = Array::make(64, 0)
    block[0] = x
    let dest : FixedArray[Byte] = FixedArray::make(64, b'\x00')
    ff_simple_idct_put_v128(dest, 8, idct_block_to_bytes(block))
    let refb = dup(block)
    ff_ref_idct(refb)
    for i = 0; i < 64; i = i + 1 {
      let rv = clip_uint8(refb[i])
      let d = if dest[i].to_int() > rv {
        dest[i].to_int() - rv
      } else {
        rv - dest[i].to_int()
      }
      assert_true(d <= 1)
    }
    x = x + 137
  }
}

test "idct simd: add variant equals clip of put + destination" {
  // A DC-only block produces a flat clipped value, so add == clip(dest + put).
  let block : Array[Int] = Array::make(64, 0)
  block[0] = 1024
  let put : FixedArray[Byte] = FixedArray::make(64, b'\x00')
  ff_simple_idct_put_v128(put, 8, idct_block_to_bytes(block))
  let base : FixedArray[Byte] = FixedArray::make(64, b'\x28')
  let add : FixedArray[Byte] = FixedArray::make(64, b'\x28')
  ff_simple_idct_add_v128(add, 8, idct_block_to_bytes(block))
  for i = 0; i < 64; i = i + 1 {
    let expected = clip_uint8(base[i].to_int() + put[i].to_int())
    assert_eq(add[i].to_int(), expected)
  }
}
