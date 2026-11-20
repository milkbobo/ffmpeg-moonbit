///|
/// SIMD (`@v128`) versions of the H.264 in-loop deblocking filter kernels
/// (`libavcodec/h264dsp_template.c`: `h264_loop_filter_luma`,
/// `h264_loop_filter_luma_intra`, `h264_loop_filter_chroma`,
/// `h264_loop_filter_chroma_intra`; the scalar ports are `h264_lf_luma`,
/// `h264_lf_luma_intra`, `h264_lf_chroma`, `h264_lf_chroma_intra` in
/// `libavcodec/h264_deblock.mbt`).
///
/// Port of the vectorised formulation used by FFmpeg's x86 SIMD path
/// (`libavcodec/x86/h264_deblock.asm`: `ff_deblock_v_luma_8`,
/// `ff_deblock_h_luma_8`, `ff_deblock_{v,h}_luma_intra_8`,
/// `ff_deblock_{v,h}_chroma_8`, `ff_deblock_{v,h}_chroma_intra_8` and the
/// `_chroma422` variants). The asm keeps a whole 16-sample luma edge (4
/// sub-blocks x 4 samples) in one `i8x16` register, derives the three
/// alpha/beta edge masks with `psubusb`+`por` (`DIFF_GT` inside
/// `LOAD_MASK`), ANDs them into the per-sample tc mask, and applies the
/// p0/q0 delta with saturating byte adds (`DEBLOCK_P0_Q0`); horizontal
/// edges are transposed through a stack scratch (`TRANSPOSE6x8_MEM`) so
/// the same vertical body applies to both orientations.
///
/// This port vectorises along the `along` dimension instead — the `d` loop
/// of the C template, 4 lanes for luma and 2..4 for chroma. One `i32x4`
/// holds the samples of one sub-block and the four sub-blocks of an edge
/// run in sequence, each with its own `tc0` (exactly like the scalar
/// port's outer `i` loop). The `i32` lane domain means the bit-depth
/// scaling (`alpha <<= BIT_DEPTH-8`, `tc0 <<= BIT_DEPTH-8`) and the
/// 14-bit worst case of `(q0-p0)*4 + (p1-q1)` need no overflow argument:
/// every intermediate is the scalar port's own `Int32` arithmetic, so the
/// output is bit-identical by construction at 8..14-bit rather than by
/// saturation analysis. The asm's masks become `i32x4` compare results,
/// its `pand`/`pandn` select becomes `v128_bitselect`, and
/// `av_clip_pixel` becomes a `min_s`/`max_s` pair.
///
/// Deviations (documented):
///   - the asm filters 16 contiguous edge samples with `i8x16` (and
///     transposes for horizontal edges); here each lane is gathered from
///     the port's `Array[Int32]` planes — that representation has no
///     contiguous 16-byte edge load — and no transpose is needed because a
///     lane's address is `base + j*ystep - k*xstep` for both orientations;
///   - the two strong-filter taps `p3`/`q3` are loaded only when some lane
///     actually takes the `|p2-p0| < beta` branch, matching the scalar
///     port's conditional reads (an unconditional gather could touch the
///     plane before the first row at a picture border).
///
/// Gated to `native`/`wasm`; other targets keep the scalar kernels. Equal
/// outputs are asserted in `h264_deblock_v128_wbtest.mbt`.

///|
/// `|d| < lim` lane-wise (`i32`). */
#cfg(any(target="native", target="wasm"))
fn dbl_abs_lt(d : V128, lim : V128) -> V128 {
  @v128.i32x4_lt_s(@v128.i32x4_abs(d), lim)
}

///|
/// `av_clip(v, lo, hi)` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn dbl_clamp(v : V128, lo : V128, hi : V128) -> V128 {
  @v128.i32x4_min_s(@v128.i32x4_max_s(v, lo), hi)
}

///|
/// `av_clip_pixel` lane-wise. */
#cfg(any(target="native", target="wasm"))
fn dbl_clip_pixel(v : V128, zero : V128, mx : V128) -> V128 {
  @v128.i32x4_min_s(@v128.i32x4_max_s(v, zero), mx)
}

///|
/// Lane `j` (0..n-1) of the returned vector is `data[base - k*xstep +
/// j*ystep]`; unused lanes stay zero. */
#cfg(any(target="native", target="wasm"))
fn dbl_gather(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  k : Int32,
  n : Int32,
) -> V128 {
  let o = base - k * xstep
  let mut v = @v128.i32x4_splat(0)
  let mut j = 0
  while j < n {
    v = @v128.i32x4_replace_lane(v, data[o + j * ystep].reinterpret_as_uint(), j)
    j = j + 1
  }
  v
}

