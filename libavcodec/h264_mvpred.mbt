///|
/// MoonBit port of the H.264 motion vector prediction from FFmpeg 9.0.2
/// `libavcodec/h264_mvpred.h` (`pred_motion`, `pred_16x8_motion`,
/// `pred_8x16_motion`, `pred_pskip_motion`), for progressive frame pictures
/// and a single L0 reference list.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C keeps the neighbours in the `scan8` cache (8-wide grid with a
/// one-cell border); this port fetches them on demand from the per-macroblock
/// `mv`/`ref_idx`/`mvd` arrays in `H264MbInfo`. The 4x4 block coordinates are
/// relative to the current macroblock, so `(-1, 0)` is the left macroblock's
/// rightmost block on the macroblock's top row, exactly the block the cache
/// slot `scan8[0] - 1` refers to.
///
/// Reference semantics (`ref_cache` values in the C): `REF_NOT_AVAIL` (-2)
/// when the neighbouring macroblock is outside the picture or not yet
/// decoded, `LIST_NOT_USED` (-1) when it is intra, `>= 0` the L0 reference
/// index of an inter macroblock.

///|
/// `PART_NOT_AVAILABLE`-style ref value: neighbour outside the picture. */
let h264_ref_not_avail : Int32 = -2

///|
/// `LIST_NOT_USED`: neighbour macroblock is intra. */
let h264_ref_list_not_used : Int32 = -1

///|
/// `MB_TYPE_16x16` etc. (`mpegutils.h`), the inter macroblock bits. */
let h264_mb_type_16x16 : Int32 = 1 << 3

///|
/// `MB_TYPE_16x8`. */
let h264_mb_type_16x8 : Int32 = 1 << 4

///|
/// `MB_TYPE_8x16`. */
let h264_mb_type_8x16 : Int32 = 1 << 5

///|
/// `MB_TYPE_8x8`. */
let h264_mb_type_8x8 : Int32 = 1 << 6

///|
/// `MB_TYPE_P0L0` / `MB_TYPE_P1L0`. */
let h264_mb_type_p0l0 : Int32 = 1 << 12

///|
/// `MB_TYPE_P1L0`. */
let h264_mb_type_p1l0 : Int32 = 1 << 13

///|
/// `MB_TYPE_SKIP`. */
let h264_mb_type_skip : Int32 = 1 << 17

///|
/// Is the macroblock type intra (I4x4 / I16x16 / PCM)?
fn h264_is_intra_type(mb_type_bits : Int32) -> Bool {
  (
    mb_type_bits &
    (h264_mb_type_intra4x4 | h264_mb_type_intra16x16 | h264_mb_type_intra_pcm)
  ) !=
  0
}

///|
/// Fetch the neighbour 4x4 block at (`bx`, `by`) in macroblock-relative 4x4
/// units. `by == -1` reads the macroblock row above (bottom row of those
/// macroblocks), `bx == -1` the macroblock to the left, `bx == 4` the
/// macroblock to the upper right. Returns `(ref, mvx, mvy)` with the
/// reference semantics above; the motion vector of a non-inter neighbour is 0.
fn h264_mv_fetch(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
) -> (Int32, Int32, Int32) {
  let ax = mb_x * 4 + bx
  let ay = mb_y * 4 + by
  if ax < 0 ||
    ay < 0 ||
    ax >= ctx.mb_width * 4 ||
    ay >= ctx.infos.length() / ctx.mb_width * 4 {
    return (h264_ref_not_avail, 0, 0)
  }
  let nmb = ay / 4 * ctx.mb_width + ax / 4
  let info = ctx.infos[nmb]
  // An undecoded macroblock counts as unavailable (`sl->top_type == 0`).
  if nmb != mb_idx && !h264_same_slice(ctx, nmb) {
    return (h264_ref_not_avail, 0, 0)
  }
  if h264_is_intra_type(info.mb_type_bits) {
    return (h264_ref_list_not_used, 0, 0)
  }
  let idx = ay % 4 * 4 + ax % 4
  (info.ref_idx[idx], info.mv[2 * idx], info.mv[2 * idx + 1])
}

///|
/// `pred_motion`: predicted MV for the partition whose top-left 4x4 block is
/// (`bx`, `by`) and whose width is `part_w` 4x4 blocks, using reference
/// `ref`. Returns `(mx, my)`.
fn h264_pred_motion(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
  part_w : Int32,
  refi : Int32,
) -> (Int32, Int32) {
  let (left_ref, amvx, amvy) = h264_mv_fetch(
    ctx,
    mb_idx,
    mb_x,
    mb_y,
    bx - 1,
    by,
  )
  let a = (amvx, amvy)
  let (top_ref, bmvx, bmvy) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, bx, by - 1)
  let b = (bmvx, bmvy)
  // fetch_diagonal_mv: C is the block above-right of the partition
  // (bx + part_w, by - 1); when that is unavailable, the block above-left.
  let mut c = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, bx + part_w, by - 1)
  if c.0 == h264_ref_not_avail {
    c = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, bx - 1, by - 1)
  }
  let diagonal_ref = c.0
  let mut match_count = 0
  if diagonal_ref == refi {
    match_count = match_count + 1
  }
  if top_ref == refi {
    match_count = match_count + 1
  }
  if left_ref == refi {
    match_count = match_count + 1
  }
  if match_count > 1 {
    (h264_mid3(a.0, b.0, c.1), h264_mid3(a.1, b.1, c.2))
  } else if match_count == 1 {
    if left_ref == refi {
      a
    } else if top_ref == refi {
      b
    } else {
      (c.1, c.2)
    }
  } else if top_ref == h264_ref_not_avail &&
    diagonal_ref == h264_ref_not_avail &&
    left_ref != h264_ref_not_avail {
    a
  } else {
    (h264_mid3(a.0, b.0, c.1), h264_mid3(a.1, b.1, c.2))
  }
}

