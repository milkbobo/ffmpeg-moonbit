///|
/// `av_clip` for the scaled-MC MV bounds.
fn vp9_clip_i32(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
/// Scaled-reference motion compensation, port of FFmpeg 9.0.2
/// `libavcodec/vp9recon.c` (`mc_luma_scaled`, `mc_chroma_scaled`) and
/// `libavcodec/vp9dsp_template.c` (`do_scaled_8tap_c`, `do_scaled_bilin_c`).
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// The 14-bit reference scales are derived on the fly with the same formula
/// as the C `s->mvscale[i]` setup in `vp9.c` (REF_FRAME_SCALE):
/// `scale = (ref_dim << 14) / cur_dim`, `step = 16 * scale >> 14`.  The
/// libvpx rounding quirks reproduced by the C are kept verbatim: the two MV
/// components are scaled separately, and the 4:2:0 chroma MV uses the
/// `webm/issues/820` rounding.

///|
/// `do_scaled_8tap_c`: two-pass scaled sub-pel interpolation. `mx`/`my` are
/// the 1/16-pel start phases (0..15), `dx`/`dy` the per-output-pixel steps,
/// `filter` the FilterMode (0 regular, 1 smooth, 2 sharp).  The horizontal
/// pass runs into a 64-wide scratch (clipped pixels, like the C's
/// `av_clip_pixel` inside `FILTER_8TAP`); the vertical pass filters that.
fn Vp9Decoder::mc_scaled_8tap(
  self : Vp9Decoder,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  dx : Int32,
  dy : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  let filters = vp9_subpel_filters
  let fb = vp9_filter_to_table(filter) * 128
  let tmp = self.mc_scaled_tmp
  let tmp_h = (((h - 1) * dy + my) >> 4) + 8
  // horizontal pass; `src_off` points at the block's top-left pixel, the C
  // starts three rows above so the vertical pass can read the top taps
  let mut so = src_off - 3 * src_stride
  let mut to = 0
  for _ in 0..<tmp_h {
    let mut imx = mx
    let mut ioff = 0
    for x in 0..<w {
      let f = fb + imx * 8
      let p = so + ioff
      let v = vp9_clip_pixel(
        (
          filters[f] * src[p - 3] +
          filters[f + 1] * src[p - 2] +
          filters[f + 2] * src[p - 1] +
          filters[f + 3] * src[p] +
          filters[f + 4] * src[p + 1] +
          filters[f + 5] * src[p + 2] +
          filters[f + 6] * src[p + 3] +
          filters[f + 7] * src[p + 4] +
          64
        ) >>
        7,
        self.pixel_max,
      )
      tmp[to + x] = v
      imx += dx
      ioff += imx >> 4
      imx = imx & 15
    }
    to += 64
    so += src_stride
  }
  // vertical pass
  let mut vmy = my
  let mut vto = 3 * 64
  let mut do_ = dst_off
  for _ in 0..<h {
    for x in 0..<w {
      let v = vp9_clip_pixel(
        (
          filters[fb + vmy * 8] * tmp[vto + x - 3 * 64] +
          filters[fb + vmy * 8 + 1] * tmp[vto + x - 2 * 64] +
          filters[fb + vmy * 8 + 2] * tmp[vto + x - 64] +
          filters[fb + vmy * 8 + 3] * tmp[vto + x] +
          filters[fb + vmy * 8 + 4] * tmp[vto + x + 64] +
          filters[fb + vmy * 8 + 5] * tmp[vto + x + 2 * 64] +
          filters[fb + vmy * 8 + 6] * tmp[vto + x + 3 * 64] +
          filters[fb + vmy * 8 + 7] * tmp[vto + x + 4 * 64] +
          64
        ) >>
        7,
        self.pixel_max,
      )
      dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) >> 1 } else { v }
    }
    vmy += dy
    vto += (vmy >> 4) * 64
    vmy = vmy & 15
    do_ += dst_stride
  }
}

///|
/// `do_scaled_bilin_c`: two-pass scaled bilinear interpolation.
fn Vp9Decoder::mc_scaled_bilin(
  self : Vp9Decoder,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  dx : Int32,
  dy : Int32,
  avg : Bool,
) -> Unit {
  let tmp = self.mc_scaled_tmp
  let tmp_h = (((h - 1) * dy + my) >> 4) + 2
  let mut so = src_off
  let mut to = 0
  for _ in 0..<tmp_h {
    let mut imx = mx
    let mut ioff = 0
    for x in 0..<w {
      tmp[to + x] = src[so + ioff] +
        ((imx * (src[so + ioff + 1] - src[so + ioff]) + 8) >> 4)
      imx += dx
      ioff += imx >> 4
      imx = imx & 15
    }
    to += 64
    so += src_stride
  }
  let mut vmy = my
  let mut vto = 0
  let mut do_ = dst_off
  for _ in 0..<h {
    for x in 0..<w {
      let v = tmp[vto + x] +
        ((vmy * (tmp[vto + x + 64] - tmp[vto + x]) + 8) >> 4)
      dst[do_ + x] = if avg { (dst[do_ + x] + v + 1) >> 1 } else { v }
    }
    vmy += dy
    vto += (vmy >> 4) * 64
    vmy = vmy & 15
    do_ += dst_stride
  }
}

