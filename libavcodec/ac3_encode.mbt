/// MoonBit port of FFmpeg 9.0.2's fixed-point AC-3 encoder
/// (`ac3enc.c` + `ac3enc_fixed.c` + `ac3enc_template.c`, ~3.0k lines C).
///
/// The encoder targets the `ac3_fixed` codec: a fully integer pipeline
/// (KBD-windowed int32 MDCT, exponent extraction, masking-curve bit
/// allocation search, mantissa quantization, frame packing with CRC-1/2),
/// which makes the output **bit-exact reproducible** against the docker
/// reference build. Bit allocation helpers (psd / bap) are shared with the
/// AC-3 decoder in `ac3.mbt`; the masking curve is a DBA_NONE specialization
/// of `ff_ac3_bit_alloc_calc_mask` with the encoder's own parameters.
///
/// Original FFmpeg code is LGPL-2.1-or-later (Justin Ruggles); this port
/// keeps the same license.
///
/// Channel indexing follows the C encoder: slot 0 is the coupling channel
/// (CPL_CH), slots 1..fbw_channels are full-bandwidth channels in AC-3
/// order, and the LFE channel (if present) is slot fbw_channels+1.

///|
let ac3e_max_coefs : Int32 = 256

///|
let ac3e_block_size : Int32 = 256

///|
let ac3e_max_blocks : Int32 = 6

///|
let ac3e_frame_size : Int32 = 1536

///|
let ac3e_chmode_mono : Int32 = 1

///|
let ac3e_chmode_stereo : Int32 = 2

///|
/// SMPTE to AC-3 channel map (`ac3_enc_channel_map[acmode][lfe_on]`): the
/// output channel i takes the encoder input plane channel_map[i]. Flattened
/// as [acmode * 2 + lfe_on] with 6 entries each. */
let ac3e_channel_map : FixedArray[FixedArray[Int32]] = [
  // DUALMONO
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  // MONO
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  // STEREO
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  // 3F
  FixedArray::from_array([0, 2, 1, 3, 4, 5]),
  FixedArray::from_array([0, 2, 1, 3, 4, 5]),
  // 2F1R
  FixedArray::from_array([0, 1, 2, 3, 4, 5]),
  FixedArray::from_array([0, 1, 3, 2, 4, 5]),
  // 3F1R
  FixedArray::from_array([0, 2, 1, 3, 4, 5]),
  FixedArray::from_array([0, 2, 1, 4, 3, 5]),
  // 2F2R
  FixedArray::from_array([0, 1, 3, 4, 2, 5]),
  FixedArray::from_array([0, 1, 3, 4, 2, 5]),
  // 3F2R
  FixedArray::from_array([0, 2, 1, 3, 4, 5]),
  FixedArray::from_array([0, 2, 1, 4, 5, 3]),
]

///|
/// LUT for exponent group counts (`exponent_group_tab[cpl][strat-1][nb]`). */
let ac3e_exponent_group_tab : FixedArray[Int32] = {
  // [2][3][256] flattened; strategies EXP_D15=1..EXP_D45=3
  let t : FixedArray[Int32] = FixedArray::make(2 * 3 * 256, 0)
  for expstr = 0; expstr < 3; expstr = expstr + 1 {
    let grpsize = 3 << expstr
    for i = 12; i < 256; i = i + 1 {
      t[(0 * 3 + expstr) * 256 + i] = (i + grpsize - 4) / grpsize
      t[(1 * 3 + expstr) * 256 + i] = i / grpsize
    }
  }
  // LFE
  t[(0 * 3 + 0) * 256 + 7] = 2
  t
}

///|
fn ac3e_group_count(cpl : Int32, strat : Int32, nb_coefs : Int32) -> Int32 {
  ac3e_exponent_group_tab[((if cpl != 0 { 1 } else { 0 }) * 3 + (strat - 1)) *
  256 +
  nb_coefs]
}

///|
let ac3e_exp_d15 : Int32 = 1

///|
let ac3e_exp_d25 : Int32 = 2

///|
let ac3e_exp_d45 : Int32 = 3

///|
/// EXP_REUSE (0) and EXP_NEW (1) come straight from the reuse table; the
/// per-block strategy is refined by `exp_strategy_reuse_tab`. */
let ac3e_exp_reuse : Int32 = 0

