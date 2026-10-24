///|
/// `dav1d_recon_b_intra` (8-bit, single thread): prediction + coefficient
/// decode + inverse transform for one intra block.
fn Av1TileCtx::recon_b_intra(
  self : Av1TileCtx,
  bs : Int32,
  intra_edge_flags : Int32,
  b : Av1IntraBlock,
) -> Unit {
  let f = self.f
  let ss_ver = f.ss_v
  let ss_hor = f.ss_h
  let bx4 = self.bx & 31
  let by4 = self.by & 31
  let cbx4 = bx4 >> ss_hor
  let cby4 = by4 >> ss_ver
  let bw4 = av1_bdim(bs, 0)
  let bh4 = av1_bdim(bs, 1)
  let cbw4 = (bw4 + ss_hor) >> ss_hor
  let cbh4 = (bh4 + ss_ver) >> ss_ver
  let w4 = av1_imin(bw4, f.bw - self.bx)
  let h4 = av1_imin(bh4, f.bh - self.by)
  let cw4 = (w4 + ss_hor) >> ss_hor
  let ch4 = (h4 + ss_ver) >> ss_ver
  let has_chroma = (bw4 > ss_hor || (self.bx & 1) != 0) &&
    (bh4 > ss_ver || (self.by & 1) != 0)
  let t_dim_w = av1_txfm_w(b.tx)
  let t_dim_h = av1_txfm_h(b.tx)
  let uv_t_dim_w = av1_txfm_w(b.uvtx)
  let uv_t_dim_h = av1_txfm_h(b.uvtx)
  let y_plane = f.planes[0]
  let u_plane = f.planes[1]
  let v_plane = f.planes[2]
  let y_stride = f.y_stride
  let uv_stride = f.uv_stride
  let edge_buf = self.edge_buf
  let topleft = 128 + 64
  let a = f.a[self.a_idx]
  let l = f.l
  let intra_edge_filter_flag = if f.seq.enable_intra_edge_filter {
    1 << 10
  } else {
    0
  }
  let mut init_y = 0
  while init_y < h4 {
    let sub_h4 = av1_imin(h4, 16 + init_y)
    let sub_ch4 = av1_imin(ch4, (init_y + 16) >> ss_ver)
    let mut init_x = 0
    while init_x < w4 {
      // luma palette prediction
      if b.pal_sz.0 != 0 {
        let dst_off = 4 * (self.by * y_stride + self.bx)
        av1_pal_pred(
          y_plane,
          dst_off,
          y_stride,
          self.pal,
          0,
          self.pal_idx_y,
          0,
          bw4 * 4,
          bh4 * 4,
        )
      }
      let intra_flags = av1_sm_flag(a, bx4) |
        av1_sm_flag(l, by4) |
        intra_edge_filter_flag
      let sb_has_tr = if init_x + 16 < w4 {
        true
      } else if init_y != 0 {
        false
      } else {
        (intra_edge_flags & av1_edge_i444_top_has_right) != 0
      }
      let sb_has_bl = if init_x != 0 {
        false
      } else if init_y + 16 < h4 {
        true
      } else {
        (intra_edge_flags & av1_edge_i444_left_has_bottom) != 0
      }
      let sub_w4 = av1_imin(w4, init_x + 16)
      let mut y = init_y
      self.by = self.by + init_y
      while y < sub_h4 {
        let mut dst_off = 4 * (self.by * y_stride + self.bx + init_x)
        let mut x = init_x
        self.bx = self.bx + init_x
        while x < sub_w4 {
          let skip_y_pred = b.pal_sz.0 != 0
          if !skip_y_pred {
            let mut angle = b.y_angle
            let edge_flags = (if (y > init_y || !sb_has_tr) &&
                x + t_dim_w >= sub_w4 {
                0
              } else {
                av1_edge_i444_top_has_right
              }) |
              (if x > init_x || (!sb_has_bl && y + t_dim_h >= sub_h4) {
                0
              } else {
                av1_edge_i444_left_has_bottom
              })
            let use_top_sb_edge = (self.by & (f.sb_step - 1)) == 0
            let (sb_plane, sb_off) = if use_top_sb_edge {
              let sby = self.by >> f.sb_shift
              (Some(f.ipred_edge[0]), f.sb128w * 128 * (sby - 1))
            } else {
              (None, 0)
            }
            let angle_ref = Ref(angle)
            let m = av1_prepare_intra_edges(
              self.bx,
              self.bx > self.col_start,
              self.by,
              self.by > self.row_start,
              self.col_end,
              self.row_end,
              edge_flags,
              y_plane,
              dst_off,
              y_stride,
              sb_plane,
              sb_off,
              b.y_mode,
              angle_ref,
              t_dim_w,
              t_dim_h,
              if f.seq.enable_intra_edge_filter {
                1
              } else {
                0
              },
              edge_buf,
              topleft,
            )
            angle = angle_ref.val
            av1_ipred_predict(
              m,
              y_plane,
              dst_off,
              y_stride,
              edge_buf,
              topleft,
              t_dim_w * 4,
              t_dim_h * 4,
              angle | intra_flags,
              4 * f.bw - 4 * self.bx,
              4 * f.bh - 4 * self.by,
            )
          }
          if !b.skip {
            let (eob, txtp, cf_ctx) = self.decode_coefs(
              a.lcoef,
              bx4 + x,
              l.lcoef,
              by4 + y,
              b.tx,
              bs,
              b,
              true,
              0,
              self.cf,
            )
            let nw = av1_imin(t_dim_w, f.bw - self.bx)
            let nh = av1_imin(t_dim_h, f.bh - self.by)
            for i in 0..<nw {
              a.lcoef[bx4 + x + i] = cf_ctx
            }
            for i in 0..<nh {
              l.lcoef[by4 + y + i] = cf_ctx
            }
            if eob >= 0 {
              av1_itxfm_add(
                y_plane,
                dst_off,
                y_stride,
                self.cf,
                eob,
                b.tx,
                txtp,
              )
            }
          } else {
            let nw = t_dim_w
            let nh = t_dim_h
            for i in 0..<nw {
              a.lcoef[bx4 + x + i] = 0x40
            }
            for i in 0..<nh {
              l.lcoef[by4 + y + i] = 0x40
            }
          }
          dst_off = dst_off + 4 * t_dim_w
          x = x + t_dim_w
          self.bx = self.bx + t_dim_w
        }
        self.bx = self.bx - x
        y = y + t_dim_h
        self.by = self.by + t_dim_h
      }
      self.by = self.by - y
      if has_chroma {
        // CFL / palette chroma prediction
        if b.uv_mode == av1_cfl_pred {
          let ac = self.ac
          let y_src_off = 4 * (self.bx & (-1 - ss_hor)) +
            4 * (self.by & (-1 - ss_ver)) * y_stride
          let uv_off = 4 *
            ((self.bx >> ss_hor) + (self.by >> ss_ver) * uv_stride)
          let furthest_r = ((cw4 << ss_hor) + t_dim_w - 1) & -t_dim_w
          let furthest_b = ((ch4 << ss_ver) + t_dim_h - 1) & -t_dim_h
          av1_cfl_ac(
            ac,
            y_plane,
            y_src_off,
            y_stride,
            cbw4 - (furthest_r >> ss_hor),
            cbh4 - (furthest_b >> ss_ver),
            cbw4 * 4,
            cbh4 * 4,
            ss_hor,
            ss_ver,
          )
          for pl in 0..<2 {
            let alpha = if pl == 0 { b.cfl_alpha.0 } else { b.cfl_alpha.1 }
            if alpha == 0 {
              continue
            }
            let angle = 0
            let plane = if pl == 0 { u_plane } else { v_plane }
            let use_top_sb_edge = (self.by & (-1 - ss_ver) & (f.sb_step - 1)) ==
              0
            let (sb_plane, sb_off) = if use_top_sb_edge {
              let sby = self.by >> f.sb_shift
              (Some(f.ipred_edge[pl + 1]), f.sb128w * 128 * (sby - 1))
            } else {
              (None, 0)
            }
            let xpos = self.bx >> ss_hor
            let ypos = self.by >> ss_ver
            let xstart = self.col_start >> ss_hor
            let ystart = self.row_start >> ss_ver
            let m = av1_prepare_intra_edges(
              xpos,
              xpos > xstart,
              ypos,
              ypos > ystart,
              self.col_end >> ss_hor,
              self.row_end >> ss_ver,
              0,
              plane,
              uv_off,
              uv_stride,
              sb_plane,
              sb_off,
              av1_dc_pred,
              Ref(angle),
              uv_t_dim_w,
              uv_t_dim_h,
              0,
              edge_buf,
              topleft,
            )
            // cfl_pred uses DC-family predictors with the AC array
            av1_cfl_predict(
              plane,
              uv_off,
              uv_stride,
              uv_t_dim_w * 4,
              uv_t_dim_h * 4,
              av1_cfl_dc(m, edge_buf, topleft, uv_t_dim_w * 4, uv_t_dim_h * 4),
              ac,
              alpha,
            )
          }
        } else if b.pal_sz.1 != 0 {
          let uv_dstoff = 4 *
            ((self.bx >> ss_hor) + (self.by >> ss_ver) * uv_stride)
          av1_pal_pred(
            u_plane,
            uv_dstoff,
            uv_stride,
            self.pal,
            8,
            self.pal_idx_uv,
            0,
            cbw4 * 4,
            cbh4 * 4,
          )
          av1_pal_pred(
            v_plane,
            uv_dstoff,
            uv_stride,
            self.pal,
            16,
            self.pal_idx_uv,
            0,
            cbw4 * 4,
            cbh4 * 4,
          )
        }
        let sm_uv_fl = av1_sm_uv_flag(a, cbx4) | av1_sm_uv_flag(l, cby4)
        let uv_sb_has_tr = if (init_x + 16) >> ss_hor < cw4 {
          true
        } else if init_y != 0 {
          false
        } else {
          (intra_edge_flags &
            (av1_edge_i444_top_has_right << (ss_hor + ss_ver))) != 0
        }
        let uv_sb_has_bl = if init_x != 0 {
          false
        } else if (init_y + 16) >> ss_ver < ch4 {
          true
        } else {
          (intra_edge_flags &
            (av1_edge_i444_left_has_bottom << (ss_hor + ss_ver))) != 0
        }
        let sub_cw4 = av1_imin(cw4, (init_x + 16) >> ss_hor)
        for pl in 0..<2 {
          let plane = if pl == 0 { u_plane } else { v_plane }
          let mut y = init_y >> ss_ver
          self.by = self.by + init_y
          while y < sub_ch4 {
            let mut dst_off = 4 *
              ((self.by >> ss_ver) * uv_stride + ((self.bx + init_x) >> ss_hor))
            let mut x = init_x >> ss_hor
            self.bx = self.bx + init_x
            while x < sub_cw4 {
              let skip_uv = (
                  b.uv_mode == av1_cfl_pred &&
                  (if pl == 0 { b.cfl_alpha.0 } else { b.cfl_alpha.1 }) != 0
                ) ||
                b.pal_sz.1 != 0
              if !skip_uv {
                let mut angle = b.uv_angle
                let edge_flags = (if (y > init_y >> ss_ver || !uv_sb_has_tr) &&
                    x + uv_t_dim_w >= sub_cw4 {
                    0
                  } else {
                    av1_edge_i444_top_has_right
                  }) |
                  (if x > init_x >> ss_hor ||
                    (!uv_sb_has_bl && y + uv_t_dim_h >= sub_ch4) {
                    0
                  } else {
                    av1_edge_i444_left_has_bottom
                  })
                let use_top_sb_edge = (
                    self.by & (-1 - ss_ver) & (f.sb_step - 1)
                  ) ==
                  0
                let (sb_plane, sb_off) = if use_top_sb_edge {
                  let sby = self.by >> f.sb_shift
                  (Some(f.ipred_edge[pl + 1]), f.sb128w * 128 * (sby - 1))
                } else {
                  (None, 0)
                }
                let uv_mode = if b.uv_mode == av1_cfl_pred {
                  av1_dc_pred
                } else {
                  b.uv_mode
                }
                let xpos = self.bx >> ss_hor
                let ypos = self.by >> ss_ver
                let xstart = self.col_start >> ss_hor
                let ystart = self.row_start >> ss_ver
                let angle_ref = Ref(angle)
                let m = av1_prepare_intra_edges(
                  xpos,
                  xpos > xstart,
                  ypos,
                  ypos > ystart,
                  self.col_end >> ss_hor,
                  self.row_end >> ss_ver,
                  edge_flags,
                  plane,
                  dst_off,
                  uv_stride,
                  sb_plane,
                  sb_off,
                  uv_mode,
                  angle_ref,
                  uv_t_dim_w,
                  uv_t_dim_h,
                  if f.seq.enable_intra_edge_filter {
                    1
                  } else {
                    0
                  },
                  edge_buf,
                  topleft,
                )
                angle = angle_ref.val
                angle = angle | intra_edge_filter_flag
                av1_ipred_predict(
                  m,
                  plane,
                  dst_off,
                  uv_stride,
                  edge_buf,
                  topleft,
                  uv_t_dim_w * 4,
                  uv_t_dim_h * 4,
                  angle | sm_uv_fl,
                  (4 * f.bw + ss_hor - 4 * (self.bx & (-1 - ss_hor))) >> ss_hor,
                  (4 * f.bh + ss_ver - 4 * (self.by & (-1 - ss_ver))) >> ss_ver,
                )
              }
              if !b.skip {
                let ccoef = a.ccoef
                let ccoef_base = pl * 32
                let l_ccoef = l.ccoef
                let l_ccoef_base = pl * 32
                let (eob, txtp, cf_ctx) = self.decode_coefs(
                  ccoef,
                  ccoef_base + cbx4 + x,
                  l_ccoef,
                  l_ccoef_base + cby4 + y,
                  b.uvtx,
                  bs,
                  b,
                  true,
                  1 + pl,
                  self.cf,
                )
                let ctw = av1_imin(
                  uv_t_dim_w,
                  (f.bw - self.bx + ss_hor) >> ss_hor,
                )
                let cth = av1_imin(
                  uv_t_dim_h,
                  (f.bh - self.by + ss_ver) >> ss_ver,
                )
                for i in 0..<ctw {
                  ccoef[ccoef_base + cbx4 + x + i] = cf_ctx
                }
                for i in 0..<cth {
                  l_ccoef[l_ccoef_base + cby4 + y + i] = cf_ctx
                }
                if eob >= 0 {
                  av1_itxfm_add(
                    plane,
                    dst_off,
                    uv_stride,
                    self.cf,
                    eob,
                    b.uvtx,
                    txtp,
                  )
                }
              } else {
                let ccoef = a.ccoef
                let ccoef_base = pl * 32
                let l_ccoef = l.ccoef
                let l_ccoef_base = pl * 32
                for i in 0..<uv_t_dim_w {
                  ccoef[ccoef_base + cbx4 + x + i] = 0x40
                }
                for i in 0..<uv_t_dim_h {
                  l_ccoef[l_ccoef_base + cby4 + y + i] = 0x40
                }
              }
              dst_off = dst_off + 4 * uv_t_dim_w
              x = x + uv_t_dim_w
              self.bx = self.bx + (uv_t_dim_w << ss_hor)
            }
            self.bx = self.bx - (x << ss_hor)
            y = y + uv_t_dim_h
            self.by = self.by + (uv_t_dim_h << ss_ver)
          }
          self.by = self.by - (y << ss_ver)
        }
      }
      init_x = init_x + 16
    }
    init_y = init_y + 16
  }
}