///|
/// Median of three values (`mid_pred`). */
fn h264_mid3(a : Int32, b : Int32, c : Int32) -> Int32 {
  if a > b {
    if b > c {
      b
    } else if a > c {
      c
    } else {
      a
    }
  } else if a > c {
    a
  } else if b > c {
    c
  } else {
    b
  }
}

///|
/// `pred_16x8_motion`: partition `i` (0 top, 1 bottom) of a 16x8 macroblock.
fn h264_pred_16x8_motion(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  i : Int32,
  refi : Int32,
) -> (Int32, Int32) {
  if i == 0 {
    let (top_ref, mx, my) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, 0, -1)
    if top_ref == refi {
      return (mx, my)
    }
  } else {
    let (left_ref, mx, my) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, -1, 2)
    if left_ref == refi {
      return (mx, my)
    }
  }
  h264_pred_motion(ctx, mb_idx, mb_x, mb_y, 0, 2 * i, 4, refi)
}

///|
/// `pred_8x16_motion`: partition `i` (0 left, 1 right) of an 8x16 macroblock.
fn h264_pred_8x16_motion(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  i : Int32,
  refi : Int32,
) -> (Int32, Int32) {
  if i == 0 {
    let (left_ref, mx, my) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, -1, 0)
    if left_ref == refi {
      return (mx, my)
    }
  } else {
    // `fetch_diagonal_mv(scan8[4], 2)`: the above-right block, or the
    // above-left one when the above-right is unavailable.
    let mut diag = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, 4, -1)
    if diag.0 == h264_ref_not_avail {
      diag = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, 1, -1)
    }
    if diag.0 == refi {
      return (diag.1, diag.2)
    }
  }
  h264_pred_motion(ctx, mb_idx, mb_x, mb_y, 2 * i, 0, 2, refi)
}

///|
/// `pred_pskip_motion`: the P_16x16 MV prediction with reference 0 and the
/// zero-MV early outs (a neighbouring inter macroblock with reference 0 and a
/// zero MV gives a zero prediction). Returns `(mx, my, ref0_available)`
/// where the last component tells whether reference 0 exists at all (no
/// reference picture decoded yet: the skip MV is then 0).
fn h264_pred_pskip_motion(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
) -> (Int32, Int32) {
  // Missing left/top neighbours force zero, independently of the other
  // neighbour. Otherwise ref 0 with a zero MV gives the same early out.
  let (lref, lmvx, lmvy) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, -1, 0)
  if lref == h264_ref_not_avail || (lref == 0 && lmvx == 0 && lmvy == 0) {
    return (0, 0)
  }
  let (tref, tmvx, tmvy) = h264_mv_fetch(ctx, mb_idx, mb_x, mb_y, 0, -1)
  if tref == h264_ref_not_avail || (tref == 0 && tmvx == 0 && tmvy == 0) {
    return (0, 0)
  }
  // Reference 0 must exist for a meaningful prediction.
  if ctx.ref_list0.length() == 0 {
    return (0, 0)
  }
  h264_pred_motion(ctx, mb_idx, mb_x, mb_y, 0, 0, 4, 0)
}

///|
/// Fetch the mvd (motion vector difference) of a neighbouring 4x4 block,
/// for the CABAC `amvd` context. Unavailable and intra neighbours
/// contribute 0, matching the `mvd_cache` fill in `fill_decode_caches`.
fn h264_mvd_fetch(
  ctx : H264DecCtx,
  mb_idx : Int32,
  mb_x : Int32,
  mb_y : Int32,
  bx : Int32,
  by : Int32,
) -> (Int32, Int32) {
  let ax = mb_x * 4 + bx
  let ay = mb_y * 4 + by
  if ax < 0 ||
    ay < 0 ||
    ax >= ctx.mb_width * 4 ||
    ay >= ctx.infos.length() / ctx.mb_width * 4 {
    return (0, 0)
  }
  let nmb = ay / 4 * ctx.mb_width + ax / 4
  let info = ctx.infos[nmb]
  if nmb != mb_idx && !h264_same_slice(ctx, nmb) {
    return (0, 0)
  }
  if h264_is_intra_type(info.mb_type_bits) {
    return (0, 0)
  }
  let idx = ay % 4 * 4 + ax % 4
  (info.mvd[2 * idx], info.mvd[2 * idx + 1])
}
