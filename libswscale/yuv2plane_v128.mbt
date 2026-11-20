///|
/// SIMD (`@v128`) versions of the `yuv2planeX` output rows
/// (`sws_yuv2planeX_row_8` / `sws_yuv2planeX_row_16`, `libswscale/vscale.c`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libswscale/x86/output.asm`: `ff_yuv2planeX_{8,9,10,16}_sse2/sse4`):
/// eight output pixels are produced at once as
///
///   val[t] = dither[t]<<12 + Σ_j src[j][t] · filter[j]      (8-bit out)
///   val[t] = half + Σ_j src[j][t] · filter[j]               (9..16-bit)
///
/// with the per-tap multiply-accumulate carried as `i32x4_extmul`
/// (`pmaddwd`-free, same arithmetic on widened `i16x8` lanes) and the
/// epilogue via saturating narrows (`i32x4 -> i16x8 -> u8x16`, the asm's
/// `packssdw`+`packuswb`; 9..16-bit output stops at the `i16x8` narrow
/// whose little-endian lanes are the `u16` stores). Dither follows
/// `ff_dither_8x8_128`: for a block-aligned group of eight pixels the
/// `(line & 7, (pixel + dither_off) & 7)` indexing is one fixed lane
/// vector per output line, precomputed by `sws_dither_row_8`.
///
/// Input rows are the 15-bit horizontal intermediates, already in the
/// `int16` domain (`hScale8To15` stores `int16`); `sws_pack_row_i16`
/// converts them to the packed little-endian layout the vector loads
/// consume. `ff_yuv2plane1_*` (the single-tap special case of the x86
/// path) is arithmetic-identical to this kernel with one tap and is not
/// duplicated.
///
/// Available on `native`, `wasm` and `wasm-gc`. Equal
/// outputs are asserted in `yuv2plane_v128_wbtest.mbt`.

///|
/// Pack a row of `int16`-domain intermediates into the little-endian
/// byte layout the SIMD paths consume (+16B pad for block loads). */
pub fn sws_pack_row_i16(row : Array[Int32], len : Int32) -> FixedArray[Byte] {
  let buf : FixedArray[Byte] = FixedArray::make(2 * len + 16, b'\x00')
  for i = 0; i < len; i = i + 1 {
    let c = row[i]
    buf[2 * i] = (c & 0xFF).to_byte()
    buf[2 * i + 1] = ((c >> 8) & 0xFF).to_byte()
  }
  buf
}

///|
#cfg(any(target="wasm", target="wasm-gc"))
fn sws_pack_vertical_rows(
  rows : Array[Array[Int32]],
  width : Int32,
  taps : Int32,
) -> Array[FixedArray[Byte]]? {
  guard width >= 8 && taps > 1 else { return None }
  Some(rows.map(row => sws_pack_row_i16(row, width)))
}

///|
#cfg(not(any(target="wasm", target="wasm-gc")))
fn sws_pack_vertical_rows(
  _rows : Array[Array[Int32]],
  _width : Int32,
  _taps : Int32,
) -> Array[FixedArray[Byte]]? {
  None
}

///|
#cfg(any(target="wasm", target="wasm-gc"))
fn sws_vertical_packed(
  packed : Array[FixedArray[Byte]],
  start : Int32,
  coeffs : Array[Int32],
  width : Int32,
  bits : Int32,
  y : Int32,
  dither_off : Int32,
  nbps : Bool,
) -> Array[Byte] {
  let rows = Array::makei(coeffs.length(), j => packed[start + j])
  if bits > 8 {
    sws_yuv2planeX_16_v128(rows, coeffs, width, bits)
  } else {
    sws_yuv2planeX_8_v128(
      rows,
      coeffs,
      width,
      sws_dither_row_8(y, dither_off, nbps),
    )
  }
}

///|
#cfg(not(any(target="wasm", target="wasm-gc")))
fn sws_vertical_packed(
  _packed : Array[FixedArray[Byte]],
  _start : Int32,
  _coeffs : Array[Int32],
  _width : Int32,
  _bits : Int32,
  _y : Int32,
  _dither_off : Int32,
  _nbps : Bool,
) -> Array[Byte] {
  abort("packed vertical rows are available on Wasm")
}

///|
/// The eight-lane dither vector for one output line: `ff_dither_8x8_128`
/// indexed by `(y & 7, (t + dither_off) & 7)` when an N-BPS source is
/// reduced to 8-bit, `ff_sws_pb_64` (all 64) otherwise. */
pub fn sws_dither_row_8(
  y : Int32,
  dither_off : Int32,
  nbps : Bool,
) -> Array[Int32] {
  let d : Array[Int32] = Array::make(8, 64)
  if nbps {
    for t = 0; t < 8; t = t + 1 {
      d[t] = sws_dither_8x8_128[y % 8 * 8 + (t + dither_off) % 8]
    }
  }
  d
}

///|
/// Sign-extended `int16` read from a packed row (`sws_pack_row_i16`
/// layout); the scalar tails use the same reads as the scalar port. */
#cfg(any(target="native", target="wasm", target="wasm-gc"))
fn sws_unpack_i16(buf : FixedArray[Byte], i : Int32) -> Int32 {
  let u = buf[2 * i].to_uint() | (buf[2 * i + 1].to_uint() << 8)
  u.reinterpret_as_int() << 16 >> 16
}

