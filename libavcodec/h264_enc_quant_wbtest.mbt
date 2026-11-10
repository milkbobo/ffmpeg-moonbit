// Whitebox amplitude gate for the encoder's transform + quantisation
// chains: a residual pushed through forward transform -> quantise -> the
// DECODER's dequantise + inverse transform must come back at its own
// amplitude, within the quantisation step. This is the test the encoder
// lacked from §376 to §386: its 4x4 forward "transform" was a Hadamard
// butterfly (odd outputs missing the factor-2 terms of the H.264 core
// transform) quantised with a step 4x too coarse (and 32x for chroma DC),
// so every residual was reconstructed at ~1/4 amplitude with a distorted
// shape. Streams stayed perfectly legal - the decoders faithfully decoded
// the wrong levels - so reconstruction invariants and external arbitration
// all passed; only an amplitude/quality measure can see a scale error.
//
// Every chain reconstructs on a mid-grey (128) plane so negative residuals
// are not clipped (a zero plane clips half the signal and fakes an error
// floor - the §385 probe made exactly that mistake).

///|
/// Largest tolerated per-sample error for one quantise/dequantise round
/// trip at `qp`: the nominal quantiser step `0.625 * 2^(qp/6)` rounded up
/// generously (several coefficients contribute to one sample).
fn h264_quant_gate_bound(qp : Int32) -> Int32 {
  2 + (1 << (qp / 6))
}

///|
/// 4x4 chain: `h264_enc_fdct_quant_res` -> `h264_enc_dequant_level` ->
/// `h264_idct_add`, returning the reconstructed residual.
fn h264_quant_gate_rt4(res : Array[Int32], qp : Int32) -> Array[Int32] {
  let pps = new_h264_pps()
  let qmul = h264_build_dequant4(pps, 0, qp)
  let levels = h264_enc_fdct_quant_res(res, 0, qp)
  let mb : Array[Int32] = Array::make(16, 0)
  for s = 0; s < 16; s = s + 1 {
    if levels[s] != 0 {
      mb[s] = h264_enc_dequant_level(levels[s], qmul[s])
    }
  }
  let plane : Array[Int32] = Array::make(16, 128)
  h264_idct_add(plane, 0, 4, mb, 0, bit_depth=8)
  let out : Array[Int32] = Array::make(16, 0)
  for i = 0; i < 16; i = i + 1 {
    out[i] = plane[i] - 128
  }
  out
}

///|
/// 8x8 chain: `h264_enc_fdct8_quant_res` -> dequant8 -> `h264_idct8_add`.
fn h264_quant_gate_rt8(res : Array[Int32], qp : Int32) -> Array[Int32] {
  let pps = new_h264_pps()
  let qmul8 = h264_build_dequant8(pps, 0, qp)
  let levels = h264_enc_fdct8_quant_res(res, 0, qp)
  let mb : Array[Int32] = Array::make(64, 0)
  for s = 0; s < 64; s = s + 1 {
    if levels[s] != 0 {
      mb[s] = h264_enc_dequant_level(levels[s], qmul8[s])
    }
  }
  let plane : Array[Int32] = Array::make(64, 128)
  h264_idct8_add(plane, 0, 8, mb, 0, bit_depth=8)
  let out : Array[Int32] = Array::make(64, 0)
  for i = 0; i < 64; i = i + 1 {
    out[i] = plane[i] - 128
  }
  out
}

///|
fn h264_quant_gate_check(
  name : String,
  qp : Int32,
  src : Array[Int32],
  got : Array[Int32],
  slack~ : Int32 = 1,
) -> Unit raise {
  let bound = h264_quant_gate_bound(qp) * slack
  for i = 0; i < src.length(); i = i + 1 {
    let d = src[i] - got[i]
    let ad = if d < 0 { -d } else { d }
    if ad > bound {
      fail(
        "\{name} qp \{qp} sample \{i}: source \{src[i]} reconstructed \{got[i]} (error \{ad} > bound \{bound})",
      )
    }
  }
}

///|
test "h264 enc: 4x4 transform/quant round trip keeps the residual amplitude" {
  for qp in [4, 5, 12, 13, 20, 21, 26, 27, 34, 35] {
    // Flat residuals (pure DC): the 4x attenuation bug returned c/4.
    for c in [40, -25, 7, 90] {
      let flat : Array[Int32] = Array::make(16, c)
      h264_quant_gate_check("flat4", qp, flat, h264_quant_gate_rt4(flat, qp))
    }
    // Horizontal / vertical / diagonal ramps: odd-symmetric content, the
    // shape the Hadamard-vs-core-transform mismatch distorted.
    let hramp : Array[Int32] = Array::make(16, 0)
    let vramp : Array[Int32] = Array::make(16, 0)
    let dramp : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        hramp[row * 4 + col] = col * 20 - 30
        vramp[row * 4 + col] = row * 14 - 21
        dramp[row * 4 + col] = (row + col) * 9 - 27
      }
    }
    h264_quant_gate_check(
      "hramp4",
      qp,
      hramp,
      h264_quant_gate_rt4(hramp, qp),
      slack=3,
    )
    h264_quant_gate_check(
      "vramp4",
      qp,
      vramp,
      h264_quant_gate_rt4(vramp, qp),
      slack=3,
    )
    h264_quant_gate_check(
      "dramp4",
      qp,
      dramp,
      h264_quant_gate_rt4(dramp, qp),
      slack=3,
    )
    let big : Array[Int32] = Array::make(16, 0)
    for row = 0; row < 4; row = row + 1 {
      for col = 0; col < 4; col = col + 1 {
        big[row * 4 + col] = col * 60 - 90
      }
    }
    h264_quant_gate_check(
      "bigramp4",
      qp,
      big,
      h264_quant_gate_rt4(big, qp),
      slack=3,
    )
    // A single impulse and a checkerboard: every basis function at once.
    let impulse : Array[Int32] = Array::make(16, 0)
    impulse[5] = 64
    h264_quant_gate_check(
      "impulse4",
      qp,
      impulse,
      h264_quant_gate_rt4(impulse, qp),
      slack=3,
    )
    let checker : Array[Int32] = Array::make(16, 0)
    for i = 0; i < 16; i = i + 1 {
      checker[i] = if (i % 4 + i / 4) % 2 == 0 { 30 } else { -30 }
    }
    h264_quant_gate_check(
      "checker4",
      qp,
      checker,
      h264_quant_gate_rt4(checker, qp),
      slack=3,
    )
  }
}

