///|
/// MoonBit port of the MPEG-1/2/2.5 Audio Layer I and Layer II decoders from
/// FFmpeg 9.0.2 `libavcodec/mpegaudiodec_template.c` (`mp_decode_layer1`,
/// `mp_decode_layer2`) and the requisites in `mpegaudiodec_common.c` /
/// `mpegaudio.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later. This port keeps the same license.
///
/// Numeric path: `USE_FLOATS=0` (the `mp2`/`mp1` fixed decoder). Scalefactor
/// expansion goes through `l1_unscale` / `l2_unscale_group`, which use the same
/// `FRAC_BITS`-scaled integer multipliers as the C (`mpa_scale_factor_mult`,
/// `mpa_scale_factor_mult2`).
///
/// Both layers write straight into the subband samples consumed by the shared
/// polyphase synthesis filter (`mp3_dsp.mbt`): Layer I produces 12 blocks of 32
/// subband samples per frame (384 PCM samples), Layer II produces 36 blocks
/// (1152 PCM samples). There is no IMDCT, no alias reduction and no bit
/// reservoir in either layer.
///
/// Not ported (documented in README): CRC *verification* (`handle_crc` only acts
/// when `err_recognition & AV_EF_CRCCHECK`; the 16 CRC bits are skipped, as in
/// the Layer III port), and free-format streams (rejected by the header parser).

///| `SBLIMIT` as used by the Layer I allocation loops (always 32 subbands). */
let mpa_layer1_subbands : Int = 32

///|
/// `ff_mpa_l2_select_table(bitrate, nb_channels, freq, lsf)` — picks one of the
/// five Layer II bit-allocation tables. `bitrate` is in kbit/s (the C passes
/// `s->bit_rate / 1000`).
fn mpa_l2_select_table(
  bitrate : Int,
  nb_channels : Int,
  freq : Int,
  lsf : Int,
) -> Int {
  let ch_bitrate = bitrate / nb_channels
  if lsf == 0 {
    if (freq == 48000 && ch_bitrate >= 56) ||
      (ch_bitrate >= 56 && ch_bitrate <= 80) {
      0
    } else if freq != 48000 && ch_bitrate >= 96 {
      1
    } else if freq != 32000 && ch_bitrate <= 48 {
      2
    } else {
      3
    }
  } else {
    4
  }
}

///|
/// `l1_unscale(n, mant, scale_factor)`: undo the Layer I/II quantisation.
/// `n` is the number of mantissa bits minus one; the mantissa is centred around
/// `2^n - 1` before being multiplied by the scalefactor-derived multiplier.
fn mpa_l1_unscale(n : Int, mant : Int, scale_factor : Int) -> Int {
  let ms = mpa_scale_factor_modshift[scale_factor]
  let mod = ms & 3
  let mut shift = ms >> 2
  // C: `MUL64((int)(mant + (-1U << n) + 1), scale_factor_mult[n-1][mod])`
  // `-1U << n` wraps to `2^32 - 2^n`, so the sum is `mant - 2^n + 1`.
  let val = mul64(mant - (1 << n) + 1, mpa_scale_factor_mult[n - 1][mod])
  shift = shift + n
  ((val + (1L << (shift - 1))) >> shift).to_int()
}

///|
/// `l2_unscale_group(steps, mant, scale_factor)`: the Layer II grouped
/// quantiser (3, 5 or 9 steps) shares one multiplier per step count.
fn mpa_l2_unscale_group(steps : Int, mant : Int, scale_factor : Int) -> Int {
  let ms = mpa_scale_factor_modshift[scale_factor]
  let mod = ms & 3
  let shift = ms >> 2
  let mut val = (mant - (steps >> 1)) * mpa_scale_factor_mult2[steps >> 2][mod]
  if shift > 0 {
    val = (val + (1 << (shift - 1))) >> shift
  }
  val
}

///| Fresh `[2][n]` byte-per-sample scratch matrix (no shared inner arrays). */
fn mpa_matrix2(n : Int) -> Array[Array[Int]] {
  let rows : Array[Array[Int]] = []
  for _ch = 0; _ch < 2; _ch = _ch + 1 {
    rows.push(Array::make(n, 0))
  }
  rows
}

