///|
/// SIMD (`@v128`) versions of the VP9 intra prediction kernels for 4x4
/// through 32x32 transform blocks (`libavcodec/vp9dsp_template.c`:
/// `dc_*`/`v_*`/`h_*`/`tm_*`/`dl_*`/`dr_*`/`vl_*`/`vr_*`/`hd_*`/`hu_*`
/// plus the `dc_left`/`dc_top`/`dc_128` variants; the scalar ports are the
/// `vp9_pred_*` family in `libavcodec/vp9_dsp.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/vp9intrapred.asm`: `vp9_ipred_dc_{4,8,16,32}x*`,
/// `vp9_ipred_v_*`, `vp9_ipred_h_*`, `vp9_ipred_tm_*`, `vp9_ipred_dl_*`,
/// `vp9_ipred_dr_*`, `vp9_ipred_vl_*`, `vp9_ipred_vr_*`, `vp9_ipred_hd_*`,
/// `vp9_ipred_hu_*`).
///
/// The asm's shape is kept: the flat modes (`dc`, `v`, `h`, `tm` and the
/// DC variants) broadcast a row vector and store it with one `mova` per
/// 16 pixels, which here is an `i32x4` splat plus 4-lane stores; the
/// directional modes (`dl`/`dr`/`vl`/`vr`/`hd`/`hu`) first build the
/// `v[]` interpolation table from the edge samples — that part is O(n)
/// and stays scalar, exactly as the asm computes it in registers before
/// the row loop — and then fill each output row from a **contiguous
/// window** of `v[]` (`p[i][j] = v[base - j + i]`), which is where the
/// O(n^2) cost lives and what the 4-lane store loop vectorises.
///
/// `i32x4` lanes carry the port's `FixedArray[Int32]` plane values
/// directly, so `tm`'s `clip_pixel(top[x] + left[y] - top[0])` and the
/// DC rounding are the scalar port's own arithmetic — no re-derivation of
/// the C's `i16`/`packuswb` saturation behaviour is needed.
///
/// Deviations (documented): the asm has a per-size entry point for every
/// mode (and 4x4 versions hand-unrolled sample by sample); here one kernel
/// per mode takes `n` in {4, 8, 16, 32}, matching the scalar port's single
/// `n`-parameterised functions. The 4x4 hand-unrolled forms of the
/// scalar port produce the same values as its generic forms (verified by
/// the wbtest over all sizes), so only the generic form is vectorised.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `vp9_ipred_v128_wbtest.mbt`.

///|
/// Mode codes, mirroring `libavcodec/vp9_dsp.mbt`'s `VP9_*_PRED`. */
#cfg(any(target="native", target="wasm"))
let vip_dc : Int32 = 0
#cfg(any(target="native", target="wasm"))
let vip_v : Int32 = 1
#cfg(any(target="native", target="wasm"))
let vip_h : Int32 = 2
#cfg(any(target="native", target="wasm"))
let vip_dl : Int32 = 3
#cfg(any(target="native", target="wasm"))
let vip_dr : Int32 = 4
#cfg(any(target="native", target="wasm"))
let vip_vr : Int32 = 5
#cfg(any(target="native", target="wasm"))
let vip_hd : Int32 = 6
#cfg(any(target="native", target="wasm"))
let vip_vl : Int32 = 7
#cfg(any(target="native", target="wasm"))
let vip_hu : Int32 = 8
#cfg(any(target="native", target="wasm"))
let vip_tm : Int32 = 9
#cfg(any(target="native", target="wasm"))
let vip_left_dc : Int32 = 10
#cfg(any(target="native", target="wasm"))
let vip_top_dc : Int32 = 11
#cfg(any(target="native", target="wasm"))
let vip_dc_128 : Int32 = 12
#cfg(any(target="native", target="wasm"))
let vip_dc_127 : Int32 = 13
#cfg(any(target="native", target="wasm"))
let vip_dc_255 : Int32 = 14

///|
/// Load four lane values from a small `FixedArray[Int32]` table. */
#cfg(any(target="native", target="wasm"))
fn vip_load4(v : FixedArray[Int32], at : Int32) -> V128 {
  let mut r = @v128.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    r = @v128.i32x4_replace_lane(r, v[at + i].reinterpret_as_uint(), i)
    i = i + 1
  }
  r
}

///|
/// Store four lanes to the destination plane. */
#cfg(any(target="native", target="wasm"))
fn vip_store4(p : FixedArray[Int32], at : Int32, v : V128) -> Unit {
  let mut i = 0
  while i < 4 {
    p[at + i] = @v128.i32x4_extract_lane(v, i).reinterpret_as_int()
    i = i + 1
  }
}

///|
/// Fill `n` output rows with one constant row vector (the `mova`-per-row
/// body of the flat modes). */
#cfg(any(target="native", target="wasm"))
fn vip_fill_rows(
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  n : Int32,
  rowv : V128,
) -> Unit {
  for y = 0; y < n; y = y + 1 {
    let base = off + y * stride
    let mut x = 0
    while x + 4 <= n {
      vip_store4(p, base + x, rowv)
      x = x + 4
    }
    while x < n {
      p[base + x] = @v128.i32x4_extract_lane(rowv, 0).reinterpret_as_int()
      x = x + 1
    }
  }
}

