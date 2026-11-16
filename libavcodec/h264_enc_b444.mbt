///|
/// Quantise three full-resolution residual planes after B prediction.
fn H264PEncoder::code_b444_residuals(
  self : H264PEncoder,
  mx : Int32,
  my : Int32,
  qp_user : Int32,
  dct8_allowed~ : Bool = true,
) -> H264PMbCode {
  let dct8 = self.dct8x8 && dct8_allowed
  let qp = self.p.qp_ext(qp_user)
  let qps = [
    qp,
    h264_get_chroma_qp(self.pps, 0, qp, bit_depth=self.p.bit_depth),
    h264_get_chroma_qp(self.pps, 1, qp, bit_depth=self.p.bit_depth),
  ]
  let levels_all = Array::make(768, 0)
  let mb = Array::make(768, 0)
  let mut cbp = 0
  for p in 0..<3 {
    let src = if p == 0 {
      self.src_y
    } else if p == 1 {
      self.src_u
    } else {
      self.src_v
    }
    let rec = if p == 0 {
      self.rec_y
    } else if p == 1 {
      self.rec_u
    } else {
      self.rec_v
    }
    let stride = if p == 0 { self.ystride } else { self.cstride }
    if dct8 {
      let qmul = h264_build_dequant8(self.pps, 3 + p, qps[p])
      for g in 0..<16 {
        self.cur_nz[16 * p + g] = 0
      }
      for i8 in 0..<4 {
        let off = (my * 16 + i8 / 2 * 8) * stride + mx * 16 + i8 % 2 * 8
        let res = Array::make(64, 0)
        for row in 0..<8 {
          for col in 0..<8 {
            res[row * 8 + col] = src[off + row * stride + col] -
              rec[off + row * stride + col]
          }
        }
        let levels = h264_enc_fdct8_quant_res(res, 0, qps[p])
        let bo = 256 * p + 64 * i8
        let mut total = 0
        for s in 0..<64 {
          levels_all[bo + s] = levels[s]
          if levels[s] != 0 {
            total += 1
            mb[bo + s] = h264_enc_dequant_level(
              levels[s],
              qmul[s],
              bit_depth=self.p.bit_depth,
            )
          }
        }
        if total > 0 {
          cbp = cbp | (1 << i8)
          if total == 1 && mb[bo] != 0 {
            h264_idct8_dc_add(
              rec,
              off,
              stride,
              mb,
              bo,
              bit_depth=self.p.bit_depth,
            )
          } else {
            h264_idct8_add(rec, off, stride, mb, bo, bit_depth=self.p.bit_depth)
          }
        }
      }
      continue
    }
    let qmul = h264_build_dequant4(self.pps, 3 + p, qps[p])
    for i in 0..<16 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = (my * 16 + gy * 4) * stride + mx * 16 + gx * 4
      let res = Array::make(16, 0)
      for row in 0..<4 {
        for col in 0..<4 {
          res[row * 4 + col] = src[off + row * stride + col] -
            rec[off + row * stride + col]
        }
      }
      let levels = h264_enc_fdct_quant_res(res, 0, qps[p])
      let bo = 256 * p + 16 * i
      let mut total = 0
      for s in 0..<16 {
        levels_all[bo + s] = levels[s]
        if levels[s] != 0 {
          total += 1
          mb[bo + s] = h264_enc_dequant_level(
            levels[s],
            qmul[s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
      self.cur_nz[16 * p + gy * 4 + gx] = total
      if total > 0 {
        cbp = cbp | (1 << (i / 4))
        h264_idct_add(rec, off, stride, mb, bo, bit_depth=self.p.bit_depth)
      }
    }
  }
  {
    luma_cbp: cbp,
    chroma_c_cbp: 0,
    luma_store: Array::make(256, 0),
    luma_dc_store: Array::make(16, 0),
    chroma_dc_store: [Array::make(8, 0), Array::make(8, 0)],
    chroma_ac_store: [Array::make(128, 0), Array::make(128, 0)],
    dct8,
    luma8_store: Array::make(256, 0),
    planes_444: levels_all,
  }
}

///|
/// Mirrors the B decoder: every explicit subpartition must be at least
/// 8x8, and direct groups require direct_8x8_inference_flag.
fn h264_b_transform8_allowed(plan : H264BPlan, direct8 : Bool) -> Bool {
  match plan {
    BParts(kind, subs, _, _) => {
      let (_, parts, direct, _) = h264_b_partitions(kind, subs)
      parts.all(p => p.w >= 2 && p.h >= 2) && (direct8 || !direct.any(v => v))
    }
    BDirect16 => direct8
    BL0x16(_, _, _) | BL1x16(_, _) | BBi16(_, _, _, _, _) => true
    _ => false
  }
}
