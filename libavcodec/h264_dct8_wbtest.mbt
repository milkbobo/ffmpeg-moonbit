// Whitebox probe for the High-profile 8x8 forward transform + quantisation
// (`h264_enc_fdct8_quant_res` / `h264_enc_mf8`): the quantise/dequantise
// pair must reproduce a residual at the SAME error scale as the validated
// 4x4 chain (`h264_enc_fdct_quant_res` + `h264_build_dequant4` + idct4) on
// identical data. A mis-scaled MF8 table (e.g. every factor off by 2x)
// would come out as a reconstruction error an order of magnitude apart.

///|
/// Deterministic LCG residual block, values roughly ±90.
fn h264_dct8_probe_block(seed : Int32) -> Array[Int32] {
  let res : Array[Int32] = Array::make(64, 0)
  let mut s : Int64 = seed.to_int64()
  for i = 0; i < 64; i = i + 1 {
    s = (s * 6364136223846793005L + 1442695040888963407L) & 0x7FFFFFFFL
    res[i] = (s % 181L - 90L).to_int()
  }
  res
}

///|
test "h264 enc: fdct8/quant8 reconstruction error parity with 4x4 chain" {
  let pps = new_h264_pps()
  for qp in [10, 22, 34, 46] {
    let qmul4 = h264_build_dequant4(pps, 0, qp)
    let qmul8 = h264_build_dequant8(pps, 0, qp)
    for blk = 0; blk < 4; blk = blk + 1 {
      let res = h264_dct8_probe_block(1000 + 97 * blk + 31 * qp)
      // 8x8 chain: quant, dequant into the decoder's coefficient layout,
      // reconstruct on a zeroed plane.
      let levels8 = h264_enc_fdct8_quant_res(res, 0, qp)
      let mb8 : Array[Int32] = Array::make(64, 0)
      let mut nz8 = 0
      for s = 0; s < 64; s = s + 1 {
        if levels8[s] != 0 {
          nz8 = nz8 + 1
          mb8[s] = h264_enc_dequant_level(levels8[s], qmul8[s])
        }
      }
      let plane8 : Array[Int32] = Array::make(8 * 16, 0)
      if nz8 == 1 && mb8[0] != 0 {
        h264_idct8_dc_add(plane8, 0, 16, mb8, 0, bit_depth=8)
      } else if nz8 != 0 {
        h264_idct8_add(plane8, 0, 16, mb8, 0, bit_depth=8)
      }
      let mut err8 = 0
      let mut energy = 0
      for row = 0; row < 8; row = row + 1 {
        for col = 0; col < 8; col = col + 1 {
          let d = res[row * 8 + col] - plane8[row * 16 + col]
          err8 = err8 + (if d < 0 { -d } else { d })
          let a = if res[row * 8 + col] < 0 {
            -res[row * 8 + col]
          } else {
            res[row * 8 + col]
          }
          energy = energy + a
        }
      }
      // 4x4 chain over the four sub-blocks.
      let plane4 : Array[Int32] = Array::make(8 * 16, 0)
      let mb4 : Array[Int32] = Array::make(256, 0)
      for i = 0; i < 4; i = i + 1 {
        let bx = i % 2 * 4
        let by = i / 2 * 4
        let sub : Array[Int32] = Array::make(16, 0)
        for row = 0; row < 4; row = row + 1 {
          for col = 0; col < 4; col = col + 1 {
            sub[row * 4 + col] = res[(by + row) * 8 + bx + col]
          }
        }
        let levels = h264_enc_fdct_quant_res(sub, 0, qp)
        let mut total = 0
        for s = 0; s < 16; s = s + 1 {
          if levels[s] != 0 {
            total = total + 1
            mb4[16 * i + s] = h264_enc_dequant_level(levels[s], qmul4[s])
          }
        }
        let off = by * 16 + bx
        if total == 1 && mb4[16 * i] != 0 {
          h264_idct_dc_add(plane4, off, 16, mb4, 16 * i, bit_depth=8)
        } else if total != 0 {
          h264_idct_add(plane4, off, 16, mb4, 16 * i, bit_depth=8)
        }
      }
      let mut err4 = 0
      for row = 0; row < 8; row = row + 1 {
        for col = 0; col < 8; col = col + 1 {
          let d = res[row * 8 + col] - plane4[row * 16 + col]
          err4 = err4 + (if d < 0 { -d } else { d })
        }
      }
      if err8 == 0 || err4 == 0 {
        fail("qp \{qp} blk \{blk}: zero reconstruction error is bogus")
      }
      // Same magnitude band as the 4x4 chain (allowing the 8x8 transform
      // its genuine compactness edge): a scale bug is an order of magnitude.
      if err8 > err4 * 3 {
        fail(
          "qp \{qp} blk \{blk}: 8x8 error \{err8} >> 4x4 error \{err4} (MF8 scale?)",
        )
      }
      if err8 * 6 < err4 {
        fail(
          "qp \{qp} blk \{blk}: 8x8 error \{err8} << 4x4 error \{err4} (over-fine quant, scale?)",
        )
      }
      ignore(energy)
    }
  }
}