///|
/// Store the lanes selected by `bits` (`i32x4_bitmask` of the update mask)
/// to `data[base - k*xstep + j*ystep]`; lanes >= n are never written. */
#cfg(any(target="native", target="wasm"))
fn dbl_store_masked(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  k : Int32,
  n : Int32,
  v : V128,
  bits : Int32,
) -> Unit {
  let o = base - k * xstep
  let mut j = 0
  while j < n {
    if ((bits >> j) & 1) != 0 {
      data[o + j * ystep] = @v128.i32x4_extract_lane(v, j).reinterpret_as_int()
    }
    j = j + 1
  }
}

///|
/// `h264_loop_filter_luma` for one 4-sample group (`along` samples of the
/// edge at `base`, one `tc0`). */
#cfg(any(target="native", target="wasm"))
fn dbl_luma_seg(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0 : Int32,
  bit_depth : Int32,
) -> Unit {
  if tc0 < 0 {
    return
  }
  let alpha_v = @v128.i32x4_splat(alpha.reinterpret_as_uint())
  let beta_v = @v128.i32x4_splat(beta.reinterpret_as_uint())
  let tc0_v = @v128.i32x4_splat(tc0.reinterpret_as_uint())
  let neg_tc0 = @v128.i32x4_splat((0 - tc0).reinterpret_as_uint())
  let one = @v128.i32x4_splat(1)
  let zero = @v128.i32x4_splat(0)
  let four = @v128.i32x4_splat(4)
  let mx = @v128.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint())
  let mut c = 0
  while c < along {
    let n = if along - c > 4 { 4 } else { along - c }
    let b = base + c * ystep
    let p2 = dbl_gather(data, b, xstep, ystep, 3, n)
    let p1 = dbl_gather(data, b, xstep, ystep, 2, n)
    let p0 = dbl_gather(data, b, xstep, ystep, 1, n)
    let q0 = dbl_gather(data, b, xstep, ystep, 0, n)
    let q1 = dbl_gather(data, b, xstep, ystep, -1, n)
    let q2 = dbl_gather(data, b, xstep, ystep, -2, n)
    let m_outer = @v128.v128_and_(
      @v128.v128_and_(
        dbl_abs_lt(@v128.i32x4_sub(p0, q0), alpha_v),
        dbl_abs_lt(@v128.i32x4_sub(p1, p0), beta_v),
      ),
      dbl_abs_lt(@v128.i32x4_sub(q1, q0), beta_v),
    )
    if @v128.v128_any_true(m_outer) {
      let m_p2 = dbl_abs_lt(@v128.i32x4_sub(p2, p0), beta_v)
      let m_q2 = dbl_abs_lt(@v128.i32x4_sub(q2, q0), beta_v)
      // tc = tc0 + (|p2-p0| < beta) + (|q2-q0| < beta)
      let tc = @v128.i32x4_add(
        tc0_v,
        @v128.i32x4_add(
          @v128.v128_and_(m_p2, one),
          @v128.v128_and_(m_q2, one),
        ),
      )
      let neg_tc = @v128.i32x4_sub(zero, tc)
      // (((q0-p0)*4) + (p1-q1) + 4) >> 3, clipped to [-tc, tc]
      let idelta = dbl_clamp(
        @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(
              @v128.i32x4_shl(@v128.i32x4_sub(q0, p0), 2),
              @v128.i32x4_sub(p1, q1),
            ),
            four,
          ),
          3,
        ),
        neg_tc,
        tc,
      )
      // p0' / q0'
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        1,
        n,
        dbl_clip_pixel(@v128.i32x4_add(p0, idelta), zero, mx),
        @v128.i32x4_bitmask(m_outer),
      )
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        0,
        n,
        dbl_clip_pixel(@v128.i32x4_sub(q0, idelta), zero, mx),
        @v128.i32x4_bitmask(m_outer),
      )
      if tc0 != 0 {
        // p1' = clip_pixel(p1 + clip((p2 + ((p0+q0+1)>>1))>>1 - p1, -tc0, tc0))
        let half_pq = @v128.i32x4_shr_s(
          @v128.i32x4_add(@v128.i32x4_add(p0, q0), one),
          1,
        )
        let aim_p = @v128.i32x4_shr_s(@v128.i32x4_add(p2, half_pq), 1)
        let new_p1 = dbl_clip_pixel(
          @v128.i32x4_add(
            p1,
            dbl_clamp(@v128.i32x4_sub(aim_p, p1), neg_tc0, tc0_v),
          ),
          zero,
          mx,
        )
        dbl_store_masked(
          data,
          b,
          xstep,
          ystep,
          2,
          n,
          new_p1,
          @v128.i32x4_bitmask(m_outer) & @v128.i32x4_bitmask(m_p2),
        )
        let aim_q = @v128.i32x4_shr_s(@v128.i32x4_add(q2, half_pq), 1)
        let new_q1 = dbl_clip_pixel(
          @v128.i32x4_add(
            q1,
            dbl_clamp(@v128.i32x4_sub(aim_q, q1), neg_tc0, tc0_v),
          ),
          zero,
          mx,
        )
        dbl_store_masked(
          data,
          b,
          xstep,
          ystep,
          -1,
          n,
          new_q1,
          @v128.i32x4_bitmask(m_outer) & @v128.i32x4_bitmask(m_q2),
        )
      }
    }
    c = c + 4
  }
}