///|
/// Scaled sub-pel kernel dispatch (`dsp->smc`): bilinear for filter 3,
/// 8-tap otherwise; `avg` selects the compound variant.  `w` is the block
/// width in the current frame; the C's per-size `smc` wrappers fix `w` at
/// the group width, with the height passed through.
pub fn Vp9Decoder::mc_scaled_kernel(
  self : Vp9Decoder,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  src : FixedArray[Int32],
  src_off : Int32,
  src_stride : Int32,
  w : Int32,
  h : Int32,
  mx : Int32,
  my : Int32,
  dx : Int32,
  dy : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  if filter == 3 {
    self.mc_scaled_bilin(
      dst, dst_off, dst_stride, src, src_off, src_stride, w, h, mx, my, dx, dy, avg,
    )
  } else {
    self.mc_scaled_8tap(
      dst, dst_off, dst_stride, src, src_off, src_stride, w, h, mx, my, dx, dy, filter,
      avg,
    )
  }
}

///|
/// `mc_luma_scaled`: scaled luma prediction.  `blk_x`/`blk_y` are the
/// block's pixel origin in the current frame, `px_off`/`py_off` the
/// sub-block offset used by the MV clip (`px`/`py` in the C), and
/// `pw`/`ph` the clip window (8x8 grid for the 4x4 walk, block dims for
/// whole-block calls).  `scale`/`step` are 14-bit values derived by the
/// caller.
fn Vp9Decoder::mc_luma_scaled(
  self : Vp9Decoder,
  ref_frame : Vp9RefFrame,
  scale_x : Int32,
  scale_y : Int32,
  step_x : Int32,
  step_y : Int32,
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  blk_x : Int32,
  blk_y : Int32,
  px_off : Int32,
  py_off : Int32,
  pw : Int32,
  ph : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  let cols8 = self.cols * 8
  let rows8 = self.rows * 8
  let mvx = vp9_clip_i32(
    mvx,
    -(blk_x + pw - px_off + 4) * 8,
    (cols8 - blk_x + px_off + 3) * 8,
  )
  let mvy = vp9_clip_i32(
    mvy,
    -(blk_y + ph - py_off + 4) * 8,
    (rows8 - blk_y + py_off + 3) * 8,
  )
  // BUG libvpx scales the two components separately; reproduce the rounding
  let mx = (((mvx * 2).to_int64() * scale_x.to_int64()) >> 14).to_int() +
    (((blk_x * 16).to_int64() * scale_x.to_int64()) >> 14).to_int()
  let my = (((mvy * 2).to_int64() * scale_y.to_int64()) >> 14).to_int() +
    (((blk_y * 16).to_int64() * scale_y.to_int64()) >> 14).to_int()
  let x = mx >> 4
  let y = my >> 4
  let mx = mx & 15
  let my = my & 15
  let refbw_m1 = ((bw - 1) * step_x + mx) >> 4
  let refbh_m1 = ((bh - 1) * step_y + my) >> 4
  let mut src = ref_frame.y
  let mut soff = ref_frame.ybase + y * ref_frame.ystride + x
  let mut sstride = ref_frame.ystride
  if x < 3 ||
    y < 3 ||
    x + 4 >= ref_frame.width - refbw_m1 ||
    y + 5 >= ref_frame.height - refbh_m1 {
    println(
      "EMU x=\{x} y=\{y} bw=\{refbw_m1 + 8} bh=\{refbh_m1 + 8} ref=\{ref_frame.width}x\{ref_frame.height} mv=(\{mvx},\{mvy}) scale=(\{scale_x},\{scale_y})",
    )
    vp9_emulated_edge(
      self.mc_scaled_emu,
      0,
      288,
      src,
      soff - 3 * sstride - 3,
      sstride,
      refbw_m1 + 8,
      refbh_m1 + 8,
      x - 3,
      y - 3,
      ref_frame.width,
      ref_frame.height,
    )
    src = self.mc_scaled_emu
    soff = 3 * 288 + 3
    sstride = 288
  }
  self.mc_scaled_kernel(
    dst, dst_off, dst_stride, src, soff, sstride, bw, bh, mx, my, step_x, step_y,
    filter, avg,
  )
}

