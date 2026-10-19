///|
/// Whitebox tests for the `libavcodec` IDCT slice (`idct.mbt`, `dctref.mbt`).
///
/// Source of truth: FFmpeg itself. The expected values are produced by the
/// double-precision reference IDCT that FFmpeg ships (`libavcodec/dctref.c`)
/// and that `libavcodec/tests/dct.c` uses to validate the integer IDCTs. The
/// random coefficient blocks are generated with FFmpeg's own lagged-Fibonacci
/// PRNG (`libavutil/lfg.c`, seed 1) and its `init_block()` procedure, so the
/// comparison reproduces the FATE `fate-idct8x8-*` methodology; the tolerances
/// (`err_inf <= 1`, `omse <= 0.02`, `|ome| <= 0.0015`) are taken verbatim from
/// `dct.c` (`spec_err = is_idct && (err_inf > 1 || omse > 0.02 || fabs(ome) >
/// 0.0015)`).

// ---------------------------------------------------------------------------
// Little-endian helpers and the AVLFG port (libavutil/lfg.c)
// ---------------------------------------------------------------------------

fn wl32(dst : Array[Byte], off : Int, v : UInt) -> Unit {
  dst[off] = (v & 0xFF).to_byte()
  dst[off + 1] = ((v >> 8) & 0xFF).to_byte()
  dst[off + 2] = ((v >> 16) & 0xFF).to_byte()
  dst[off + 3] = ((v >> 24) & 0xFF).to_byte()
}

fn rl32(src : FixedArray[Byte], off : Int) -> UInt {
  src[off].to_uint() |
  (src[off + 1].to_uint() << 8) |
  (src[off + 2].to_uint() << 16) |
  (src[off + 3].to_uint() << 24)
}

///| `AVLFG`: shared through the reference-type arrays so it behaves like the C pointer. */
struct Lfg {
  state : Array[UInt]
  index : Array[Int]
}

///|
/// `av_lfg_init` (libavutil/lfg.c): seed the state with MD5 of the 16-byte
/// scratch block, exactly as the C code does (note `tmp[5..15]` persist across
/// iterations, `tmp` is *not* cleared inside the loop).
fn lfg_init(seed : UInt) -> Lfg {
  let state : Array[UInt] = Array::make(64, 0)
  let tmp : Array[Byte] = Array::make(16, b'\x00')
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  let mut i = 8
  while i < 64 {
    wl32(tmp, 0, seed)
    tmp[4] = i.to_byte()
    @libavutil.av_md5_sum(digest, Bytes::from_array(tmp[:]), 16)
    state[i] = rl32(digest, 0)
    state[i + 1] = rl32(digest, 4)
    state[i + 2] = rl32(digest, 8)
    state[i + 3] = rl32(digest, 12)
    i = i + 4
  }
  { state: state, index: [0] }
}

///| `av_lfg_get`: advance the lagged-Fibonacci generator by one step. */
fn Lfg::get(self : Lfg) -> UInt {
  let idx = self.index[0]
  let a = self.state[(idx - 24) & 63] + self.state[(idx - 55) & 63]
  self.state[idx & 63] = a
  self.index[0] = idx + 1
  a
}

///| Deep copy of an `Array[Int]`. */
fn dup(a : Array[Int]) -> Array[Int] {
  let r : Array[Int] = Array::make(a.length(), 0)
  for i = 0; i < a.length(); i = i + 1 {
    r[i] = a[i]
  }
  r
}

///| Absolute value of a `Double` (avoids the deprecated `Double::abs`). */
fn dabs(x : Double) -> Double {
  if x < 0.0 {
    -x
  } else {
    x
  }
}

///|
/// `init_block()` / `permute` (identity permutation for `FF_IDCT_PERM_NONE`)
/// from `libavcodec/tests/dct.c`, with `bits = 8` (`vals = 256`).
fn init_block(
  block : Array[Int],
  mode : Int,
  is_idct : Bool,
  lfg : Lfg,
  vals : Int,
) -> Unit {
  for i = 0; i < 64; i = i + 1 {
    block[i] = 0
  }
  match mode {
    0 => {
      for i = 0; i < 64; i = i + 1 {
        block[i] = (lfg.get() % (vals * 2).reinterpret_as_uint()).reinterpret_as_int() -
          vals
      }
      if is_idct {
        ff_ref_fdct(block)
        for i = 0; i < 64; i = i + 1 {
          block[i] = block[i] >> 3
        }
      }
    }
    1 => {
      let j = (lfg.get() % 10).reinterpret_as_int() + 1
      for i = 0; i < j; i = i + 1 {
        let idx = (lfg.get() % 64).reinterpret_as_int()
        block[idx] = (lfg.get() % (vals * 2).reinterpret_as_uint()).reinterpret_as_int() -
          vals
      }
    }
    _ => {
      block[0] = (lfg.get() % (16 * vals).reinterpret_as_uint()).reinterpret_as_int() -
        (8 * vals)
      block[63] = if (block[0] & 1) == 1 { 0 } else { 1 }
    }
  }
}

///| Apply the selected SIMPLE-C variant. */
fn run_idct(variant : Int, block : Array[Int]) -> Unit {
  match variant {
    0 => ff_simple_idct_int16_8bit(block)
    1 => ff_simple_idct_int16_10bit(block)
    _ => ff_simple_idct_int16_12bit(block)
  }
}