///|
/// `sws_yuv2planeX_row_8` over packed rows, eight pixels per block.
#cfg(any(target="native", target="wasm", target="wasm-gc"))
pub fn sws_yuv2planeX_8_v128(
  rows : Array[FixedArray[Byte]],
  coffs : Array[Int32],
  dst_w : Int32,
  dither8 : Array[Int32],
) -> Array[Byte] {
  let mut dith = @v128.i16x8_splat(0)
  for t = 0; t < 8; t = t + 1 {
    dith = @v128.i16x8_replace_lane(dith, dither8[t].reinterpret_as_uint(), t)
  }
  let dith_lo = @v128.i32x4_shl(@v128.i32x4_extend_low_i16x8_s(dith), 12)
  let dith_hi = @v128.i32x4_shl(@v128.i32x4_extend_high_i16x8_s(dith), 12)
  let zero = @v128.i32x4_splat(0)
  let lim = @v128.i32x4_splat(255)
  let out : Array[Byte] = Array::make(dst_w, b'\x00')
  let scratch : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let mut i = 0
  while i + 8 <= dst_w {
    let mut alo = dith_lo
    let mut ahi = dith_hi
    for j in 0..<coffs.length() {
      let cv = @v128.i16x8_splat(coffs[j].to_uint16())
      let px = @v128.v128_load(rows[j], 2 * i)
      alo = @v128.i32x4_add(alo, @v128.i32x4_extmul_low_i16x8_s(px, cv))
      ahi = @v128.i32x4_add(ahi, @v128.i32x4_extmul_high_i16x8_s(px, cv))
    }
    let lo = @v128.i32x4_min_s(
      @v128.i32x4_max_s(@v128.i32x4_shr_s(alo, 19), zero),
      lim,
    )
    let hi = @v128.i32x4_min_s(
      @v128.i32x4_max_s(@v128.i32x4_shr_s(ahi, 19), zero),
      lim,
    )
    let pk = @v128.i16x8_narrow_i32x4_u(lo, hi)
    let u8 = @v128.i8x16_narrow_i16x8_u(pk, pk)
    @v128.v128_store(scratch, 0, u8)
    for t = 0; t < 8; t = t + 1 {
      out[i + t] = scratch[t]
    }
    i = i + 8
  }
  // scalar tail: the scalar port's per-pixel loop
  while i < dst_w {
    let mut val = dither8[i % 8] << 12
    for j in 0..<coffs.length() {
      val = val + sws_unpack_i16(rows[j], i) * coffs[j]
    }
    out[i] = sws_clip_uint8(val >> 19).to_byte()
    i = i + 1
  }
  out
}

///|
/// `sws_yuv2planeX_row_16` over packed rows, eight pixels per block.
#cfg(any(target="native", target="wasm", target="wasm-gc"))
pub fn sws_yuv2planeX_16_v128(
  rows : Array[FixedArray[Byte]],
  coffs : Array[Int32],
  dst_w : Int32,
  dst_bits : Int32,
) -> Array[Byte] {
  let shift = 11 + 16 - dst_bits
  let zero = @v128.i32x4_splat(0)
  let lim = @v128.i32x4_splat((1 << dst_bits) - 1)
  let out : Array[Byte] = Array::make(2 * dst_w, b'\x00')
  let scratch : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let mut i = 0
  while i + 8 <= dst_w {
    let mut alo = @v128.i32x4_splat(1 << (shift - 1))
    let mut ahi = alo
    for j in 0..<coffs.length() {
      let cv = @v128.i16x8_splat(coffs[j].to_uint16())
      let px = @v128.v128_load(rows[j], 2 * i)
      alo = @v128.i32x4_add(alo, @v128.i32x4_extmul_low_i16x8_s(px, cv))
      ahi = @v128.i32x4_add(ahi, @v128.i32x4_extmul_high_i16x8_s(px, cv))
    }
    let lo = @v128.i32x4_min_s(
      @v128.i32x4_max_s(@v128.i32x4_shr_s(alo, shift), zero),
      lim,
    )
    let hi = @v128.i32x4_min_s(
      @v128.i32x4_max_s(@v128.i32x4_shr_s(ahi, shift), zero),
      lim,
    )
    // little-endian u16 stores: the i16 lanes are the bytes
    @v128.v128_store(scratch, 0, @v128.i16x8_narrow_i32x4_u(lo, hi))
    for t = 0; t < 16; t = t + 1 {
      out[2 * i + t] = scratch[t]
    }
    i = i + 8
  }
  // scalar tail: the scalar port's per-pixel loop
  while i < dst_w {
    let mut val = 1 << (shift - 1)
    for j in 0..<coffs.length() {
      val = val + sws_unpack_i16(rows[j], i) * coffs[j]
    }
    let raw = val >> shift
    let clamped = if (raw & -(1 << dst_bits)) != 0 {
      if raw < 0 {
        0
      } else {
        (1 << dst_bits) - 1
      }
    } else {
      raw
    }
    out[2 * i] = (clamped & 0xFF).to_byte()
    out[2 * i + 1] = ((clamped >> 8) & 0xFF).to_byte()
    i = i + 1
  }
  out
}
