///|
/// §465: three-way joint rate–distortion choice over the qindex ladder,
/// the per-SB skip threshold, AND the reference age (which past
/// reconstruction to predict from).
///
/// §462 already searched q × skip but always predicted from the previous
/// frame. §464 gave the session an eight-slot reconstruction ring, so a
/// frame can now also pick an older reference. This selector trial-encodes
/// every (q, skip, age) combination and keeps the cheapest
/// `lambda * SAD + bits * 1000` — the same real-value cost as §462, no
/// estimated rate model.
///
/// Each candidate reference is supplied as its own plane set, so the
/// caller decides which ages are available; `ref_slots` carries the AV1
/// slot each candidate lives in so the caller can honour the winner
/// without a second lookup.

///|
/// One candidate reference picture: the planes to predict from plus the
/// AV1 reference slot and the age (frames back) it came from.
pub(all) struct Av1EncRefCandidate {
  slot : Int32
  age : Int32
  y : FixedArray[Int32]
  y_stride : Int32
  u : FixedArray[Int32]
  uv_stride : Int32
  v : FixedArray[Int32]
}

///|
/// The winning (qindex, skip percentage, reference) triple. `ref_index`
/// indexes the caller's candidate list.
pub(all) struct Av1EncRdRefChoice {
  q : Int32
  skip_pct : Int32
  ref_index : Int32
  cost : Int64
}

///|
/// Pick the cheapest (qindex, skip threshold, reference) combination for
/// one inter frame. Every trial runs on a private reference-store fork so
/// the caller's state is untouched. Ties prefer the lower q, then the
/// lower skip percentage, then the earlier candidate (youngest reference).
pub fn av1_enc_rd_select_q_skip_ref_inter(
  seq : Av1SequenceParameters,
  refs : Av1RefmvsReferenceStore,
  src_y : FixedArray[Int32],
  src_y_stride : Int32,
  src_u : FixedArray[Int32],
  src_u_stride : Int32,
  src_v : FixedArray[Int32],
  ref_candidates : Array[Av1EncRefCandidate],
  candidates : Array[Int32],
  skip_pcts : Array[Int32],
  lambda~ : Int32 = 1000,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
) -> Result[Av1EncRdRefChoice, String] {
  if candidates.is_empty() {
    return Err("av1 enc rd: empty q candidate set")
  }
  if ref_candidates.is_empty() {
    return Err("av1 enc rd: empty reference candidate set")
  }
  let w = seq.width
  let h = seq.height
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  // The residual baseline is always a candidate shape.
  let pcts : Array[Int32] = [0]
  for p in skip_pcts {
    if p < 0 || p > 100 {
      return Err("av1 enc rd: skip percentage outside 0..=100")
    }
    if !pcts.contains(p) {
      pcts.push(p)
    }
  }
  let mut best_q = candidates[0]
  let mut best_pct = 0
  let mut best_ref = 0
  let mut best_cost : Int64? = None
  for q in candidates {
    if q < 0 || q > 255 {
      return Err("av1 enc rd: qindex outside 0..=255")
    }
    for pct in pcts {
      for ri in 0..<ref_candidates.length() {
        let rc = ref_candidates[ri]
        let trial_refs = av1_enc_rd_fork_refs(refs)
        let trial = if pct > 0 {
          av1_enc_write_me_skip420_inter_frame_obu(
            seq,
            trial_refs,
            src_y,
            src_y_stride,
            src_u,
            src_u_stride,
            src_v,
            rc.y,
            rc.y_stride,
            rc.u,
            rc.uv_stride,
            rc.v,
            base_q_idx=q,
            range~,
            dz_pm~,
            skip_sad_pct=pct,
            skip_uniform=true,
            ref_slot=rc.slot,
          )
        } else {
          av1_enc_write_me_res420_inter_frame_obu(
            seq,
            trial_refs,
            src_y,
            src_y_stride,
            src_u,
            src_u_stride,
            src_v,
            rc.y,
            rc.y_stride,
            rc.u,
            rc.uv_stride,
            rc.v,
            base_q_idx=q,
            range~,
            dz_pm~,
            ref_slot=rc.slot,
          )
        }
        let (pkt, exp_y, exp_u, exp_v) = match trial {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let mut sad : Int64 = 0L
        for y in 0..<h {
          for x in 0..<w {
            sad += (exp_y[y * w + x] - src_y[y * src_y_stride + x])
              .abs()
              .to_int64()
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
        let bits = pkt.length().to_int64() * 8L
        let cost = lambda.to_int64() * sad + bits * 1000L
        let better = match best_cost {
          None => true
          Some(bc) =>
            cost < bc ||
            (
              cost == bc &&
              (
                q < best_q ||
                (
                  q == best_q &&
                  (pct < best_pct || (pct == best_pct && ri < best_ref))
                )
              )
            )
        }
        if better {
          best_cost = Some(cost)
          best_q = q
          best_pct = pct
          best_ref = ri
        }
      }
    }
  }
  Ok({
    q: best_q,
    skip_pct: best_pct,
    ref_index: best_ref,
    cost: best_cost.unwrap(),
  })
}