///|
/// `h264_lf_luma` with the four sub-blocks carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_lf_luma_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0 : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_luma_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tc0,
      bit_depth,
    )
  }
}

///|
/// `h264_loop_filter_luma_intra` for one 4-sample group. */
#cfg(any(target="native", target="wasm"))
fn dbl_luma_intra_seg(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth : Int32,
) -> Unit {
  ignore(bit_depth)
  let alpha_v = @v128.i32x4_splat(alpha.reinterpret_as_uint())
  let beta_v = @v128.i32x4_splat(beta.reinterpret_as_uint())
  let two = @v128.i32x4_splat(2)
  let four = @v128.i32x4_splat(4)
  let mut c = 0
  while c < along {
    let n = if along - c > 4 { 4 } else { along - c }
    let b = base + c * ystep
    let p1 = dbl_gather(data, b, xstep, ystep, 2, n)
    let p0 = dbl_gather(data, b, xstep, ystep, 1, n)
    let q0 = dbl_gather(data, b, xstep, ystep, 0, n)
    let q1 = dbl_gather(data, b, xstep, ystep, -1, n)
    let m_outer = @v128.v128_and_(
      @v128.v128_and_(
        dbl_abs_lt(@v128.i32x4_sub(p0, q0), alpha_v),
        dbl_abs_lt(@v128.i32x4_sub(p1, p0), beta_v),
      ),
      dbl_abs_lt(@v128.i32x4_sub(q1, q0), beta_v),
    )
    if @v128.v128_any_true(m_outer) {
      let p2 = dbl_gather(data, b, xstep, ystep, 3, n)
      let q2 = dbl_gather(data, b, xstep, ystep, -2, n)
      // |p0-q0| < (alpha >> 2) + 2 selects the strong (3-tap) branch
      let m_strong = dbl_abs_lt(
        @v128.i32x4_sub(p0, q0),
        @v128.i32x4_splat(((alpha >> 2) + 2).reinterpret_as_uint()),
      )
      let m_p2 = dbl_abs_lt(@v128.i32x4_sub(p2, p0), beta_v)
      let m_q2 = dbl_abs_lt(@v128.i32x4_sub(q2, q0), beta_v)
      let m_p = @v128.v128_and_(m_strong, m_p2)
      let m_q = @v128.v128_and_(m_strong, m_q2)
      let outer_bits = @v128.i32x4_bitmask(m_outer)
      // p0' = strong&&p2 ? (p2+2p1+2p0+2q0+q1+4)>>3 : (2p1+p0+q1+2)>>2
      let p0_a = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(p2, @v128.i32x4_mul(p1, two)),
            @v128.i32x4_add(@v128.i32x4_mul(p0, two), @v128.i32x4_mul(q0, two)),
          ),
          @v128.i32x4_add(q1, four),
        ),
        3,
      )
      let p0_b = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(@v128.i32x4_mul(p1, two), p0),
          @v128.i32x4_add(q1, two),
        ),
        2,
      )
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        1,
        n,
        @v128.v128_bitselect(p0_a, p0_b, m_p),
        outer_bits,
      )
      // q0' = strong&&q2 ? (p1+2p0+2q0+2q1+q2+4)>>3 : (2q1+q0+p1+2)>>2
      let q0_a = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(
            @v128.i32x4_add(q2, @v128.i32x4_mul(q1, two)),
            @v128.i32x4_add(@v128.i32x4_mul(q0, two), @v128.i32x4_mul(p0, two)),
          ),
          @v128.i32x4_add(p1, four),
        ),
        3,
      )
      let q0_b = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(@v128.i32x4_mul(q1, two), q0),
          @v128.i32x4_add(p1, two),
        ),
        2,
      )
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        0,
        n,
        @v128.v128_bitselect(q0_a, q0_b, m_q),
        outer_bits,
      )
      // The strong-filter taps only run for lanes whose outer mask held.
      let p_bits = @v128.i32x4_bitmask(@v128.v128_and_(m_outer, m_p))
      if p_bits != 0 {
        // p1' = (p2+p1+p0+q0+2)>>2, p2' = (2p3+3p2+p1+p0+q0+4)>>3
        let p1_new = @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(@v128.i32x4_add(p2, p1), @v128.i32x4_add(p0, q0)),
            two,
          ),
          2,
        )
        dbl_store_masked(data, b, xstep, ystep, 2, n, p1_new, p_bits)
        let p3 = dbl_gather(data, b, xstep, ystep, 4, n)
        let p2_new = @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(
              @v128.i32x4_add(@v128.i32x4_mul(p3, two), @v128.i32x4_mul(p2, two)),
              @v128.i32x4_add(p2, p1),
            ),
            @v128.i32x4_add(@v128.i32x4_add(p0, q0), four),
          ),
          3,
        )
        dbl_store_masked(data, b, xstep, ystep, 3, n, p2_new, p_bits)
      }
      let q_bits = @v128.i32x4_bitmask(@v128.v128_and_(m_outer, m_q))
      if q_bits != 0 {
        // q1' = (p0+q0+q1+q2+2)>>2, q2' = (2q3+3q2+q1+q0+p0+4)>>3
        let q1_new = @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(@v128.i32x4_add(p0, q0), @v128.i32x4_add(q1, q2)),
            two,
          ),
          2,
        )
        dbl_store_masked(data, b, xstep, ystep, -1, n, q1_new, q_bits)
        let q3 = dbl_gather(data, b, xstep, ystep, -3, n)
        let q2_new = @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(
              @v128.i32x4_add(@v128.i32x4_mul(q3, two), @v128.i32x4_mul(q2, two)),
              @v128.i32x4_add(q2, q1),
            ),
            @v128.i32x4_add(@v128.i32x4_add(q0, p0), four),
          ),
          3,
        )
        dbl_store_masked(data, b, xstep, ystep, -2, n, q2_new, q_bits)
      }
    }
    c = c + 4
  }
}

