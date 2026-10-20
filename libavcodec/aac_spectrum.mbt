///|
/// MoonBit port of the AAC (MPEG-4 Audio / AAC-LC) spectral decoding half of
/// FFmpeg 9.0.2 `libavcodec/aac/aacdec_proc_template.c`
/// (`decode_spectrum_and_dequant`, float path), `aacdec.c`'s
/// `decode_scalefactors` and `aacdec_dsp_template.c`'s
/// `dequant_scalefactors` / `apply_tns`, over the tables of
/// `aac_tables.mbt` (extracted from `aactab.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// The C VLC subsystem is replaced by binary tries built from the same
/// `(length, code)` tables (the approach of `h264_cavlc.mbt`); decoded
/// symbols are the packed codebook indices of `ff_aac_codebook_vector_idx`,
/// unpacked exactly the way the float `VMUL{2,4}{,S}` macros do. The C's
/// float sign-bit XOR is expressed as plain sign flips; scalefactors and
/// `n^(4/3)` values keep the float32 table values (exactly representable as
/// Double) while products are computed in Double, which the differential PCM
/// vectors tolerate.

///|
/// One node of a binary VLC trie (`c0`/`c1` are child indices, `-1` = none). */
priv struct AacVlcNode {
  c0 : Int32
  c1 : Int32
  sym : Int32
}

///|
/// A binary VLC trie indexed by consecutive bits starting at the MSB. */
priv struct AacVlc {
  nodes : Array[AacVlcNode]
}

///|
/// Build a decode trie from explicit `(length, code)` VLC tables. */
fn aac_vlc_build(lens : Array[Int32], codes : Array[UInt32]) -> AacVlc {
  let nodes : Array[AacVlcNode] = [{ c0: -1, c1: -1, sym: -1, }]
  for sym = 0; sym < lens.length(); sym = sym + 1 {
    let len = lens[sym]
    if len > 0 {
      let mut node = 0
      for k = len - 1; k >= 0; k = k - 1 {
        let cur = nodes[node]
        let bit = ((codes[sym] >> k) & 1).reinterpret_as_int()
        let next = if bit == 0 { cur.c0 } else { cur.c1 }
        if next < 0 {
          nodes.push({ c0: -1, c1: -1, sym: -1, })
          let idx = nodes.length() - 1
          if bit == 0 {
            nodes[node] = { c0: idx, c1: cur.c1, sym: cur.sym, }
          } else {
            nodes[node] = { c0: cur.c0, c1: idx, sym: cur.sym, }
          }
          node = idx
        } else {
          node = next
        }
      }
      nodes[node] = { c0: nodes[node].c0, c1: nodes[node].c1, sym, }
    }
  }
  { nodes, }
}

///|
/// Decode one symbol; returns -1 on an invalid or truncated code. */
fn AacVlc::decode(self : AacVlc, gb : BitReader) -> Int32 {
  let mut node = 0
  while self.nodes[node].sym < 0 {
    let bit = gb.read1().reinterpret_as_int()
    node = if bit == 0 { self.nodes[node].c0 } else { self.nodes[node].c1 }
    if node < 0 || gb.bits_left() < 0 {
      return -1
    }
  }
  self.nodes[node].sym
}

///|
/// `ff_vlc_scalefactors` (the decoded symbol is the scalefactor code). */
let aac_vlc_scalefactors : AacVlc = aac_vlc_build(
  aac_scalefactor_bits, aac_scalefactor_code,
)

///|
/// `ff_vlc_spectral[0..10]`. */
let aac_vlc_spectral : Array[AacVlc] = [
  aac_vlc_build(aac_bits1, aac_codes1),
  aac_vlc_build(aac_bits2, aac_codes2),
  aac_vlc_build(aac_bits3, aac_codes3),
  aac_vlc_build(aac_bits4, aac_codes4),
  aac_vlc_build(aac_bits5, aac_codes5),
  aac_vlc_build(aac_bits6, aac_codes6),
  aac_vlc_build(aac_bits7, aac_codes7),
  aac_vlc_build(aac_bits8, aac_codes8),
  aac_vlc_build(aac_bits9, aac_codes9),
  aac_vlc_build(aac_bits10, aac_codes10),
  aac_vlc_build(aac_bits11, aac_codes11),
]