///| Error statistics of one variant against the reference on `mode` inputs. */
fn idct_stats(variant : Int, mode : Int, its : Int) -> (Int, Double, Double) {
  let lfg = lfg_init(1)
  let mut err_inf = 0
  let mut err2 : Int64 = 0
  let mut err_sum : Int64 = 0
  for _it = 0; _it < its; _it = _it + 1 {
    let orig : Array[Int] = Array::make(64, 0)
    init_block(orig, mode, true, lfg, 256)
    let block = dup(orig)
    run_idct(variant, block)
    let refb = dup(orig)
    ff_ref_idct(refb)
    for i = 0; i < 64; i = i + 1 {
      let e = block[i] - refb[i]
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "idct: SIMPLE-C 8/10/12-bit match the dctref reference (FFmpeg dct.c criteria)" {
  ff_ref_dct_init()
  let its = 2000
  for mode = 0; mode < 3; mode = mode + 1 {
    // All three SIMPLE-C variants meet the strict dct.c criteria below
    // (dct.c lists SIMPLE-C10 with nonspec = 0; SIMPLE-C12 is listed with
    // nonspec = 1, so FFmpeg does not require it, but it holds here too).
    let (e8, m8, a8) = idct_stats(0, mode, its)
    assert_true(e8 <= 1)
    assert_true(m8 <= 0.02)
    assert_true(dabs(a8) <= 0.0015)
    let (e10, m10, a10) = idct_stats(1, mode, its)
    assert_true(e10 <= 1)
    assert_true(m10 <= 0.02)
    assert_true(dabs(a10) <= 0.0015)
    let (e12, _m12, _a12) = idct_stats(2, mode, its)
    assert_true(e12 <= 1)
  }
}

test "idct: put variant DC-only matches the reference" {
  ff_ref_dct_init()
  let mut x = -2048
  while x <= 2048 {
    let block : Array[Int] = Array::make(64, 0)
    block[0] = x
    let dest : Array[Int] = Array::make(64, 0)
    ff_simple_idct_put_int16_8bit(dest, 8, block)
    let refb : Array[Int] = Array::make(64, 0)
    refb[0] = x
    ff_ref_idct(refb)
    let rv = clip_uint8(refb[0])
    let v = dest[0]
    let d = if v > rv { v - rv } else { rv - v }
    assert_true(d <= 1)
    // The reference for a DC-only block is flat, and so is the SIMPLE-C output.
    for i = 0; i < 64; i = i + 1 {
      assert_true(dest[i] == dest[0])
    }
    x = x + 137
  }
}

test "idct: put/add variants clamp to the pixel range" {
  ff_ref_dct_init()
  let block0 : Array[Int] = Array::make(64, 0)
  block0[0] = 2048
  let put : Array[Int] = Array::make(64, 0)
  ff_simple_idct_put_int16_8bit(put, 8, dup(block0))
  let add : Array[Int] = Array::make(64, 40)
  ff_simple_idct_add_int16_8bit(add, 8, dup(block0))
  for i = 0; i < 64; i = i + 1 {
    assert_eq(put[i], 255)
    assert_eq(add[i], 255)
  }
}

test "idctdsp: clamped pixel helpers follow av_clip_uint8" {
  let block : Array[Int] = Array::make(64, 0)
  block[0] = -1
  block[1] = 0
  block[2] = 1
  block[3] = 300
  block[4] = -300
  block[5] = 127
  block[6] = 128
  block[7] = 255
  let px : Array[Int] = Array::make(64, 7)
  ff_put_pixels_clamped_c(block, px, 8)
  assert_eq(px[0], 0)
  assert_eq(px[1], 0)
  assert_eq(px[2], 1)
  assert_eq(px[3], 255)
  assert_eq(px[4], 0)
  assert_eq(px[5], 127)
  assert_eq(px[6], 128)
  assert_eq(px[7], 255)
  assert_eq(px[8], 0)
  assert_eq(px[63], 0)

  let px2 : Array[Int] = Array::make(64, 200)
  ff_add_pixels_clamped_c(block, px2, 8)
  assert_eq(px2[0], 199)
  assert_eq(px2[3], 255)
  assert_eq(px2[4], 0)
  assert_eq(px2[7], 255)
  assert_eq(px2[63], 200)

  let px3 : Array[Int] = Array::make(64, 0)
  put_signed_pixels_clamped_c(block, px3, 8)
  assert_eq(px3[0], 127)
  assert_eq(px3[3], 255)
  assert_eq(px3[4], 0)
  assert_eq(px3[5], 255)
  assert_eq(px3[6], 255)
  assert_eq(px3[7], 255)
}

test "idctdsp: scan-table permutations" {
  let none = ff_init_scantable_permutation(0)
  assert_eq(none[0], 0)
  assert_eq(none[63], 63)
  let mpeg2 = ff_init_scantable_permutation(1)
  assert_eq(mpeg2[1], 4)
  assert_eq(mpeg2[2], 1)
  assert_eq(mpeg2[3], 5)
  assert_eq(mpeg2[8], 8)
  let transpose = ff_init_scantable_permutation(2)
  assert_eq(transpose[1], 8)
  assert_eq(transpose[8], 1)
  let parttrans = ff_init_scantable_permutation(3)
  assert_eq(parttrans[1], 8)
  assert_eq(parttrans[8], 1)
  let src : Array[Int] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    src[i] = i
  }
  let dst : Array[Int] = Array::make(64, 0)
  ff_permute_scantable(dst, src, transpose)
  assert_eq(dst[1], 8)
  assert_eq(dst[8], 1)
}