///|
/// `h264_lf_luma_intra` with the strong-filter taps carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_lf_luma_intra_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_luma_intra_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      bit_depth,
    )
  }
}

///|
/// `h264_loop_filter_chroma` for one sub-block (`tc` already carries the
/// chroma `+1` of the port). */
#cfg(any(target="native", target="wasm"))
fn dbl_chroma_seg(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc : Int32,
  bit_depth : Int32,
) -> Unit {
  if tc <= 0 {
    return
  }
  let alpha_v = @v128.i32x4_splat(alpha.reinterpret_as_uint())
  let beta_v = @v128.i32x4_splat(beta.reinterpret_as_uint())
  let tc_v = @v128.i32x4_splat(tc.reinterpret_as_uint())
  let neg_tc = @v128.i32x4_splat((0 - tc).reinterpret_as_uint())
  let zero = @v128.i32x4_splat(0)
  let four = @v128.i32x4_splat(4)
  let mx = @v128.i32x4_splat(((1 << bit_depth) - 1).reinterpret_as_uint())
  let mut c = 0
  while c < along {
    let n = if along - c > 4 { 4 } else { along - c }
    let b = base + c * ystep
    let p1 = dbl_gather(data, b, xstep, ystep, 2, n)
    let p0 = dbl_gather(data, b, xstep, ystep, 1, n)
    let q0 = dbl_gather(data, b, xstep, ystep, 0, n)
    let q1 = dbl_gather(data, b, xstep, ystep, -1, n)
    let m_outer = @v128.v128_and_(
      @v128.v128_and_(
        dbl_abs_lt(@v128.i32x4_sub(p0, q0), alpha_v),
        dbl_abs_lt(@v128.i32x4_sub(p1, p0), beta_v),
      ),
      dbl_abs_lt(@v128.i32x4_sub(q1, q0), beta_v),
    )
    if @v128.v128_any_true(m_outer) {
      let delta = dbl_clamp(
        @v128.i32x4_shr_s(
          @v128.i32x4_add(
            @v128.i32x4_add(
              @v128.i32x4_shl(@v128.i32x4_sub(q0, p0), 2),
              @v128.i32x4_sub(p1, q1),
            ),
            four,
          ),
          3,
        ),
        neg_tc,
        tc_v,
      )
      let bits = @v128.i32x4_bitmask(m_outer)
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        1,
        n,
        dbl_clip_pixel(@v128.i32x4_add(p0, delta), zero, mx),
        bits,
      )
      dbl_store_masked(
        data,
        b,
        xstep,
        ystep,
        0,
        n,
        dbl_clip_pixel(@v128.i32x4_sub(q0, delta), zero, mx),
        bits,
      )
    }
    c = c + 4
  }
}