///|
/// `SCALE_DIFF_ZERO` (`aac.h`). */
let aac_scale_diff_zero : Int32 = 60

///|
/// `NOISE_PRE` / `NOISE_PRE_BITS` / `NOISE_OFFSET`. */
let aac_noise_pre : Int32 = 256

///|
let aac_noise_pre_bits : Int32 = 9

///|
let aac_noise_offset : Int32 = 90

///|
/// `POW_SF2_ZERO` (`aac.h`): index of 2^0 in `ff_aac_pow2sf_tab`. */
let aac_pow_sf2_zero : Int32 = 200

///|
/// `decode_scalefactors` (spec 4.6.2.3.2): differential coding per band, a
/// 9-bit noise preamble before the first noise band, clipped intensity /
/// noise positions. Returns the raw `sfo` values (input to
/// `aac_sf_dequant`). */
pub fn aac_decode_scalefactors(
  gb : BitReader,
  info : AacIcsInfo,
  sect_cb : Array[Array[Int32]],
  global_gain : Int32,
) -> Result[Array[Array[Int32]], String] {
  // offset[0] regular, [1] noise, [2] intensity.
  let mut offset0 : Int32 = global_gain
  let mut offset1 = offset0 - aac_noise_offset
  let mut offset2 = 0
  let mut noise_flag = true
  let sfo : Array[Array[Int32]] = []
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let row : Array[Int32] = Array::make(info.max_sfb, 0)
    for sfb = 0; sfb < info.max_sfb; sfb = sfb + 1 {
      let cb = sect_cb[g][sfb]
      if cb == 0 {
        row[sfb] = 0
      } else if cb == 14 || cb == 15 {
        // INTENSITY_BT2 / INTENSITY_BT
        let v = aac_vlc_scalefactors.decode(gb)
        if v < 0 {
          return Err("invalid scalefactor code")
        }
        offset2 = offset2 + v - aac_scale_diff_zero
        let clipped = if offset2 < -155 {
          -155
        } else if offset2 > 100 {
          100
        } else {
          offset2
        }
        row[sfb] = clipped - 100
      } else if cb == 13 {
        // NOISE_BT: the first noise band carries a 9-bit preamble.
        if noise_flag {
          noise_flag = false
          offset1 = offset1 +
            gb.read(aac_noise_pre_bits).reinterpret_as_int() -
            aac_noise_pre
        } else {
          let v = aac_vlc_scalefactors.decode(gb)
          if v < 0 {
            return Err("invalid scalefactor code")
          }
          offset1 = offset1 + v - aac_scale_diff_zero
        }
        let clipped = if offset1 < -100 {
          -100
        } else if offset1 > 155 {
          155
        } else {
          offset1
        }
        row[sfb] = clipped
      } else {
        let v = aac_vlc_scalefactors.decode(gb)
        if v < 0 {
          return Err("invalid scalefactor code")
        }
        offset0 = offset0 + v - aac_scale_diff_zero
        if offset0 > 255 || offset0 < 0 {
          return Err("scalefactor out of range")
        }
        row[sfb] = offset0 - 100
      }
    }
    sfo.push(row)
  }
  Ok(sfo)
}

///|
/// `dequant_scalefactors` (float): `sf = ±2^(sfo/4)` per band type, with
/// the intensity position negated (`POW_SF2_ZERO` indexes the zero). */
pub fn aac_sf_dequant(
  info : AacIcsInfo,
  sect_cb : Array[Array[Int32]],
  sfo : Array[Array[Int32]],
) -> Array[Array[Double]] {
  let sf : Array[Array[Double]] = []
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let row : Array[Double] = Array::make(info.max_sfb, 0.0)
    for sfb = 0; sfb < info.max_sfb; sfb = sfb + 1 {
      let cb = sect_cb[g][sfb]
      let v = sfo[g][sfb]
      row[sfb] = if cb == 0 {
        0.0
      } else if cb == 14 || cb == 15 {
        aac_pow2sf[-v - 100 + aac_pow_sf2_zero]
      } else {
        // Noise and regular bands share `-ff_aac_pow2sf_tab[sfo + 200]`.
        -aac_pow2sf[v + aac_pow_sf2_zero]
      }
    }
    sf.push(row)
  }
  sf
}

