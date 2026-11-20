///|
/// §457: per-frame rate–distortion qindex selection for AV1 inter frames.
///
/// The §449b full-residual chain already exposes everything a coarse RD
/// decision needs: trial-encoding a candidate `base_q_idx` yields both the
/// exact reconstruction the decoder will realize (so distortion is measured
/// on the real decoded pixels, not an estimate) and the real packet bytes
/// (so bit cost comes from the actual msac/CDF trajectory, not a hand-wavy
/// hint — the §456 deadzone lesson is that byte direction is content
/// dependent under adaptive CDFs).
///
/// The cost is an integer fixed point in Int64:
///
///   cost = lambda * SAD(src, recon) + bits * 1000
///
/// where `bits = packet_bytes * 8`. `lambda` is therefore the weight of one
/// SAD unit relative to 1/1000 of a bit: `lambda = 0` minimizes bits only
/// (picks the coarsest candidate), while a large `lambda` minimizes
/// distortion only (picks the finest candidate). Ties prefer the smaller
/// qindex. No new syntax is introduced — the chosen q is just the frame
/// header's `base_q_idx`, so every candidate stream is decoded by the same
/// decoder and the winner round-trips pixel-exact.

///|
/// Default candidate ladder used by the session when RD is enabled but no
/// explicit ladder is supplied. Fits the 8-bit dequant tables and spans a
/// coarse-to-fine range wide enough for the bit/distortion tradeoff to move.
pub fn av1_enc_rd_default_q_candidates() -> Array[Int32] {
  [40, 100, 160, 220]
}

///|
/// Snapshot the reference store so a trial encode cannot leak its slot
/// refresh into the caller. `refresh` only replaces slot entries with fresh
/// `Av1RefmvsReference` values; it never mutates an existing entry, so a
/// shallow `FixedArray::copy()` of the slots is a sufficient isolation
/// boundary.
fn av1_enc_rd_fork_refs(
  refs : Av1RefmvsReferenceStore,
) -> Av1RefmvsReferenceStore {
  Av1RefmvsReferenceStore::{ slots: refs.slots.copy(), }
}

///|
/// Pick the best inter-frame `base_q_idx` from `candidates` by minimizing
/// `lambda * SAD + bits * 1000`. `refs` is not modified: each trial runs on
/// a private fork. Returns the winning qindex (always a member of
/// `candidates`); ties go to the smaller qindex.
pub fn av1_enc_rd_select_q_inter(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  src_y : FixedArray[Int32],
  src_y_stride : Int32,
  src_u : FixedArray[Int32],
  src_u_stride : Int32,
  src_v : FixedArray[Int32],
  ref_y : FixedArray[Int32],
  ref_y_stride : Int32,
  ref_u : FixedArray[Int32],
  ref_u_stride : Int32,
  ref_v : FixedArray[Int32],
  candidates : Array[Int32],
  lambda~ : Int32 = 1000,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
) -> Result[Int32, String] {
  if candidates.is_empty() {
    return Err("av1 enc rd: empty q candidate set")
  }
  let w = seq.width
  let h = seq.height
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  let mut best_q = candidates[0]
  let mut best_cost : Int64? = None
  for q in candidates {
    if q < 0 || q > 255 {
      return Err("av1 enc rd: qindex outside 0..=255")
    }
    let trial_refs = av1_enc_rd_fork_refs(refs)
    let trial = av1_enc_write_me_res420_inter_frame_obu(
      seq,
      trial_refs,
      src_y,
      src_y_stride,
      src_u,
      src_u_stride,
      src_v,
      ref_y,
      ref_y_stride,
      ref_u,
      ref_u_stride,
      ref_v,
      base_q_idx=q,
      range~,
      dz_pm~,
    )
    let (pkt, exp_y, exp_u, exp_v) = match trial {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    // Distortion on the planes the decoder will actually realize.
    let mut sad : Int64 = 0L
    for y in 0..<h {
      for x in 0..<w {
        sad += (exp_y[y * w + x] - src_y[y * src_y_stride + x]).abs().to_int64()
      }
    }
    for y in 0..<ch {
      for x in 0..<cw {
        sad += (exp_u[y * cw + x] - src_u[y * src_u_stride + x])
          .abs()
          .to_int64()
        sad += (exp_v[y * cw + x] - src_v[y * src_u_stride + x])
          .abs()
          .to_int64()
      }
    }
    // Real packet bytes msac/CDF produced for this candidate.
    let bits = pkt.length().to_int64() * 8L
    let cost = lambda.to_int64() * sad + bits * 1000L
    if best_cost is None ||
      cost < best_cost.unwrap() ||
      (cost == best_cost.unwrap() && q < best_q) {
      best_cost = Some(cost)
      best_q = q
    }
  }
  Ok(best_q)
}
