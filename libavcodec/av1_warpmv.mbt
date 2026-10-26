///|
/// Warp affine motion derivation: port of dav1d 1.5.1 `src/warpmv.c`
/// (`dav1d_find_affine_int`, `dav1d_get_shear_params`,
/// `dav1d_set_affine_mv2d`) plus `derive_warpmv` from `src/decode.c`.
/// Matrices use dav1d's 16.16 fixed point; shear parameters are the
/// `u.p.alpha/beta/gamma/delta` projection values.

///|
/// `div_lut` from dav1d `warpmv.c` (1/(1 + f/256) in Q14).
let av1_warpmv_div_lut : FixedArray[Int] = [
  16384, 16320, 16257, 16194, 16132, 16070, 16009, 15948, 15888, 15828, 15768,
  15709, 15650, 15592, 15534, 15477, 15420, 15364, 15308, 15252, 15197, 15142,
  15087, 15033, 14980, 14926, 14873, 14821, 14769, 14717, 14665, 14614, 14564,
  14513, 14463, 14413, 14364, 14315, 14266, 14218, 14170, 14122, 14075, 14028,
  13981, 13935, 13888, 13843, 13797, 13752, 13707, 13662, 13618, 13574, 13530,
  13487, 13443, 13400, 13358, 13315, 13273, 13231, 13190, 13148, 13107, 13066,
  13026, 12985, 12945, 12906, 12866, 12827, 12788, 12749, 12710, 12672, 12633,
  12596, 12558, 12520, 12483, 12446, 12409, 12373, 12336, 12300, 12264, 12228,
  12193, 12157, 12122, 12087, 12053, 12018, 11984, 11950, 11916, 11882, 11848,
  11815, 11782, 11749, 11716, 11683, 11651, 11619, 11586, 11555, 11523, 11491,
  11460, 11429, 11398, 11367, 11336, 11305, 11275, 11245, 11215, 11185, 11155,
  11125, 11096, 11067, 11038, 11009, 10980, 10951, 10923, 10894, 10866, 10838,
  10810, 10782, 10755, 10727, 10700, 10673, 10645, 10618, 10592, 10565, 10538,
  10512, 10486, 10460, 10434, 10408, 10382, 10356, 10331, 10305, 10280, 10255,
  10230, 10205, 10180, 10156, 10131, 10107, 10082, 10058, 10034, 10010, 9986,
  9963, 9939, 9916, 9892, 9869, 9846, 9823, 9800, 9777, 9754, 9732,
  9709, 9687, 9664, 9642, 9620, 9598, 9576, 9554, 9533, 9511, 9489,
  9468, 9447, 9425, 9404, 9383, 9362, 9341, 9321, 9300, 9279, 9259,
  9239, 9218, 9198, 9178, 9158, 9138, 9118, 9098, 9079, 9059, 9039,
  9020, 9001, 8981, 8962, 8943, 8924, 8905, 8886, 8867, 8849, 8830,
  8812, 8793, 8775, 8756, 8738, 8720, 8702, 8684, 8666, 8648, 8630,
  8613, 8595, 8577, 8560, 8542, 8525, 8508, 8490, 8473, 8456, 8439,
  8422, 8405, 8389, 8372, 8355, 8339, 8322, 8306, 8289, 8273, 8257,
  8240, 8224, 8208, 8192,
]

///|
/// dav1d `Dav1dWarpedMotionParams`: type 0 identity, 1 translation,
/// 2 rot-zoom, 3 affine.
pub(all) struct Av1WarpedMotion {
  mut typ : Int
  matrix : FixedArray[Int] // [6], 16.16 fixed point
  mut alpha : Int
  mut beta : Int
  mut gamma : Int
  mut delta : Int
}

///|
pub fn av1_warpmv_default() -> Av1WarpedMotion {
  {
    typ: 0,
    matrix: [0, 0, 0x10000, 0, 0, 0x10000],
    alpha: 0,
    beta: 0,
    gamma: 0,
    delta: 0,
  }
}

