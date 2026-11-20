///|
/// SIMD (`@v128`) version of the VP9 loop filter
/// (`libavcodec/vp9dsp_template.c`: `loop_filter` with its `wd` 4/8/16
/// branches — `flat8out`, `flat8in` and the `hev`/non-`hev` 4-tap form;
/// the scalar port is `vp9_loop_filter_core` in `libavcodec/vp9_dsp.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/vp9lpf.asm`: the `v`/`h`/`mix2` entry points with the
/// `lp`/`hp` coefficient banks and the `INTRA_`/`FILTER_` select masks).
/// The asm's lane axis is the **eight filter lines** of one edge, with the
/// p/q taps gathered along the perpendicular stride (`strideb`); that is
/// preserved here:
///
///   - lane `i` of an `i32x4` is line `i`; two vectors cover the eight
///     lines of one edge segment (`vp9_loop_filter_strip4_v128` twice);
///   - the `fm` gate, the `flat8in`/`flat8out` gates and the `hev` test are
///     lane-wise `i32x4` compares combined with
///     `v128_and_`/`v128_or_`/`v128_not`, exactly like the asm's
///     `pcmpeqb`+`pand`/`por`;
///   - because different lanes may take different branches, all three
///     candidate outputs are computed lane-wise and merged with
///     `v128_bitselect` against the branch masks, then written with a
///     per-lane masked store. The asm instead branches on whether a whole
///     16-pixel group's mask is all-zero; selecting per lane is strictly
///     more general and identical whenever the mask is uniform (which the
///     caller-side edge grouping makes the common case).
///
/// `i32x4` lanes carry the port's `FixedArray[Int32]` samples, so
/// `clip_intp2`/`clip_pixel` and the `F`/`E`/`I`/`H` bit-depth scaling are
/// the scalar port's own arithmetic — no re-derivation of the asm's
/// `packuswb` saturation is needed.
///
/// The `flat8out` 14-line tree is generated from the C's multiplicities:
/// output `t` (tap offset `-7+t`) averages the 16 taps
/// `[p7 p6 p5 p4 p3 p2 p1 p0 q0 q1 q2 q3 q4 q5 q6 q7]` over the active
/// range `[max(0,t-6), min(15,t+8)]`, with the low end counted `7-t`
/// times when `lo == 0` and the high end counted `t-6` times when
/// `hi == 15`, plus one extra copy of tap `t+1` (the "doubled" centre).
/// Each output therefore has exactly 16 terms, matching the C line by
/// line (verified in the wbtest against a verbatim transcription).
///
/// Deviations (documented): the asm has separate `_h`/`_v` entry points
/// (`stridea`/`strideb` swapped) and a `mix2` variant splitting the filter
/// parameters into two halves; here one kernel takes `stridea`/`strideb`
/// explicitly and `mix2` is two calls, which is what the scalar port's
/// `vp9_loop_filter_mix2` does.
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernel. Equal
/// outputs are asserted in `vp9_lpf_v128_wbtest.mbt`.

///|
/// `av_clip_intp2` lane-wise: clamp to `[-2^(bits-1), 2^(bits-1)-1]`. */
#cfg(any(target="native", target="wasm"))
fn vlpf_clip_intp2_v(v : V128, bits : Int32) -> V128 {
  let hi = @v128.i32x4_splat(((1 << (bits - 1)) - 1).reinterpret_as_uint())
  let lo = @v128.i32x4_splat((0 - (1 << (bits - 1))).reinterpret_as_uint())
  @v128.i32x4_min_s(@v128.i32x4_max_s(v, lo), hi)
}

///|
/// `av_clip_pixel` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn vlpf_clip_pixel_v(v : V128, pixel_max : Int32) -> V128 {
  @v128.i32x4_min_s(
    @v128.i32x4_max_s(v, @v128.i32x4_splat(0)),
    @v128.i32x4_splat(pixel_max.reinterpret_as_uint()),
  )
}