///|
test "h264 enc: 8x8 transform/quant round trip keeps the residual amplitude" {
  for qp in [4, 5, 12, 13, 20, 21, 26, 27, 34, 35] {
    for c in [40, -25, 7, 90] {
      let flat : Array[Int32] = Array::make(64, c)
      h264_quant_gate_check("flat8", qp, flat, h264_quant_gate_rt8(flat, qp))
    }
    let hramp : Array[Int32] = Array::make(64, 0)
    let vramp : Array[Int32] = Array::make(64, 0)
    let dramp : Array[Int32] = Array::make(64, 0)
    for row = 0; row < 8; row = row + 1 {
      for col = 0; col < 8; col = col + 1 {
        hramp[row * 8 + col] = col * 9 - 31
        vramp[row * 8 + col] = row * 7 - 24
        dramp[row * 8 + col] = (row + col) * 4 - 28
      }
    }
    h264_quant_gate_check(
      "hramp8",
      qp,
      hramp,
      h264_quant_gate_rt8(hramp, qp),
      slack=3,
    )
    h264_quant_gate_check(
      "vramp8",
      qp,
      vramp,
      h264_quant_gate_rt8(vramp, qp),
      slack=3,
    )
    h264_quant_gate_check(
      "dramp8",
      qp,
      dramp,
      h264_quant_gate_rt8(dramp, qp),
      slack=3,
    )
    let checker : Array[Int32] = Array::make(64, 0)
    for i = 0; i < 64; i = i + 1 {
      checker[i] = if (i % 8 / 2 + i / 8 / 2) % 2 == 0 { 30 } else { -30 }
    }
    h264_quant_gate_check(
      "checker8",
      qp,
      checker,
      h264_quant_gate_rt8(checker, qp),
      slack=3,
    )
  }
}

///|
/// The two DC side chains: the Intra16x16 luma DC Hadamard (decoder:
/// `h264_luma_dc_dequant_idct`, `>> 8`) and the chroma DC 2x2 Hadamard
/// (decoder: `h264_chroma_dc_dequant_idct`, `>> 7`). A flat residual `c`
/// over the whole macroblock makes every block sum `16 * c`.
test "h264 enc: luma/chroma DC Hadamard round trips keep the amplitude" {
  let pps = new_h264_pps()
  for qp in [4, 5, 12, 13, 20, 21, 26, 27, 34, 35] {
    let bound = h264_quant_gate_bound(qp)
    for c in [40, -25, 7, 90] {
      // Luma DC (Intra16x16).
      let qmul = h264_build_dequant4(pps, 0, qp)
      let sums : Array[Int32] = Array::make(16, 16 * c)
      let dc_store : Array[Int32] = Array::make(16, 0)
      ignore(h264_enc_luma_dc_hadamard_quant(sums, 0, 4, dc_store, 0, qp))
      let mb : Array[Int32] = Array::make(768, 0)
      let dc_raw : Array[Int32] = Array::make(16, 0)
      for s = 0; s < 16; s = s + 1 {
        dc_raw[s] = dc_store[s]
      }
      h264_luma_dc_dequant_idct(mb, 0, dc_raw, 0, qmul[0], bit_depth=8)
      let plane : Array[Int32] = Array::make(16, 128)
      h264_idct_dc_add(plane, 0, 4, mb, 0, bit_depth=8)
      let luma = plane[5] - 128
      let dl = if luma - c < 0 { c - luma } else { luma - c }
      if dl > bound {
        fail("luma DC qp \{qp}: flat \{c} reconstructed \{luma}")
      }
      // Chroma DC.
      let qmul_c = h264_build_dequant4(pps, 1, qp)
      let csums : Array[Int32] = Array::make(4, 16 * c)
      let cdc : Array[Int32] = Array::make(4, 0)
      ignore(h264_enc_chroma_dc_hadamard_quant(csums, cdc, 0, qp))
      let cmb : Array[Int32] = Array::make(768, 0)
      for s = 0; s < 4; s = s + 1 {
        cmb[256 + 16 * s] = cdc[s]
      }
      h264_chroma_dc_dequant_idct(cmb, 256, qmul_c[0], bit_depth=8)
      let cplane : Array[Int32] = Array::make(16, 128)
      h264_idct_dc_add(cplane, 0, 4, cmb, 256, bit_depth=8)
      let chroma = cplane[5] - 128
      let dc = if chroma - c < 0 { c - chroma } else { chroma - c }
      if dc > bound {
        fail("chroma DC qp \{qp}: flat \{c} reconstructed \{chroma}")
      }
    }
  }
}