///|
let ac3e_exp_new : Int32 = 1

///|
let ac3e_exp_strategy_reuse_tab : FixedArray[Int32] = [
  // [num_blks_code][interval]
  ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15,
  ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15,
  ac3e_exp_d25, ac3e_exp_d25, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15,
  ac3e_exp_d45, ac3e_exp_d25, ac3e_exp_d25, ac3e_exp_d15, ac3e_exp_d15, ac3e_exp_d15,
]

///|
/// New exponent difference threshold. */
let ac3e_exp_diff_threshold : Int32 = 500

///|
/// CRC-16 polynomial (x^16 + x^15 + x^2 + 1). */
let ac3e_crc16_poly : Int32 = (1 << 0) | (1 << 2) | (1 << 15) | (1 << 16)

///|
/// Per-block data. */
priv struct Ac3EncBlock {
  mdct_coef : Array[FixedArray[Int32]]
  exp : Array[FixedArray[Int32]]
  grouped_exp : Array[FixedArray[Int32]]
  psd : Array[FixedArray[Int32]]
  band_psd : Array[FixedArray[Int32]]
  mask : Array[FixedArray[Int32]]
  qmant : Array[FixedArray[Int32]]
  cpl_coord_exp : Array[FixedArray[Int32]]
  cpl_coord_mant : Array[FixedArray[Int32]]
  mut new_rematrixing_strategy : Bool
  mut num_rematrixing_bands : Int32
  rematrixing_flags : FixedArray[Int32]
  mut new_cpl_strategy : Bool
  mut cpl_in_use : Bool
  channel_in_cpl : FixedArray[Int32]
  mut num_cpl_channels : Int32
  new_cpl_coords : FixedArray[Int32]
  cpl_master_exp : FixedArray[Int32]
  mut new_snr_offsets : Bool
  mut new_cpl_leak : Int32
  end_freq : FixedArray[Int32]
}

///|
/// AC3Mant: per-block mantissa grouping state. */
priv struct Ac3EncMant {
  mut mant1_cnt : Int32
  mut mant2_cnt : Int32
  mut mant4_cnt : Int32
  mut qmant1_idx : Int32 // (block, ch) owning slot is unique: store absolute index
  mut qmant2_idx : Int32
  mut qmant4_idx : Int32
  // The qmant pointer in C spans block/ch arrays; here we keep the target
  // array plus index instead.
  mut qmant1_arr : FixedArray[Int32]
  mut qmant2_arr : FixedArray[Int32]
  mut qmant4_arr : FixedArray[Int32]
}

///|
/// The fixed-point AC-3 encoder. */
priv struct Ac3FixedEncoder {
  sample_rate : Int32
  bit_rate : Int32
  channel_mode : Int32
  channels : Int32 // fbw + lfe
  fbw_channels : Int32
  lfe_on : Bool
  lfe_channel : Int32 // fbw+1 when lfe, else -1
  center_mix_level : Int32
  surround_mix_level : Int32
  channel_map : FixedArray[Int32]
  num_blks_code : Int32
  num_blocks : Int32
  frame_size_min : Int32
  mut frame_size : Int32
  frame_size_code : Int32
  bitstream_id : Int32
  bitstream_mode : Int32
  bandwidth_code : Int32
  start_freq : FixedArray[Int32]
  mut cpl_end_freq : Int32
  mut cpl_on : Bool
  cpl_enabled : Bool
  mut num_cpl_subbands : Int32
  mut num_cpl_bands : Int32
  cpl_band_sizes : FixedArray[Int32]
  rematrixing_enabled : Bool
  slow_decay_code : Int32
  fast_decay_code : Int32
  slow_gain_code : Int32
  db_per_bit_code : Int32
  floor_code : Int32
  ba_slow_decay : Int32
  ba_fast_decay : Int32
  ba_slow_gain : Int32
  ba_db_per_bit : Int32
  ba_floor : Int32
  sr_code : Int32
  mut coarse_snr_offset : Int32
  fast_gain_code : FixedArray[Int32]
  fine_snr_offset : FixedArray[Int32]
  mut frame_bits_fixed : Int32
  mut frame_bits : Int32
  mut exponent_bits : Int32
  crc_inv : FixedArray[Int32]
  mut bits_written : Int64
  mut samples_written : Int64
  blocks : Array[Ac3EncBlock]
  exp_strategy : Array[FixedArray[Int32]]
  exp_ref_block : Array[FixedArray[Int32]]
  ref_bap : Array[Array[FixedArray[Int32]]]
  bap_bank0 : Array[Array[FixedArray[Int32]]]
  bap_bank1 : Array[Array[FixedArray[Int32]]]
  mut bap_cur : Bool // true: bank0 is the active write target (C bap_buffer)
  planar_samples : Array[FixedArray[Int32]]
  window : FixedArray[Int32]
  windowed_samples : FixedArray[Int32]
  mdct : Ac3Mdct
  cpl_coords : FixedArray[Int64] // [blk][ch][16]
  energy : FixedArray[Int64] // [blk][ch][16]
}

