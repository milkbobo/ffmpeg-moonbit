///|
/// LAME block switcher of FFmpeg's AAC psy model: `psy_lame_window`
/// (`libavcodec/aacpsy.c`), the callback registered as
/// `ff_aac_psy_model.window` (FFmpeg 9.0.2 does not use `psy_3gpp_window` -
/// that one is `av_unused` dead code with a mismatching signature).
///
/// One instance carries one channel's cross-frame grouping state
/// (`AacPsyChannel`'s LAME members): the previous frame's 16 sub-shortblock
/// peaks, its trailing attack value and the two hand-over flags.  The
/// window *sequence* state machine (`lame_apply_block_type`) is deliberately
/// not ported - the encoder keeps its own `prev_sequence`/`attack_pending`
/// machine (§302) - so `analyze` reports `uselongblock` instead of window
/// types.
///
/// Timing rewrite (§304): FFmpeg's callback runs one packet ahead of the
/// spectrum (`la` lookahead into the next packet) and stores
/// `next_window_seq`/`next_grouping` for the *next* frame.  This port is
/// synchronous: the caller analyses the frame's own 2048-sample MDCT input
/// `[prev | pcm]`, whose region `buf[523..1568)` is exactly the region
/// FFmpeg's lookahead covered one call earlier (FFmpeg's `firbuf = la + 11`
/// with `la = overlap + 1536` in the 3072 planar buffer, whose `[1024..3072)`
/// half is this `[prev | pcm]`), and consumes the first-attack grouping for
/// the *same* frame.  Call `analyze` every frame, as FFmpeg does, so the
/// peak history and the `prev_attack`/`next_attack0_zero` chains stay on the
/// reference cadence.
///
/// Numerics: FFmpeg runs the whole detector in `float` over `float` planar
/// samples; every step below rounds once per C operation via the
/// `aac_two_f32` helpers, and each input sample is rounded to f32 on read,
/// modelling FFmpeg's `float` buffers.  Constants are transcribed as the
/// exact f32 values of the C initializers (double expression, rounded once
/// on store).

///|
/// `psy_fir_coeffs` (`aacpsy.c`): LAME's fs/4 high-pass FIR, the ten
/// half-length taps FFmpeg already doubled.  Exact f32 values.
let aac_lame_fir_coeffs : Array[Double] = [
  -1.7303260184043527e-17, -0.017031719908118248, -1.3495279640235235e-17, 0.04180720075964928,
  -6.732779685849225e-17, -0.08763240277767181, -3.0835000291318875e-17, 0.1863476037979126,
  -1.1044240253100168e-16, -0.6276379823684692,
]

///|
/// `psy_abr_map`'s `st_lrm` column (`aacpsy.c`), exact f32 values, indexed
/// like `aac_lame_abr_kbps`.
let aac_lame_abr_st_lrm : Array[Double] = [
  7.599999904632568, 7.599999904632568, 7.599999904632568, 7.599999904632568, 7.599999904632568,
  7.599999904632568, 7.599999904632568, 7.400000095367432, 7.0, 6.599999904632568,
  6.199999809265137, 6.199999809265137, 6.199999809265137,
]

///|
/// `psy_abr_map`'s `quality` (kbps per channel) column.
let aac_lame_abr_kbps : Array[Int32] = [
  8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160,
]

///|
/// `lame_calc_attack_threshold` (`aacpsy.c`): find the ABR table entries
/// bracketing the bitrate and take the *closer* endpoint's `st_lrm`
/// (nearest endpoint, never interpolated); at or above 160 kbps/channel the
/// initial clamp keeps both ranges at the last entry.  FFmpeg passes
/// `bit_rate / nb_channels / 1000` (integer division).
fn aac_lame_attack_threshold(bitrate_kbps : Int32) -> Double {
  let mut lower = 12
  let mut upper = 12
  for i = 1; i < 13; i = i + 1 {
    if aac_lame_abr_kbps[i] > bitrate_kbps {
      upper = i
      lower = i - 1
      break
    }
  }
  if aac_lame_abr_kbps[upper] - bitrate_kbps >
    bitrate_kbps - aac_lame_abr_kbps[lower] {
    aac_lame_abr_st_lrm[lower]
  } else {
    aac_lame_abr_st_lrm[upper]
  }
}

///|
/// `window_grouping[9]` (`aacpsy.c`): the grouping byte per first-attack
/// block.  Bit i set means window i continues its group, clear means it
/// starts a new one; attack positions later in the frame leave more (and
/// shorter) groups in front.
let aac_window_grouping : Array[Int32] = [
  0xB6, 0x6C, 0xD8, 0xB2, 0x66, 0xC6, 0x96, 0x36, 0x36,
]

///|
/// Expand a grouping byte into `group_len[8]` the way `psy_lame_window`
/// fills `wi.grouping`: a clear bit starts a group at that window and every
/// window increments its group's length (so a set bit extends the current
/// group).  This is also the expansion behind `scale_factor_grouping`
/// (`!group_len[w]`, w = 1..7, `put_ics_info`).
pub fn aac_window_grouping_expand(grouping : Int32) -> Array[Int32] {
  let group_len : Array[Int32] = Array::make(8, 0)
  let mut lastgrp = 0
  for i = 0; i < 8; i = i + 1 {
    if ((grouping >> i) & 1) == 0 {
      lastgrp = i
    }
    group_len[lastgrp] = group_len[lastgrp] + 1
  }
  group_len
}

