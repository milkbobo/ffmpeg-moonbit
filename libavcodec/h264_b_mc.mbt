///|
/// FFmpeg 9.0.2 h264_mb.c mc_part_weighted/implicit_weight_table, progressive.
/// LGPL-2.1-or-later. Small local prediction buffers preserve rounding before
/// combining the two unweighted predictors.
fn h264_b_prediction(
  ctx : H264DecCtx,
  list : Int32,
  refi : Int32,
  mb_x : Int32,
  mb_y : Int32,
  x : Int32,
  y : Int32,
  w : Int32,
  h : Int32,
  mvx : Int32,
  mvy : Int32,
) -> Array[Array[Int32]] {
  let list_refs = if list == 0 { ctx.ref_list0 } else { ctx.ref_list1 }
  let entry = h264_ref_entry(ctx, refi, ctx.mb_field, mb_y & 1)
  let pic = list_refs[entry.min(list_refs.length() - 1)]
  let field = ctx.mb_field
  let parity = mb_y & 1
  let out = [Array::make(256, 0), Array::make(256, 0), Array::make(256, 0)]
  let src_y = if field { (mb_y >> 1) * 16 } else { mb_y * 16 }
  h264_mc_luma(
    out[0],
    0,
    16,
    pic.y,
    mb_x * 16 + x + (mvx >> 2),
    src_y + y + (mvy >> 2),
    pic.ystride,
    w,
    h,
    mvx & 3,
    mvy & 3,
    pic.width,
    pic.height,
    sbase=pic.base_y,
    bit_depth=ctx.bit_depth,
  )
  if ctx.chroma_format == 3 {
    for c in 0..<2 {
      let (src, base) = if c == 0 {
        (pic.u, pic.base_u)
      } else {
        (pic.v, pic.base_v)
      }
      h264_mc_luma(
        out[c + 1],
        0,
        16,
        src,
        mb_x * 16 + x + (mvx >> 2),
        src_y + y + (mvy >> 2),
        pic.cstride,
        w,
        h,
        mvx & 3,
        mvy & 3,
        pic.cwidth,
        pic.cheight,
        sbase=base,
        bit_depth=ctx.bit_depth,
      )
    }
  } else {
    let cw = w >> ctx.chroma_hshift
    let ch = h >> ctx.chroma_vshift
    let src_cy = if field {
      (mb_y >> 1) * (16 >> ctx.chroma_vshift)
    } else {
      mb_y * (16 >> ctx.chroma_vshift)
    }
    let chroma_my = if field && ctx.chroma_format == 1 {
      mvy + 2 * (parity - (pic.parity - 1))
    } else {
      mvy
    }
    for c in 0..<2 {
      let (src, base) = if c == 0 {
        (pic.u, pic.base_u)
      } else {
        (pic.v, pic.base_v)
      }
      h264_mc_chroma(
        out[c + 1],
        0,
        8,
        src,
        mb_x * (16 >> ctx.chroma_hshift) + (x >> ctx.chroma_hshift),
        src_cy + (y >> ctx.chroma_vshift),
        mvx,
        chroma_my,
        pic.cstride,
        cw,
        ch,
        pic.cwidth,
        pic.cheight,
        sbase=base,
        vshift=ctx.chroma_vshift,
      )
    }
  }
  out
}