///|
/// Compute  values (). */
fn ac3e_mul_poly(a0 : Int32, b0 : Int32, poly : Int32) -> Int32 {
  let mut a = a0
  let mut b = b0
  let mut c = 0
  while a != 0 {
    if (a & 1) != 0 {
      c = c ^ b
    }
    a = a >> 1
    b = b << 1
    if (b & (1 << 16)) != 0 {
      b = b ^ poly
    }
  }
  c
}

///|
fn ac3e_pow_poly(a0 : Int32, n0 : Int32, poly : Int32) -> Int32 {
  let mut a = a0
  let mut n = n0
  let mut r = 1
  while n != 0 {
    if (n & 1) != 0 {
      r = ac3e_mul_poly(r, a, poly)
    }
    a = ac3e_mul_poly(a, a, poly)
    n = n >> 1
  }
  r
}

///|
/// Frame size in 16-bit words for [frame_size_code][sr_code]
/// (decoder-shared ac3_frame_size_tab). */
fn ac3e_frame_words(frame_size_code : Int32, sr_code : Int32) -> Int32 {
  ac3_frame_size_tab[frame_size_code][sr_code]
}

///|
/// `av_log2`: index of the highest set bit. */
fn ac3e_log2(v0 : Int32) -> Int32 {
  let mut v = v0
  let mut r = -1
  while v != 0 {
    v = v >> 1
    r += 1
  }
  r
}

///|
fn ac3e_popcount(v0 : Int32) -> Int32 {
  let mut v = v0
  let mut n = 0
  while v != 0 {
    n += v & 1
    v = v >> 1
  }
  n
}

///|
/// Allocate one bap bank: [ch][blk] -> 256 bap slots. */
fn ac3e_make_bap_bank(
  ch_count : Int32,
  num_blocks : Int32,
) -> Array[Array[FixedArray[Int32]]] {
  let bank : Array[Array[FixedArray[Int32]]] = []
  for _ch = 0; _ch <= ch_count; _ch = _ch + 1 {
    let row : Array[FixedArray[Int32]] = []
    for _blk = 0; _blk < num_blocks; _blk = _blk + 1 {
      row.push(FixedArray::make(ac3e_max_coefs, 0))
    }
    bank.push(row)
  }
  bank
}

