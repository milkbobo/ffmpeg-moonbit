///|
/// libswscale port, slice 2: generic planar scaling for 8-bit YUV 4:2:0
/// input and output (`utils.c` `initFilter` + `swscale.c` `hScale8To15_c`
/// + `output.c` `yuv2planeX_8_c`, the legacy path that FFmpeg 9's
/// `run_legacy_swscale` still executes).  Arithmetic is all integer
/// (fixed-point filter design included - the bicubic branch never calls
/// libm), so the port is byte-exact against the C reference (verified
/// with an `av_force_cpu_flags(0)` harness inside docker).  Note the
/// x86 SIMD build picks `filterAlign = 4`, whose error-diffusion
/// normalization differs by +/-1 on a handful of pixels; that dual
/// official path is documented, and this port follows the C scalar
/// semantics (§323 precedent).
///
/// Original FFmpeg code is LGPL-2.1-or-later (GNU GPL-2.0-or-later for
/// the scale kernels); this port keeps the same license.

///|
pub enum SwsScaleAlgo {
  Bicubic // default of both `sws_getContext` flags and vf_scale
}

///|
/// Chroma subsampling of the planar YUV formats this scaler accepts;
/// `av_pix_fmt_get_chroma_sub_sample` gives the (h, v) shifts.
pub(all) enum SwsChromaFmt {
  Yuv420
  Yuv422
  Yuv444
}

///|
fn SwsChromaFmt::shifts(self : SwsChromaFmt) -> (Int32, Int32) {
  match self {
    Yuv420 => (1, 1)
    Yuv422 => (1, 0)
    Yuv444 => (0, 0)
  }
}

///|
/// `AV_CEIL_RSHIFT(w, s)` - always round toward +inf.
fn sws_ceil_rshift(w : Int32, s : Int32) -> Int32 {
  (w + (1 << s) - 1) >> s
}

///|
/// Evenness required by a format's own subsampling: 4:2:0 both
/// dimensions, 4:2:2 width only, 4:4:4 nothing.
fn sws_fmt_even_ok(fmt : SwsChromaFmt, w : Int32, h : Int32) -> Bool {
  if fmt is Yuv420 {
    w % 2 == 0 && h % 2 == 0
  } else if fmt is Yuv422 {
    w % 2 == 0
  } else {
    true
  }
}

///|
/// `ff_dither_8x8_128`: the ordered dither applied when an N-BPS
/// (> 8-bit) source is reduced to 8-bit output (`should_dither` in
/// swscale.c); row = output line & 7, column = pixel & 7.
let sws_dither_8x8_128 : FixedArray[Int32] = FixedArray::from_array([
  36, 68, 60, 92, 34, 66, 58, 90, 100, 4, 124, 28, 98, 2, 122, 26, 52, 84, 44, 76,
  50, 82, 42, 74, 116, 20, 108, 12, 114, 18, 106, 10, 32, 64, 56, 88, 38, 70, 62,
  94, 96, 0, 120, 24, 102, 6, 126, 30, 48, 80, 40, 72, 54, 86, 46, 78, 112, 16, 104,
  8, 118, 22, 110, 14,
])

///|
/// Colorspace matrix of the YUV source (`ff_yuv2rgb_coeffs` selection
/// made through `sws_setColorspaceDetails`): BT.601 is the
/// SWS_CS_DEFAULT of every earlier slice, BT.709 the ITU-R Rec. 709
/// twin.  The 24bpp tables and the per-pixel full-chroma coefficients
/// are probed per (colorspace, range) pair - the cms double pass in
/// between defeats integer re-derivation on the chroma side (one
/// 224/255 rounding differs even on coefficients).
pub(all) enum SwsColorSpace {
  Bt601
  Bt709
  Fcc
  Smpte240M
  Bt2020 // NCL and CL share ff_yuv2rgb_coeffs
}