///|
/// `lcg_random` (`aacdec_proc_template.c`): the spectral noise generator. */
fn aac_lcg_random(prev : Int32) -> Int32 {
  (prev.reinterpret_as_uint() * 1664525U + 1013904223U).reinterpret_as_int()
}

///|
/// PNS noise state (`ac->random_state`, seeded 0x1f2e3d4c in decode_init). */
pub struct AacSpectrumState {
  mut random_state : Int32
}

///|
pub fn new_aac_spectrum_state() -> AacSpectrumState {
  { random_state: 0x1f2e3d4c, }
}

///|
/// Scalefactor band geometry for one sampling index: the long (1024) and
/// short (128) window offset tables, their band counts and the TNS band
/// limits. */
pub struct AacSwb {
  offsets_long : Array[UInt32]
  num_long : Int32
  offsets_short : Array[UInt32]
  num_short : Int32
  /// `ff_tns_max_bands_1024/128` per sampling index.
  tns_max_long : Int32
  tns_max_short : Int32
}

///|
/// `ff_swb_offset_1024/128` and `ff_aac_num_swb_1024/128` per sampling
/// index (0..11; the escape index 12 shares the 96000 Hz entry like the C
/// pointer tables). */
pub fn aac_swb_tables(sampling_index : Int32) -> Result[AacSwb, String] {
  if sampling_index < 0 || sampling_index > 12 {
    return Err("invalid sampling index")
  }
  let i = sampling_index
  Ok({
    offsets_long: aac_swb_offset_1024[i],
    num_long: aac_num_swb_1024[i],
    offsets_short: aac_swb_offset_128[i],
    num_short: aac_num_swb_128[i],
    tns_max_long: aac_tns_max_bands_1024[i],
    tns_max_short: aac_tns_max_bands_128[i],
  })
}