///|
fn h264_b_compensate(ctx : H264DecCtx, index : Int32) -> Result[Unit, String] {
  let info = ctx.infos[index]
  let mx = index % ctx.mb_width
  let my = index / ctx.mb_width
  let field = ctx.mb_field
  let parity = my & 1
  let ystride = h264_mb_ystride(ctx)
  let cstride = h264_mb_cstride(ctx)
  let ybase = h264_mb_ybase(ctx, mx, my)
  let cbase = h264_mb_cbase(ctx, mx, my)
  for gy in 0..<4 {
    for gx in 0..<4 {
      let block = gy * 4 + gx
      let r0 = info.ref_idx[block]
      let r1 = info.ref_idx1[block]
      let e0 = h264_ref_entry(ctx, r0, field, parity)
      let e1 = h264_ref_entry(ctx, r1, field, parity)
      if e0 >= ctx.ref_list0.length() ||
        e1 >= ctx.ref_list1.length() ||
        (r0 < 0 && r1 < 0) {
        return Err("invalid B prediction reference")
      }
      let a = if r0 >= 0 {
        h264_b_prediction(
          ctx,
          0,
          r0,
          mx,
          my,
          gx * 4,
          gy * 4,
          4,
          4,
          info.mv[2 * block],
          info.mv[2 * block + 1],
        )
      } else {
        []
      }
      let b = if r1 >= 0 {
        h264_b_prediction(
          ctx,
          1,
          r1,
          mx,
          my,
          gx * 4,
          gy * 4,
          4,
          4,
          info.mv1[2 * block],
          info.mv1[2 * block + 1],
        )
      } else {
        []
      }
      let explicit = ctx.pps.weighted_bipred_idc == 1
      let implicit = ctx.pps.weighted_bipred_idc == 2 && r0 >= 0 && r1 >= 0
      let mut implicit0 = 32
      if implicit {
        let cur_poc = if field {
          if parity == 0 {
            ctx.poc_top
          } else {
            ctx.poc_bottom
          }
        } else {
          ctx.poc
        }
        let p0 = ctx.ref_list0[e0].poc
        let p1 = ctx.ref_list1[e1].poc
        let td = (p1 - p0).max(-128).min(127)
        if td != 0 &&
          !ctx.long_pocs.contains(ctx.ref_list0[e0].identity) &&
          !ctx.long_pocs.contains(ctx.ref_list1[e1].identity) {
          let tb = (cur_poc - p0).max(-128).min(127)
          let tx = (16384 + (td.abs() >> 1)) / td
          let scale = (tb * tx + 32) >> 8
          if scale >= -64 && scale <= 128 {
            implicit0 = 64 - scale
          }
        }
      }
      for plane in 0..<3 {
        let chroma = plane > 0
        // Chroma block geometry per format: 4:2:0 2x2, 4:2:2 2x4, 4:4:4 4x4.
        let bw = if !chroma {
          4
        } else if ctx.chroma_format == 3 {
          4
        } else {
          2
        }
        let bh = if !chroma {
          4
        } else if ctx.chroma_format == 3 {
          4
        } else if ctx.chroma_format == 2 {
          4
        } else {
          2
        }
        let stride = if chroma { cstride } else { ystride }
        let local_stride = if chroma && ctx.chroma_format != 3 { 8 } else { 16 }
        let target = if plane == 0 {
          ctx.y
        } else if plane == 1 {
          ctx.u
        } else {
          ctx.v
        }
        let start = if chroma {
          cbase + gy * bh * cstride + gx * bw
        } else {
          ybase + gy * bh * ystride + gx * bw
        }
        let denom = if chroma {
          ctx.pwt.chroma_log2_weight_denom
        } else {
          ctx.pwt.luma_log2_weight_denom
        }
        let w0 = if r0 < 0 || !explicit {
          1
        } else if chroma {
          ctx.pwt.chroma_weight_l0[r0][plane - 1]
        } else {
          ctx.pwt.luma_weight_l0[r0]
        }
        let w1 = if r1 < 0 || !explicit {
          1
        } else if chroma {
          ctx.pwt.chroma_weight_l1[r1][plane - 1]
        } else {
          ctx.pwt.luma_weight_l1[r1]
        }
        let o0 = (if r0 < 0 || !explicit {
            0
          } else if chroma {
            ctx.pwt.chroma_offset_l0[r0][plane - 1]
          } else {
            ctx.pwt.luma_offset_l0[r0]
          }) <<
          (ctx.bit_depth - 8)
        let o1 = (if r1 < 0 || !explicit {
            0
          } else if chroma {
            ctx.pwt.chroma_offset_l1[r1][plane - 1]
          } else {
            ctx.pwt.luma_offset_l1[r1]
          }) <<
          (ctx.bit_depth - 8)
        for y in 0..<bh {
          for x in 0..<bw {
            let av = if r0 >= 0 { a[plane][y * local_stride + x] } else { 0 }
            let bv = if r1 >= 0 { b[plane][y * local_stride + x] } else { 0 }
            let value = if r0 >= 0 && r1 >= 0 {
              if explicit {
                ((av * w0 + bv * w1 + (1 << denom)) >> (denom + 1)) +
                ((o0 + o1 + 1) >> 1)
              } else if implicit {
                (implicit0 * av + (64 - implicit0) * bv + 32) >> 6
              } else {
                (av + bv + 1) >> 1
              }
            } else {
              let v = if r0 >= 0 { av } else { bv }
              let w = if r0 >= 0 { w0 } else { w1 }
              let o = if r0 >= 0 { o0 } else { o1 }
              if explicit {
                (
                  (v * w + (if denom > 0 { 1 << (denom - 1) } else { 0 })) >>
                  denom
                ) +
                o
              } else {
                v
              }
            }
            target[start + y * stride + x] = h264_clip8(
              value,
              bit_depth=ctx.bit_depth,
            )
          }
        }
      }
    }
  }
  Ok(())
}