///|
/// Gather four lines' samples at tap offset `k` (lane `i` = line `i`). */
#cfg(any(target="native", target="wasm"))
fn vlpf_gather(
  p : FixedArray[Int32],
  off : Int32,
  stridea : Int32,
  strideb : Int32,
  k : Int32,
) -> V128 {
  let base = off + k * strideb
  let mut v = @v128.i32x4_splat(0)
  let mut i = 0
  while i < 4 {
    v = @v128.i32x4_replace_lane(v, p[base + i * stridea].reinterpret_as_uint(), i)
    i = i + 1
  }
  v
}

///|
/// Write the lanes selected by `bits` to tap offset `k`. */
#cfg(any(target="native", target="wasm"))
fn vlpf_store_masked(
  p : FixedArray[Int32],
  off : Int32,
  stridea : Int32,
  strideb : Int32,
  k : Int32,
  v : V128,
  bits : Int32,
) -> Unit {
  if bits == 0 {
    return
  }
  let base = off + k * strideb
  let mut i = 0
  while i < 4 {
    if ((bits >> i) & 1) != 0 {
      p[base + i * stridea] = @v128.i32x4_extract_lane(v, i).reinterpret_as_int()
    }
    i = i + 1
  }
}

///|
/// `abs(a - b) <= lim` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn vlpf_abs_le(a : V128, b : V128, lim : V128) -> V128 {
  @v128.i32x4_le_s(@v128.i32x4_abs(@v128.i32x4_sub(a, b)), lim)
}

///|
/// `abs(a - b) > lim` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn vlpf_abs_gt(a : V128, b : V128, lim : V128) -> V128 {
  @v128.i32x4_gt_s(@v128.i32x4_abs(@v128.i32x4_sub(a, b)), lim)
}

///|
/// One `flat8out` output: the 16-term weighted average for output index
/// `t` (0..13) over the 16 taps `p7..p0,q0..q7`.
#cfg(any(target="native", target="wasm"))
fn vlpf_flat8out_line(taps : Array[V128], t : Int32) -> V128 {
  let lo = if t > 6 { t - 6 } else { 0 }
  let hi = if t + 8 < 15 { t + 8 } else { 15 }
  let dbl = t + 1
  let mut acc = @v128.i32x4_splat(0)
  for j = lo; j <= hi; j = j + 1 {
    let mut mult = 1
    if j == lo && lo == 0 {
      mult = 7 - t
    } else if j == hi && hi == 15 {
      mult = t - 6
    }
    if j == dbl {
      mult = mult + 1
    }
    let mut c = 0
    while c < mult {
      acc = @v128.i32x4_add(acc, taps[j])
      c = c + 1
    }
  }
  @v128.i32x4_shr_s(@v128.i32x4_add(acc, @v128.i32x4_splat(8)), 4)
}