///|
/// One channel's LAME block-switcher state (`AacPsyChannel`, `aacpsy.c`).
pub struct AacLameWindow {
  /// `pch->attack_threshold`: the f32-exact `st_lrm` for this channel's
  /// bitrate, fixed at init (`lame_window_init`).
  attack_threshold : Double
  /// `pch->prev_energy_subshort[16]`: the previous frame's sub-shortblock
  /// peaks (despite the name they are `max|x|`, not energies), f32-exact,
  /// initialised to `10.0f`.  Only the array contents change, never the
  /// reference, so the field itself is immutable.
  prev_energy_subshort : Array[Double]
  /// `pch->prev_attack`: `attacks[7]` as the previous call left it.
  mut prev_attack : Int32
  /// `pch->next_attack0_zero`: suppresses `attacks[0]` when the previous
  /// frame's last block showed no attack.
  mut next_attack0_zero : Bool
  /// `pch->next_grouping`: the grouping byte stored for the next short
  /// frame.  Kept for reference parity (and cross-checked by the window
  /// vectors); the synchronous consumer reads this call's `group_byte`
  /// instead.
  mut next_grouping : Int32
}

///|
/// Build the per-channel switcher state as `lame_window_init` does: the
/// ABR attack threshold from the bitrate and sixteen `10.0f` seed peaks.
pub fn AacLameWindow::new(bitrate_kbps_per_ch : Int32) -> AacLameWindow {
  {
    attack_threshold: aac_lame_attack_threshold(bitrate_kbps_per_ch),
    prev_energy_subshort: Array::make(16, 10.0),
    prev_attack: 0,
    next_attack0_zero: false,
    next_grouping: 0,
  }
}

///|
/// Integer decisions of one `AacLameWindow::analyze` call - the quantities
/// the reference harness prints per frame in `--win` mode (`RAW` line, via
/// `patch.py` probes): the final `attacks[0..8]` after the cascade,
/// `att_sum` as computed for the block-type decision, `uselongblock`, the
/// first-attack index, and the stored grouping byte with its `group_len`
/// expansion.
pub struct AacLameDecision {
  /// `attacks[0..8]`, final values (after the cross-frame flags and the
  /// cascade): `0`, or `(i % 2) + 1` for the sub-block that fired.
  attacks : Array[Int32]
  /// `att_sum` including the restored `attacks[0]` - what the block-type
  /// decision reads; larger than `sum(attacks)` when the cascade (which
  /// runs after) suppressed further attacks.
  att_sum : Int32
  /// `uselongblock`: false iff `prev_attack == 2 || att_sum`.
  uselong : Bool
  /// Index of the first non-zero attack block (0 when all are zero), i.e.
  /// the `window_grouping` selector.
  grp_first : Int32
  /// `pch->next_grouping` as it was *before* this call stored its result:
  /// the byte FFmpeg's next short frame would expand (`wi` fill reads it
  /// before the tail overwrites it).
  wi_grp_pre : Int32
  /// `window_grouping[grp_first]`: the byte this call stores as
  /// `next_grouping`; in the synchronous rewrite it is also this frame's
  /// grouping.
  group_byte : Int32
  /// `group_len[8]` expanded from `group_byte`: this frame's window groups.
  group_len : Array[Int32]
}