///|
/// Construct the encoder. `bit_rate_in` of 0 selects the default for the
/// channel count (matching ff_ac3_enc_defaults). */
fn Ac3FixedEncoder::new(
  sample_rate : Int32,
  layout_mask : Int32,
  bit_rate_in : Int32,
) -> Result[Ac3FixedEncoder, String] {
  let lfe_on = (layout_mask & 0x8) != 0 // AV_CH_LOW_FREQUENCY
  let channels_in = ac3e_popcount(layout_mask)
  let fbw_channels = channels_in - (if lfe_on { 1 } else { 0 })
  let lfe_channel = if lfe_on { fbw_channels + 1 } else { -1 }
  let mask_no_lfe = layout_mask & (if lfe_on { -9 } else { -1 })
  let channel_mode : Int32 = if mask_no_lfe == 0x4 {
    ac3e_chmode_mono
  } else if mask_no_lfe == 0x3 {
    ac3e_chmode_stereo
  } else if mask_no_lfe == 0x7 {
    3 // 3F (SURROUND)
  } else if mask_no_lfe == 0x103 {
    4 // 2F1R (2_1)
  } else if mask_no_lfe == 0x107 {
    5 // 3F1R (4POINT0)
  } else if mask_no_lfe == 0x33 || mask_no_lfe == 0x603 {
    6 // 2F2R (QUAD / 2_2)
  } else if mask_no_lfe == 0x607 || mask_no_lfe == 0x37 {
    7 // 3F2R (5POINT0 / 5POINT0_BACK)
  } else {
    return Err("ac3: unsupported channel layout")
  }
  let has_center = (channel_mode & 0x01) != 0 &&
    channel_mode != ac3e_chmode_mono
  let has_surround = (channel_mode & 0x04) != 0
  let channel_map = ac3e_channel_map[channel_mode * 2 +
    (if lfe_on { 1 } else { 0 })]
  // --- sample rate ---
  let mut sr_code = -1
  for i = 0; i < 3; i = i + 1 {
    if ac3_sample_rate_tab[i] == sample_rate {
      sr_code = i
      break
    }
  }
  if sr_code < 0 {
    return Err("ac3: unsupported sample rate")
  }
  // --- bit rate ---
  let bit_rate = if bit_rate_in == 0 {
    match fbw_channels {
      1 => 96000
      2 => 192000
      3 => 320000
      4 => 384000
      _ => 448000
    }
  } else {
    bit_rate_in
  }
  let mut best_code = 0
  let mut best_diff : Int64 = 0x7FFFFFFFFFFFFFFFL
  for i = 0; i < 19; i = i + 1 {
    let br = ac3_bitrate_tab[i] * 1000
    let diff = (br - bit_rate).to_int64().abs()
    if diff < best_diff {
      best_code = i
      best_diff = diff
    }
    if best_diff == 0L {
      break
    }
  }
  let frame_size_code = best_code * 2
  let frame_size_min = 2 * ac3e_frame_words(frame_size_code, sr_code)
  // --- metadata validation (defaults: no production info, no bsi) ---
  let center_mix_level = if has_center {
    2 // default LEVEL_MINUS_4POINT5DB (0.594) -> cmixlev code 2
  } else {
    0
  }
  let surround_mix_level = if has_surround {
    3 // default LEVEL_MINUS_6DB (0.500) -> surmixlev code 3
  } else {
    0
  }
  // --- bandwidth ---
  let bandwidth_code = ac3_enc_bandwidth_tab[(fbw_channels - 1) * 57 +
    sr_code * 19 +
    frame_size_code / 2]
  // --- coupling ---
  let mut cpl_enabled = channel_mode >= ac3e_chmode_stereo
  let mut cpl_start = 0
  if cpl_enabled {
    cpl_start = ac3_enc_coupling_start_tab[(channel_mode - 2) * 57 +
      sr_code * 19 +
      frame_size_code / 2]
    if cpl_start < 0 {
      cpl_enabled = false
    }
  }
  let num_blocks = ac3e_max_blocks
  let ch_count = fbw_channels + (if lfe_on { 1 } else { 0 })
  let end_freq_default = bandwidth_code * 3 + 73
  let start_freq : FixedArray[Int32] = FixedArray::make(7, 0)
  let blocks : Array[Ac3EncBlock] = []
  for _blk = 0; _blk < num_blocks; _blk = _blk + 1 {
    let end_freq : FixedArray[Int32] = FixedArray::make(7, 0)
    for ch = 1; ch <= fbw_channels; ch = ch + 1 {
      end_freq[ch] = end_freq_default
    }
    if lfe_on {
      end_freq[lfe_channel] = 7
    }
    let mdct_coef : Array[FixedArray[Int32]] = []
    let exp : Array[FixedArray[Int32]] = []
    let grouped_exp : Array[FixedArray[Int32]] = []
    let psd : Array[FixedArray[Int32]] = []
    let band_psd : Array[FixedArray[Int32]] = []
    let mask : Array[FixedArray[Int32]] = []
    let qmant : Array[FixedArray[Int32]] = []
    let cpl_coord_exp : Array[FixedArray[Int32]] = []
    let cpl_coord_mant : Array[FixedArray[Int32]] = []
    for ch = 0; ch <= ch_count; ch = ch + 1 {
      mdct_coef.push(FixedArray::make(ac3e_max_coefs, 0))
      exp.push(FixedArray::make(ac3e_max_coefs, 0))
      grouped_exp.push(FixedArray::make(128, 0))
      psd.push(FixedArray::make(ac3e_max_coefs, 0))
      band_psd.push(FixedArray::make(64, 0))
      mask.push(FixedArray::make(64, 0))
      qmant.push(FixedArray::make(ac3e_max_coefs, 0))
      cpl_coord_exp.push(FixedArray::make(16, 0))
      cpl_coord_mant.push(FixedArray::make(16, 0))
    }
    blocks.push({
      mdct_coef,
      exp,
      grouped_exp,
      psd,
      band_psd,
      mask,
      qmant,
      cpl_coord_exp,
      cpl_coord_mant,
      new_rematrixing_strategy: false,
      num_rematrixing_bands: 4,
      rematrixing_flags: FixedArray::make(4, 0),
      new_cpl_strategy: false,
      cpl_in_use: false,
      channel_in_cpl: FixedArray::make(7, 0),
      num_cpl_channels: 0,
      new_cpl_coords: FixedArray::make(7, 0),
      cpl_master_exp: FixedArray::make(7, 0),
      new_snr_offsets: false,
      new_cpl_leak: 0,
      end_freq,
    })
  }
  let planar_samples : Array[FixedArray[Int32]] = []
  for _ch = 0; _ch < channels_in; _ch = _ch + 1 {
    planar_samples.push(FixedArray::make(ac3e_block_size, 0))
  }
  let exp_strategy : Array[FixedArray[Int32]] = []
  let exp_ref_block : Array[FixedArray[Int32]] = []
  let ref_bap : Array[Array[FixedArray[Int32]]] = []
  for _ch = 0; _ch <= ch_count; _ch = _ch + 1 {
    exp_strategy.push(FixedArray::make(num_blocks, 0))
    exp_ref_block.push(FixedArray::make(num_blocks, 0))
    let row : Array[FixedArray[Int32]] = []
    for _blk = 0; _blk < num_blocks; _blk = _blk + 1 {
      row.push(FixedArray::make(ac3e_max_coefs, 0))
    }
    ref_bap.push(row)
  }
  let enc : Ac3FixedEncoder = {
    sample_rate,
    bit_rate,
    channel_mode,
    channels: channels_in,
    fbw_channels,
    lfe_on,
    lfe_channel,
    center_mix_level,
    surround_mix_level,
    channel_map,
    num_blks_code: 0x3,
    num_blocks,
    frame_size_min,
    frame_size: frame_size_min,
    frame_size_code,
    bitstream_id: 8,
    bitstream_mode: 0,
    bandwidth_code,
    start_freq,
    cpl_end_freq: 0,
    cpl_on: false,
    cpl_enabled,
    num_cpl_subbands: 0,
    num_cpl_bands: 0,
    cpl_band_sizes: FixedArray::make(18, 0),
    rematrixing_enabled: channel_mode == ac3e_chmode_stereo,
    slow_decay_code: 2,
    fast_decay_code: 1,
    slow_gain_code: 1,
    db_per_bit_code: 3,
    floor_code: 7,
    ba_slow_decay: ac3_slow_decay_tab[2],
    ba_fast_decay: ac3_fast_decay_tab[1],
    ba_slow_gain: ac3_slow_gain_tab[1],
    ba_db_per_bit: ac3_db_per_bit_tab[3],
    ba_floor: ac3_floor_tab[7],
    sr_code,
    coarse_snr_offset: 40,
    fast_gain_code: FixedArray::make(7, 4),
    fine_snr_offset: FixedArray::make(7, 0),
    frame_bits_fixed: 0,
    frame_bits: 0,
    exponent_bits: 0,
    crc_inv: FixedArray::make(2, 0),
    bits_written: 0L,
    samples_written: 0L,
    blocks,
    exp_strategy,
    exp_ref_block,
    ref_bap,
    bap_bank0: ac3e_make_bap_bank(ch_count, num_blocks),
    bap_bank1: ac3e_make_bap_bank(ch_count, num_blocks),
    bap_cur: true,
    planar_samples,
    window: ac3_kbd_window_fixed(5.0, ac3e_block_size),
    windowed_samples: FixedArray::make(2 * ac3e_block_size, 0),
    mdct: Ac3Mdct::new(),
    cpl_coords: FixedArray::make(ac3e_max_blocks * 7 * 16, 0L),
    energy: FixedArray::make(ac3e_max_blocks * 7 * 16, 0L),
  }
  // --- crc_inv ---
  let mut frame_size_58 = ((enc.frame_size >> 2) + (enc.frame_size >> 4)) << 1
  enc.crc_inv[0] = ac3e_pow_poly(
    ac3e_crc16_poly >> 1,
    8 * frame_size_58 - 16,
    ac3e_crc16_poly,
  )
  if enc.sr_code == 1 {
    frame_size_58 = (((enc.frame_size + 2) >> 2) + ((enc.frame_size + 2) >> 4)) <<
      1
    enc.crc_inv[1] = ac3e_pow_poly(
      ac3e_crc16_poly >> 1,
      8 * frame_size_58 - 16,
      ac3e_crc16_poly,
    )
  }
  // --- count_frame_bits_fixed ---
  enc.count_frame_bits_fixed()
  // --- coupling frequency setup ---
  if enc.cpl_enabled {
    let cpl_end_band = enc.bandwidth_code / 4 + 3
    let upper = if cpl_end_band - 1 < 15 { cpl_end_band - 1 } else { 15 }
    let cpl_start_band = if cpl_start > upper {
      upper
    } else if cpl_start < 0 {
      0
    } else {
      cpl_start
    }
    enc.num_cpl_subbands = cpl_end_band - cpl_start_band
    enc.num_cpl_bands = 1
    enc.cpl_band_sizes[0] = 12
    let mut nb = 1
    for i = cpl_start_band + 1; i < cpl_end_band; i = i + 1 {
      if ac3_enc_cpl_band_struct[i] != 0 {
        enc.cpl_band_sizes[0] += 12
      } else {
        enc.num_cpl_bands += 1
        enc.cpl_band_sizes[nb] = 12
        nb += 1
      }
    }
    enc.start_freq[0] = cpl_start_band * 12 + 37
    enc.cpl_end_freq = cpl_end_band * 12 + 37
    for blk = 0; blk < num_blocks; blk = blk + 1 {
      enc.blocks[blk].end_freq[0] = enc.cpl_end_freq
    }
  }
  Ok(enc)
}