///|
/// A smooth diagonal ramp must survive quantisation: the 8x8 transform
/// concentrates it into a few low-frequency coefficients. Gate against the
/// validated 4x4 chain on the same ramp (four sub-block quantise/dequantise
/// round trips) - the 8x8 reconstruction must track the source at least as
/// well, since it owns the whole ramp shape in one transform. Catches a
/// mis-scaled MF8 that destroys low frequencies.
test "h264 enc: fdct8 keeps low-frequency residuals at fine qp" {
  let pps = new_h264_pps()
  let qp = 10
  let qmul8 = h264_build_dequant8(pps, 0, qp)
  let qmul4 = h264_build_dequant4(pps, 0, qp)
  let res : Array[Int32] = Array::make(64, 0)
  for row = 0; row < 8; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      res[row * 8 + col] = (row + col) * 4 - 28 // -28..+28 ramp
    }
  }
  // 8x8 chain.
  let levels8 = h264_enc_fdct8_quant_res(res, 0, qp)
  let mb8 : Array[Int32] = Array::make(64, 0)
  for s = 0; s < 64; s = s + 1 {
    if levels8[s] != 0 {
      mb8[s] = h264_enc_dequant_level(levels8[s], qmul8[s])
    }
  }
  let plane8 : Array[Int32] = Array::make(8 * 16, 0)
  h264_idct8_add(plane8, 0, 16, mb8, 0, bit_depth=8)
  // 4x4 chain over the four sub-blocks.
  let plane4 : Array[Int32] = Array::make(8 * 16, 0)
  let mb4 : Array[Int32] = Array::make(64, 0)
  for i = 0; i < 4; i = i + 1 {
    let bx = i % 2 * 4
    let by = i / 2 * 4
    let sub : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        sub[row * 4 + col] = res[(by + row) * 8 + bx + col]
      }
    }
    let levels = h264_enc_fdct_quant_res(sub, 0, qp)
    for s = 0; s < 16; s = s + 1 {
      if levels[s] != 0 {
        mb4[16 * i + s] = h264_enc_dequant_level(levels[s], qmul4[s])
      }
    }
  }
  for i = 0; i < 4; i = i + 1 {
    let bx = i % 2 * 4
    let by = i / 2 * 4
    h264_idct_add(plane4, by * 16 + bx, 16, mb4, 16 * i, bit_depth=8)
  }
  let mut err8 = 0
  let mut err4 = 0
  for row = 0; row < 8; row = row + 1 {
    for col = 0; col < 8; col = col + 1 {
      let d8 = res[row * 8 + col] - plane8[row * 16 + col]
      err8 = err8 + d8 * d8
      let d4 = res[row * 8 + col] - plane4[row * 16 + col]
      err4 = err4 + d4 * d4
    }
  }
  // The 8x8 chain must be at least as good as the validated 4x4 chain on
  // the same ramp (one transform owning the whole shape vs four sub-blocks).
  if err8 > err4 {
    fail("ramp SSD: 8x8 \{err8} worse than 4x4 \{err4} (transform scale?)")
  }
}
