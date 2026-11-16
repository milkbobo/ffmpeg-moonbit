///|
/// I16 prediction and Hadamard DC/AC coding for three full-resolution planes.
fn H264PEncoder::code_bi16444_residuals(
  self : H264PEncoder,
  mx : Int32,
  my : Int32,
  eff : Int32,
  qp_user : Int32,
) -> H264PMbCode {
  let qp = self.p.qp_ext(qp_user)
  let qps = [
    qp,
    h264_get_chroma_qp(self.pps, 0, qp, bit_depth=self.p.bit_depth),
    h264_get_chroma_qp(self.pps, 1, qp, bit_depth=self.p.bit_depth),
  ]
  let levels_all = Array::make(768, 0)
  let dc_all = Array::make(48, 0)
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
    let stride = self.ystride
    let base = my * 16 * stride + mx * 16
    match
      h264_pred16x16(
        rec,
        base,
        stride,
        eff,
        my > 0,
        mx > 0,
        bit_depth=self.p.bit_depth,
      ) {
      Ok(_) => ()
      Err(e) => abort(e)
    }
    let qmul = h264_build_dequant4(self.pps, p, qps[p])
    let sums = Array::make(16, 0)
    for i in 0..<16 {
      let gx = h264_luma_block_x[i]
      let gy = h264_luma_block_y[i]
      let off = base + gy * 4 * stride + gx * 4
      let res = Array::make(16, 0)
      let mut sum = 0
      for row in 0..<4 {
        for col in 0..<4 {
          let d = src[off + row * stride + col] - rec[off + row * stride + col]
          res[row * 4 + col] = d
          sum += d
        }
      }
      sums[gy * 4 + gx] = sum
      let levels = h264_enc_fdct_quant_res(res, 0, qps[p])
      let mut count = 0
      for s in 1..<16 {
        let bo = 256 * p + 16 * i + s
        levels_all[bo] = levels[s]
        if levels[s] != 0 {
          count += 1
          mb[bo] = h264_enc_dequant_level(
            levels[s],
            qmul[s],
            bit_depth=self.p.bit_depth,
          )
        }
      }
      self.cur_nz[16 * p + gy * 4 + gx] = count
      if count > 0 {
        cbp = 15
      }
    }
    let dc = h264_enc_luma_dc_hadamard_quant(sums, 0, 4, dc_all, 16 * p, qps[p])
    h264_luma_dc_dequant_idct(
      mb,
      256 * p,
      dc,
      0,
      qmul[0],
      bit_depth=self.p.bit_depth,
    )
    for i in 0..<16 {
      let off = base +
        h264_luma_block_y[i] * 4 * stride +
        h264_luma_block_x[i] * 4
      h264_idct_add(
        rec,
        off,
        stride,
        mb,
        256 * p + 16 * i,
        bit_depth=self.p.bit_depth,
      )
    }
  }
  {
    luma_cbp: cbp,
    chroma_c_cbp: 0,
    luma_store: Array::make(256, 0),
    luma_dc_store: dc_all,
    chroma_dc_store: [Array::make(8, 0), Array::make(8, 0)],
    chroma_ac_store: [Array::make(128, 0), Array::make(128, 0)],
    dct8: false,
    luma8_store: Array::make(256, 0),
    planes_444: levels_all,
  }
}
