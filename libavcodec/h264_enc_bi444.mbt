///|
/// Three-plane I4 replay for B pictures; every plane shares signalled modes
/// and uses its own QP and intra dequantisation matrix.
fn H264PEncoder::code_bi444_residuals(
  self : H264PEncoder,
  mx : Int32,
  my : Int32,
  modes : Array[Int32],
  qp_user : Int32,
) -> H264PMbCode {
  let qp = self.p.qp_ext(qp_user)
  let qps = [
    qp,
    h264_get_chroma_qp(self.pps, 0, qp, bit_depth=self.p.bit_depth),
    h264_get_chroma_qp(self.pps, 1, qp, bit_depth=self.p.bit_depth),
  ]
  let levels_all = Array::make(768, 0)
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
    let store = Array::make(256, 0)
    match
      h264_enc_luma_i4_pass(
        src,
        rec,
        self.ystride,
        mx,
        my,
        self.pps,
        qps[p],
        store,
        Array::make(16, 0),
        Array::make(256, 0),
        h264_enc_i4_avail(mx, my, self.mb_width),
        fixed_modes=modes,
        bit_depth=self.p.bit_depth,
        matrix=p,
      ) {
      Ok((_, pattern)) => cbp = cbp | pattern
      Err(e) => abort(e)
    }
    for i in 0..<256 {
      levels_all[256 * p + i] = store[i]
    }
    for i in 0..<16 {
      let mut count = 0
      for s in 0..<16 {
        if store[16 * i + s] != 0 {
          count += 1
        }
      }
      self.cur_nz[16 * p + h264_luma_block_grid[i]] = count
    }
  }
  {
    luma_cbp: cbp,
    chroma_c_cbp: 0,
    luma_store: Array::make(256, 0),
    luma_dc_store: Array::make(16, 0),
    chroma_dc_store: [Array::make(8, 0), Array::make(8, 0)],
    chroma_ac_store: [Array::make(128, 0), Array::make(128, 0)],
    dct8: false,
    luma8_store: Array::make(256, 0),
    planes_444: levels_all,
  }
}
