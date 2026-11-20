///|
/// §449a pseudo-inverse forward transform for DCT_DCT TX_32X32. The
/// encoder has no AV1 forward transform; instead it measures the
/// decoder's own inverse kernel: the 2-D itx basis vector f_p (the
/// pixel delta of a unit coefficient at scan position p) is probed by
/// running `av1_itxfm_add` once per position. The basis is orthogonal
/// (±1 rounding), so any residual R decomposes as C_p = <R, f_p> /
/// ||f_p||² — and quantizing C against the decoder's dequant formula
/// ((tbl·t) >> dq_shift) yields tokens whose reconstruction the encoder
/// can predict exactly by running the same kernel on the dequantized
/// coefficients. Cost model = reconstruction model, by construction.

///|
/// The measured itx basis for one transform size: `basis[p * n + i]`
/// is the pixel delta of a unit coefficient at scan position p scaled
/// by `probe_scale` on pixel i (raster), `g[p]` its squared norm, `n`
/// the coefficient/pixel count. The probe runs at a large coefficient
/// so the kernels sit in their linear regime (unit probes collapse
/// into the output rounding and lose the basis shape); the scale
/// cancels in c_p = dot*S/g.
priv struct Av1EncItxBasis {
  tx : Int32
  n : Int32
  g : FixedArray[Int64]
  basis : FixedArray[Int32]
  probe_scale : Int32
}

///|
/// Probe scale: large enough that the itx's final (x + 8) >> 4 output
/// rounding (absolute +-0.5 pixel) is a small relative error on the
/// measured basis (entries ~16), small enough to keep every
/// intermediate inside the 8-bit row/col clip tables (max ~12k < 32k).
let av1_enc_itx_probe_scale : Int32 = 16384

///|
/// Probe the decoder's itx kernel: one 2-D transform per scan position
/// with a single scaled coefficient (eob = p; the dc probe uses eob = 1
/// so the dc runs through the full path like every eob > 0 frame).
fn av1_enc_itx_basis(tx : Int32) -> Av1EncItxBasis {
  let lw = av1_txfm_lw(tx)
  let lh = av1_txfm_lh(tx)
  let pw = 4 << lw
  let ph = 4 << lh
  let n = pw * ph
  let s = av1_enc_itx_probe_scale
  let basis : FixedArray[Int32] = FixedArray::make(n * n, 0)
  let g : FixedArray[Int64] = FixedArray::make(n, 0L)
  for p in 0..<n {
    let coeff : FixedArray[Int32] = FixedArray::make(n, 0)
    let pos = if p == 0 { 0 } else { av1_scan(tx, p) }
    coeff[pos] = s
    let eob = if p == 0 { 1 } else { p }
    let dst : FixedArray[Int32] = FixedArray::make(n, 0)
    // bd_max must be a legal bit-depth ceiling: the clip tables are
    // derived as (bd_max + 1) << 7 / << 5 and overflow Int32 for
    // arbitrary large values, silently clamping the whole transform.
    av1_itxfm_add(dst, 0, pw, coeff, eob, tx, 0, 4095)
    let mut acc : Int64 = 0L
    let base = p * n
    for i in 0..<n {
      let v = dst[i]
      basis[base + i] = v
      acc += v.to_int64() * v.to_int64()
    }
    g[p] = acc
  }
  { tx, n, g, basis, probe_scale: s, }
}

///|
/// The TX_32X32 basis (the inter/leaf-32 workhorse).
fn av1_enc_itx_basis32() -> Av1EncItxBasis {
  av1_enc_itx_basis(3)
}