///|
/// Pick the probed 24bpp LUT set for a (colorspace, range) pair.
fn sws_rgb_lut_set(
  cs : SwsColorSpace,
  full_range : Bool,
) -> (
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
) {
  match (cs, full_range) {
    (Bt601, false) =>
      (
        official_y_table, official_base_r, official_base_gu, official_off_gv, official_base_b,
      )
    (Bt601, true) =>
      (
        official_full_y_table, official_full_base_r, official_full_base_gu, official_full_off_gv,
        official_full_base_b,
      )
    (Bt709, false) =>
      (
        official_709_y_table, official_709_base_r, official_709_base_gu, official_709_off_gv,
        official_709_base_b,
      )
    (Bt709, true) =>
      (
        official_709_full_y_table, official_709_full_base_r, official_709_full_base_gu,
        official_709_full_off_gv, official_709_full_base_b,
      )
    (Fcc, false) =>
      (
        official_fcc_y_table, official_fcc_base_r, official_fcc_base_gu, official_fcc_off_gv,
        official_fcc_base_b,
      )
    (Fcc, true) =>
      (
        official_fcc_full_y_table, official_fcc_full_base_r, official_fcc_full_base_gu,
        official_fcc_full_off_gv, official_fcc_full_base_b,
      )
    (Smpte240M, false) =>
      (
        official_smpte240m_y_table, official_smpte240m_base_r, official_smpte240m_base_gu,
        official_smpte240m_off_gv, official_smpte240m_base_b,
      )
    (Smpte240M, true) =>
      (
        official_smpte240m_full_y_table, official_smpte240m_full_base_r, official_smpte240m_full_base_gu,
        official_smpte240m_full_off_gv, official_smpte240m_full_base_b,
      )
    (Bt2020, false) =>
      (
        official_bt2020_y_table, official_bt2020_base_r, official_bt2020_base_gu,
        official_bt2020_off_gv, official_bt2020_base_b,
      )
    (Bt2020, true) =>
      (
        official_bt2020_full_y_table, official_bt2020_full_base_r, official_bt2020_full_base_gu,
        official_bt2020_full_off_gv, official_bt2020_full_base_b,
      )
  }
}

///|
/// Per-pixel full-chroma coefficients (y, y_off, v2r, v2g, u2g, u2b)
/// for a (colorspace, range) pair, all probed.
fn sws_rgb_full_chroma_coeffs(
  cs : SwsColorSpace,
  full_range : Bool,
) -> (Int32, Int32, Int32, Int32, Int32, Int32) {
  match (cs, full_range) {
    (Bt601, false) => (9539, 8192, 13075, -6660, -3209, 16525)
    (Bt601, true) => (8192, 0, 11485, -5850, -2819, 14516)
    (Bt709, false) => (9539, 8192, 14686, -4366, -1747, 17305)
    (Bt709, true) => (8192, 0, 12901, -3835, -1534, 15201)
    (Fcc, false) => (9539, 8192, 13056, -6639, -3095, 16600)
    (Fcc, true) => (8192, 0, 11469, -5831, -2719, 14582)
    (Smpte240M, false) => (9539, 8192, 14697, -4445, -2113, 17029)
    (Smpte240M, true) => (8192, 0, 12911, -3904, -1856, 14959)
    (Bt2020, false) => (9539, 8192, 13752, -5328, -1535, 17545)
    (Bt2020, true) => (8192, 0, 12080, -4680, -1348, 15412)
  }
}

///|
pub(all) suberror SwsScaleError {
  InvalidScaleConfig(String)
} derive(Debug)

///|
pub extend SwsScaleError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Integer floor log2 (av_log2 semantics: av_log2(0) == 0).
fn sws_av_log2(v0 : Int32) -> Int32 {
  let mut v = v0
  let mut n = 0
  while v > 1 {
    v = v >> 1
    n = n + 1
  }
  n
}

///|
/// C integer division truncates toward zero; MoonBit `/` matches, this
/// helper just names the contract for the negative operands in
/// initFilter.
fn sws_c_div(a : Int64, b : Int64) -> Int64 {
  a / b
}

///|
/// FFmpeg `ROUNDED_DIV(a,b)` (libavutil/common.h).
fn sws_rounded_div(a : Int64, b : Int64) -> Int64 {
  if a >= 0L {
    (a + (b >> 1)) / b
  } else {
    (a - (b >> 1)) / b
  }
}

///|
fn sws_clip_uint8(x : Int32) -> Int32 {
  if (x & -256) != 0 {
    if x < 0 {
      0
    } else {
      255
    }
  } else {
    x
  }
}

///|
/// One direction's polyphase filter: per-output-pixel start position
/// plus a flat `size`-tap coefficient bank normalized to `one`.
struct SwsFilter {
  coeffs : Array[Int32]
  pos : Array[Int32]
  size : Int32
}