///|
/// `mp_decode_layer1`: 384 samples per frame. Returns the number of 32-sample
/// blocks (12) that were written to `dec.sb_samples`.
///
/// `gb` must be positioned after the frame header and the optional 16-bit CRC.
fn mpa_decode_layer1(
  dec : Mp3Decoder,
  gb : BitReader,
  h : MpaDecodeHeader,
) -> Result[Int, String] {
  let nch = h.nb_channels
  let mut bound = mpa_layer1_subbands
  if h.mode == 1 {
    // MPA_JSTEREO: above `bound` the two channels share one bit allocation.
    bound = (h.mode_ext + 1) * 4
  }
  let allocation = mpa_matrix2(mpa_layer1_subbands)
  let scale_factors = mpa_matrix2(mpa_layer1_subbands)
  // Bit allocation, 4 bits per subband.
  for i = 0; i < bound; i = i + 1 {
    for ch = 0; ch < nch; ch = ch + 1 {
      allocation[ch][i] = gb.read(4).reinterpret_as_int()
    }
  }
  for i = bound; i < mpa_layer1_subbands; i = i + 1 {
    allocation[0][i] = gb.read(4).reinterpret_as_int()
  }
  // Scalefactors, 6 bits, only where a bit allocation is present.
  for i = 0; i < bound; i = i + 1 {
    for ch = 0; ch < nch; ch = ch + 1 {
      if allocation[ch][i] != 0 {
        scale_factors[ch][i] = gb.read(6).reinterpret_as_int()
      }
    }
  }
  for i = bound; i < mpa_layer1_subbands; i = i + 1 {
    if allocation[0][i] != 0 {
      scale_factors[0][i] = gb.read(6).reinterpret_as_int()
      scale_factors[1][i] = gb.read(6).reinterpret_as_int()
    }
  }
  // Samples: 12 blocks of 32 subband samples; the allocation is `n`, and each
  // sample carries `n + 1` mantissa bits.
  for j = 0; j < 12; j = j + 1 {
    for i = 0; i < bound; i = i + 1 {
      for ch = 0; ch < nch; ch = ch + 1 {
        let n = allocation[ch][i]
        let v = if n != 0 {
          mpa_l1_unscale(
            n,
            gb.read(n + 1).reinterpret_as_int(),
            scale_factors[ch][i],
          )
        } else {
          0
        }
        dec.sb_samples[ch][j * 32 + i] = v
      }
    }
    for i = bound; i < mpa_layer1_subbands; i = i + 1 {
      let n = allocation[0][i]
      if n != 0 {
        let mant = gb.read(n + 1).reinterpret_as_int()
        dec.sb_samples[0][j * 32 + i] = mpa_l1_unscale(n, mant, scale_factors[0][i])
        dec.sb_samples[1][j * 32 + i] = mpa_l1_unscale(n, mant, scale_factors[1][i])
      } else {
        dec.sb_samples[0][j * 32 + i] = 0
        dec.sb_samples[1][j * 32 + i] = 0
      }
    }
  }
  Ok(12)
}