///|
fn av1_warp_clip(v : Int, lo : Int, hi : Int) -> Int {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn av1_warp_abs(v : Int) -> Int {
  if v < 0 { -v } else { v }
}

///|
fn av1_warp_abs64(v : Int64) -> Int64 {
  if v < 0L { -v } else { v }
}

///|
fn av1_warp_sign(v : Int64) -> Int {
  if v < 0L { -1 } else { 1 }
}

///|
fn av1_warp_apply_sign(v : Int, sign : Int) -> Int {
  if sign < 0 { -v } else { v }
}

///|
fn av1_warp_ulog2(v : UInt) -> Int {
  let mut x = v
  let mut n = 0
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
fn av1_warp_ulog2_64(v : UInt64) -> Int {
  let mut x = v
  let mut n = 0
  while x > 1 {
    x = x >> 1
    n = n + 1
  }
  n
}

///|
fn av1_warp_iclip_wmp(v : Int) -> Int {
  let cv = av1_warp_clip(v, -32768, 32767)
  av1_warp_apply_sign((av1_warp_abs(cv) + 32) >> 6, cv) << 6
}

///|
fn av1_warp_resolve_divisor_32(d : UInt) -> (Int, Int) {
  let shift0 = av1_warp_ulog2(d)
  let e = d.reinterpret_as_int() - (1 << shift0)
  let f = if shift0 > 8 {
    (e + (1 << (shift0 - 9))) >> (shift0 - 8)
  } else {
    e << (8 - shift0)
  }
  (av1_warpmv_div_lut[f], shift0 + 14)
}

///|
fn av1_warp_resolve_divisor_64(d : UInt64) -> (Int, Int) {
  let shift0 = av1_warp_ulog2_64(d)
  let e = d.reinterpret_as_int64() - (1L << shift0)
  let f = if shift0 > 8 {
    (e + (1L << (shift0 - 9))) >> (shift0 - 8)
  } else {
    e << (8 - shift0)
  }
  (av1_warpmv_div_lut[f.to_int()], shift0 + 14)
}

///|
/// `dav1d_get_shear_params`. Returns true when the model is invalid
/// (divergence too large); shear fields are updated either way.
pub fn av1_warpmv_get_shear_params(wm : Av1WarpedMotion) -> Bool {
  let mat = wm.matrix
  if mat[2] <= 0 {
    return true
  }
  wm.alpha = av1_warp_iclip_wmp(mat[2] - 0x10000)
  wm.beta = av1_warp_iclip_wmp(mat[3])
  let (mult, shift) = av1_warp_resolve_divisor_32(
    av1_warp_abs(mat[2]).reinterpret_as_uint(),
  )
  let y = av1_warp_apply_sign(mult, mat[2])
  let rnd = (1 << shift) >> 1
  let v1 = mat[4].to_int64() * 0x10000L * y.to_int64()
  let t1 = ((av1_warp_abs64(v1) + rnd.to_int64()) >> shift).to_int()
  wm.gamma = av1_warp_iclip_wmp(av1_warp_apply_sign(t1, av1_warp_sign(v1)))
  let v2 = mat[3].to_int64() * mat[4].to_int64() * y.to_int64()
  let t2 = ((av1_warp_abs64(v2) + rnd.to_int64()) >> shift).to_int()
  wm.delta = av1_warp_iclip_wmp(
    mat[5] - av1_warp_apply_sign(t2, av1_warp_sign(v2)) - 0x10000,
  )
  (4 * av1_warp_abs(wm.alpha) + 7 * av1_warp_abs(wm.beta) >= 0x10000) ||
  (4 * av1_warp_abs(wm.gamma) + 4 * av1_warp_abs(wm.delta) >= 0x10000)
}

///|
fn av1_warp_mult_shift(px : Int64, idet : Int, shift : Int, diag : Bool) -> Int {
  let v1 = px * idet.to_int64()
  let v2 = av1_warp_apply_sign(
    ((av1_warp_abs64(v1) + ((1L << shift) >> 1)) >> shift).to_int(),
    av1_warp_sign(v1),
  )
  if diag {
    av1_warp_clip(v2, 0xe001, 0x11fff)
  } else {
    av1_warp_clip(v2, -0x1fff, 0x1fff)
  }
}

///|
/// `dav1d_find_affine_int`: least-squares fit from `np` samples
/// (`pts[i*4 + 0..1]` = source x/y, `+ 2..3` = projected x/y). Returns
/// true on a singular system, matching dav1d's nonzero return.
pub fn av1_warpmv_find_affine_int(
  pts : FixedArray[Int],
  np : Int,
  bw4 : Int,
  bh4 : Int,
  mv : (Int, Int),
  bx4 : Int,
  by4 : Int,
  wm : Av1WarpedMotion,
) -> Bool {
  let mat = wm.matrix
  let mut a00 = 0
  let mut a01 = 0
  let mut a11 = 0
  let mut bx0 = 0
  let mut bx1 = 0
  let mut by0 = 0
  let mut by1 = 0
  let rsuy = 2 * bh4 - 1
  let rsux = 2 * bw4 - 1
  let suy = rsuy * 8
  let sux = rsux * 8
  let (mvy, mvx) = mv
  let duy = suy + mvy
  let dux = sux + mvx
  let isuy = by4 * 4 + rsuy
  let isux = bx4 * 4 + rsux
  for i in 0..<np {
    let sx = pts[i * 4] - sux
    let sy = pts[i * 4 + 1] - suy
    let dx = pts[i * 4 + 2] - dux
    let dy = pts[i * 4 + 3] - duy
    if av1_warp_abs(sx - dx) < 256 && av1_warp_abs(sy - dy) < 256 {
      a00 = a00 + ((sx * sx) >> 2) + sx * 2 + 8
      a01 = a01 + ((sx * sy) >> 2) + sx + sy + 4
      a11 = a11 + ((sy * sy) >> 2) + sy * 2 + 8
      bx0 = bx0 + ((sx * dx) >> 2) + sx + dx + 8
      bx1 = bx1 + ((sy * dx) >> 2) + sy + dx + 4
      by0 = by0 + ((sx * dy) >> 2) + sx + dy + 4
      by1 = by1 + ((sy * dy) >> 2) + sy + dy + 8
    }
  }
  let det = a00.to_int64() * a11.to_int64() - a01.to_int64() * a01.to_int64()
  if det == 0L {
    return true
  }
  let (mult, shift0) = av1_warp_resolve_divisor_64(av1_warp_abs64(det).reinterpret_as_uint64())
  let mut idet = av1_warp_apply_sign(mult, av1_warp_sign(det))
  let mut shift = shift0 - 16
  if shift < 0 {
    idet = idet << -shift
    shift = 0
  }
  mat[2] = av1_warp_mult_shift(
    a11.to_int64() * bx0.to_int64() - a01.to_int64() * bx1.to_int64(),
    idet, shift, true,
  )
  mat[3] = av1_warp_mult_shift(
    a00.to_int64() * bx1.to_int64() - a01.to_int64() * bx0.to_int64(),
    idet, shift, false,
  )
  mat[4] = av1_warp_mult_shift(
    a11.to_int64() * by0.to_int64() - a01.to_int64() * by1.to_int64(),
    idet, shift, false,
  )
  mat[5] = av1_warp_mult_shift(
    a00.to_int64() * by1.to_int64() - a01.to_int64() * by0.to_int64(),
    idet, shift, true,
  )
  mat[0] = av1_warp_clip(
    mvx * 0x2000 - (isux * (mat[2] - 0x10000) + isuy * mat[3]),
    -0x800000, 0x7fffff,
  )
  mat[1] = av1_warp_clip(
    mvy * 0x2000 - (isux * mat[4] + isuy * (mat[5] - 0x10000)),
    -0x800000, 0x7fffff,
  )
  false
}

///|
/// `dav1d_set_affine_mv2d`: anchor an existing warp model at the block
/// centre with `mv`.
pub fn av1_warpmv_set_affine_mv2d(
  bw4 : Int,
  bh4 : Int,
  mv : (Int, Int),
  bx4 : Int,
  by4 : Int,
  wm : Av1WarpedMotion,
) -> Unit {
  let mat = wm.matrix
  let rsuy = 2 * bh4 - 1
  let rsux = 2 * bw4 - 1
  let isuy = by4 * 4 + rsuy
  let isux = bx4 * 4 + rsux
  let (mvy, mvx) = mv
  mat[0] = av1_warp_clip(
    mvx * 0x2000 - (isux * (mat[2] - 0x10000) + isuy * mat[3]),
    -0x800000, 0x7fffff,
  )
  mat[1] = av1_warp_clip(
    mvy * 0x2000 - (isux * mat[4] + isuy * (mat[5] - 0x10000)),
    -0x800000, 0x7fffff,
  )
}