///|
/// `initFilter` (utils.c) for the general (non point / fast-bilinear)
/// branch with no srcFilter/dstFilter, `filterAlign = 1` (pure C path).
fn sws_init_filter(
  x_inc : Int64,
  src_w : Int32,
  dst_w : Int32,
  one : Int32,
  src_pos : Int32,
  dst_pos : Int32,
) -> SwsFilter raise SwsScaleError {
  guard dst_w >= 1 && src_w >= 1 else {
    raise InvalidScaleConfig("swscale: dimensions must be positive")
  }
  let fone : Int64 = 1L <<
    (
      54 -
      (if sws_av_log2(src_w / dst_w) < 8 {
        sws_av_log2(src_w / dst_w)
      } else {
        8
      })
    )
  let filter_pos : Array[Int32] = Array::make(dst_w, 0)
  // The unscaled shortcut (1:1 xInc, matching positions).
  let dx = x_inc - 65536L
  let unscaled = dx < 10L && dx > -10L && src_pos == dst_pos
  if unscaled {
    for i in 0..<dst_w {
      filter_pos[i] = i
    }
    // filterSize 1, all taps fone; skips reduction and border fixes
    // identically (they leave it untouched), normalization maps fone
    // to exactly `one`.
    let coeffs : Array[Int32] = Array::make(dst_w, 0)
    for i in 0..<dst_w {
      coeffs[i] = one
    }
    return { coeffs, pos: filter_pos, size: 1, }
  }
  // Bicubic (sizeFactor 4): filterSize depends on down/upscale.
  let mut filter_size = if x_inc <= 65536L {
    5
  } else {
    1 + (4 * src_w + dst_w - 1) / dst_w
  }
  filter_size = if filter_size < src_w - 2 { filter_size } else { src_w - 2 }
  filter_size = if filter_size > 1 { filter_size } else { 1 }
  // B = 0.0, C = 0.6 in fixed point (int64 truncation of the double
  // product, exactly like the C).
  let b : Int64 = 0L
  let c : Int64 = (0.6 * 16777216.0).to_int64()
  let coeff_one : Int64 = 1L << 24
  let mut x_dst_in_src : Int64 = ((dst_pos.to_int64() * x_inc) >> 7) -
    ((src_pos.to_int64() * 65536L) >> 7)
  let filter : Array[Int64] = Array::make(dst_w * filter_size, 0L)
  for i in 0..<dst_w {
    let xx0 = sws_c_div(
      x_dst_in_src - (filter_size - 2).to_int64() * 65536L,
      131072L,
    )
    filter_pos[i] = xx0.to_int()
    let mut xx = xx0
    for j in 0..<filter_size {
      let mut d = if xx * 131072L - x_dst_in_src < 0L {
        -(xx * 131072L - x_dst_in_src)
      } else {
        xx * 131072L - x_dst_in_src
      }
      d = d << 13
      if x_inc > 65536L {
        d = d * dst_w.to_int64() / src_w.to_int64()
      }
      let mut coeff : Int64 = 0L
      if d < 2147483648L {
        let dd = (d * d) >> 30
        let ddd = (dd * d) >> 30
        coeff = if d < 1073741824L {
          (12L * coeff_one - 9L * b - 6L * c) * ddd +
          (-18L * coeff_one + 12L * b + 6L * c) * dd +
          (6L * coeff_one - 2L * b) * 1073741824L
        } else {
          (-b - 6L * c) * ddd +
          (6L * b + 30L * c) * dd +
          (-12L * b - 48L * c) * d +
          (8L * b + 24L * c) * 1073741824L
        }
      }
      filter[i * filter_size + j] = coeff / ((1L << 54) / fone)
      xx = xx + 1L
    }
    x_dst_in_src = x_dst_in_src + 2L * x_inc
  }
  // filter2 == filter (no src/dst vectors); pos shift term is zero.
  // Reduction step 1: shift away near-zero heads (SWS_MAX_REDUCE_CUTOFF
  // 0.002 as a double threshold - swscale.h; the S334 port briefly used
  // 0.00002, which no earlier vector could distinguish), monotonicity
  // guarded.
  let cutoff_thresh : Double = 0.002 * fone.to_double()
  let mut min_filter_size = 0
  for ii in 0..<dst_w {
    let i = dst_w - 1 - ii
    let mut min = filter_size
    let mut cut : Int64 = 0
    let mut j = 0
    while j < filter_size {
      cut = cut +
        (if filter[i * filter_size] < 0L {
          -filter[i * filter_size]
        } else {
          filter[i * filter_size]
        })
      if cut.to_double() > cutoff_thresh {
        break
      }
      if i < dst_w - 1 && filter_pos[i] >= filter_pos[i + 1] {
        break
      }
      // move coefficients left by one
      for k in 1..<filter_size {
        filter[i * filter_size + k - 1] = filter[i * filter_size + k]
      }
      filter[i * filter_size + filter_size - 1] = 0L
      filter_pos[i] = filter_pos[i] + 1
      j = j + 1
    }
    cut = 0
    j = filter_size - 1
    while j > 0 {
      cut = cut +
        (if filter[i * filter_size + j] < 0L {
          -filter[i * filter_size + j]
        } else {
          filter[i * filter_size + j]
        })
      if cut.to_double() > cutoff_thresh {
        break
      }
      min = min - 1
      j = j - 1
    }
    if min > min_filter_size {
      min_filter_size = min
    }
  }
  guard min_filter_size > 0 else {
    raise InvalidScaleConfig("swscale: filter reduced to nothing")
  }
  // filterAlign 1 (pure C): size stays minFilterSize.
  let size = min_filter_size
  // Step 2: copy the reduced taps (flags carry no BITEXACT padding).
  let coeffs : Array[Int64] = Array::make(dst_w * size, 0L)
  for i in 0..<dst_w {
    for j in 0..<size {
      coeffs[i * size + j] = filter[i * filter_size + j]
    }
  }
  // Border fixes.
  for i in 0..<dst_w {
    if filter_pos[i] < 0 {
      for j in 1..<size {
        let left = if j + filter_pos[i] > 0 { j + filter_pos[i] } else { 0 }
        coeffs[i * size + left] = coeffs[i * size + left] + coeffs[i * size + j]
        coeffs[i * size + j] = 0
      }
      filter_pos[i] = 0
    }
    if filter_pos[i] + size > src_w {
      let shift = filter_pos[i] +
        (if size - src_w < 0 { size - src_w } else { 0 })
      let mut acc : Int64 = 0
      let mut j = size - 1
      while j >= 0 {
        if filter_pos[i] + j >= src_w {
          acc = acc + coeffs[i * size + j]
          coeffs[i * size + j] = 0
        }
        j = j - 1
      }
      j = size - 1
      while j >= 0 {
        if j < shift {
          coeffs[i * size + j] = 0
        } else {
          coeffs[i * size + j] = coeffs[i * size + j - shift]
        }
        j = j - 1
      }
      filter_pos[i] = filter_pos[i] - shift
      coeffs[i * size + src_w - 1 - filter_pos[i]] = coeffs[i * size +
        src_w -
        1 -
        filter_pos[i]] +
        acc
    }
  }
  // Normalize with error diffusion to `one` per output pixel.
  let one64 : Int64 = one.to_int64()
  let out : Array[Int32] = Array::make(dst_w * size, 0)
  for i in 0..<dst_w {
    let mut sum : Int64 = 0
    for j in 0..<size {
      sum = sum + coeffs[i * size + j]
    }
    sum = (sum + (one64 >> 1)) / one64
    if sum == 0L {
      sum = 1L
    }
    let mut error : Int64 = 0
    for j in 0..<size {
      let v = coeffs[i * size + j] + error
      let int_v = sws_rounded_div(v, sum)
      out[i * size + j] = int_v.to_int()
      error = v - int_v * sum
    }
  }
  { coeffs: out, pos: filter_pos, size, }
}