///|
/// `mp_decode_layer2`: 1152 samples per frame. Returns the number of 32-sample
/// blocks (36) written to `dec.sb_samples`.
///
/// `gb` must be positioned after the frame header and the optional 16-bit CRC.
fn mpa_decode_layer2(
  dec : Mp3Decoder,
  gb : BitReader,
  h : MpaDecodeHeader,
) -> Result[Int, String] {
  let nch = h.nb_channels
  let table = mpa_l2_select_table(h.bit_rate / 1000, nch, h.sample_rate, h.lsf)
  let sblimit_tab = mpa_sblimit_table[table]
  let alloc_table = mpa_alloc_tables[table]
  let mut bound = if h.mode == 1 { (h.mode_ext + 1) * 4 } else { sblimit_tab }
  if bound > sblimit_tab {
    bound = sblimit_tab
  }
  let bit_alloc = mpa_matrix2(sblimit_tab)
  let scale_code = mpa_matrix2(sblimit_tab)
  let scale_factors = mpa_matrix2(sblimit_tab * 3)
  // Bit allocation: the first byte of each alloc-table row is the number of
  // bits used for that subband; the row then holds the quantiser index for each
  // allocation value, so the next subband starts `1 << bits` entries later.
  let mut j = 0
  for i = 0; i < bound; i = i + 1 {
    let bits = alloc_table[j]
    for ch = 0; ch < nch; ch = ch + 1 {
      bit_alloc[ch][i] = gb.read(bits).reinterpret_as_int()
    }
    j = j + (1 << bits)
  }
  for i = bound; i < sblimit_tab; i = i + 1 {
    let bits = alloc_table[j]
    let v = gb.read(bits).reinterpret_as_int()
    bit_alloc[0][i] = v
    bit_alloc[1][i] = v
    j = j + (1 << bits)
  }
  // Scalefactor selection information, 2 bits per allocated subband.
  for i = 0; i < sblimit_tab; i = i + 1 {
    for ch = 0; ch < nch; ch = ch + 1 {
      if bit_alloc[ch][i] != 0 {
        scale_code[ch][i] = gb.read(2).reinterpret_as_int()
      }
    }
  }
  // (`handle_crc` sits here in the C; it only runs with AV_EF_CRCCHECK.)
  // Scalefactors: three per allocated subband, with four sharing patterns.
  for i = 0; i < sblimit_tab; i = i + 1 {
    for ch = 0; ch < nch; ch = ch + 1 {
      if bit_alloc[ch][i] != 0 {
        let base = i * 3
        match scale_code[ch][i] {
          0 => {
            scale_factors[ch][base] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 1] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 2] = gb.read(6).reinterpret_as_int()
          }
          1 => {
            scale_factors[ch][base] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 2] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 1] = scale_factors[ch][base]
          }
          2 => {
            scale_factors[ch][base] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 1] = scale_factors[ch][base]
            scale_factors[ch][base + 2] = scale_factors[ch][base]
          }
          _ => {
            scale_factors[ch][base] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 2] = gb.read(6).reinterpret_as_int()
            scale_factors[ch][base + 1] = scale_factors[ch][base + 2]
          }
        }
      }
    }
  }
  // Samples: 3 groups of 12 samples per subband, each group 4 triples.
  for k = 0; k < 3; k = k + 1 {
    for l = 0; l < 12; l = l + 3 {
      let mut jj = 0
      for i = 0; i < bound; i = i + 1 {
        let bit_alloc_bits = alloc_table[jj]
        for ch = 0; ch < nch; ch = ch + 1 {
          let b = bit_alloc[ch][i]
          if b != 0 {
            let base = i * 3
            let scale = scale_factors[ch][base + k]
            let qindex = alloc_table[jj + b]
            let bits = mpa_quant_bits[qindex]
            if bits < 0 {
              // One code word carries three samples.
              let v = gb.read(-bits).reinterpret_as_int()
              let v2 = mpa_division_tabs[qindex][v]
              let steps = mpa_quant_steps[qindex]
              dec.sb_samples[ch][(k * 12 + l) * 32 + i] = mpa_l2_unscale_group(
                steps,
                v2 & 15,
                scale,
              )
              dec.sb_samples[ch][(k * 12 + l + 1) * 32 + i] = mpa_l2_unscale_group(
                steps,
                (v2 >> 4) & 15,
                scale,
              )
              dec.sb_samples[ch][(k * 12 + l + 2) * 32 + i] = mpa_l2_unscale_group(
                steps,
                v2 >> 8,
                scale,
              )
            } else {
              for m = 0; m < 3; m = m + 1 {
                let v = gb.read(bits).reinterpret_as_int()
                dec.sb_samples[ch][(k * 12 + l + m) * 32 + i] = mpa_l1_unscale(
                  bits - 1,
                  v,
                  scale,
                )
              }
            }
          } else {
            dec.sb_samples[ch][(k * 12 + l) * 32 + i] = 0
            dec.sb_samples[ch][(k * 12 + l + 1) * 32 + i] = 0
            dec.sb_samples[ch][(k * 12 + l + 2) * 32 + i] = 0
          }
        }
        jj = jj + (1 << bit_alloc_bits)
      }
      // Joint-stereo region: one shared allocation and mantissa stream, two
      // scalefactors.
      for i = bound; i < sblimit_tab; i = i + 1 {
        let bit_alloc_bits = alloc_table[jj]
        let b = bit_alloc[0][i]
        if b != 0 {
          let base = i * 3
          let scale0 = scale_factors[0][base + k]
          let scale1 = scale_factors[1][base + k]
          let qindex = alloc_table[jj + b]
          let bits = mpa_quant_bits[qindex]
          if bits < 0 {
            let v = gb.read(-bits).reinterpret_as_int()
            let steps = mpa_quant_steps[qindex]
            let mant = v % steps
            let v1 = v / steps
            dec.sb_samples[0][(k * 12 + l) * 32 + i] = mpa_l2_unscale_group(
              steps,
              mant,
              scale0,
            )
            dec.sb_samples[1][(k * 12 + l) * 32 + i] = mpa_l2_unscale_group(
              steps,
              mant,
              scale1,
            )
            let mant2 = v1 % steps
            let v2 = v1 / steps
            dec.sb_samples[0][(k * 12 + l + 1) * 32 + i] = mpa_l2_unscale_group(
              steps,
              mant2,
              scale0,
            )
            dec.sb_samples[1][(k * 12 + l + 1) * 32 + i] = mpa_l2_unscale_group(
              steps,
              mant2,
              scale1,
            )
            dec.sb_samples[0][(k * 12 + l + 2) * 32 + i] = mpa_l2_unscale_group(
              steps,
              v2,
              scale0,
            )
            dec.sb_samples[1][(k * 12 + l + 2) * 32 + i] = mpa_l2_unscale_group(
              steps,
              v2,
              scale1,
            )
          } else {
            for m = 0; m < 3; m = m + 1 {
              let mant = gb.read(bits).reinterpret_as_int()
              dec.sb_samples[0][(k * 12 + l + m) * 32 + i] = mpa_l1_unscale(
                bits - 1,
                mant,
                scale0,
              )
              dec.sb_samples[1][(k * 12 + l + m) * 32 + i] = mpa_l1_unscale(
                bits - 1,
                mant,
                scale1,
              )
            }
          }
        } else {
          for m = 0; m < 3; m = m + 1 {
            dec.sb_samples[0][(k * 12 + l + m) * 32 + i] = 0
            dec.sb_samples[1][(k * 12 + l + m) * 32 + i] = 0
          }
        }
        jj = jj + (1 << bit_alloc_bits)
      }
      // Unallocated subbands stay silent.
      for i = sblimit_tab; i < mpa_layer1_subbands; i = i + 1 {
        for ch = 0; ch < nch; ch = ch + 1 {
          dec.sb_samples[ch][(k * 12 + l) * 32 + i] = 0
          dec.sb_samples[ch][(k * 12 + l + 1) * 32 + i] = 0
          dec.sb_samples[ch][(k * 12 + l + 2) * 32 + i] = 0
        }
      }
    }
  }
  Ok(36)
}