///|
/// Quantize one 32x32 residual leaf into the §443 token spec. `res` is
/// the residual in raster order (`res_stride` between rows). Fills
/// `toks`/`signs` (1024 scan-order slots) and returns `(eob, cul)`:
/// eob is the last nonzero scan position (−1 when the leaf quantizes to
/// all-zero → all_skip), cul the level sum for the coefficient-context
/// mirror. `dc_tbl`/`ac_tbl` are the frame's dequant table entries
/// (ydc/yac), `dq_shift` the tx's dequant shift, `dz_pm` the deadzone
/// in per-mille of the quantization step (0 = round half up — every
/// coefficient at or past half a step survives; 500 = floor — a
/// coefficient must reach a full step). Raising the deadzone trades
/// distortion for rate: more coefficients zero out, so fewer tokens
/// and cheaper contexts downstream.
fn av1_enc_quantize_leaf(
  res : FixedArray[Int32],
  res_stride : Int32,
  basis : Av1EncItxBasis,
  dc_tbl : Int32,
  ac_tbl : Int32,
  dq_shift : Int32,
  toks : FixedArray[Int32],
  signs : FixedArray[Int32],
  dz_pm~ : Int32 = 0,
) -> (Int32, Int32) {
  let n = basis.n
  let pw = 4 << av1_txfm_lw(basis.tx)
  let ph = 4 << av1_txfm_lh(basis.tx)
  for i in 0..<n {
    toks[i] = 0
    signs[i] = 0
  }
  let scale = 1 << dq_shift
  // One pass over the basis: dot_p = <R, f_p>. The basis is stored
  // scan-position-major, so accumulate per position.
  let mut eob = -1
  let mut cul = 0
  for p in 0..<n {
    let g = basis.g[p]
    if g == 0L {
      continue
    }
    let base = p * n
    let mut dot : Int64 = 0L
    for y in 0..<ph {
      let rrow = y * res_stride
      let brow = base + y * pw
      for x in 0..<pw {
        let r = res[rrow + x]
        if r != 0 {
          dot += r.to_int64() * basis.basis[brow + x].to_int64()
        }
      }
    }
    // C_p = dot * probe_scale / g (the probe scale cancels the
    // measurement's coefficient scaling); the token t then satisfies
    // dequant(t) = (tbl * t) >> dq_shift ~ C_p, i.e. t = C_p * scale /
    // tbl. The deadzone raises the rounding threshold by dz_pm/1000 of
    // a step: t = (2*mag*scale + gt - (2*dz_pm*gt)/1000) / (2*gt) —
    // dz 0 is round-half-up, 500 is floor. The dz term is divided out
    // on its own so the products stay inside the Int64 envelope of the
    // dz-0 formula.
    let mut mag = if dot < 0L { -dot } else { dot }
    let neg = dot < 0L
    mag = mag * basis.probe_scale.to_int64()
    // Golomb dequant wraps at 24 bits: (tbl * t) must stay < 2^24.
    let tbl = if p == 0 { dc_tbl } else { ac_tbl }
    let gt = g * tbl.to_int64()
    let dz_term = 2L * dz_pm.to_int64() * gt / 1000L
    let num = mag * scale.to_int64() * 2L + gt - dz_term
    let den = gt * 2L
    let mut t = (num / den).to_int()
    let t_max = 16777215 / (if tbl > 0 { tbl } else { 1 })
    if t > t_max {
      t = t_max
    }
    if t <= 0 {
      continue
    }
    toks[p] = t
    signs[p] = if neg { 1 } else { 0 }
    cul += t
    eob = p
  }
  (eob, cul)
}

///|
/// Dequantize one leaf's token spec back to coefficients and add the
/// decoder's itx on top of `dst` (in place) — the exact reconstruction
/// the decoder will realize for this leaf. Returns the leaf's eob
/// (−1 when the spec is all-zero; nothing is added).
fn av1_enc_recon_leaf(
  dst : FixedArray[Int32],
  dst_off : Int32,
  dst_stride : Int32,
  toks : FixedArray[Int32],
  signs : FixedArray[Int32],
  tx : Int32,
  dc_tbl : Int32,
  ac_tbl : Int32,
  dq_shift : Int32,
) -> Int32 {
  let n = (4 << av1_txfm_lw(tx)) * (4 << av1_txfm_lh(tx))
  let coeff : FixedArray[Int32] = FixedArray::make(n, 0)
  // cf_max mirrors decode_coefs (8-bit: (1 << 15) - 1): every
  // dequantized ac coefficient - and golomb-scaled dc - saturates at
  // cf_max + sign before the itx, so the reconstruction must too.
  let cf_max = (1 << 15) - 1
  let mut eob = -1
  for p in 0..<n {
    let t = toks[p]
    if t == 0 {
      continue
    }
    let sign = signs[p]
    let tbl = if p == 0 { dc_tbl } else { ac_tbl }
    let mut dq = ((tbl.to_int64() * t.to_int64()) >> dq_shift).to_int()
    // Golomb-scaled tokens wrap the product at 24 bits (decoder).
    if t >= 15 {
      dq = ((tbl.to_int64() * t.to_int64()) & 0xFFFFFF).to_int() >> dq_shift
    }
    if p != 0 || t >= 15 {
      dq = av1_imin(dq, cf_max + sign)
    }
    coeff[av1_scan(tx, p)] = if sign != 0 { -dq } else { dq }
    eob = p
  }
  if eob >= 0 {
    av1_itxfm_add(dst, dst_off, dst_stride, coeff, eob, tx, 0, 255)
  }
  eob
}