///|
/// Planar YUV scaler (bicubic, FFmpeg legacy C path): 4:2:0 / 4:2:2 /
/// 4:4:4 on either side, any combination.  Chroma plane geometry is
/// `AV_CEIL_RSHIFT` of the format's shifts; the filter design itself is
/// dimension-generic (get_local_pos resolves to 128 for every
/// subsampling, so luma and chroma filters all take pos 128/128).
pub struct SwsPlanarScaler {
  algo : SwsScaleAlgo
  src_w : Int32
  src_h : Int32
  dst_w : Int32
  dst_h : Int32
  src_bits : Int32
  dst_bits : Int32
  chr_sw : Int32
  chr_sh : Int32
  chr_dw : Int32
  chr_dh : Int32
  h_lum : SwsFilter
  h_chr : SwsFilter
  v_lum : SwsFilter
  v_chr : SwsFilter
}

///|
/// The scaling algorithm this context was built with.  `SwsScaleAlgo`
/// currently has a single variant, so every context reports `Bicubic`;
/// the accessor exists so callers do not have to assume it.
pub fn SwsPlanarScaler::algo(self : SwsPlanarScaler) -> SwsScaleAlgo {
  self.algo
}

///|
/// Build a scaler.  Evenness is required only where the format's own
/// subsampling demands it: 4:2:0 both dimensions, 4:2:2 width only.
pub fn SwsPlanarScaler::new(
  src_w~ : Int32,
  src_h~ : Int32,
  dst_w~ : Int32,
  dst_h~ : Int32,
  src_fmt~ : SwsChromaFmt = Yuv420,
  dst_fmt~ : SwsChromaFmt = Yuv420,
  src_bits~ : Int32 = 8,
  dst_bits~ : Int32 = 8,
  scaler~ : SwsScaleAlgo = Bicubic,
) -> SwsPlanarScaler raise SwsScaleError {
  guard src_bits == 8 || src_bits == 10 else {
    raise InvalidScaleConfig("swscale: only 8- or 10-bit sources")
  }
  guard dst_bits == 8 || dst_bits == 10 else {
    raise InvalidScaleConfig("swscale: only 8- or 10-bit destinations")
  }
  guard src_w >= 2 && src_h >= 2 && dst_w >= 2 && dst_h >= 2 else {
    raise InvalidScaleConfig("swscale: dimensions must be >= 2")
  }
  guard src_w - 2 >= 1 else {
    raise InvalidScaleConfig("swscale: source too narrow")
  }
  let (src_hs, src_vs) = src_fmt.shifts()
  let (dst_hs, dst_vs) = dst_fmt.shifts()
  let chr_sw = sws_ceil_rshift(src_w, src_hs)
  let chr_sh = sws_ceil_rshift(src_h, src_vs)
  let chr_dw = sws_ceil_rshift(dst_w, dst_hs)
  let chr_dh = sws_ceil_rshift(dst_h, dst_vs)
  let lum_x_inc = ((src_w.to_int64() << 16) + (dst_w >> 1).to_int64()) /
    dst_w.to_int64()
  let lum_y_inc = ((src_h.to_int64() << 16) + (dst_h >> 1).to_int64()) /
    dst_h.to_int64()
  let chr_x_inc = ((chr_sw.to_int64() << 16) + (chr_dw >> 1).to_int64()) /
    chr_dw.to_int64()
  let chr_y_inc = ((chr_sh.to_int64() << 16) + (chr_dh >> 1).to_int64()) /
    chr_dh.to_int64()
  // get_local_pos defaults: luma 128, chroma 128 for every shift
  // ((128 << cs) >> cs == 128).
  {
    algo: scaler,
    src_w,
    src_h,
    dst_w,
    dst_h,
    src_bits,
    dst_bits,
    chr_sw,
    chr_sh,
    chr_dw,
    chr_dh,
    h_lum: sws_init_filter(lum_x_inc, src_w, dst_w, 1 << 14, 128, 128),
    h_chr: sws_init_filter(chr_x_inc, chr_sw, chr_dw, 1 << 14, 128, 128),
    v_lum: sws_init_filter(lum_y_inc, src_h, dst_h, 1 << 12, 128, 128),
    v_chr: sws_init_filter(chr_y_inc, chr_sh, chr_dh, 1 << 12, 128, 128),
  }
}

