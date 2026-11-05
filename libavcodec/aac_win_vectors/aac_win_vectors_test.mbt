///|
/// Black-box regression for the LAME window/grouping analyser
/// (`AacLameWindow`, the port of FFmpeg 9.0.2 `psy_lame_window`).
///
/// Expected values come from `_ref/aacenc/vectors_win.txt`, produced by
/// running the unmodified FFmpeg block switcher (function pointer
/// `s->psy.model->window`) over the deterministic PCM stream mirrored below,
/// with FFmpeg's exact 3072-sample sliding-window geometry and its
/// `la = samples2 + 512` lookahead.  Regenerate with:
///   bash _ref/aacenc/build.sh
///   ./aac_ref.exe --win 26 > vectors_win.txt        (from _ref/aacenc)
///   python scripts/gen_aac_win_vectors.py
///
/// Everything compared is an integer decision, asserted exactly over all
/// 26 frames x 2 channels: the final `attacks[0..8]` (post cascade),
/// `att_sum`, `uselongblock`, the first-attack grouping index, the
/// pre-overwrite `next_grouping` and `prev_attack`.  The vectors cover every
/// first-attack index 0..8 (the whole `window_grouping` table), quiet frames
/// (`uselongblock` true) and cascade/trumpet suppression (frames whose
/// `att_sum` exceeds the sum of the final attacks).
///
/// Channel 1's burst pair at offsets 700/764 fires attacks in consecutive
/// blocks; the 5000-sample period is not a multiple of the 64-sample
/// sub-block, so attack positions drift through the run.

///|
/// Burst events per channel: `[start, start + len)` within each 5000-sample
/// period, at the given amplitude.  Mirror of the harness `win_ev_*`.
let aac_win_ev_off : Array[Array[Int]] = [
  [300, 1500, 3200, 4400],
  [700, 764, 2600, 4200],
]

///|
let aac_win_ev_len : Array[Array[Int]] = [
  [90, 40, 130, 50],
  [60, 60, 200, 30],
]

///|
let aac_win_ev_amp : Array[Array[Int]] = [
  [22000, 18000, 24000, 15000],
  [20000, 21000, 23000, 16000],
]

///|
/// Mirror of the harness `win_pcm`: pure integer arithmetic, so every float
/// handed to the analyser is bit-identical to the C run.  The unsigned-32
/// LCG is emulated with masked `Int` products (the `vp9_scaled_kernel_test`
/// idiom): the mask keeps every value congruent mod 2^32 on both Int widths,
/// and every shift is immediately masked to low bits, which do not depend on
/// the sign fill.  Quiet samples alternate sign at amplitude 20..27
/// (Nyquist passes the high-pass FIR; neighbouring peaks stay far below the
/// 7.40 attack threshold), burst samples are scaled LCG noise; the final
/// `v / 32768` is an exact float.
fn aac_win_pcm(ch : Int, n : Int) -> Double {
  // 0x85ebca77 == 2246822519U (the decimal literal leaves the Int range).
  let st0 = (12345 + 0x85ebca77 * (2 * n + ch)) & 0xFFFFFFFF
  let base = 20 + ((st0 >> 13) & 7)
  let mut v = if n % 2 == 1 { base } else { -base }
  let pos = n % 5000
  for ev = 0; ev < 4; ev = ev + 1 {
    let off = aac_win_ev_off[ch][ev]
    if pos >= off && pos < off + aac_win_ev_len[ch][ev] {
      let st = (st0 * 1664525 + 1013904223) & 0xFFFFFFFF
      v = (((st >> 12) & 8191) - 4096) * (aac_win_ev_amp[ch][ev] / 4096)
      break
    }
  }
  v.to_double() / 32768.0
}