///|
/// `count_frame_bits_fixed` (fixed parameters only, AC-3 branch). */
fn Ac3FixedEncoder::count_frame_bits_fixed(self : Ac3FixedEncoder) -> Unit {
  let frame_bits_inc : FixedArray[Int32] = FixedArray::from_array([
    0, 0, 2, 2, 2, 4, 2, 4,
  ])
  let mut frame_bits = 16
  frame_bits += 49
  frame_bits += frame_bits_inc[self.channel_mode]
  for blk = 0; blk < self.num_blocks; blk = blk + 1 {
    frame_bits += self.fbw_channels // block switch flags
    frame_bits += self.fbw_channels // dither flags
    frame_bits += 1 // dynamic range
    frame_bits += 1 // cplstre
    frame_bits += 2 * self.fbw_channels // exponent strategy
    if self.lfe_on {
      frame_bits += 1
    }
    frame_bits += 1 // bit allocation params
    if blk == 0 {
      frame_bits += 2 + 2 + 2 + 2 + 3
    }
    frame_bits += 1 // snr offsets
    frame_bits += 1 // delta bit allocation
    frame_bits += 1 // skipped data
  }
  frame_bits += 1 // aux data
  frame_bits += 1 + 16 // CRC
  self.frame_bits_fixed = frame_bits
}

///|
/// `ac3_adjust_frame_size` — only used when sr_code == 1 (44.1 kHz). */
fn Ac3FixedEncoder::adjust_frame_size(self : Ac3FixedEncoder) -> Unit {
  while self.bits_written >= self.bit_rate.to_int64() &&
        self.samples_written >= self.sample_rate.to_int64() {
    self.bits_written -= self.bit_rate.to_int64()
    self.samples_written -= self.sample_rate.to_int64()
  }
  let bump = if self.bits_written * self.sample_rate.to_int64() <
    self.samples_written * self.bit_rate.to_int64() {
    1
  } else {
    0
  }
  self.frame_size = self.frame_size_min + 2 * bump
  self.bits_written += self.frame_size.to_int64() * 8L
  self.samples_written += ac3e_block_size.to_int64() *
    self.num_blocks.to_int64()
}