///|
/// hScale8To15_c / hScale16To15_c: one source row to 15-bit
/// intermediates (int16 wrap on store, top clamped like the C FFMIN).
/// `src_bits` picks the shift `depth - 1` (8 -> 7, 10 -> 9) and the
/// sample reads (u8 or little-endian u16 pairs); the 15-bit
/// intermediate is full-scale aligned either way.
fn sws_hscale8to15(
  src : Bytes,
  row_off : Int32,
  f : SwsFilter,
  dst_w : Int32,
  src_bits : Int32,
) -> Array[Int32] {
  let sh = src_bits - 1
  let step = (src_bits + 7) / 8 // bytes per sample: 1 or 2
  let out : Array[Int32] = Array::make(dst_w, 0)
  for i in 0..<dst_w {
    // byte address of this output pixel's first tap (row_off and
    // filterPos are in samples; step converts)
    let base = (row_off + f.pos[i]) * step
    let mut val = 0
    for j in 0..<f.size {
      let sample = if step == 1 {
        src[base + j].to_int()
      } else {
        src[base + 2 * j].to_int() | (src[base + 2 * j + 1].to_int() << 8)
      }
      val = val + sample * f.coeffs[f.size * i + j]
    }
    let v = if val >> sh < 32767 { val >> sh } else { 32767 }
    // int16 wrap semantics of the C store.
    out[i] = v << 16 >> 16
  }
  out
}

///|
/// Scale one plane (generic H then V, rows h-scaled on demand).
fn sws_scale_plane(
  src : Bytes,
  src_h : Int32,
  dst_h : Int32,
  h : SwsFilter,
  v : SwsFilter,
  dst_w : Int32,
  src_bits : Int32,
  dst_bits : Int32,
  dither_off~ : Int32 = 0,
) -> Bytes raise SwsScaleError {
  // H-scale every source row once (row stride in samples).
  let hrows : Array[Array[Int32]] = []
  let src_w = src.length() / src_h / ((src_bits + 7) / 8)
  for r in 0..<src_h {
    hrows.push(sws_hscale8to15(src, r * src_w, h, dst_w, src_bits))
  }
  let dst : Array[Byte] = []
  for y in 0..<dst_h {
    let rows : Array[Array[Int32]] = []
    for j in 0..<v.size {
      let sy = v.pos[y] + j
      guard sy >= 0 && sy < src_h else {
        raise InvalidScaleConfig("swscale: vertical filter out of range")
      }
      rows.push(hrows[sy])
    }
    // Vertical combine with this output row's own coefficient bank row.
    // 8-bit output keeps the dithered C path (ff_sws_pb_64); 10-bit
    // output is yuv2planeX_10_c_template: shift 11 + 16 - bits, rounding
    // offset 1 << (shift - 1), av_clip_uintp2(_, bits), LE u16 store.
    let row0 = y
    let out_row : Array[Byte] = []
    if dst_bits > 8 {
      let shift = 11 + 16 - dst_bits
      let half = 1 << (shift - 1)
      let clip_mask = dst_bits
      for i in 0..<dst_w {
        let mut val = half
        for j in 0..<v.size {
          val = val + rows[j][i] * v.coeffs[row0 * v.size + j]
        }
        // av_clip_uintp2(val >> shift, bits)
        let raw = val >> shift
        let clamped = if (raw & -(1 << clip_mask)) != 0 {
          if raw < 0 {
            0
          } else {
            (1 << clip_mask) - 1
          }
        } else {
          raw
        }
        out_row.push((clamped & 0xFF).to_byte())
        out_row.push(((clamped >> 8) & 0xFF).to_byte())
      }
    } else {
      // sws_pb_64 (all 64) for byte sources; ff_dither_8x8_128 indexed
      // by (output line & 7, pixel & 7) when an N-BPS source is reduced
      // to 8-bit (`should_dither`).
      let nbps = src_bits > 8
      for i in 0..<dst_w {
        // the V plane is written with a +3 column offset (vscale.c)
        let dither = if nbps {
          sws_dither_8x8_128[y % 8 * 8 + (i + dither_off) % 8]
        } else {
          64
        }
        let mut val = dither << 12
        for j in 0..<v.size {
          val = val + rows[j][i] * v.coeffs[row0 * v.size + j]
        }
        out_row.push(sws_clip_uint8(val >> 19).to_byte())
      }
    }
    for b in out_row {
      dst.push(b)
    }
  }
  Bytes::from_array(dst)
}

