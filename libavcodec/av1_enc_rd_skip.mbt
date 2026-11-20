///|
/// §462: joint rate–distortion selection over the qindex ladder AND the
/// per-SB skip switch. §457 chose a qindex on the full-residual chain and
/// §458/§460 added skip as a separate, independently-triggered decision —
/// so a frame could pick a q that is only optimal for the residual path
/// while skip would have been cheaper (or vice versa). This selector
/// trial-encodes BOTH shapes for every candidate q and keeps the
/// (q, skip) pair with the lowest `lambda * SAD + bits * 1000` cost.
///
/// Distortion is measured on the planes the decoder will actually
/// realize (each trial returns its own expected reconstruction) and bits
/// are the real msac packet length — no estimated rate model, per the
/// §456 lesson that byte direction is content-dependent under adaptive
/// CDFs. Every trial runs on a private reference-store fork so the
/// caller's state is untouched.

///|
/// The winning (qindex, skip percentage) pair. `skip_pct = 0` means the
/// plain §449b residual path won; a positive value means a skip-mixed
/// frame won at that threshold.
pub(all) struct Av1EncRdSkipChoice {
  q : Int32
  skip_pct : Int32
  cost : Int64
}

///|
/// Pick the best (qindex, skip threshold) combination for one inter frame.
/// `skip_pcts` holds the skip thresholds to try (each is passed straight
/// to the skip writer; 0 is always tried as the residual baseline even if
/// absent from the list). Returns the cheapest combination; ties prefer
/// the lower q, then the lower skip percentage.
pub fn av1_enc_rd_select_q_skip_inter(
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
  skip_pcts : Array[Int32],
  lambda~ : Int32 = 1000,
  range~ : Int32 = 8,
  dz_pm~ : Int32 = 0,
) -> Result[Av1EncRdSkipChoice, String] {
  if candidates.is_empty() {
    return Err("av1 enc rd: empty q candidate set")
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
  let mut best_cost : Int64? = None
  for q in candidates {
    if q < 0 || q > 255 {
      return Err("av1 enc rd: qindex outside 0..=255")
    }
    for pct in pcts {
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
          ref_y,
          ref_y_stride,
          ref_u,
          ref_u_stride,
          ref_v,
          base_q_idx=q,
          range~,
          dz_pm~,
          skip_sad_pct=pct,
          skip_uniform=true,
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
          ref_y,
          ref_y_stride,
          ref_u,
          ref_u_stride,
          ref_v,
          base_q_idx=q,
          range~,
          dz_pm~,
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
          (cost == bc && (q < best_q || (q == best_q && pct < best_pct)))
      }
      if better {
        best_cost = Some(cost)
        best_q = q
        best_pct = pct
      }
    }
  }
  Ok({ q: best_q, skip_pct: best_pct, cost: best_cost.unwrap(), })
}