///|
/// `mc_chroma_scaled`: scaled chroma prediction for both chroma planes,
/// including the `webm/issues/820` 4:2:0 rounding.
fn Vp9Decoder::mc_chroma_scaled(
  self : Vp9Decoder,
  ref_frame : Vp9RefFrame,
  scale_x : Int32,
  scale_y : Int32,
  step_x : Int32,
  step_y : Int32,
  dst_cb : FixedArray[Int32],
  dst_cr : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  blk_x : Int32,
  blk_y : Int32,
  px_off : Int32,
  py_off : Int32,
  pw : Int32,
  ph : Int32,
  mvx : Int32,
  mvy : Int32,
  bw : Int32,
  bh : Int32,
  filter : Int32,
  avg : Bool,
) -> Unit {
  let ss_h = self.ss_h
  let ss_v = self.ss_v
  // `blk_x`/`blk_y` and `bw`/`bh` arrive in chroma coordinates (the
  // dispatcher halves them for 4:2:0), so the C's sub-sampled branches are
  // re-expressed directly in this domain.
  let cw = (ref_frame.width + ss_h) >> ss_h
  let ch = (ref_frame.height + ss_v) >> ss_v
  let cbw = bw
  let cbh = bh
  let mvx = if ss_h != 0 {
    // BUG https://code.google.com/p/webm/issues/detail?id=820
    vp9_clip_i32(
      mvx,
      -(blk_x + pw - px_off + 4) * 16,
      (self.cols * 4 - blk_x + px_off + 3) * 16,
    )
  } else {
    vp9_clip_i32(
      mvx,
      -(blk_x + pw - px_off + 4) * 8,
      (self.cols * 8 - blk_x + px_off + 3) * 8,
    )
  }
  let mvy = if ss_v != 0 {
    vp9_clip_i32(
      mvy,
      -(blk_y + ph - py_off + 4) * 16,
      (self.rows * 4 - blk_y + py_off + 3) * 16,
    )
  } else {
    vp9_clip_i32(
      mvy,
      -(blk_y + ph - py_off + 4) * 8,
      (self.rows * 8 - blk_y + py_off + 3) * 8,
    )
  }
  let mx = if ss_h != 0 {
    let s0 = ((mvx.to_int64() * scale_x.to_int64()) >> 14).to_int()
    let s1 = (((blk_x * 16).to_int64() * scale_x.to_int64()) >> 14).to_int()
    let s2 = (((blk_x * 32).to_int64() * scale_x.to_int64()) >> 14).to_int()
    s0 + (s1 & -16) + (s2 & 15)
  } else {
    let s0 = (((mvx * 2).to_int64() * scale_x.to_int64()) >> 14).to_int()
    let s1 = (((blk_x * 16).to_int64() * scale_x.to_int64()) >> 14).to_int()
    s0 + s1
  }
  let my = if ss_v != 0 {
    let s0 = ((mvy.to_int64() * scale_y.to_int64()) >> 14).to_int()
    let s1 = (((blk_y * 16).to_int64() * scale_y.to_int64()) >> 14).to_int()
    let s2 = (((blk_y * 32).to_int64() * scale_y.to_int64()) >> 14).to_int()
    s0 + (s1 & -16) + (s2 & 15)
  } else {
    let s0 = (((mvy * 2).to_int64() * scale_y.to_int64()) >> 14).to_int()
    let s1 = (((blk_y * 16).to_int64() * scale_y.to_int64()) >> 14).to_int()
    s0 + s1
  }
  let x = mx >> 4
  let y = my >> 4
  let mx = mx & 15
  let my = my & 15
  let refbw_m1 = ((cbw - 1) * step_x + mx) >> 4
  let refbh_m1 = ((cbh - 1) * step_y + my) >> 4
  let src_cb = ref_frame.cb
  let src_cr = ref_frame.cr
  let base = ref_frame.uvbase + y * ref_frame.uvstride + x
  let sstride = ref_frame.uvstride
  if x < 3 || y < 3 || x + 4 >= cw - refbw_m1 || y + 5 >= ch - refbh_m1 {
    vp9_emulated_edge(
      self.mc_scaled_emu,
      0,
      288,
      src_cb,
      base - 3 * sstride - 3,
      sstride,
      refbw_m1 + 8,
      refbh_m1 + 8,
      x - 3,
      y - 3,
      cw,
      ch,
    )
    self.mc_scaled_kernel(
      dst_cb,
      dst_off,
      dst_stride,
      self.mc_scaled_emu,
      3 * 288 + 3,
      288,
      cbw,
      cbh,
      mx,
      my,
      step_x,
      step_y,
      filter,
      avg,
    )
    vp9_emulated_edge(
      self.mc_scaled_emu,
      0,
      288,
      src_cr,
      base - 3 * sstride - 3,
      sstride,
      refbw_m1 + 8,
      refbh_m1 + 8,
      x - 3,
      y - 3,
      cw,
      ch,
    )
    self.mc_scaled_kernel(
      dst_cr,
      dst_off,
      dst_stride,
      self.mc_scaled_emu,
      3 * 288 + 3,
      288,
      cbw,
      cbh,
      mx,
      my,
      step_x,
      step_y,
      filter,
      avg,
    )
    return
  }
  self.mc_scaled_kernel(
    dst_cb, dst_off, dst_stride, src_cb, base, sstride, cbw, cbh, mx, my, step_x,
    step_y, filter, avg,
  )
  self.mc_scaled_kernel(
    dst_cr, dst_off, dst_stride, src_cr, base, sstride, cbw, cbh, mx, my, step_x,
    step_y, filter, avg,
  )
  println(
    "CHW dbg: dir cb=\{dst_cb[dst_off]} cr=\{dst_cr[dst_off]} cbw=\{cbw} cbh=\{cbh} mx=\{mx} my=\{my} step=(\{step_x},\{step_y}) base=\{base} sstride=\{sstride}",
  )
}