///|
/// One `psy_lame_window` call for one channel.  `buf[start..start+1045)` is
/// the FIR input (`firbuf = la + 11`); in the synchronous rewrite the caller
/// passes `start = 523` of the 2048-sample `[prev | pcm]` MDCT input.  The
/// region's 1045 samples feed a 1024-point high-pass FIR, whose outputs are
/// peak-picked over sixteen 64-sample sub-blocks; those peaks (plus the two
/// restored from state) drive the attack intensities, the suppression
/// passes, and the first-attack grouping decision.  The `la == NULL` flush
/// path is not modelled - this encoder has no flush API (documented §304
/// deviation, the test streams end with one quiet frame instead).
pub fn AacLameWindow::analyze(
  self : AacLameWindow,
  buf : Array[Double],
  start : Int32,
) -> AacLameDecision {
  // 1) high-pass FIR (`psy_hp_filter`): 1024 outputs over 1045 inputs,
  //    taps at +/-10 around each centre, `sum1` on the even taps and the
  //    centre, `sum2` on the odd taps.  The 32768 factor is LAME's domain
  //    alignment (the model expects +/-32768, the PCM is [-1, 1]).
  let hpfsmpl : Array[Double] = Array::make(1024, 0.0)
  for i = 0; i < 1024; i = i + 1 {
    let s0 = start + i
    let mut sum1 = aac_two_f32(buf[s0 + 10])
    let mut sum2 = 0.0
    for j = 0; j < 9; j = j + 2 {
      sum1 = aac_two_add(
        sum1,
        aac_two_mul(
          aac_lame_fir_coeffs[j],
          aac_two_add(aac_two_f32(buf[s0 + j]), aac_two_f32(buf[s0 + 21 - j])),
        ),
      )
      sum2 = aac_two_add(
        sum2,
        aac_two_mul(
          aac_lame_fir_coeffs[j + 1],
          aac_two_add(
            aac_two_f32(buf[s0 + j + 1]),
            aac_two_f32(buf[s0 + 21 - j - 1]),
          ),
        ),
      )
    }
    hpfsmpl[i] = aac_two_mul(aac_two_add(sum1, sum2), 32768.0)
  }
  // 2) sub-shortblock peaks: sub-blocks 0..1 restore the previous frame's
  //    last two peaks and compare them against its sub-blocks 12..13 (the
  //    famous `[i + 3 - 2]` index, "two sub-blocks earlier"); sub-blocks
  //    2..17 peak-pick the FIR output in order.
  let energy_subshort : Array[Double] = Array::make(18, 0.0)
  let attack_intensity : Array[Double] = Array::make(18, 0.0)
  let energy_short : Array[Double] = Array::make(9, 0.0)
  for i = 0; i < 2; i = i + 1 {
    energy_subshort[i] = self.prev_energy_subshort[i + 14]
    attack_intensity[i] = aac_two_div(
      energy_subshort[i],
      self.prev_energy_subshort[i + 12],
    )
    energy_short[0] = aac_two_add(energy_short[0], energy_subshort[i])
  }
  let mut pf = 0
  for i = 0; i < 16; i = i + 1 {
    // `p` is max|x| (the LAME names say "energy"; the values are peaks),
    // seeded at 1.0f, so a sub-block never peaks below 1.0 and the
    // divisions below never see a zero operand.
    let mut p = 1.0
    let pfe = pf + 64
    while pf < pfe {
      let a = hpfsmpl[pf].abs()
      if a > p {
        p = a
      }
      pf = pf + 1
    }
    self.prev_energy_subshort[i] = p
    energy_subshort[i + 2] = p
    energy_short[1 + i / 2] = aac_two_add(energy_short[1 + i / 2], p)
    let ess = energy_subshort[i]
    attack_intensity[i + 2] = if p > ess {
      aac_two_div(p, ess)
    } else if ess > aac_two_mul(p, 10.0) {
      aac_two_div(ess, aac_two_mul(p, 10.0))
    } else {
      0.0
    }
  }
  // 3) attacks: first sub-block of each short block whose intensity beats
  //    the threshold (later sub-blocks only fill in if the block is still
  //    unset).  Block 0 is the restored previous-frame tail.
  let attacks : Array[Int32] = Array::make(9, 0)
  for i = 0; i < 18; i = i + 1 {
    if attacks[i / 2] == 0 && attack_intensity[i] > self.attack_threshold {
      attacks[i / 2] = i % 2 + 1
    }
  }
  // 4) periodic-signal suppression ("trumpet"): a quiet, similar pair of
  //    neighbouring short blocks clears the later attack (and the restored
  //    block 0 when block 1 is stronger).  2.3f is 2.299999952316284.
  let mut att_sum = 0
  let ratio_2p3 = 2.299999952316284
  for i = 1; i < 9; i = i + 1 {
    let u = energy_short[i - 1]
    let v = energy_short[i]
    let m = if u > v { u } else { v }
    if m < 40000.0 &&
      u < aac_two_mul(ratio_2p3, v) &&
      v < aac_two_mul(ratio_2p3, u) {
      if i == 1 && attacks[0] < attacks[1] {
        attacks[0] = 0
      }
      attacks[i] = 0
    }
    att_sum = att_sum + attacks[i]
  }
  // 5) cross-frame flags: block 0 is suppressed when the previous frame's
  //    last block was quiet, and only survives if it grew.
  if self.next_attack0_zero {
    attacks[0] = 0
  }
  self.next_attack0_zero = attacks[8] == 0
  if attacks[0] <= self.prev_attack {
    attacks[0] = 0
  }
  att_sum = att_sum + attacks[0]
  // 6) block-type decision and the cascade (only on the short-block path):
  //    neighbouring attacks keep just the earlier one.
  let uselong = !(self.prev_attack == 2 || att_sum != 0)
  if !uselong {
    for i = 1; i < 9; i = i + 1 {
      if attacks[i] != 0 && attacks[i - 1] != 0 {
        attacks[i] = 0
      }
    }
  }
  // 7) grouping from the first surviving attack; the expansion the encoder
  //    consumes uses this call's byte (synchronous), the stored
  //    `next_grouping` keeps the reference chain for the vectors.
  let wi_grp_pre = self.next_grouping
  let mut grp_first = 0
  for i = 0; i < 9; i = i + 1 {
    if attacks[i] != 0 {
      grp_first = i
      break
    }
  }
  let group_byte = aac_window_grouping[grp_first]
  self.next_grouping = group_byte
  self.prev_attack = attacks[7]
  {
    attacks,
    att_sum,
    uselong,
    grp_first,
    wi_grp_pre,
    group_byte,
    group_len: aac_window_grouping_expand(group_byte),
  }
}