///|
/// `decode_spectrum_and_dequant` (float path, spec 4.6.2.3.3 / 4.6.3.3):
/// Huffman-decode every section into `coeffs` (window `w` at `w*128`) and
/// multiply by the band's scalefactor on the fly. Intensity bands (14/15)
/// zero the coefficients; noise bands (13) fill scaled `lcg_random` values
/// with unit band energy. */
pub fn aac_decode_spectrum(
  gb : BitReader,
  info : AacIcsInfo,
  swb : AacSwb,
  sect_cb : Array[Array[Int32]],
  sf : Array[Array[Double]],
  noise : AacSpectrumState,
  coeffs : Array[Double],
) -> Result[Unit, String] {
  let is8 = info.window_sequence == aac_eight_short
  let src = if is8 { swb.offsets_short } else { swb.offsets_long }
  let offsets : Array[Int32] = []
  for k = 0; k < src.length(); k = k + 1 {
    offsets.push(src[k].reinterpret_as_int())
  }
  let c = 1024 / info.num_windows
  let max_sfb = info.max_sfb
  // Tail beyond max_sfb is zero for every window.
  for g = 0; g < info.num_windows; g = g + 1 {
    for k = offsets[max_sfb]; k < c; k = k + 1 {
      coeffs[g * 128 + k] = 0.0
    }
  }
  let mut base = 0
  for g = 0; g < info.num_window_groups; g = g + 1 {
    let g_len = info.window_group_length[g]
    for i = 0; i < max_sfb; i = i + 1 {
      let cb = sect_cb[g][i]
      // `cbt_m1` is unsigned in the C: ZERO_BT (0) - 1 wraps around and
      // takes the intensity (zero-fill) path below.
      let cbt_m1 = cb - 1
      let start = offsets[i]
      let off_len = offsets[i + 1] - start
      let mut cfo = base + start
      if cbt_m1 >= 13 || cbt_m1 < 0 {
        // INTENSITY_BT2 / INTENSITY_BT: no spectral data.
        for _grp = 0; _grp < g_len; _grp = _grp + 1 {
          for k = 0; k < off_len; k = k + 1 {
            coeffs[cfo + k] = 0.0
          }
          cfo = cfo + 128
        }
      } else if cbt_m1 == 12 {
        // NOISE_BT (PNS): scaled white noise, unit energy per band.
        let s = sf[g][i]
        for _grp = 0; _grp < g_len; _grp = _grp + 1 {
          let mut energy = 0.0
          for k = 0; k < off_len; k = k + 1 {
            noise.random_state = aac_lcg_random(noise.random_state)
            coeffs[cfo + k] = noise.random_state.to_double()
            energy = energy + coeffs[cfo + k] * coeffs[cfo + k]
          }
          let scale = s / energy.sqrt()
          for k = 0; k < off_len; k = k + 1 {
            coeffs[cfo + k] = coeffs[cfo + k] * scale
          }
          cfo = cfo + 128
        }
      } else {
        let vlc = aac_vlc_spectral[cbt_m1]
        let vals = aac_book_vals[cbt_m1]
        // The VLC symbols are the packed codebook indices
        // (`ff_aac_codebook_vector_idx`), not the table row.
        let idxs = aac_book_idx[cbt_m1]
        let s = sf[g][i]
        match cbt_m1 >> 1 {
          0 =>
            // Books 1, 2: unsigned 4-tuples, 2-bit value indices (`VMUL4`).
            for _grp = 0; _grp < g_len; _grp = _grp + 1 {
              let mut cf = cfo
              let mut len = off_len
              while len > 0 {
                let row = vlc.decode(gb)
                if row < 0 || row >= aac_spectral_sizes[cbt_m1] {
                  return Err("invalid spectral code")
                }
                let idx = idxs[row].reinterpret_as_int()
                coeffs[cf] = vals[idx & 3] * s
                coeffs[cf + 1] = vals[(idx >> 2) & 3] * s
                coeffs[cf + 2] = vals[(idx >> 4) & 3] * s
                coeffs[cf + 3] = vals[(idx >> 6) & 3] * s
                cf = cf + 4
                len = len - 4
              }
              cfo = cfo + 128
            }
          1 =>
            // Books 3, 4: 4-tuples with signs (`VMUL4S`): the sign bits are
            // consumed in value order by the non-zero values.
            for _grp = 0; _grp < g_len; _grp = _grp + 1 {
              let mut cf = cfo
              let mut len = off_len
              while len > 0 {
                let row = vlc.decode(gb)
                if row < 0 || row >= aac_spectral_sizes[cbt_m1] {
                  return Err("invalid spectral code")
                }
                let idx = idxs[row].reinterpret_as_int()
                let nnz = (idx >> 8) & 15
                let signs = aac_read_sign_bits(gb, nnz)
                let mut sign_left = nnz
                for j = 0; j < 4; j = j + 1 {
                  let vi = (idx >> (2 * j)) & 3
                  let v = vals[vi] * s
                  if vi != 0 && sign_left > 0 {
                    if ((signs >> (sign_left - 1)) & 1) != 0 {
                      coeffs[cf + j] = -v
                    } else {
                      coeffs[cf + j] = v
                    }
                    sign_left = sign_left - 1
                  } else {
                    coeffs[cf + j] = v
                  }
                }
                cf = cf + 4
                len = len - 4
              }
              cfo = cfo + 128
            }
          2 =>
            // Books 5, 6: unsigned pairs, 4-bit value indices (`VMUL2`).
            for _grp = 0; _grp < g_len; _grp = _grp + 1 {
              let mut cf = cfo
              let mut len = off_len
              while len > 0 {
                let row = vlc.decode(gb)
                if row < 0 || row >= aac_spectral_sizes[cbt_m1] {
                  return Err("invalid spectral code")
                }
                let idx = idxs[row].reinterpret_as_int()
                coeffs[cf] = vals[idx & 15] * s
                coeffs[cf + 1] = vals[(idx >> 4) & 15] * s
                cf = cf + 2
                len = len - 2
              }
              cfo = cfo + 128
            }
          3 | 4 =>
            // Books 7..10: pairs with signs (`VMUL2S`).
            for _grp = 0; _grp < g_len; _grp = _grp + 1 {
              let mut cf = cfo
              let mut len = off_len
              while len > 0 {
                let row = vlc.decode(gb)
                if row < 0 || row >= aac_spectral_sizes[cbt_m1] {
                  return Err("invalid spectral code")
                }
                let idx = idxs[row].reinterpret_as_int()
                let nnz = (idx >> 8) & 15
                let signs = aac_read_sign_bits(gb, nnz)
                let mut sign_left = nnz
                for j = 0; j < 2; j = j + 1 {
                  let vi = (idx >> (4 * j)) & 15
                  let v = vals[vi] * s
                  if vi != 0 && sign_left > 0 {
                    if ((signs >> (sign_left - 1)) & 1) != 0 {
                      coeffs[cf + j] = -v
                    } else {
                      coeffs[cf + j] = v
                    }
                    sign_left = sign_left - 1
                  } else {
                    coeffs[cf + j] = v
                  }
                }
                cf = cf + 2
                len = len - 2
              }
              cfo = cfo + 128
            }
          _ =>
            // Book 11: pairs with escape sequences (`ff_cbrt_tab[n]` holds
            // float32(n^(4/3))); the band is scaled afterwards like the C's
            // closing `vector_fmul_scalar`.
            for _grp = 0; _grp < g_len; _grp = _grp + 1 {
              let mut cf = cfo
              let mut len = off_len
              while len > 0 {
                let row = vlc.decode(gb)
                if row < 0 || row >= aac_spectral_sizes[cbt_m1] {
                  return Err("invalid spectral code")
                }
                let idx = idxs[row].reinterpret_as_int()
                if idx == 0 {
                  coeffs[cf] = 0.0
                  coeffs[cf + 1] = 0.0
                  cf = cf + 2
                  len = len - 2
                  continue
                }
                let nnz = idx >> 12
                let nzt = (idx >> 8) & 15
                let signs = aac_read_sign_bits(gb, nnz)
                let mut sign_left = nnz
                let mut cb_idx = idx
                for j = 0; j < 2; j = j + 1 {
                  let is_escape = (nzt & (1 << j)) != 0
                  let mut v : Double = 0.0
                  if is_escape {
                    // escape_sequence: count the 1s before the first 0
                    // (max 8), then b = count + 4 magnitude bits and
                    // n = 2^b + bits.
                    let mut b = 0
                    while gb.read1().reinterpret_as_int() != 0 {
                      b = b + 1
                      if b > 8 {
                        return Err("error in spectral data, ESC overflow")
                      }
                    }
                    b = b + 4
                    let n = (1 << b) + gb.read(b).reinterpret_as_int()
                    if n >= aac_pow43.length() {
                      return Err("error in spectral data, ESC overflow")
                    }
                    v = aac_pow43[n]
                  } else {
                    v = vals[cb_idx & 15]
                  }
                  cb_idx = cb_idx >> 4
                  if v != 0.0 && sign_left > 0 {
                    if ((signs >> (sign_left - 1)) & 1) != 0 {
                      v = -v
                    }
                    sign_left = sign_left - 1
                  }
                  coeffs[cf + j] = v
                }
                cf = cf + 2
                len = len - 2
              }
              for k = 0; k < off_len; k = k + 1 {
                coeffs[cfo + k] = coeffs[cfo + k] * s
              }
              cfo = cfo + 128
            }
        }
      }
    }
    base = base + g_len * 128
  }
  Ok(())
}