///|
/// Test-support wrapper: quantize one 32x32 raster residual leaf at
/// `base_q_idx` and return `(toks, signs, delta)` — the §443 token
/// spec, its signs, and the exact itx(dequant) pixel delta on a zero
/// prediction (raster 1024), so blackbox tests can validate the token
/// chain against the key-frame decode path in isolation.
pub fn av1_enc_debug_quantize_leaf32(
  res : FixedArray[Int32],
  base_q_idx : Int32,
  dz_pm~ : Int32 = 0,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
  let dq_tbl = if base_q_idx >= 0 { av1_dq_tbl_0 } else { av1_dq_tbl_0 }
  let q = av1_imin(av1_imax(base_q_idx, 0), 255)
  let dc_tbl = dq_tbl[q * 2].to_int()
  let ac_tbl = dq_tbl[q * 2 + 1].to_int()
  let dq_shift = av1_imax(0, av1_txfm_ctx(3) - 2)
  let basis = av1_enc_itx_basis32()
  let toks : FixedArray[Int32] = FixedArray::make(1024, 0)
  let signs : FixedArray[Int32] = FixedArray::make(1024, 0)
  let _ = av1_enc_quantize_leaf(
    res,
    32,
    basis,
    dc_tbl,
    ac_tbl,
    dq_shift,
    toks,
    signs,
    dz_pm~,
  )
  // Run the itx on a mid-gray prediction and subtract it back — the
  // kernel clamps its output to [0, bd_max], so a zero prediction
  // would swallow every negative delta.
  let delta : FixedArray[Int32] = FixedArray::make(1024, 128)
  let _ = av1_enc_recon_leaf(
    delta, 0, 32, toks, signs, 3, dc_tbl, ac_tbl, dq_shift,
  )
  for i in 0..<1024 {
    delta[i] = delta[i] - 128
  }
  (toks, signs, delta)
}

///|
/// Test-support: reconstruct one leaf's token spec (dequant + the
/// decoder's itx on a zero prediction) — the exact delta the decoder
/// will realize for this spec.
pub fn av1_enc_debug_recon_leaf32(
  toks : FixedArray[Int32],
  signs : FixedArray[Int32],
  base_q_idx : Int32,
) -> (FixedArray[Int32], Int32) {
  let dq_tbl = av1_dq_tbl_0
  let q = av1_imin(av1_imax(base_q_idx, 0), 255)
  let dc_tbl = dq_tbl[q * 2].to_int()
  let ac_tbl = dq_tbl[q * 2 + 1].to_int()
  let dq_shift = av1_imax(0, av1_txfm_ctx(3) - 2)
  // Run the itx on a mid-gray prediction and subtract it back — the
  // kernel clamps its output to [0, bd_max], so a zero prediction
  // would swallow every negative delta.
  let delta : FixedArray[Int32] = FixedArray::make(1024, 128)
  let _ = av1_enc_recon_leaf(
    delta, 0, 32, toks, signs, 3, dc_tbl, ac_tbl, dq_shift,
  )
  let raw = delta[0]
  for i in 0..<1024 {
    delta[i] = delta[i] - 128
  }
  (delta, raw)
}

///|
/// Temporary §449b: dc response ladder at bd_max=4095.
pub fn av1_enc_debug_dc_ladder() -> String {
  let mut out = ""
  for x in [256, 1024, 4096, 16384, 65536, 262144] {
    let coeff : FixedArray[Int32] = FixedArray::make(1024, 0)
    coeff[0] = x
    let dst : FixedArray[Int32] = FixedArray::make(1024, 0)
    av1_itxfm_add(dst, 0, 32, coeff, 1, 3, 0, 4095)
    out = out + "X=\{x}: d0=\{dst[0]} d1=\{dst[1]} d31=\{dst[31]}; "
  }
  out
}