///|
test "lame window grouping matches FFmpeg 9.0.2 (26 frames x 2 channels)" {
  // 64 kbps/ch picks the exact ABR entry: f32(7.40).
  let lame_ch : Array[@libavcodec.AacLameWindow] = [
    @libavcodec.AacLameWindow::new(64),
    @libavcodec.AacLameWindow::new(64),
  ]
  if lame_ch[0].attack_threshold != 7.400000095367432 {
    fail(
      "64 kbps/ch attack threshold must be f32(7.40), got \{lame_ch[0].attack_threshold}",
    )
  }
  // MDCT-input mirror: buf = [prev packet | this packet]; the analyser's
  // region buf[523..1568) is the samples FFmpeg's lookahead covered.
  let buf_ch : Array[Array[Double]] = [
    Array::make(2048, 0.0),
    Array::make(2048, 0.0),
  ]
  let frames = @aac_win_vectors.aac_win_att_sum.length() / 2
  // The grouping byte one call stores must surface as the next same-channel
  // call's pre-overwrite value (FFmpeg's next_grouping chain).
  let prev_group_byte : Array[Int] = [0, 0]
  for m = 0; m < frames; m = m + 1 {
    for ch = 0; ch < 2; ch = ch + 1 {
      let buf = buf_ch[ch]
      for k = 0; k < 1024; k = k + 1 {
        buf[k] = buf[1024 + k]
        buf[1024 + k] = aac_win_pcm(ch, m * 1024 + k)
      }
      let d = lame_ch[ch].analyze(buf, 523)
      let idx = m * 2 + ch
      let want = @aac_win_vectors.aac_win_attacks[idx]
      for i = 0; i < 9; i = i + 1 {
        if d.attacks[i] != want[i] {
          fail(
            "frame \{m} ch \{ch}: attacks[\{i}] \{d.attacks[i]} != \{want[i]}",
          )
        }
      }
      if d.att_sum != @aac_win_vectors.aac_win_att_sum[idx] {
        fail(
          "frame \{m} ch \{ch}: att_sum \{d.att_sum} != \{@aac_win_vectors.aac_win_att_sum[idx]}",
        )
      }
      if d.uselong != @aac_win_vectors.aac_win_uselong[idx] {
        fail(
          "frame \{m} ch \{ch}: uselong \{d.uselong} != \{@aac_win_vectors.aac_win_uselong[idx]}",
        )
      }
      if d.grp_first != @aac_win_vectors.aac_win_grp_first[idx] {
        fail(
          "frame \{m} ch \{ch}: grp_first \{d.grp_first} != \{@aac_win_vectors.aac_win_grp_first[idx]}",
        )
      }
      if d.wi_grp_pre != @aac_win_vectors.aac_win_wi_grp_pre[idx] {
        fail(
          "frame \{m} ch \{ch}: wi_grp_pre \{d.wi_grp_pre} != \{@aac_win_vectors.aac_win_wi_grp_pre[idx]}",
        )
      }
      if prev_group_byte[ch] != @aac_win_vectors.aac_win_wi_grp_pre[idx] {
        fail(
          "frame \{m} ch \{ch}: stored group byte \{prev_group_byte[ch]} did not surface as wi_grp_pre \{@aac_win_vectors.aac_win_wi_grp_pre[idx]}",
        )
      }
      // attacks[7] *is* the stored prev_attack.
      if d.attacks[7] != @aac_win_vectors.aac_win_prev_attack[idx] {
        fail(
          "frame \{m} ch \{ch}: attacks[7] \{d.attacks[7]} != stored prev_attack \{@aac_win_vectors.aac_win_prev_attack[idx]}",
        )
      }
      // group_len must be the byte's expansion and cover all eight windows.
      let expanded = @libavcodec.aac_window_grouping_expand(d.group_byte)
      for i = 0; i < 8; i = i + 1 {
        if expanded[i] != d.group_len[i] {
          fail(
            "frame \{m} ch \{ch}: group_len[\{i}] \{d.group_len[i]} != expansion \{expanded[i]}",
          )
        }
      }
      prev_group_byte[ch] = d.group_byte
    }
  }
}

///|
test "lame attack threshold picks the nearer ABR endpoint" {
  // Bracket checks from psy_abr_map (kbps/ch -> st_lrm): 64 and 96 sit
  // exactly on entries; 72 is equidistant between 64 and 80 and the tie
  // takes the upper (7.00); 130 is closer to 128; 4 clamps low; 200 clamps
  // at the last entry.
  let cases : Array[(Int, Double)] = [
    (64, 7.400000095367432),
    (96, 6.599999904632568),
    (130, 6.199999809265137),
    (4, 7.599999904632568),
    (200, 6.199999809265137),
    (9, 7.599999904632568),
    (15, 7.599999904632568),
    (72, 7.0),
  ]
  for pair in cases {
    let w = @libavcodec.AacLameWindow::new(pair.0)
    if w.attack_threshold != pair.1 {
      fail(
        "\{pair.0} kbps/ch: threshold \{w.attack_threshold} != \{pair.1}",
      )
    }
  }
}