///|
/// One 4-line group of the loop filter. All three `wd` branches are
/// computed lane-wise and merged with `v128_bitselect`.
#cfg(any(target="native", target="wasm"))
pub fn vp9_loop_filter_strip4_v128(
  p : FixedArray[Int32],
  off : Int32,
  stridea : Int32,
  strideb : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  let shift = bpp - 8
  let f_flat = 1 << shift
  let ev = @v128.i32x4_splat((e << shift).reinterpret_as_uint())
  let iv = @v128.i32x4_splat((i_lim << shift).reinterpret_as_uint())
  let hv = @v128.i32x4_splat((h_lim << shift).reinterpret_as_uint())
  let fv = @v128.i32x4_splat(f_flat.reinterpret_as_uint())
  let p3 = vlpf_gather(p, off, stridea, strideb, -4)
  let p2 = vlpf_gather(p, off, stridea, strideb, -3)
  let p1 = vlpf_gather(p, off, stridea, strideb, -2)
  let p0 = vlpf_gather(p, off, stridea, strideb, -1)
  let q0 = vlpf_gather(p, off, stridea, strideb, 0)
  let q1 = vlpf_gather(p, off, stridea, strideb, 1)
  let q2 = vlpf_gather(p, off, stridea, strideb, 2)
  let q3 = vlpf_gather(p, off, stridea, strideb, 3)
  // fm = six |diff| <= I, and 2|p0-q0| + (|p1-q1| >> 1) <= E
  let fm = @v128.v128_and_(
    @v128.v128_and_(
      @v128.v128_and_(vlpf_abs_le(p3, p2, iv), vlpf_abs_le(p2, p1, iv)),
      @v128.v128_and_(vlpf_abs_le(p1, p0, iv), vlpf_abs_le(q1, q0, iv)),
    ),
    @v128.v128_and_(
      @v128.v128_and_(vlpf_abs_le(q2, q1, iv), vlpf_abs_le(q3, q2, iv)),
      @v128.i32x4_le_s(
        @v128.i32x4_add(
          @v128.i32x4_mul(
            @v128.i32x4_abs(@v128.i32x4_sub(p0, q0)),
            @v128.i32x4_splat(2),
          ),
          @v128.i32x4_shr_u(@v128.i32x4_abs(@v128.i32x4_sub(p1, q1)), 1),
        ),
        ev,
      ),
    ),
  )
  if !@v128.v128_any_true(fm) {
    return
  }
  let flat8in = if wd >= 8 {
    @v128.v128_and_(
      @v128.v128_and_(
        @v128.v128_and_(vlpf_abs_le(p3, p0, fv), vlpf_abs_le(p2, p0, fv)),
        vlpf_abs_le(p1, p0, fv),
      ),
      @v128.v128_and_(
        @v128.v128_and_(vlpf_abs_le(q1, q0, fv), vlpf_abs_le(q2, q0, fv)),
        vlpf_abs_le(q3, q0, fv),
      ),
    )
  } else {
    @v128.i32x4_splat(0)
  }
  let mut taps : Array[V128] = []
  let mut flat8out = @v128.i32x4_splat(0)
  if wd >= 16 {
    let p4 = vlpf_gather(p, off, stridea, strideb, -5)
    let p5 = vlpf_gather(p, off, stridea, strideb, -6)
    let p6 = vlpf_gather(p, off, stridea, strideb, -7)
    let p7 = vlpf_gather(p, off, stridea, strideb, -8)
    let q4 = vlpf_gather(p, off, stridea, strideb, 4)
    let q5 = vlpf_gather(p, off, stridea, strideb, 5)
    let q6 = vlpf_gather(p, off, stridea, strideb, 6)
    let q7 = vlpf_gather(p, off, stridea, strideb, 7)
    flat8out = @v128.v128_and_(
      @v128.v128_and_(
        @v128.v128_and_(vlpf_abs_le(p7, p0, fv), vlpf_abs_le(p6, p0, fv)),
        @v128.v128_and_(vlpf_abs_le(p5, p0, fv), vlpf_abs_le(p4, p0, fv)),
      ),
      @v128.v128_and_(
        @v128.v128_and_(vlpf_abs_le(q4, q0, fv), vlpf_abs_le(q5, q0, fv)),
        @v128.v128_and_(vlpf_abs_le(q6, q0, fv), vlpf_abs_le(q7, q0, fv)),
      ),
    )
    taps = [p7, p6, p5, p4, p3, p2, p1, p0, q0, q1, q2, q3, q4, q5, q6, q7]
  }
  let m_out = if wd >= 16 {
    @v128.v128_and_(fm, @v128.v128_and_(flat8out, flat8in))
  } else {
    @v128.i32x4_splat(0)
  }
  let m_in = @v128.v128_and_(
    fm,
    @v128.v128_and_(flat8in, @v128.v128_not(m_out)),
  )
  let m_rest = @v128.v128_and_(fm, @v128.v128_not(m_in))
  let hev = @v128.v128_or_(vlpf_abs_gt(p1, p0, hv), vlpf_abs_gt(q1, q0, hv))
  let m_hev = @v128.v128_and_(m_rest, hev)
  let m_nev = @v128.v128_and_(m_rest, @v128.v128_not(hev))
  let r8 = @v128.i32x4_splat(8)
  let r4 = @v128.i32x4_splat(4)
  let two = @v128.i32x4_splat(2)
  // ---- flat8out: taps -7..+6 (only with wd >= 16) ----
  if wd >= 16 {
    let bits = @v128.i32x4_bitmask(m_out)
    if bits != 0 {
      for t = 0; t < 14; t = t + 1 {
        vlpf_store_masked(
          p,
          off,
          stridea,
          strideb,
          -7 + t,
          vlpf_flat8out_line(taps, t),
          bits,
        )
      }
    }
  }
  // ---- flat8in: taps -3..+2 ----
  let bits_in = @v128.i32x4_bitmask(m_in)
  if bits_in != 0 {
    let sh3 = 3
    let v3 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p3, @v128.i32x4_add(p3, p3)),
            @v128.i32x4_add(@v128.i32x4_mul(p2, two), p1),
          ),
          @v128.i32x4_add(p0, q0),
        ),
        r4,
      ),
      sh3,
    )
    let v2 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p3, p3),
            @v128.i32x4_add(p2, @v128.i32x4_mul(p1, two)),
          ),
          @v128.i32x4_add(p0, @v128.i32x4_add(q0, q1)),
        ),
        r4,
      ),
      sh3,
    )
    let v1 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p3, p2),
            @v128.i32x4_add(p1, @v128.i32x4_mul(p0, two)),
          ),
          @v128.i32x4_add(q0, @v128.i32x4_add(q1, q2)),
        ),
        r4,
      ),
      sh3,
    )
    let w0 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p2, p1),
            @v128.i32x4_add(p0, @v128.i32x4_mul(q0, two)),
          ),
          @v128.i32x4_add(q1, @v128.i32x4_add(q2, q3)),
        ),
        r4,
      ),
      sh3,
    )
    let w1 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p1, p0),
            @v128.i32x4_add(q0, @v128.i32x4_mul(q1, two)),
          ),
          @v128.i32x4_add(q2, @v128.i32x4_add(q3, q3)),
        ),
        r4,
      ),
      sh3,
    )
    let w2 = @v128.i32x4_shr_s(
      @v128.i32x4_add(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p0, q0),
            @v128.i32x4_add(q1, @v128.i32x4_mul(q2, two)),
          ),
          @v128.i32x4_add(q3, @v128.i32x4_add(q3, q3)),
        ),
        r4,
      ),
      sh3,
    )
    vlpf_store_masked(p, off, stridea, strideb, -3, v3, bits_in)
    vlpf_store_masked(p, off, stridea, strideb, -2, v2, bits_in)
    vlpf_store_masked(p, off, stridea, strideb, -1, v1, bits_in)
    vlpf_store_masked(p, off, stridea, strideb, 0, w0, bits_in)
    vlpf_store_masked(p, off, stridea, strideb, 1, w1, bits_in)
    vlpf_store_masked(p, off, stridea, strideb, 2, w2, bits_in)
  }
  // ---- 4-tap form: hev and non-hev merged ----
  let bits_rest = @v128.i32x4_bitmask(m_rest)
  if bits_rest != 0 {
    let three = @v128.i32x4_splat(3)
    let fmax = @v128.i32x4_splat(((1 << (bpp - 1)) - 1).reinterpret_as_uint())
    let fhev = vlpf_clip_intp2_v(
      @v128.i32x4_add(
        @v128.i32x4_mul(@v128.i32x4_sub(q0, p0), three),
        vlpf_clip_intp2_v(@v128.i32x4_sub(p1, q1), bpp - 1),
      ),
      bpp - 1,
    )
    let fnev = vlpf_clip_intp2_v(
      @v128.i32x4_mul(@v128.i32x4_sub(q0, p0), three),
      bpp - 1,
    )
    let f1_hev = @v128.i32x4_shr_s(
      @v128.i32x4_min_s(@v128.i32x4_add(fhev, r4), fmax),
      3,
    )
    let f2_hev = @v128.i32x4_shr_s(
      @v128.i32x4_min_s(
        @v128.i32x4_add(fhev, @v128.i32x4_splat(3)),
        fmax,
      ),
      3,
    )
    let f1_nev = @v128.i32x4_shr_s(
      @v128.i32x4_min_s(@v128.i32x4_add(fnev, r4), fmax),
      3,
    )
    let f2_nev = @v128.i32x4_shr_s(
      @v128.i32x4_min_s(
        @v128.i32x4_add(fnev, @v128.i32x4_splat(3)),
        fmax,
      ),
      3,
    )
    let p0_out = @v128.v128_bitselect(
      vlpf_clip_pixel_v(@v128.i32x4_add(p0, f2_hev), pixel_max),
      vlpf_clip_pixel_v(@v128.i32x4_add(p0, f2_nev), pixel_max),
      m_hev,
    )
    let q0_out = @v128.v128_bitselect(
      vlpf_clip_pixel_v(@v128.i32x4_sub(q0, f1_hev), pixel_max),
      vlpf_clip_pixel_v(@v128.i32x4_sub(q0, f1_nev), pixel_max),
      m_hev,
    )
    vlpf_store_masked(p, off, stridea, strideb, -1, p0_out, bits_rest)
    vlpf_store_masked(p, off, stridea, strideb, 0, q0_out, bits_rest)
    let bits_nev = @v128.i32x4_bitmask(m_nev)
    if bits_nev != 0 {
      let fhalf = @v128.i32x4_shr_s(
        @v128.i32x4_add(f1_nev, @v128.i32x4_splat(1)),
        1,
      )
      vlpf_store_masked(
        p,
        off,
        stridea,
        strideb,
        -2,
        vlpf_clip_pixel_v(@v128.i32x4_add(p1, fhalf), pixel_max),
        bits_nev,
      )
      vlpf_store_masked(
        p,
        off,
        stridea,
        strideb,
        1,
        vlpf_clip_pixel_v(@v128.i32x4_sub(q1, fhalf), pixel_max),
        bits_nev,
      )
    }
  }
  ignore(r8)
}

