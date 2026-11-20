///|
/// SIMD (`@v128`) versions of the encoder pixel-difference kernels —
/// FFmpeg `libavcodec/me_cmp.c`/`x86/me_cmp.asm` (`ff_sad16_sse2`,
/// `ff_sse16_sse2`) and `libavcodec/pixblockdsp.c`/`x86/pixblockdsp.asm`
/// (`ff_get_pixels_sse2`, `ff_diff_pixels_sse2`).
///
/// The scalar port keeps these as per-encoder helpers
/// (`h264_enc_sad4`/`h264_enc_sad8` and the SSD/SAD loops of
/// `h264_encode_p`/`av1_enc_me`); the SIMD kernels here work on the
/// same `Array[Int32]`/`FixedArray[Int32]` pixel planes (values in the
/// 8-bit domain, 0..255), packing the compared window into the flat
/// byte layout `@v128` loads consume — the `get_pixels`/`diff_pixels`
/// role of pixblockdsp folded into `mec_pack_window`/
/// `mec_pack_plane_u8_fx`.
///
/// Per 16 bytes the byte-wise |a−b| is the classic two-way saturating
/// subtraction `or_(sub_sat_u(a,b), sub_sat_u(b,a))` (one side is
/// always zero — the x86 kernels get it in one `psadbw`, which Wasm
/// SIMD128 lacks); SAD then takes two pairwise-extending horizontal
/// sums and SSE widens the |a−b| lanes and dots them with ones
/// (`pmaddwd` structure). Sums are order-free, so flat-window
/// accumulation is bit-identical to the scalar loops.
///
/// Deviations (documented): `hadamard8_diff`/SATD has no scalar
/// counterpart anywhere in the port (the encoders are SAD/SSD-driven)
/// and is not duplicated. This is a subpackage rather than a libavcodec
/// whitebox file because the parent package's test command line
/// exceeds the Windows limit on long checkouts and its whitebox units
/// cannot use `@v128` on wasm-gc; equality with `h264_enc_sad4`/`sad8`
/// (same window arithmetic as the inline reference here) is therefore
/// asserted through the reference, not by calling the privates.
///
/// Gated to `native`/`wasm`; other targets keep the scalar loops.
/// Equal outputs are asserted in `me_cmp_v128_wbtest.mbt`.

///|
/// Pack a `w x h` window of an `Array[Int32]` pixel plane (8-bit domain)
/// into flat bytes, row-major, +16B zero pad. */
pub fn mec_pack_window(
  src : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
) -> FixedArray[Byte] {
  let buf : FixedArray[Byte] = FixedArray::make(w * h + 16, b'\x00')
  for row = 0; row < h; row = row + 1 {
    let base = off + row * stride
    for col = 0; col < w; col = col + 1 {
      buf[row * w + col] = src[base + col].to_byte()
    }
  }
  buf
}

///|
/// Pack a flat `FixedArray[Int32]` pixel plane (8-bit domain) to bytes. */
pub fn mec_pack_plane_u8_fx(
  src : FixedArray[Int32],
  len : Int32,
) -> FixedArray[Byte] {
  let buf : FixedArray[Byte] = FixedArray::make(len + 16, b'\x00')
  for i = 0; i < len; i = i + 1 {
    buf[i] = src[i].to_byte()
  }
  buf
}

///|
/// Horizontal sum of the four `i32x4` lanes. */
#cfg(any(target="native", target="wasm"))
fn mec_red4(v : V128) -> Int32 {
  let u = @v128.i32x4_extract_lane(v, 0) +
  @v128.i32x4_extract_lane(v, 1) +
  @v128.i32x4_extract_lane(v, 2) +
  @v128.i32x4_extract_lane(v, 3)
  u.reinterpret_as_int()
}

///|
/// Byte-wise |a−b| of two vectors: one of the two saturating
/// subtractions is zero, so their or is the absolute difference. */
#cfg(any(target="native", target="wasm"))
fn mec_absdiff(a : V128, b : V128) -> V128 {
  @v128.v128_or_(
    @v128.i8x16_sub_sat_u(a, b),
    @v128.i8x16_sub_sat_u(b, a),
  )
}

///|
/// SAD over `n` flat bytes (`ff_sad{8,16}` structure). */
#cfg(any(target="native", target="wasm"))
pub fn mec_sad_packed_v128(
  a : FixedArray[Byte],
  b : FixedArray[Byte],
  n : Int32,
) -> Int32 {
  let mut acc = @v128.i32x4_splat(0)
  let mut p = 0
  while p + 16 <= n {
    let d = mec_absdiff(@v128.v128_load(a, p), @v128.v128_load(b, p))
    acc = @v128.i32x4_add(
      acc,
      @v128.i32x4_extadd_pairwise_i16x8_u(
        @v128.i16x8_extadd_pairwise_i8x16_u(d),
      ),
    )
    p = p + 16
  }
  let mut sum = mec_red4(acc)
  while p < n {
    let x = a[p].to_int()
    let y = b[p].to_int()
    sum = sum + (if x < y { y - x } else { x - y })
    p = p + 1
  }
  sum
}

///|
/// SSE (sum of squared differences) over `n` flat bytes
/// (`ff_sse{8,16}` structure: |a−b| widened, `pmaddwd` of the lanes
/// with themselves). */
#cfg(any(target="native", target="wasm"))
pub fn mec_sse_packed_v128(
  a : FixedArray[Byte],
  b : FixedArray[Byte],
  n : Int32,
) -> Int32 {
  let mut acc = @v128.i32x4_splat(0)
  let mut p = 0
  while p + 16 <= n {
    let d = mec_absdiff(@v128.v128_load(a, p), @v128.v128_load(b, p))
    let dlo = @v128.i16x8_extend_low_i8x16_u(d)
    let dhi = @v128.i16x8_extend_high_i8x16_u(d)
    acc = @v128.i32x4_add(acc, @v128.i32x4_dot_i16x8_s(dlo, dlo))
    acc = @v128.i32x4_add(acc, @v128.i32x4_dot_i16x8_s(dhi, dhi))
    p = p + 16
  }
  let mut sum = mec_red4(acc)
  while p < n {
    let dd = a[p].to_int() - b[p].to_int()
    sum = sum + dd * dd
    p = p + 1
  }
  sum
}

///|
/// SAD over a `w x h` window of two `Array[Int32]` planes at
/// `(off, stride)` — the `h264_enc_sad4`/`h264_enc_sad8` geometry. */
#cfg(any(target="native", target="wasm"))
pub fn mec_sad_v128(
  src : Array[Int32],
  rec : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  mec_sad_packed_v128(
    mec_pack_window(src, off, stride, w, h),
    mec_pack_window(rec, off, stride, w, h),
    w * h,
  )
}

///|
/// SSE over the same window geometry. */
#cfg(any(target="native", target="wasm"))
pub fn mec_sse_v128(
  src : Array[Int32],
  rec : Array[Int32],
  off : Int32,
  stride : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  mec_sse_packed_v128(
    mec_pack_window(src, off, stride, w, h),
    mec_pack_window(rec, off, stride, w, h),
    w * h,
  )
}