///|
/// Copy `n` contiguous entries of `v` starting at `vbase` into one output
/// row (the directional modes' row fill). */
#cfg(any(target="native", target="wasm"))
fn vip_row_window(
  p : FixedArray[Int32],
  dstrow : Int32,
  v : FixedArray[Int32],
  vbase : Int32,
  n : Int32,
  filler : Int32,
  nvalid : Int32,
) -> Unit {
  let mut x = 0
  while x + 4 <= n && x + 4 <= nvalid {
    vip_store4(p, dstrow + x, vip_load4(v, vbase + x))
    x = x + 4
  }
  while x < nvalid {
    p[dstrow + x] = v[vbase + x]
    x = x + 1
  }
  while x < n {
    p[dstrow + x] = filler
    x = x + 1
  }
}

///|
/// `vp9_intra_pred` with the flat modes broadcast through `@v128` and the
/// directional ones filling rows from their interpolation table.
#cfg(any(target="native", target="wasm"))
pub fn vp9_intra_pred_v128(
  n : Int32,
  mode : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  left : FixedArray[Int32],
  top : FixedArray[Int32],
  pixel_mid : Int32,
  pixel_max : Int32,
) -> Unit {
  let shift : Int32 = if n == 4 {
    3
  } else if n == 8 {
    4
  } else if n == 16 {
    5
  } else {
    6
  }
  if mode == vip_v {
    // every row repeats top[1..n]
    let mut x = 0
    while x + 4 <= n {
      vip_store4(p, off + x, vip_load4(top, 1 + x))
      x = x + 4
    }
    while x < n {
      p[off + x] = top[1 + x]
      x = x + 1
    }
    for y = 1; y < n; y = y + 1 {
      let base = off + y * stride
      let mut x2 = 0
      while x2 + 4 <= n {
        vip_store4(p, base + x2, vip_load4(top, 1 + x2))
        x2 = x2 + 4
      }
      while x2 < n {
        p[base + x2] = top[1 + x2]
        x2 = x2 + 1
      }
    }
  } else if mode == vip_h {
    // row y repeats left[n-1-y]
    for y = 0; y < n; y = y + 1 {
      let rowv = @v128.i32x4_splat(left[n - 1 - y].reinterpret_as_uint())
      let base = off + y * stride
      let mut x = 0
      while x + 4 <= n {
        vip_store4(p, base + x, rowv)
        x = x + 4
      }
      while x < n {
        p[base + x] = left[n - 1 - y]
        x = x + 1
      }
    }
  } else if mode == vip_dc {
    let mut sum = n
    for i = 0; i < n; i = i + 1 {
      sum += left[i] + top[1 + i]
    }
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((sum >> shift).reinterpret_as_uint()),
    )
  } else if mode == vip_left_dc {
    let mut sum = n >> 1
    for i = 0; i < n; i = i + 1 {
      sum += left[i]
    }
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((sum >> (shift - 1)).reinterpret_as_uint()),
    )
  } else if mode == vip_top_dc {
    let mut sum = n >> 1
    for i = 0; i < n; i = i + 1 {
      sum += top[1 + i]
    }
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((sum >> (shift - 1)).reinterpret_as_uint()),
    )
  } else if mode == vip_dc_128 {
    vip_fill_rows(p, off, stride, n, @v128.i32x4_splat(pixel_mid.reinterpret_as_uint()))
  } else if mode == vip_dc_127 {
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((pixel_mid - 1).reinterpret_as_uint()),
    )
  } else if mode == vip_dc_255 {
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((pixel_mid + 1).reinterpret_as_uint()),
    )
  } else if mode == vip_tm {
    // top[x] + left[y] - top[0], clipped per lane
    let tl = top[0]
    let lo = @v128.i32x4_splat(0)
    let hi = @v128.i32x4_splat(pixel_max.reinterpret_as_uint())
    for y = 0; y < n; y = y + 1 {
      let lmt = @v128.i32x4_splat((left[n - 1 - y] - tl).reinterpret_as_uint())
      let base = off + y * stride
      let mut x = 0
      while x + 4 <= n {
        let t = vip_load4(top, 1 + x)
        vip_store4(
          p,
          base + x,
          @v128.i32x4_min_s(@v128.i32x4_max_s(@v128.i32x4_add(t, lmt), lo), hi),
        )
        x = x + 4
      }
      while x < n {
        let v = top[1 + x] + (left[n - 1 - y] - tl)
        p[base + x] = if v < 0 {
          0
        } else if v > pixel_max {
          pixel_max
        } else {
          v
        }
        x = x + 1
      }
    }
  } else if mode == vip_dl {
    let v : FixedArray[Int32] = FixedArray::make(n, 0)
    for i = 0; i < n - 2; i = i + 1 {
      v[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    v[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
    for j = 0; j < n; j = j + 1 {
      vip_row_window(p, off + j * stride, v, j, n, top[n], n - 1 - j)
    }
  } else if mode == vip_dr {
    let v : FixedArray[Int32] = FixedArray::make(n + n - 1, 0)
    for i = 0; i < n - 2; i = i + 1 {
      v[i] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
      v[n + 1 + i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    v[n - 2] = (left[n - 2] + left[n - 1] * 2 + top[0] + 2) >> 2
    v[n - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
    v[n] = (top[0] + top[1] * 2 + top[2] + 2) >> 2
    for j = 0; j < n; j = j + 1 {
      vip_row_window(p, off + j * stride, v, n - 1 - j, n, 0, n)
    }
  } else if mode == vip_vr {
    let ve : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
    let vo : FixedArray[Int32] = FixedArray::make(n + n / 2 - 1, 0)
    for i = 0; i < n / 2 - 2; i = i + 1 {
      vo[i] = (left[i * 2 + 3] + left[i * 2 + 2] * 2 + left[i * 2 + 1] + 2) >> 2
      ve[i] = (left[i * 2 + 4] + left[i * 2 + 3] * 2 + left[i * 2 + 2] + 2) >> 2
    }
    vo[n / 2 - 2] = (left[n - 1] + left[n - 2] * 2 + left[n - 3] + 2) >> 2
    ve[n / 2 - 2] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
    ve[n / 2 - 1] = (top[0] + top[1] + 1) >> 1
    vo[n / 2 - 1] = (left[n - 1] + top[0] * 2 + top[1] + 2) >> 2
    for i = 0; i < n - 1; i = i + 1 {
      ve[n / 2 + i] = (top[1 + i] + top[2 + i] + 1) >> 1
      vo[n / 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
    }
    for j = 0; j < n / 2; j = j + 1 {
      vip_row_window(p, off + (j * 2) * stride, ve, n / 2 - 1 - j, n, 0, n)
      vip_row_window(p, off + (j * 2 + 1) * stride, vo, n / 2 - 1 - j, n, 0, n)
    }
  } else if mode == vip_vl {
    let ve : FixedArray[Int32] = FixedArray::make(n - 1, 0)
    let vo : FixedArray[Int32] = FixedArray::make(n - 1, 0)
    for i = 0; i < n - 2; i = i + 1 {
      ve[i] = (top[1 + i] + top[2 + i] + 1) >> 1
      vo[i] = (top[1 + i] + top[2 + i] * 2 + top[3 + i] + 2) >> 2
    }
    ve[n - 2] = (top[n - 1] + top[n] + 1) >> 1
    vo[n - 2] = (top[n - 1] + top[n] * 3 + 2) >> 2
    for j = 0; j < n / 2; j = j + 1 {
      vip_row_window(p, off + (j * 2) * stride, ve, j, n, top[n], n - j - 1)
      vip_row_window(
        p,
        off + (j * 2 + 1) * stride,
        vo,
        j,
        n,
        top[n],
        n - j - 1,
      )
    }
  } else if mode == vip_hd {
    let v : FixedArray[Int32] = FixedArray::make(n * 3 - 2, 0)
    for i = 0; i < n - 2; i = i + 1 {
      v[i * 2] = (left[i + 1] + left[i] + 1) >> 1
      v[i * 2 + 1] = (left[i + 2] + left[i + 1] * 2 + left[i] + 2) >> 2
      v[n * 2 + i] = (top[i] + top[1 + i] * 2 + top[2 + i] + 2) >> 2
    }
    v[n * 2 - 2] = (top[0] + left[n - 1] + 1) >> 1
    v[n * 2 - 4] = (left[n - 1] + left[n - 2] + 1) >> 1
    v[n * 2 - 1] = (top[1] + top[0] * 2 + left[n - 1] + 2) >> 2
    v[n * 2 - 3] = (top[0] + left[n - 1] * 2 + left[n - 2] + 2) >> 2
    for j = 0; j < n; j = j + 1 {
      vip_row_window(p, off + j * stride, v, n * 2 - 2 - j * 2, n, 0, n)
    }
  } else if mode == vip_hu {
    let v : FixedArray[Int32] = FixedArray::make(n * 2 - 2, 0)
    for i = 0; i < n - 2; i = i + 1 {
      v[i * 2] = (left[i] + left[i + 1] + 1) >> 1
      v[i * 2 + 1] = (left[i] + left[i + 1] * 2 + left[i + 2] + 2) >> 2
    }
    v[n * 2 - 4] = (left[n - 2] + left[n - 1] + 1) >> 1
    v[n * 2 - 3] = (left[n - 2] + left[n - 1] * 3 + 2) >> 2
    for j = 0; j < n / 2; j = j + 1 {
      vip_row_window(p, off + j * stride, v, j * 2, n, 0, n)
    }
    for j = n / 2; j < n; j = j + 1 {
      vip_row_window(
        p,
        off + j * stride,
        v,
        j * 2,
        n,
        left[n - 1],
        n * 2 - 2 - j * 2,
      )
    }
  } else {
    vip_fill_rows(
      p,
      off,
      stride,
      n,
      @v128.i32x4_splat((pixel_mid + 1).reinterpret_as_uint()),
    )
  }
}
