///|
/// Whitebox tests for the SIMD (`@v128`) H.264 chroma MC kernel
/// (`h264_chromamc_v128.mbt`).
///
/// The `hc_*` reference is a verbatim transcription of the scalar port
/// (`h264_mc_chroma` in `libavcodec/h264_mc.mbt`) — the parent
/// package's privates are not visible from a subpackage — and the SIMD
/// kernel must match it on every output pixel, across subpel phases,
/// geometries, chroma shifts and edge-clamped windows.

///|
fn hc_clamp(v : Int32, limit : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v >= limit {
    limit - 1
  } else {
    v
  }
}

///|
/// Verbatim `h264_mc_chroma`. */
fn hc_mc_chroma(
  dst : Array[Int32],
  dstoff : Int32,
  dstride : Int32,
  src : Array[Int32],
  src_x : Int32,
  src_y : Int32,
  mx : Int32,
  my : Int32,
  sstride : Int32,
  w : Int32,
  h : Int32,
  pic_w : Int32,
  pic_h : Int32,
  sbase : Int32,
  vshift : Int32,
) -> Unit {
  let ysh = 2 + vshift
  let fy = src_y + (my >> ysh)
  let dx = mx & 7
  let dy = if vshift == 1 { my & 7 } else { (my << 1) & 7 }
  let ax = 8 - dx
  let ay = 8 - dy
  for row = 0; row < h; row = row + 1 {
    let y0 = hc_clamp(fy + row, pic_h)
    let y1 = hc_clamp(fy + row + 1, pic_h)
    for col = 0; col < w; col = col + 1 {
      let fx = src_x + (mx >> 3)
      let xa = hc_clamp(fx + col, pic_w)
      let xb = hc_clamp(fx + col + 1, pic_w)
      let a = src[sbase + y0 * sstride + xa]
      let b = src[sbase + y0 * sstride + xb]
      let c = src[sbase + y1 * sstride + xa]
      let d = src[sbase + y1 * sstride + xb]
      dst[dstoff + row * dstride + col] = (
          a * ax * ay + b * dx * ay + c * ax * dy + d * dx * dy + 32
        ) >>
        6
    }
  }
}

///|
/// Deterministic pixel-plane generator (LCG). */
fn hc_gen_px(seed : UInt32, n : Int32, max : Int32) -> Array[Int32] {
  let a : Array[Int32] = Array::make(n, 0)
  let mut s = seed
  for i = 0; i < n; i = i + 1 {
    s = s * 1103515245U + 12345U
    a[i] = ((s >> 16) & 0xFFU).reinterpret_as_int() % (max + 1)
  }
  a
}

///|
test "chroma mc v128: equality across phases, geometry and clamping" {
  let pic_w : Int32 = 24
  let pic_h : Int32 = 20
  let sstride : Int32 = pic_w
  let src = hc_gen_px(0x9E3779B9U, pic_w * pic_h, 255)
  let dstride : Int32 = 16
  let dst_n = dstride * 12
  let phases : Array[Int32] = [0, 1, 2, 3, 4, 5, 6, 7]
  for vshift in [1, 0] {
    for dx in phases {
      for dy in phases {
        // mx/my encode dx/dy in their low bits (mx>>3 gives the base x)
        let mx = 8 + dx
        let my = (8 + dy) << vshift
        let dims_list : Array[(Int32, Int32)] = [
          (4, 4), (8, 4), (4, 8), (8, 8),
        ]
        for dims in dims_list {
          let (w, h) = dims
          // interior, right/bottom edge and off-frame left/top windows
          let windows : Array[(Int32, Int32)] = [
            (10, 8), (pic_w - 2, pic_h - 2), (-3, -2),
          ]
          for xy in windows {
            let (sx, sy) = xy
            let d1 = hc_gen_px(0xDEADBEEFU, dst_n, 255)
            let d2 = Array::make(dst_n, 0)
            for i = 0; i < dst_n; i = i + 1 {
              d2[i] = d1[i]
            }
            hc_mc_chroma(
              d1, 3 * dstride + 2, dstride, src, sx, sy, mx, my, sstride, w, h, pic_w, pic_h, 0, vshift,
            )
            h264_mc_chroma_v128(
              d2, 3 * dstride + 2, dstride, src, sx, sy, mx, my, sstride, w, h, pic_w, pic_h, sbase=0, vshift=vshift,
            )
            for r = 0; r < h; r = r + 1 {
              for c = 0; c < w; c = c + 1 {
                let p = 3 * dstride + 2 + r * dstride + c
                assert_eq(d2[p], d1[p])
              }
            }
          }
        }
      }
    }
  }
}

///|
test "chroma mc v128: zero phase is a pure copy" {
  let pic_w : Int32 = 16
  let pic_h : Int32 = 12
  let src = hc_gen_px(0xA5A5A5A5U, pic_w * pic_h, 255)
  let d : Array[Int32] = Array::make(8 * 8, -1)
  h264_mc_chroma_v128(
    d, 0, 8, src, 4, 2, 0, 0, pic_w, 8, 8, pic_w, pic_h, sbase=0, vshift=1,
  )
  for r = 0; r < 8; r = r + 1 {
    for c = 0; c < 8; c = c + 1 {
      assert_eq(d[r * 8 + c], src[(2 + r) * pic_w + 4 + c])
    }
  }
}