///|
/// Scale a full planar YUV frame (planar Y/U/V bytes, tight strides),
/// with the source/destination chroma geometry chosen at construction.
pub fn SwsPlanarScaler::scale(
  self : SwsPlanarScaler,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> (Bytes, Bytes, Bytes) raise SwsScaleError {
  // Source planes hold src_bits/8 bytes per sample.
  let sb = (self.src_bits + 7) / 8
  guard y.length() >= self.src_w * self.src_h * sb else {
    raise InvalidScaleConfig("swscale: Y plane too small")
  }
  guard u.length() >= self.chr_sw * self.chr_sh * sb else {
    raise InvalidScaleConfig("swscale: U plane too small")
  }
  guard v.length() >= self.chr_sw * self.chr_sh * sb else {
    raise InvalidScaleConfig("swscale: V plane too small")
  }
  let y_out = sws_scale_plane(
    y,
    self.src_h,
    self.dst_h,
    self.h_lum,
    self.v_lum,
    self.dst_w,
    self.src_bits,
    self.dst_bits,
  )
  let u_out = sws_scale_plane(
    u,
    self.chr_sh,
    self.chr_dh,
    self.h_chr,
    self.v_chr,
    self.chr_dw,
    self.src_bits,
    self.dst_bits,
  )
  let v_out = sws_scale_plane(
    v,
    self.chr_sh,
    self.chr_dh,
    self.h_chr,
    self.v_chr,
    self.chr_dw,
    self.src_bits,
    self.dst_bits,
    dither_off=3,
  )
  (y_out, u_out, v_out)
}

///|
/// Planar YUV (4:2:0 / 4:2:2 / 4:4:4) -> packed RGB24/BGR24 at an
/// arbitrary size.  Routing mirrors `sws_init_context`: an RGB
/// destination without SWS_FULL_CHR_H_INT sets `chrDstHSubSample = 1`
/// (half-width chroma, the legacy `yuv2rgb_X_c_template` pair writer),
/// while an odd dstW or a non-subsampled (4:4:4) source forces full
/// internal chroma (`yuv2rgb_full_X_c` per-pixel interpolation); in
/// every case chroma V targets the full dstH (RGB formats carry no
/// vertical subsampling).  The LUT is the slice-1 official probe (its
/// headroom covers the unclamped Y/U/V of the scaled path).
pub struct SwsRgbScaler {
  src_w : Int32
  src_h : Int32
  dst_w : Int32
  dst_h : Int32
  chr_sw : Int32
  chr_sh : Int32
  chr_dw : Int32
  full_chroma : Bool
  full_range : Bool
  colorspace : SwsColorSpace
  h_lum : SwsFilter
  h_chr : SwsFilter
  v_lum : SwsFilter
  v_chr : SwsFilter
  bgr : Bool
}

///|
/// Build the scaler; evenness is required only where the source
/// format's own subsampling demands it, the destination any size >= 2.
/// `full_range` selects the yuvj (JPEG) colorimetry: cy 1<<16 / oy 0
/// and chroma coefficients scaled by 224/255 (probed 24bpp tables and
/// per-pixel coefficients, the limited-range twin stays the default).
pub fn SwsRgbScaler::new(
  src_w~ : Int32,
  src_h~ : Int32,
  dst_w~ : Int32,
  dst_h~ : Int32,
  src_fmt~ : SwsChromaFmt = Yuv420,
  bgr~ : Bool = false,
  full_range~ : Bool = false,
  colorspace~ : SwsColorSpace = Bt601,
) -> SwsRgbScaler raise SwsScaleError {
  guard src_w >= 2 && src_h >= 2 && dst_w >= 2 && dst_h >= 2 else {
    raise InvalidScaleConfig("swscale: dimensions must be >= 2")
  }
  guard sws_fmt_even_ok(src_fmt, src_w, src_h) else {
    raise InvalidScaleConfig("swscale: subsampled source needs even dimensions")
  }
  let (src_hs, src_vs) = src_fmt.shifts()
  let chr_sw = sws_ceil_rshift(src_w, src_hs)
  let chr_sh = sws_ceil_rshift(src_h, src_vs)
  // utils.c: an odd dstW or a 4:4:4 source ("input having non
  // subsampled chroma") forces full internal H chroma; otherwise the
  // RGB destination keeps chrDstHSubSample = 1 (half-width pairs).
  let full_chroma = dst_w % 2 != 0 || src_fmt is Yuv444
  let chr_dw = if full_chroma { dst_w } else { dst_w / 2 }
  let lum_x_inc = ((src_w.to_int64() << 16) + (dst_w >> 1).to_int64()) /
    dst_w.to_int64()
  let lum_y_inc = ((src_h.to_int64() << 16) + (dst_h >> 1).to_int64()) /
    dst_h.to_int64()
  let chr_x_inc = ((chr_sw.to_int64() << 16) + (chr_dw >> 1).to_int64()) /
    chr_dw.to_int64()
  let chr_y_inc = ((chr_sh.to_int64() << 16) + (dst_h >> 1).to_int64()) /
    dst_h.to_int64()
  {
    src_w,
    src_h,
    dst_w,
    dst_h,
    chr_sw,
    chr_sh,
    chr_dw,
    full_chroma,
    full_range,
    colorspace,
    h_lum: sws_init_filter(lum_x_inc, src_w, dst_w, 1 << 14, 128, 128),
    h_chr: sws_init_filter(chr_x_inc, chr_sw, chr_dw, 1 << 14, 128, 128),
    v_lum: sws_init_filter(lum_y_inc, src_h, dst_h, 1 << 12, 128, 128),
    v_chr: sws_init_filter(chr_y_inc, chr_sh, dst_h, 1 << 12, 128, 128),
    bgr,
  }
}

///|
/// Scale and convert one planar YUV frame (tight strides) to packed
/// RGB24 (R first) or BGR24.
pub fn SwsRgbScaler::scale(
  self : SwsRgbScaler,
  y : Bytes,
  u : Bytes,
  v : Bytes,
) -> Bytes raise SwsScaleError {
  guard y.length() >= self.src_w * self.src_h else {
    raise InvalidScaleConfig("swscale: Y plane too small")
  }
  guard u.length() >= self.chr_sw * self.chr_sh else {
    raise InvalidScaleConfig("swscale: U plane too small")
  }
  guard v.length() >= self.chr_sw * self.chr_sh else {
    raise InvalidScaleConfig("swscale: V plane too small")
  }
  let dw = self.dst_w
  let chr_dw = self.chr_dw
  // H-scale every source row once (chroma planes each, at chr_dw width).
  let lum_rows : Array[Array[Int32]] = []
  for r in 0..<self.src_h {
    lum_rows.push(sws_hscale8to15(y, r * self.src_w, self.h_lum, dw, 8))
  }
  let u_rows : Array[Array[Int32]] = []
  let v_rows : Array[Array[Int32]] = []
  let chr_sh = self.chr_sh
  for r in 0..<chr_sh {
    u_rows.push(sws_hscale8to15(u, r * self.chr_sw, self.h_chr, chr_dw, 8))
    v_rows.push(sws_hscale8to15(v, r * self.chr_sw, self.h_chr, chr_dw, 8))
  }
  let out : Array[Byte] = []
  if self.full_chroma {
    // Odd width or 4:4:4 source: full-chroma interpolation
    // (yuv2rgb_full_X_c_template + yuv2rgb_write_full), coefficients
    // probed from FFmpeg 9.0.2 (SWS_CS_DEFAULT BT.601; limited and
    // full-range pairs).
    let (y_coeff, y_off, v2r, v2g, u2g, u2b) = sws_rgb_full_chroma_coeffs(
      self.colorspace,
      self.full_range,
    )
    for ry in 0..<self.dst_h {
      let lrows : Array[Array[Int32]] = []
      for j in 0..<self.v_lum.size {
        lrows.push(lum_rows[self.v_lum.pos[ry] + j])
      }
      let urows : Array[Array[Int32]] = []
      let vrows : Array[Array[Int32]] = []
      for j in 0..<self.v_chr.size {
        let sy = self.v_chr.pos[ry] + j
        urows.push(u_rows[sy])
        vrows.push(v_rows[sy])
      }
      let ybase = ry * self.v_lum.size
      let cbase = ry * self.v_chr.size
      for i in 0..<dw {
        let mut yv = 1 << 9
        let mut uv = (1 << 9) - (128 << 19)
        let mut vv = (1 << 9) - (128 << 19)
        for j in 0..<self.v_lum.size {
          yv = yv + lrows[j][i] * self.v_lum.coeffs[ybase + j]
        }
        for j in 0..<self.v_chr.size {
          uv = uv + urows[j][i] * self.v_chr.coeffs[cbase + j]
          vv = vv + vrows[j][i] * self.v_chr.coeffs[cbase + j]
        }
        let y10 = yv >> 10
        let u10 = uv >> 10
        let v10 = vv >> 10
        let yy = (y10 - y_off) * y_coeff + (1 << 21)
        let mut r = yy + v10 * v2r
        let mut g = yy + v10 * v2g + u10 * u2g
        let mut b = yy + u10 * u2b
        if ((r | g | b) & -1073741824) != 0 {
          // av_clip_uintp2(x, 30)
          r = if (r & -1073741824) != 0 {
            if r < 0 {
              0
            } else {
              1073741823
            }
          } else {
            r
          }
          g = if (g & -1073741824) != 0 {
            if g < 0 {
              0
            } else {
              1073741823
            }
          } else {
            g
          }
          b = if (b & -1073741824) != 0 {
            if b < 0 {
              0
            } else {
              1073741823
            }
          } else {
            b
          }
        }
        if self.bgr {
          out.push((b >> 22).to_byte())
          out.push((g >> 22).to_byte())
          out.push((r >> 22).to_byte())
        } else {
          out.push((r >> 22).to_byte())
          out.push((g >> 22).to_byte())
          out.push((b >> 22).to_byte())
        }
      }
    }
    return Bytes::from_array(out[:])
  }
  // LUT set per (colorspace, range); limited BT.601 is the slice-1
  // official probe, the other three are its probed twins.
  let (y_tab, base_r, base_gu, off_gv, base_b) = sws_rgb_lut_set(
    self.colorspace,
    self.full_range,
  )
  for ry in 0..<self.dst_h {
    // Vertical combine per output row; the X template works in pixel
    // pairs sharing one chroma sample.
    let y1_rows : Array[Array[Int32]] = []
    for j in 0..<self.v_lum.size {
      let sy = self.v_lum.pos[ry] + j
      guard sy >= 0 && sy < self.src_h else {
        raise InvalidScaleConfig("swscale: vertical filter out of range")
      }
      y1_rows.push(lum_rows[sy])
    }
    let u_rows_v : Array[Array[Int32]] = []
    let v_rows_v : Array[Array[Int32]] = []
    for j in 0..<self.v_chr.size {
      let sy = self.v_chr.pos[ry] + j
      guard sy >= 0 && sy < chr_sh else {
        raise InvalidScaleConfig("swscale: chroma filter out of range")
      }
      u_rows_v.push(u_rows[sy])
      v_rows_v.push(v_rows[sy])
    }
    let ybase = ry * self.v_lum.size
    let cbase = ry * self.v_chr.size
    for i in 0..<chr_dw {
      let mut y1 = 1 << 18
      let mut y2 = 1 << 18
      for j in 0..<self.v_lum.size {
        y1 = y1 + y1_rows[j][i * 2] * self.v_lum.coeffs[ybase + j]
        if i * 2 + 1 < dw {
          y2 = y2 + y1_rows[j][i * 2 + 1] * self.v_lum.coeffs[ybase + j]
        }
      }
      let mut uu = 1 << 18
      let mut vv = 1 << 18
      for j in 0..<self.v_chr.size {
        uu = uu + u_rows_v[j][i] * self.v_chr.coeffs[cbase + j]
        vv = vv + v_rows_v[j][i] * self.v_chr.coeffs[cbase + j]
      }
      let y1v = y1 >> 19
      let y2v = y2 >> 19
      let uv = (uu >> 19) + 512
      let vvv = (vv >> 19) + 512
      // Two pixels through the official LUT (G wraps mod 256 like the
      // C's uint8_t store).
      let r1 = y_tab[base_r[vvv] + y1v]
      let g1 = y_tab[base_gu[uv] + off_gv[vvv] + y1v]
      let b1 = y_tab[base_b[uv] + y1v]
      if self.bgr {
        out.push(b1.to_byte())
        out.push(g1.to_byte())
        out.push(r1.to_byte())
      } else {
        out.push(r1.to_byte())
        out.push(g1.to_byte())
        out.push(b1.to_byte())
      }
      if i * 2 + 1 < dw {
        let r2 = y_tab[base_r[vvv] + y2v]
        let g2 = y_tab[base_gu[uv] + off_gv[vvv] + y2v]
        let b2 = y_tab[base_b[uv] + y2v]
        if self.bgr {
          out.push(b2.to_byte())
          out.push(g2.to_byte())
          out.push(r2.to_byte())
        } else {
          out.push(r2.to_byte())
          out.push(g2.to_byte())
          out.push(b2.to_byte())
        }
      }
    }
  }
  Bytes::from_array(out[:])
}