///|
/// `vp9_loop_filter_h`: `stridea = stride`, `strideb = 1`. */
#cfg(any(target="native", target="wasm"))
pub fn vp9_loop_filter_h_v128(
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  for g = 0; g < 2; g = g + 1 {
    vp9_loop_filter_strip4_v128(
      p,
      off + 4 * g * stride,
      stride,
      1,
      e,
      i_lim,
      h_lim,
      wd,
      bpp,
      pixel_max,
    )
  }
}

///|
/// `vp9_loop_filter_v`: `stridea = 1`, `strideb = stride`. */
#cfg(any(target="native", target="wasm"))
pub fn vp9_loop_filter_v_v128(
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  wd : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  for g = 0; g < 2; g = g + 1 {
    vp9_loop_filter_strip4_v128(
      p,
      off + 4 * g,
      1,
      stride,
      e,
      i_lim,
      h_lim,
      wd,
      bpp,
      pixel_max,
    )
  }
}

///|
/// `vp9_loop_filter_mix2`: two edges whose `e`/`i`/`h` come packed in the
/// low and high halves of one word, with independent widths `wd1`/`wd2`.
#cfg(any(target="native", target="wasm"))
pub fn vp9_loop_filter_mix2_v128(
  dir : Int32,
  wd1 : Int32,
  wd2 : Int32,
  p : FixedArray[Int32],
  off : Int32,
  stride : Int32,
  e : Int32,
  i_lim : Int32,
  h_lim : Int32,
  bpp : Int32,
  pixel_max : Int32,
) -> Unit {
  let e1 = e & 0xFF
  let i1 = i_lim & 0xFF
  let h1 = h_lim & 0xFF
  let e2 = e >> 8
  let i2 = i_lim >> 8
  let h2 = h_lim >> 8
  if dir == 0 {
    vp9_loop_filter_h_v128(
      p,
      off,
      stride,
      e1,
      i1,
      h1,
      4 << wd1,
      bpp,
      pixel_max,
    )
    vp9_loop_filter_h_v128(
      p,
      off + 8 * stride,
      stride,
      e2,
      i2,
      h2,
      4 << wd2,
      bpp,
      pixel_max,
    )
  } else {
    vp9_loop_filter_v_v128(
      p,
      off,
      stride,
      e1,
      i1,
      h1,
      4 << wd1,
      bpp,
      pixel_max,
    )
    vp9_loop_filter_v_v128(
      p,
      off + 8,
      stride,
      e2,
      i2,
      h2,
      4 << wd2,
      bpp,
      pixel_max,
    )
  }
}