///|
/// Read `n` bits and pack them so that the first-read bit is the MSB of the
/// result (`SHOW_UBITS` semantics used by the sign-bit macros). */
fn aac_read_sign_bits(gb : BitReader, n : Int32) -> Int32 {
  let mut v = 0
  for _i = 0; _i < n; _i = _i + 1 {
    v = (v << 1) | gb.read1().reinterpret_as_int()
  }
  v
}

///|
/// `decode_pulses` position checks, deferred from syntax parsing until
/// the actual sampling-rate SWB table is available. The full long-window
/// band count, not max_sfb, bounds the encoded start and positions.
fn aac_resolve_pulses(pulse : AacPulse, swb : AacSwb) -> Result[Array[Int32], String] {
  if pulse.offsets.length() == 0 { return Ok([]) }
  if pulse.start_sfb >= swb.num_long {
    return Err("pulse start band out of range")
  }
  let positions : Array[Int32] = []
  let mut pos = swb.offsets_long[pulse.start_sfb].reinterpret_as_int()
  for i = 0; i < pulse.offsets.length(); i = i + 1 {
    pos = pos + pulse.offsets[i]
    if pos >= swb.offsets_long[swb.num_long].reinterpret_as_int() {
      return Err("pulse position out of range")
    }
    positions.push(pos)
  }
  Ok(positions)
}