///|
/// `h264_lf_chroma` with the bilinear p0/q0 update carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_lf_chroma_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_chroma_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tc,
      bit_depth,
    )
  }
}

///|
/// `h264_loop_filter_chroma_intra` for one sub-block. */
#cfg(any(target="native", target="wasm"))
fn dbl_chroma_intra_seg(
  data : Array[Int32],
  base : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth : Int32,
) -> Unit {
  ignore(bit_depth)
  let alpha_v = @v128.i32x4_splat(alpha.reinterpret_as_uint())
  let beta_v = @v128.i32x4_splat(beta.reinterpret_as_uint())
  let two = @v128.i32x4_splat(2)
  let mut c = 0
  while c < along {
    let n = if along - c > 4 { 4 } else { along - c }
    let b = base + c * ystep
    let p1 = dbl_gather(data, b, xstep, ystep, 2, n)
    let p0 = dbl_gather(data, b, xstep, ystep, 1, n)
    let q0 = dbl_gather(data, b, xstep, ystep, 0, n)
    let q1 = dbl_gather(data, b, xstep, ystep, -1, n)
    let m_outer = @v128.v128_and_(
      @v128.v128_and_(
        dbl_abs_lt(@v128.i32x4_sub(p0, q0), alpha_v),
        dbl_abs_lt(@v128.i32x4_sub(p1, p0), beta_v),
      ),
      dbl_abs_lt(@v128.i32x4_sub(q1, q0), beta_v),
    )
    if @v128.v128_any_true(m_outer) {
      let bits = @v128.i32x4_bitmask(m_outer)
      let p0_new = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(@v128.i32x4_mul(p1, two), p0),
          @v128.i32x4_add(q1, two),
        ),
        2,
      )
      let q0_new = @v128.i32x4_shr_s(
        @v128.i32x4_add(
          @v128.i32x4_add(@v128.i32x4_mul(q1, two), q0),
          @v128.i32x4_add(p1, two),
        ),
        2,
      )
      dbl_store_masked(data, b, xstep, ystep, 1, n, p0_new, bits)
      dbl_store_masked(data, b, xstep, ystep, 0, n, q0_new, bits)
    }
    c = c + 4
  }
}

///|
/// `h264_lf_chroma_intra` with the convex-average taps carried by `@v128`.
#cfg(any(target="native", target="wasm"))
pub fn h264_lf_chroma_intra_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_chroma_intra_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      bit_depth,
    )
  }
}

///|
/// `ff_deblock_v_luma_8` / `ff_deblock_h_luma_8` shape: one edge with four
/// independent `tc0` values (the asm's `int8_t *tc0`). Negative entries
/// skip their sub-block. */
#cfg(any(target="native", target="wasm"))
pub fn h264_deblock_luma_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tc0s : Array[Int32],
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_luma_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tc0s[s],
      bit_depth,
    )
  }
}

///|
/// `ff_deblock_v_chroma_8` / `ff_deblock_h_chroma_8` shape: one chroma edge
/// with four independent `tc` values. Non-positive entries skip their
/// sub-block. */
#cfg(any(target="native", target="wasm"))
pub fn h264_deblock_chroma_v128(
  data : Array[Int32],
  start : Int32,
  xstep : Int32,
  ystep : Int32,
  along : Int32,
  alpha : Int32,
  beta : Int32,
  tcs : Array[Int32],
  bit_depth~ : Int32 = 8,
) -> Unit {
  for s = 0; s < 4; s = s + 1 {
    dbl_chroma_seg(
      data,
      start + s * along * ystep,
      xstep,
      ystep,
      along,
      alpha,
      beta,
      tcs[s],
      bit_depth,
    )
  }
}
