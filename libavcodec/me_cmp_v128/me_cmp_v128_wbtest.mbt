///|
/// Whitebox tests for the SIMD (`@v128`) encoder pixel-difference
/// kernels (`me_cmp_v128.mbt`).
///
/// The SIMD paths must agree with the scalar loops exactly. The inline
/// reference is the arithmetic of the encoder kernels
/// (`h264_enc_sad4`/`h264_enc_sad8` and the SSD loops): a per-pixel
/// |a−b| / (a−b)² accumulation over the same (off, stride, w, h)
/// window.

///|
/// Deterministic 8-bit-domain plane generator (LCG). */
fn mec_gen_plane(seed : UInt32, n : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFU).reinterpret_as_int()
  }
  a
}

///|
/// Scalar window SAD/SSE reference. */
fn mec_ref(
  src : Array[Int32],
  rec : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
  squared : Bool,
) -> Int32 {
  let mut sum = 0
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let d = src[off + row * stride + col] - rec[off + row * stride + col]
      sum = sum + (if squared { d * d } else if d < 0 { -d } else { d })
    }
  }
  sum
}

///|
test "me_cmp v128: sad/sse equality across window geometries" {
  let geoms : Array[(Int32, Int32)] = [
    (4, 4),
    (8, 8),
    (16, 16),
    (8, 4),
    (16, 8),
    (4, 8),
    (32, 16),
    (64, 64),
  ]
  let stride : Int32 = 96
  let plane_n = 96 * 96
  for idx = 0; idx < geoms.length(); idx = idx + 1 {
    let (w, h) = geoms[idx]
    let src = mec_gen_plane(0x9E3779B9U + idx.reinterpret_as_uint(), plane_n)
    let rec = mec_gen_plane(0xDEADBEEFU + idx.reinterpret_as_uint(), plane_n)
    // carve several windows (odd offsets, kept inside the plane)
    for k = 0; k < 4; k = k + 1 {
      let roff = (7 + k * 13) % (96 - h + 1)
      let coff = (3 + k * 9) % (96 - w + 1)
      let off = roff * stride + coff
      assert_eq(
        mec_sad_v128(src, rec, off, stride, w, h),
        mec_ref(src, rec, off, stride, w, h, false),
      )
      assert_eq(
        mec_sse_v128(src, rec, off, stride, w, h),
        mec_ref(src, rec, off, stride, w, h, true),
      )
    }
  }
}

///|
test "me_cmp v128: flat packed kernels and boundaries" {
  // flat kernels over packed planes equal the window kernels on the
  // same data
  let n : Int32 = 4096
  let src = mec_gen_plane(0xA5A5A5A5U, n)
  let rec = mec_gen_plane(0x5A5A5A5AU, n)
  let pa = mec_pack_plane_u8_fx(FixedArray::from_array(src[:]), n)
  let pb = mec_pack_plane_u8_fx(FixedArray::from_array(rec[:]), n)
  assert_eq(
    mec_sad_packed_v128(pa, pb, n),
    mec_ref(src, rec, 0, n, n, 1, false),
  )
  assert_eq(mec_sse_packed_v128(pa, pb, n), mec_ref(src, rec, 0, n, n, 1, true))
  // extremes: identical planes, and all-0 vs all-255
  let z = mec_pack_plane_u8_fx(FixedArray::make(256, 0), 256)
  let m = mec_pack_plane_u8_fx(FixedArray::make(256, 255), 256)
  assert_eq(mec_sad_packed_v128(z, z, 256), 0)
  assert_eq(mec_sse_packed_v128(z, z, 256), 0)
  assert_eq(mec_sad_packed_v128(z, m, 256), 255 * 256)
  assert_eq(mec_sse_packed_v128(z, m, 256), 255 * 255 * 256)
  // non-multiple-of-16 lengths exercise the scalar tails
  for tail = 1; tail < 32; tail = tail + 1 {
    let len = 512 + tail
    let s2 = mec_gen_plane(0xC0FFEE01U + tail.reinterpret_as_uint(), len)
    let r2 = mec_gen_plane(0x0BADF00DU + tail.reinterpret_as_uint(), len)
    let a2 = mec_pack_plane_u8_fx(FixedArray::from_array(s2[:]), len)
    let b2 = mec_pack_plane_u8_fx(FixedArray::from_array(r2[:]), len)
    assert_eq(
      mec_sad_packed_v128(a2, b2, len),
      mec_ref(s2, r2, 0, len, len, 1, false),
    )
    assert_eq(
      mec_sse_packed_v128(a2, b2, len),
      mec_ref(s2, r2, 0, len, len, 1, true),
    )
  }
}