///|
/// Float `decode_spectrum_and_dequant` pulse reconstruction. Undo the
/// 4/3 power, add the pulse in the quantized domain, then dequantize
/// again. Noise and zero-scale bands are unchanged; repeated positions
/// deliberately see the coefficient changed by the previous pulse.
fn aac_apply_pulses(
  coeffs : Array[Double],
  pulse : AacPulse,
  positions : Array[Int32],
  swb : AacSwb,
  sect_cb : Array[Array[Int32]],
  sf : Array[Array[Double]],
) -> Unit {
  let mut band = 0
  for i = 0; i < positions.length(); i = i + 1 {
    let pos = positions[i]
    while swb.offsets_long[band + 1].reinterpret_as_int() <= pos {
      band = band + 1
    }
    // FFmpeg initializes band_type and sf beyond max_sfb to zero.
    if band >= sf[0].length() || sect_cb[0][band] == 13 || sf[0][band] == 0.0 {
      continue
    }
    let scale = sf[0][band]
    let mut co = coeffs[pos]
    let mut ico = -pulse.amp[i].to_double()
    if co != 0.0 {
      co = co / scale
      ico = co / co.abs().sqrt().sqrt() + (if co > 0.0 { -ico } else { ico })
    }
    coeffs[pos] = @math.cbrt(ico.abs()) * ico * scale
  }
}

///|
/// `tns_decode_coef`'s `compute_lpc_coefs(..., lpc_stride = 0,
/// normalize = 0)`: the Levinson recursion expanding the quantized TNS
/// coefficients into predictor coefficients, in place (the float path's
/// `LPC_SRA_R`/`LPC_MUL26` are identities). */
fn aac_tns_lpc(coef : Array[Double], order : Int32) -> Array[Double] {
  let n = order
  let lpc : Array[Double] = Array::make(n, 0.0)
  for i = 0; i < n; i = i + 1 {
    let r = -coef[i]
    lpc[i] = r
    let mut j = 0
    while j < (i + 1) / 2 {
      let f = lpc[j]
      let b = lpc[i - 1 - j]
      lpc[j] = f + r * b
      lpc[i - 1 - j] = b + r * f
      j = j + 1
    }
  }
  lpc
}

///|
/// `apply_tns` (`aacdec_dsp_template.c`): per window, filters run bottom-up
/// over the band range derived from `length` and `tns_max_bands`; each is an
/// in-place AR filter over `size` samples walking with `inc` (+1 or -1 per
/// `direction`), subtracting `lpc[i-1] * coef[start - i*inc]` causally. */
pub fn aac_apply_tns(
  coeffs : Array[Double],
  tns : AacTns,
  info : AacIcsInfo,
  swb : AacSwb,
) -> Unit {
  let is8 = info.window_sequence == aac_eight_short
  let src = if is8 { swb.offsets_short } else { swb.offsets_long }
  let offsets : Array[Int32] = []
  for k = 0; k < src.length(); k = k + 1 {
    offsets.push(src[k].reinterpret_as_int())
  }
  let max_bands = if is8 { swb.tns_max_short } else { swb.tns_max_long }
  let mmm = if max_bands < info.max_sfb { max_bands } else { info.max_sfb }
  if mmm <= 0 {
    return
  }
  let num_swb = offsets.length() - 1
  for w = 0; w < info.num_windows; w = w + 1 {
    let mut bottom = num_swb
    for filt = 0; filt < tns.n_filt[w]; filt = filt + 1 {
      let top = bottom
      bottom = top - tns.filters[w][filt].length
      if bottom < 0 {
        bottom = 0
      }
      let order = tns.filters[w][filt].order
      if order == 0 {
        continue
      }
      let b = if bottom < mmm { bottom } else { mmm }
      let t = if top < mmm { top } else { mmm }
      let start = offsets[b]
      let end = offsets[t]
      let size = end - start
      if size <= 0 {
        continue
      }
      let lpc = aac_tns_lpc(tns.filters[w][filt].coef, order)
      let inc = if tns.filters[w][filt].direction != 0 { -1 } else { 1 }
      let mut st = if tns.filters[w][filt].direction != 0 {
        w * 128 + end - 1
      } else {
        w * 128 + start
      }
      for m = 0; m < size; m = m + 1 {
        let lim = if m < order { m } else { order }
        for i = 1; i <= lim; i = i + 1 {
          coeffs[st] = coeffs[st] - coeffs[st - i * inc] * lpc[i - 1]
        }
        st = st + inc
      }
    }
  }
}
