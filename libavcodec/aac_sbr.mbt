///|
/// MoonBit port of the bitstream-syntax half of FFmpeg 9.0.2 AAC Spectral
/// Band Replication: `libavcodec/aacsbr_template.c` (read_sbr_header,
/// sbr_make_f_master / f_derived / hf_calc_npatches / f_tablelim,
/// read_sbr_grid/dtdf/invf/envelope/noise/data/extension,
/// ff_aac_sbr_decode_extension) for the float (USE_FIXED 0) instance.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Implementation notes:
///   * Float-typed C arithmetic is done in Double; `make_bands`'s running
///     product stays in Float (f32) because its `lrintf` rounding must match
///     the C bit-exactly (integer outputs).
///   * `env_facs_q` / `noise_facs_q` are `uint8_t` in the C: delta paths wrap
///     modulo 256 before the `> 127U` / `> 30U` range checks are applied to
///     the wrapped value; this port mirrors the wrap explicitly.
///   * USAC SBR entry points (`ff_aac_sbr_decode_usac_data`) are not ported;
///     the legacy MPEG-4 extension payload path is.

///|
/// `SBR_SYNTHESIS_BUF_SIZE` = (1280-128)*2.
let aac_sbr_synthesis_buf_size : Int32 = 2304

///|
/// Element type ids this SBR state was configured for (TYPE_SCE..).
pub struct AacSbrSpectrumParams {
  mut bs_start_freq : Int32
  mut bs_stop_freq : Int32
  mut bs_xover_band : Int32
  mut bs_freq_scale : Int32
  mut bs_alter_scale : Int32
  mut bs_noise_bands : Int32
}

///|
fn aac_sbr_spectrum_params_equal(
  a : AacSbrSpectrumParams,
  b : AacSbrSpectrumParams,
) -> Bool {
  a.bs_start_freq == b.bs_start_freq &&
  a.bs_stop_freq == b.bs_stop_freq &&
  a.bs_xover_band == b.bs_xover_band &&
  a.bs_freq_scale == b.bs_freq_scale &&
  a.bs_alter_scale == b.bs_alter_scale &&
  a.bs_noise_bands == b.bs_noise_bands
}

///|
/// Per-channel SBR data (`SBRData`); the big DSP buffers are flat arrays
/// laid out exactly as the C's multidimensional arrays.
pub struct AacSbrData {
  mut bs_frame_class : Int32
  mut bs_add_harmonic_flag : Int32
  mut bs_num_env : Int32
  bs_freq_res : Array[Int32]
  mut bs_num_noise : Int32
  bs_df_env : Array[Int32]
  bs_df_noise : Array[Int32]
  bs_invf_mode : Array[Array[Int32]]
  bs_add_harmonic : Array[Int32]
  mut bs_amp_res : Int32
  synthesis_filterbank_samples : Array[Double]
  analysis_filterbank_samples : Array[Double]
  mut synthesis_filterbank_samples_offset : Int32
  e_a : Array[Int32]
  bw_array : Array[Double]
  /// w_buf[buf][i][k][c] flattened: ((((buf*32)+i)*32+k)*2+c).
  w_buf : Array[Double]
  mut ypos : Int32
  /// y_buf[pos][i][m][c] flattened.
  y_buf : Array[Double]
  g_temp : Array[Double]
  q_temp : Array[Double]
  s_indexmapped : Array[Int32]
  env_facs_q : Array[Int32]
  env_facs : Array[Double]
  noise_facs_q : Array[Int32]
  noise_facs : Array[Double]
  t_env : Array[Int32]
  mut t_env_num_env_old : Int32
  t_q : Array[Int32]
  mut f_indexnoise : Int32
  mut f_indexsine : Int32
}

///|
fn aac_new_sbr_data() -> AacSbrData {
  {
    bs_frame_class: 0,
    bs_add_harmonic_flag: 0,
    bs_num_env: 0,
    bs_freq_res: Array::make(9, 0),
    bs_num_noise: 0,
    bs_df_env: Array::make(9, 0),
    bs_df_noise: Array::make(2, 0),
    bs_invf_mode: [Array::make(5, 0), Array::make(5, 0)],
    bs_add_harmonic: Array::make(48, 0),
    bs_amp_res: 0,
    synthesis_filterbank_samples: Array::make(aac_sbr_synthesis_buf_size, 0.0),
    analysis_filterbank_samples: Array::make(1312, 0.0),
    synthesis_filterbank_samples_offset: aac_sbr_synthesis_buf_size -
    (1280 - 128),
    e_a: Array::make(2, 0),
    bw_array: Array::make(5, 0.0),
    w_buf: Array::make(2 * 32 * 32 * 2, 0.0),
    ypos: 0,
    y_buf: Array::make(2 * 38 * 64 * 2, 0.0),
    g_temp: Array::make(42 * 48, 0.0),
    q_temp: Array::make(42 * 48, 0.0),
    s_indexmapped: Array::make(9 * 48, 0),
    env_facs_q: Array::make(9 * 48, 0),
    env_facs: Array::make(9 * 48, 0.0),
    noise_facs_q: Array::make(3 * 5, 0),
    noise_facs: Array::make(3 * 5, 0.0),
    t_env: Array::make(9, 0),
    t_env_num_env_old: 0,
    t_q: Array::make(3, 0),
    f_indexnoise: 0,
    f_indexsine: 0,
  }
}

///|
/// `SpectralBandReplication` state owned by one channel element.
pub struct AacSbr {
  mut sample_rate : Int32
  mut core_sample_rate : Int32
  mut start : Bool
  mut ready_for_dequant : Bool
  mut id_aac : Int32
  mut reset : Bool
  spectrum_params : AacSbrSpectrumParams
  mut bs_amp_res_header : Int32
  mut bs_limiter_bands : Int32
  mut bs_limiter_gains : Int32
  mut bs_interpol_freq : Int32
  mut bs_smoothing_mode : Int32
  mut bs_coupling : Int32
  /// k[0], k[1], k[2] (k0, k1, k2 of the spec).
  k : Array[Int32]
  /// kx', kx.
  kx : Array[Int32]
  /// M', M.
  m : Array[Int32]
  mut kx_and_m_pushed : Bool
  mut n_master : Int32
  data : Array[AacSbrData]
  /// N_Low, N_High.
  n : Array[Int32]
  mut n_q : Int32
  mut n_lim : Int32
  f_master : Array[Int32]
  f_tablelow : Array[Int32]
  f_tablehigh : Array[Int32]
  f_tablenoise : Array[Int32]
  f_tablelim : Array[Int32]
  mut num_patches : Int32
  patch_num_subbands : Array[Int32]
  patch_start_subband : Array[Int32]
  /// x_low[k][i][c] flattened.
  x_low : Array[Double]
  /// x_high[k][i][c] flattened.
  x_high : Array[Double]
  /// X[ch][x][i][k] flattened.
  x_qmf : Array[Double]
  alpha0 : Array[Double]
  alpha1 : Array[Double]
  e_origmapped : Array[Double]
  q_mapped : Array[Double]
  s_mapped : Array[Int32]
  e_curr : Array[Double]
  q_m : Array[Double]
  s_m : Array[Double]
  gain : Array[Double]
  qmf_filter_scratch : Array[Double]
  /// Embedded Parametric Stereo context (`sbr->ps` of `SpectralBandReplication`).
  ps : AacPs
  /// Whether a PS extension payload is legal in this stream (`m4ac.ps != 0`).
  mut ps_allowed : Bool
}

///|
/// `ff_aac_sbr_ctx_alloc_init` for the parser half (DSP buffers zeroed).
pub fn aac_new_sbr(id_aac : Int32) -> AacSbr {
  let sbr : AacSbr = {
    sample_rate: 0,
    core_sample_rate: 0,
    start: false,
    ready_for_dequant: false,
    id_aac,
    reset: false,
    spectrum_params: {
      bs_start_freq: 0,
      bs_stop_freq: 0,
      bs_xover_band: 0,
      bs_freq_scale: 0,
      bs_alter_scale: 0,
      bs_noise_bands: 0,
    },
    bs_amp_res_header: 0,
    bs_limiter_bands: 0,
    bs_limiter_gains: 0,
    bs_interpol_freq: 0,
    bs_smoothing_mode: 0,
    bs_coupling: 0,
    k: Array::make(5, 0),
    kx: [32, 32],
    m: [0, 0],
    kx_and_m_pushed: false,
    n_master: 0,
    data: [aac_new_sbr_data(), aac_new_sbr_data()],
    n: [0, 0],
    n_q: 0,
    n_lim: 0,
    f_master: Array::make(49, 0),
    f_tablelow: Array::make(25, 0),
    f_tablehigh: Array::make(49, 0),
    f_tablenoise: Array::make(6, 0),
    f_tablelim: Array::make(30, 0),
    num_patches: 0,
    patch_num_subbands: Array::make(6, 0),
    patch_start_subband: Array::make(6, 0),
    x_low: Array::make(32 * 40 * 2, 0.0),
    x_high: Array::make(64 * 40 * 2, 0.0),
    x_qmf: Array::make(2 * 2 * 38 * 64, 0.0),
    alpha0: Array::make(64 * 2, 0.0),
    alpha1: Array::make(64 * 2, 0.0),
    e_origmapped: Array::make(8 * 48, 0.0),
    q_mapped: Array::make(8 * 48, 0.0),
    s_mapped: Array::make(8 * 48, 0),
    e_curr: Array::make(8 * 48, 0.0),
    q_m: Array::make(8 * 48, 0.0),
    s_m: Array::make(8 * 48, 0.0),
    gain: Array::make(8 * 48, 0.0),
    qmf_filter_scratch: Array::make(5 * 64, 0.0),
    ps: aac_ps_new(),
    ps_allowed: false,
  }
  // `sbr_turnoff` half of ctx init: defaults for pure upsampling mode.
  sbr.data[0].e_a[1] = -1
  sbr.data[1].e_a[1] = -1
  sbr.spectrum_params.bs_start_freq = -1
  sbr.spectrum_params.bs_stop_freq = -1
  sbr.spectrum_params.bs_xover_band = -1
  sbr.spectrum_params.bs_freq_scale = -1
  sbr.spectrum_params.bs_alter_scale = -1
  sbr.spectrum_params.bs_noise_bands = -1
  sbr
}

///|
/// `sbr_turnoff`: pure upsampling mode with first-header reset defaults.
fn AacSbr::turnoff(self : AacSbr) -> Unit {
  self.start = false
  self.ready_for_dequant = false
  self.kx[1] = 32 // Typo in spec, kx' inits to 32
  self.m[1] = 0
  self.data[0].e_a[1] = -1
  self.data[1].e_a[1] = -1
  self.spectrum_params.bs_start_freq = -1
  self.spectrum_params.bs_stop_freq = -1
  self.spectrum_params.bs_xover_band = -1
  self.spectrum_params.bs_freq_scale = -1
  self.spectrum_params.bs_alter_scale = -1
  self.spectrum_params.bs_noise_bands = -1
}

///|
/// Huffman VLC tables built once: key `(len << 20) | code` -> symbol with
/// the table's `sbr_vlc_offsets` added (aacdec_tab.c `init_sbr_tables`,
/// codes assigned in table order by `ff_vlc_init_from_lengths`).
let aac_sbr_vlc_maps : Array[Map[Int32, Int32]] = {
  let maps : Array[Map[Int32, Int32]] = []
  let mut base = 0
  for t in 0..<10 {
    let m : Map[Int32, Int32] = Map([])
    let n = aac_sbr_huffman_nb_codes[t]
    let mut code : Int64 = 0L
    for i in 0..<n {
      let sym = aac_sbr_huffman_tab[base + i].0
      let len = aac_sbr_huffman_tab[base + i].1
      let assigned = code >> (32 - len)
      m[(len << 20) | assigned.to_int()] = sym + aac_sbr_vlc_offsets[t]
      code = code + (1L << (32 - len))
    }
    maps.push(m)
    base = base + n
  }
  maps
}

///|
/// `get_vlc2` over one of the ten SBR codebooks: bit-by-bit canonical
/// decode (the C's 9-bit table lookups are an implementation detail).
fn aac_sbr_vlc_decode(gb : BitReader, table : Int32) -> Result[Int32, String] {
  let m = aac_sbr_vlc_maps[table]
  let mut v = 0
  for len in 1..<=24 {
    v = (v << 1) | gb.read(1).reinterpret_as_int()
    match m.get((len << 20) | v) {
      Some(sym) => return Ok(sym)
      None => continue
    }
  }
  Err("SBR Huffman code is longer than 24 bits")
}

///|
/// Huffman codebook indices (`aacsbr.h` enum, AAC SBR VLC order).
let aac_sbr_t_huffman_env_1_5db : Int32 = 0

///|
let aac_sbr_f_huffman_env_1_5db : Int32 = 1

///|
let aac_sbr_t_huffman_env_bal_1_5db : Int32 = 2

///|
let aac_sbr_f_huffman_env_bal_1_5db : Int32 = 3

///|
let aac_sbr_t_huffman_env_3_0db : Int32 = 4

///|
let aac_sbr_f_huffman_env_3_0db : Int32 = 5

///|
let aac_sbr_t_huffman_env_bal_3_0db : Int32 = 6

///|
let aac_sbr_f_huffman_env_bal_3_0db : Int32 = 7

///|
let aac_sbr_t_huffman_noise_3_0db : Int32 = 8

///|
let aac_sbr_t_huffman_noise_bal_3_0db : Int32 = 9

///|
/// `lrintf` under the default FE_TONEAREST rounding mode: round half to
/// even. Boundary ties only arise from exact values, never from the
/// transcendental inputs of `make_bands`, so this matches the C.
fn aac_lrintf(x : Double) -> Int32 {
  let f = @math.floor(x)
  let diff = x - f
  if diff > 0.5 {
    (f + 1.0).to_int()
  } else if diff < 0.5 {
    f.to_int()
  } else {
    let fi = f.to_int()
    if fi % 2 == 0 {
      fi
    } else {
      fi + 1
    }
  }
}

///|
/// `make_bands` (aacsbr.c, float instance): geometric band widths. The
/// running product must stay in f32 — its rounding feeds `lrintf` and the
/// integer outputs have to match the C exactly.
fn aac_sbr_make_bands(
  bands : Array[Int32],
  start : Int32,
  stop : Int32,
  num_bands : Int32,
) -> Unit {
  let base : Double = @math.pow(
    stop.to_double() / start.to_double(),
    1.0 / num_bands.to_double(),
  )
  let basef : Float = Float::from_double(base)
  let mut prod : Float = Float::from_double(start.to_double())
  let mut previous = start
  for k = 0; k < num_bands - 1; k = k + 1 {
    prod = prod * basef
    let present = aac_lrintf(prod.to_double())
    bands[k] = present - previous
    previous = present
  }
  bands[num_bands - 1] = stop - previous
}

///|
/// `qsort_comparison_function_int16` + `AV_QSORT` on Int arrays: the sort
/// is not stable in the C, but equal elements are indistinguishable.
fn aac_sbr_sort_int16(a : Array[Int32], n : Int32) -> Unit {
  // insertion sort: deterministic and sufficient for n <= 64
  for i = 1; i < n; i = i + 1 {
    let v = a[i]
    let mut j = i - 1
    while j >= 0 && a[j] > v {
      a[j + 1] = a[j]
      j = j - 1
    }
    a[j + 1] = v
  }
}

///|
/// `in_table_int16`.
fn aac_sbr_in_table(
  table : Array[Int32],
  last_el : Int32,
  needle : Int32,
) -> Bool {
  for i in 0..<=last_el {
    if table[i] == needle {
      return true
    }
  }
  false
}

///|
/// Limiter Frequency Band Table (14496-3 sp04 p198): `sbr_make_f_tablelim`.
fn AacSbr::make_f_tablelim(self : AacSbr) -> Unit {
  if self.bs_limiter_bands > 0 {
    let bands_warped : Array[Double] = [
      1.32715174233856803909, // 2^(0.49/1.2)
       1.18509277094158210129, // 2^(0.49/2)
       1.11987160404675912501, // 2^(0.49/3)
    ]
    let lim_bands_per_octave_warped = bands_warped[self.bs_limiter_bands - 1]
    let patch_borders : Array[Int32] = Array::make(7, 0)
    patch_borders[0] = self.kx[1]
    for k in 1..<=self.num_patches {
      patch_borders[k] = patch_borders[k - 1] + self.patch_num_subbands[k - 1]
    }
    for i in 0..<=self.n[0] {
      self.f_tablelim[i] = self.f_tablelow[i]
    }
    if self.num_patches > 1 {
      for k in 1..<self.num_patches {
        self.f_tablelim[self.n[0] + k] = patch_borders[k]
      }
    }
    aac_sbr_sort_int16(self.f_tablelim, self.num_patches + self.n[0])
    self.n_lim = self.n[0] + self.num_patches - 1
    let mut inp = 1
    let mut out = 0
    while out < self.n_lim {
      let in_v = self.f_tablelim[inp]
      let out_v = self.f_tablelim[out]
      if in_v.to_double() >= out_v.to_double() * lim_bands_per_octave_warped {
        out = out + 1
        self.f_tablelim[out] = in_v
        inp = inp + 1
      } else if in_v == out_v ||
        !aac_sbr_in_table(patch_borders, self.num_patches, in_v) {
        inp = inp + 1
        self.n_lim = self.n_lim - 1
      } else if !aac_sbr_in_table(patch_borders, self.num_patches, out_v) {
        self.f_tablelim[out] = in_v
        inp = inp + 1
        self.n_lim = self.n_lim - 1
      } else {
        out = out + 1
        self.f_tablelim[out] = in_v
        inp = inp + 1
      }
    }
  } else {
    self.f_tablelim[0] = self.f_tablelow[0]
    self.f_tablelim[1] = self.f_tablelow[self.n[0]]
    self.n_lim = 1
  }
}

///|
/// `read_sbr_header`: returns bits consumed; sets `reset` on param change.
fn AacSbr::read_header(self : AacSbr, gb : BitReader) -> Int32 {
  let cnt = gb.count()
  let old_bs_limiter_bands = self.bs_limiter_bands
  let old = {
    bs_start_freq: self.spectrum_params.bs_start_freq,
    bs_stop_freq: self.spectrum_params.bs_stop_freq,
    bs_xover_band: self.spectrum_params.bs_xover_band,
    bs_freq_scale: self.spectrum_params.bs_freq_scale,
    bs_alter_scale: self.spectrum_params.bs_alter_scale,
    bs_noise_bands: self.spectrum_params.bs_noise_bands,
  }
  self.start = true
  self.ready_for_dequant = false
  self.bs_amp_res_header = gb.read1().reinterpret_as_int()
  self.spectrum_params.bs_start_freq = gb.read(4).reinterpret_as_int()
  self.spectrum_params.bs_stop_freq = gb.read(4).reinterpret_as_int()
  self.spectrum_params.bs_xover_band = gb.read(3).reinterpret_as_int()
  gb.skip(2) // bs_reserved
  let bs_header_extra_1 = gb.read1().reinterpret_as_int()
  let bs_header_extra_2 = gb.read1().reinterpret_as_int()
  if bs_header_extra_1 != 0 {
    self.spectrum_params.bs_freq_scale = gb.read(2).reinterpret_as_int()
    self.spectrum_params.bs_alter_scale = gb.read1().reinterpret_as_int()
    self.spectrum_params.bs_noise_bands = gb.read(2).reinterpret_as_int()
  } else {
    self.spectrum_params.bs_freq_scale = 2
    self.spectrum_params.bs_alter_scale = 1
    self.spectrum_params.bs_noise_bands = 2
  }
  if !aac_sbr_spectrum_params_equal(old, self.spectrum_params) {
    self.reset = true
  }
  if bs_header_extra_2 != 0 {
    self.bs_limiter_bands = gb.read(2).reinterpret_as_int()
    self.bs_limiter_gains = gb.read(2).reinterpret_as_int()
    self.bs_interpol_freq = gb.read1().reinterpret_as_int()
    self.bs_smoothing_mode = gb.read1().reinterpret_as_int()
  } else {
    self.bs_limiter_bands = 2
    self.bs_limiter_gains = 2
    self.bs_interpol_freq = 1
    self.bs_smoothing_mode = 1
  }
  if self.bs_limiter_bands != old_bs_limiter_bands && !self.reset {
    self.make_f_tablelim()
  }
  gb.count() - cnt
}

///|
/// `check_n_master` (14496-3 sp04 p205).
fn aac_sbr_check_n_master(
  n_master : Int32,
  bs_xover_band : Int32,
) -> Result[Unit, String] {
  if n_master <= 0 {
    return Err("Invalid n_master: \{n_master}")
  }
  if bs_xover_band >= n_master {
    return Err(
      "Invalid bitstream, crossover band index beyond array bounds: \{bs_xover_band}",
    )
  }
  Ok(())
}

///|
/// Master Frequency Band Table (14496-3 sp04 p194): `sbr_make_f_master`.
fn AacSbr::make_f_master(self : AacSbr) -> Result[Unit, String] {
  let sbr_offset_row : Array[Int32] = match self.sample_rate {
    16000 => aac_sbr_offset[0]
    22050 => aac_sbr_offset[1]
    24000 => aac_sbr_offset[2]
    32000 => aac_sbr_offset[3]
    44100 | 48000 | 64000 => aac_sbr_offset[4]
    88200 | 96000 | 128000 | 176400 | 192000 => aac_sbr_offset[5]
    _ => return Err("Unsupported sample rate for SBR: \{self.sample_rate}")
  }
  let temp : Int32 = if self.sample_rate < 32000 {
    3000
  } else if self.sample_rate < 64000 {
    4000
  } else {
    5000
  }
  let start_min = ((temp << 7) + (self.sample_rate >> 1)) / self.sample_rate
  let stop_min = ((temp << 8) + (self.sample_rate >> 1)) / self.sample_rate
  self.k[0] = start_min + sbr_offset_row[self.spectrum_params.bs_start_freq]
  if self.spectrum_params.bs_stop_freq < 14 {
    self.k[2] = stop_min
    let stop_dk : Array[Int32] = Array::make(13, 0)
    aac_sbr_make_bands(stop_dk, stop_min, 64, 13)
    aac_sbr_sort_int16(stop_dk, 13)
    for k in 0..<self.spectrum_params.bs_stop_freq {
      self.k[2] = self.k[2] + stop_dk[k]
    }
  } else if self.spectrum_params.bs_stop_freq == 14 {
    self.k[2] = 2 * self.k[0]
  } else if self.spectrum_params.bs_stop_freq == 15 {
    self.k[2] = 3 * self.k[0]
  } else {
    return Err("Invalid bs_stop_freq: \{self.spectrum_params.bs_stop_freq}")
  }
  if self.k[2] > 64 {
    self.k[2] = 64
  }
  let max_qmf_subbands : Int32 = if self.sample_rate <= 32000 {
    48
  } else if self.sample_rate == 44100 {
    35
  } else {
    32 // sample_rate >= 48000
  }
  if self.k[2] - self.k[0] > max_qmf_subbands {
    return Err(
      "Invalid bitstream, too many QMF subbands: \{self.k[2] - self.k[0]}",
    )
  }
  if self.spectrum_params.bs_freq_scale == 0 {
    let dk = self.spectrum_params.bs_alter_scale + 1
    self.n_master = (self.k[2] - self.k[0] + (dk & 2)) >> dk << 1
    match
      aac_sbr_check_n_master(self.n_master, self.spectrum_params.bs_xover_band) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    for k in 1..<=self.n_master {
      self.f_master[k] = dk
    }
    let k2diff = self.k[2] - self.k[0] - self.n_master * dk
    if k2diff < 0 {
      self.f_master[1] = self.f_master[1] - 1
      if k2diff < -1 {
        self.f_master[2] = self.f_master[2] - 1
      }
    } else if k2diff != 0 {
      self.f_master[self.n_master] = self.f_master[self.n_master] + 1
    }
    self.f_master[0] = self.k[0]
    for k in 1..<=self.n_master {
      self.f_master[k] = self.f_master[k] + self.f_master[k - 1]
    }
  } else {
    let half_bands = 7 - self.spectrum_params.bs_freq_scale // {1,2,3}
    let mut two_regions = false
    if 49 * self.k[2] > 110 * self.k[0] {
      two_regions = true
      self.k[1] = 2 * self.k[0]
    } else {
      self.k[1] = self.k[2]
    }
    let num_bands_0 = aac_lrintf(
        half_bands.to_double() *
        @math.log2(self.k[1].to_double() / self.k[0].to_double()),
      ) *
      2
    if num_bands_0 <= 0 {
      return Err("Invalid num_bands_0: \{num_bands_0}")
    }
    let vk0 : Array[Int32] = Array::make(49, 0)
    vk0[0] = 0
    aac_sbr_make_bands_from(vk0, 1, self.k[0], self.k[1], num_bands_0)
    aac_sbr_sort_int16_from(vk0, 1, num_bands_0)
    let vdk0_max = vk0[num_bands_0]
    vk0[0] = self.k[0]
    for k in 1..<=num_bands_0 {
      if vk0[k] <= 0 {
        return Err("Invalid vDk0[\{k}]: \{vk0[k]}")
      }
      vk0[k] = vk0[k] + vk0[k - 1]
    }
    if two_regions {
      let invwarp : Double = if self.spectrum_params.bs_alter_scale != 0 {
        0.76923076923076923077
      } else {
        1.0
      }
      let num_bands_1 = aac_lrintf(
          half_bands.to_double() *
          invwarp *
          @math.log2(self.k[2].to_double() / self.k[1].to_double()),
        ) *
        2
      let vk1 : Array[Int32] = Array::make(49, 0)
      aac_sbr_make_bands_from(vk1, 1, self.k[1], self.k[2], num_bands_1)
      let vdk1_min = aac_sbr_array_min_from(vk1, 1, num_bands_1)
      if vdk1_min < vdk0_max {
        aac_sbr_sort_int16_from(vk1, 1, num_bands_1)
        let change1 = if vdk0_max - vk1[1] < (vk1[num_bands_1] - vk1[1]) >> 1 {
          vdk0_max - vk1[1]
        } else {
          (vk1[num_bands_1] - vk1[1]) >> 1
        }
        vk1[1] = vk1[1] + change1
        vk1[num_bands_1] = vk1[num_bands_1] - change1
      }
      aac_sbr_sort_int16_from(vk1, 1, num_bands_1)
      vk1[0] = self.k[1]
      for k in 1..<=num_bands_1 {
        if vk1[k] <= 0 {
          return Err("Invalid vDk1[\{k}]: \{vk1[k]}")
        }
        vk1[k] = vk1[k] + vk1[k - 1]
      }
      self.n_master = num_bands_0 + num_bands_1
      match
        aac_sbr_check_n_master(
          self.n_master,
          self.spectrum_params.bs_xover_band,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      for i in 0..<=num_bands_0 {
        self.f_master[i] = vk0[i]
      }
      for i in 0..<num_bands_1 {
        self.f_master[num_bands_0 + 1 + i] = vk1[1 + i]
      }
    } else {
      self.n_master = num_bands_0
      match
        aac_sbr_check_n_master(
          self.n_master,
          self.spectrum_params.bs_xover_band,
        ) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      for i in 0..<=num_bands_0 {
        self.f_master[i] = vk0[i]
      }
    }
  }
  Ok(())
}

///|
/// `make_bands(vk0+1, ...)`: fills bands[off..off+num_bands).
fn aac_sbr_make_bands_from(
  bands : Array[Int32],
  off : Int32,
  start : Int32,
  stop : Int32,
  num_bands : Int32,
) -> Unit {
  let base : Double = @math.pow(
    stop.to_double() / start.to_double(),
    1.0 / num_bands.to_double(),
  )
  let basef : Float = Float::from_double(base)
  let mut prod : Float = Float::from_double(start.to_double())
  let mut previous = start
  for k = 0; k < num_bands - 1; k = k + 1 {
    prod = prod * basef
    let present = aac_lrintf(prod.to_double())
    bands[off + k] = present - previous
    previous = present
  }
  bands[off + num_bands - 1] = stop - previous
}

///|
/// `AV_QSORT(vk0 + 1, num_bands_0, ...)` — sort a sub-range.
fn aac_sbr_sort_int16_from(a : Array[Int32], off : Int32, n : Int32) -> Unit {
  for i = 1; i < n; i = i + 1 {
    let v = a[off + i]
    let mut j = i - 1
    while j >= 0 && a[off + j] > v {
      a[off + j + 1] = a[off + j]
      j = j - 1
    }
    a[off + j + 1] = v
  }
}

///|
/// `array_min_int16(vk1 + 1, num_bands_1)`.
fn aac_sbr_array_min_from(a : Array[Int32], off : Int32, nel : Int32) -> Int32 {
  let mut min = a[off]
  for i in 1..<nel {
    if a[off + i] < min {
      min = a[off + i]
    }
  }
  min
}

///|
/// High Frequency Generation - Patch Construction (sp04 p216 fig 4.46):
/// `sbr_hf_calc_npatches`.
fn AacSbr::hf_calc_npatches(self : AacSbr) -> Result[Unit, String] {
  let mut last_k = -1
  let mut last_msb = -1
  let mut sb = 0
  let mut msb = self.k[0]
  let mut usb = self.kx[1]
  let goal_sb = ((1000 << 11) + (self.sample_rate >> 1)) / self.sample_rate
  self.num_patches = 0
  let mut k : Int32 = 0
  if goal_sb < self.kx[1] + self.m[1] {
    k = 0
    while self.f_master[k] < goal_sb {
      k = k + 1
    }
  } else {
    k = self.n_master
  }
  let mut loop_guard = 0
  while true {
    loop_guard = loop_guard + 1
    if loop_guard > 64 {
      return Err("patch construction failed")
    }
    let mut odd = 0
    if k == last_k && msb == last_msb {
      return Err("patch construction failed")
    }
    last_k = k
    last_msb = msb
    // for (i = k; i == k || sb > (k[0] - 1 + msb - odd); i--)
    let mut i = k
    while i == k || sb > self.k[0] - 1 + msb - odd {
      sb = self.f_master[i]
      odd = (sb + self.k[0]) & 1
      i = i - 1
    }
    if self.num_patches > 5 {
      return Err("Too many patches: \{self.num_patches}")
    }
    let num = if sb - usb > 0 { sb - usb } else { 0 }
    self.patch_num_subbands[self.num_patches] = num
    self.patch_start_subband[self.num_patches] = self.k[0] - odd - num
    if num > 0 {
      usb = sb
      msb = sb
      self.num_patches = self.num_patches + 1
    } else {
      msb = self.kx[1]
    }
    if self.f_master[k] - sb < 3 {
      k = self.n_master
    }
    if sb == self.kx[1] + self.m[1] {
      break
    }
  }
  if self.num_patches > 1 && self.patch_num_subbands[self.num_patches - 1] < 3 {
    self.num_patches = self.num_patches - 1
  }
  Ok(())
}

///|
/// Derived Frequency Band Tables (sp04 p197): `sbr_make_f_derived`.
fn AacSbr::make_f_derived(self : AacSbr) -> Result[Unit, String] {
  self.n[1] = self.n_master - self.spectrum_params.bs_xover_band
  self.n[0] = (self.n[1] + 1) >> 1
  for i in 0..<=self.n[1] {
    self.f_tablehigh[i] = self.f_master[self.spectrum_params.bs_xover_band + i]
  }
  self.m[1] = self.f_tablehigh[self.n[1]] - self.f_tablehigh[0]
  self.kx[1] = self.f_tablehigh[0]
  if self.kx[1] + self.m[1] > 64 {
    return Err("Stop frequency border too high: \{self.kx[1] + self.m[1]}")
  }
  if self.kx[1] > 32 {
    return Err("Start frequency border too high: \{self.kx[1]}")
  }
  self.f_tablelow[0] = self.f_tablehigh[0]
  let mut temp = self.n[1] & 1
  for k in 1..<=self.n[0] {
    self.f_tablelow[k] = self.f_tablehigh[2 * k - temp]
  }
  self.n_q = aac_lrintf(
    self.spectrum_params.bs_noise_bands.to_double() *
    @math.log2(self.k[2].to_double() / self.kx[1].to_double()),
  )
  if self.n_q < 1 {
    self.n_q = 1
  }
  if self.n_q > 5 {
    self.n_q = 1
    return Err("Too many noise floor scale factors: \{self.n_q}")
  }
  self.f_tablenoise[0] = self.f_tablelow[0]
  temp = 0
  for k in 1..<=self.n_q {
    temp = temp + (self.n[0] - temp) / (self.n_q + 1 - k)
    self.f_tablenoise[k] = self.f_tablelow[temp]
  }
  match self.hf_calc_npatches() {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.make_f_tablelim()
  self.data[0].f_indexnoise = 0
  self.data[1].f_indexnoise = 0
  Ok(())
}

///|
/// `sbr_reset`.
fn AacSbr::sbr_reset(self : AacSbr) -> Unit {
  let failed = match self.make_f_master() {
    Ok(_) =>
      match self.make_f_derived() {
        Ok(_) => false
        Err(_) => true
      }
    Err(_) => true
  }
  if failed {
    self.turnoff()
  }
}

///|
/// `ceil_log2[]` index helper for bs_pointer reads.
let aac_sbr_ceil_log2 : Array[Int32] = [0, 1, 2, 2, 3, 3]

///|
/// `read_sbr_grid` (sp04 time-frequency grid).
fn AacSbr::read_grid(
  self : AacSbr,
  gb : BitReader,
  ch_data : AacSbrData,
  num_time_slots : Int32,
) -> Result[Unit, String] {
  let mut bs_pointer = 0
  let mut abs_bord_trail = num_time_slots
  let bs_num_env_old = ch_data.bs_num_env
  ch_data.bs_freq_res[0] = ch_data.bs_freq_res[ch_data.bs_num_env]
  ch_data.bs_amp_res = self.bs_amp_res_header
  ch_data.t_env_num_env_old = ch_data.t_env[ch_data.bs_num_env]
  let bs_frame_class = gb.read(2).reinterpret_as_int()
  match bs_frame_class {
    0 => {
      // FIXFIX
      let n = 1 << gb.read(2).reinterpret_as_int()
      if n > 5 {
        return Err(
          "Invalid bitstream, too many SBR envelopes in FIXFIX type SBR frame: \{n}",
        )
      }
      ch_data.bs_num_env = n
      let num_rel_lead = ch_data.bs_num_env - 1
      if ch_data.bs_num_env == 1 {
        ch_data.bs_amp_res = 0
      }
      ch_data.t_env[0] = 0
      ch_data.t_env[ch_data.bs_num_env] = abs_bord_trail
      abs_bord_trail = (abs_bord_trail + (ch_data.bs_num_env >> 1)) /
        ch_data.bs_num_env
      for i in 0..<num_rel_lead {
        ch_data.t_env[i + 1] = ch_data.t_env[i] + abs_bord_trail
      }
      ch_data.bs_freq_res[1] = gb.read1().reinterpret_as_int()
      for i in 1..<ch_data.bs_num_env {
        ch_data.bs_freq_res[i + 1] = ch_data.bs_freq_res[1]
      }
    }
    1 => {
      // FIXVAR
      abs_bord_trail = abs_bord_trail + gb.read(2).reinterpret_as_int()
      let num_rel_trail = gb.read(2).reinterpret_as_int()
      ch_data.bs_num_env = num_rel_trail + 1
      ch_data.t_env[0] = 0
      ch_data.t_env[ch_data.bs_num_env] = abs_bord_trail
      for i in 0..<num_rel_trail {
        ch_data.t_env[ch_data.bs_num_env - 1 - i] = ch_data.t_env[ch_data.bs_num_env -
          i] -
          2 * gb.read(2).reinterpret_as_int() -
          2
      }
      bs_pointer = gb
        .read(aac_sbr_ceil_log2[ch_data.bs_num_env])
        .reinterpret_as_int()
      for i in 0..<ch_data.bs_num_env {
        ch_data.bs_freq_res[ch_data.bs_num_env - i] = gb
          .read1()
          .reinterpret_as_int()
      }
    }
    2 => {
      // VARFIX
      ch_data.t_env[0] = gb.read(2).reinterpret_as_int()
      let num_rel_lead = gb.read(2).reinterpret_as_int()
      ch_data.bs_num_env = num_rel_lead + 1
      ch_data.t_env[ch_data.bs_num_env] = abs_bord_trail
      for i in 0..<num_rel_lead {
        ch_data.t_env[i + 1] = ch_data.t_env[i] +
          2 * gb.read(2).reinterpret_as_int() +
          2
      }
      bs_pointer = gb
        .read(aac_sbr_ceil_log2[ch_data.bs_num_env])
        .reinterpret_as_int()
      for i in 0..<ch_data.bs_num_env {
        ch_data.bs_freq_res[i + 1] = gb.read1().reinterpret_as_int()
      }
    }
    _ => {
      // VARVAR
      ch_data.t_env[0] = gb.read(2).reinterpret_as_int()
      abs_bord_trail = abs_bord_trail + gb.read(2).reinterpret_as_int()
      let num_rel_lead = gb.read(2).reinterpret_as_int()
      let num_rel_trail = gb.read(2).reinterpret_as_int()
      let n = num_rel_lead + num_rel_trail + 1
      if n > 5 {
        return Err(
          "Invalid bitstream, too many SBR envelopes in VARVAR type SBR frame: \{n}",
        )
      }
      ch_data.bs_num_env = n
      ch_data.t_env[ch_data.bs_num_env] = abs_bord_trail
      for i in 0..<num_rel_lead {
        ch_data.t_env[i + 1] = ch_data.t_env[i] +
          2 * gb.read(2).reinterpret_as_int() +
          2
      }
      for i in 0..<num_rel_trail {
        ch_data.t_env[ch_data.bs_num_env - 1 - i] = ch_data.t_env[ch_data.bs_num_env -
          i] -
          2 * gb.read(2).reinterpret_as_int() -
          2
      }
      bs_pointer = gb
        .read(aac_sbr_ceil_log2[ch_data.bs_num_env])
        .reinterpret_as_int()
      for i in 0..<ch_data.bs_num_env {
        ch_data.bs_freq_res[i + 1] = gb.read1().reinterpret_as_int()
      }
    }
  }
  ch_data.bs_frame_class = bs_frame_class
  if bs_pointer > ch_data.bs_num_env + 1 {
    return Err(
      "Invalid bitstream, bs_pointer points to a middle noise border outside the time borders table: \{bs_pointer}",
    )
  }
  for i in 1..<=ch_data.bs_num_env {
    if ch_data.t_env[i - 1] >= ch_data.t_env[i] {
      return Err("Not strictly monotone time borders")
    }
  }
  ch_data.bs_num_noise = if ch_data.bs_num_env > 1 { 2 } else { 1 }
  ch_data.t_q[0] = ch_data.t_env[0]
  ch_data.t_q[ch_data.bs_num_noise] = ch_data.t_env[ch_data.bs_num_env]
  if ch_data.bs_num_noise > 1 {
    let idx : Int32 = if ch_data.bs_frame_class == 0 {
      ch_data.bs_num_env >> 1
    } else if (ch_data.bs_frame_class & 1) != 0 {
      // FIXVAR or VARVAR
      let p = if bs_pointer - 1 > 1 { bs_pointer - 1 } else { 1 }
      ch_data.bs_num_env - p
    } else if bs_pointer == 0 {
      1
    } else if bs_pointer == 1 {
      ch_data.bs_num_env - 1
    } else {
      bs_pointer - 1
    }
    ch_data.t_q[1] = ch_data.t_env[idx]
  }
  ch_data.e_a[0] = if ch_data.e_a[1] != bs_num_env_old { -1 } else { 0 }
  ch_data.e_a[1] = -1
  if (ch_data.bs_frame_class & 1) != 0 && bs_pointer != 0 {
    // FIXVAR or VARVAR and bs_pointer != 0
    ch_data.e_a[1] = ch_data.bs_num_env + 1 - bs_pointer
  } else if ch_data.bs_frame_class == 2 && bs_pointer > 1 {
    // VARFIX and bs_pointer > 1
    ch_data.e_a[1] = bs_pointer - 1
  }
  Ok(())
}

///|
/// `copy_sbr_grid` (coupled CPE: derive ch1's grid from ch0's).
fn aac_sbr_copy_grid(dst : AacSbrData, src : AacSbrData) -> Unit {
  dst.bs_freq_res[0] = dst.bs_freq_res[dst.bs_num_env]
  dst.t_env_num_env_old = dst.t_env[dst.bs_num_env]
  dst.e_a[0] = if dst.e_a[1] != dst.bs_num_env { -1 } else { 0 }
  for i in 1..<9 {
    dst.bs_freq_res[i] = src.bs_freq_res[i]
  }
  for i in 0..<9 {
    dst.t_env[i] = src.t_env[i]
  }
  for i in 0..<3 {
    dst.t_q[i] = src.t_q[i]
  }
  dst.bs_num_env = src.bs_num_env
  dst.bs_amp_res = src.bs_amp_res
  dst.bs_num_noise = src.bs_num_noise
  dst.bs_frame_class = src.bs_frame_class
  dst.e_a[1] = src.e_a[1]
}

///|
/// `read_sbr_dtdf`.
fn AacSbr::read_dtdf(
  self : AacSbr,
  gb : BitReader,
  ch_data : AacSbrData,
) -> Unit {
  ignore(self)
  for i in 0..<ch_data.bs_num_env {
    ch_data.bs_df_env[i] = gb.read1().reinterpret_as_int()
  }
  for i in 0..<ch_data.bs_num_noise {
    ch_data.bs_df_noise[i] = gb.read1().reinterpret_as_int()
  }
}

///|
/// `read_sbr_invf`.
fn AacSbr::read_invf(
  self : AacSbr,
  gb : BitReader,
  ch_data : AacSbrData,
) -> Unit {
  for i in 0..<5 {
    ch_data.bs_invf_mode[1][i] = ch_data.bs_invf_mode[0][i]
  }
  for i in 0..<self.n_q {
    ch_data.bs_invf_mode[0][i] = gb.read(2).reinterpret_as_int()
  }
}

///|
/// `read_sbr_envelope`; `ch` is 0/1 within the element.
fn AacSbr::read_envelope(
  self : AacSbr,
  gb : BitReader,
  ch_data : AacSbrData,
  ch : Int32,
) -> Result[Unit, String] {
  let mut bits : Int32 = 0
  let mut t_huff : Int32 = 0
  let mut f_huff : Int32 = 0
  let delta : Int32 = (if ch == 1 && self.bs_coupling == 1 { 1 } else { 0 }) + 1
  let odd = self.n[1] & 1
  if self.bs_coupling != 0 && ch != 0 {
    if ch_data.bs_amp_res != 0 {
      bits = 5
      t_huff = aac_sbr_t_huffman_env_bal_3_0db
      f_huff = aac_sbr_f_huffman_env_bal_3_0db
    } else {
      bits = 6
      t_huff = aac_sbr_t_huffman_env_bal_1_5db
      f_huff = aac_sbr_f_huffman_env_bal_1_5db
    }
  } else if ch_data.bs_amp_res != 0 {
    bits = 6
    t_huff = aac_sbr_t_huffman_env_3_0db
    f_huff = aac_sbr_f_huffman_env_3_0db
  } else {
    bits = 7
    t_huff = aac_sbr_t_huffman_env_1_5db
    f_huff = aac_sbr_f_huffman_env_1_5db
  }
  for i in 0..<ch_data.bs_num_env {
    let e = i + 1
    if ch_data.bs_df_env[i] != 0 {
      if ch_data.bs_freq_res[i + 1] == ch_data.bs_freq_res[i] {
        for j in 0..<self.n[ch_data.bs_freq_res[i + 1]] {
          let sym = match aac_sbr_vlc_decode(gb, t_huff) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          let v = (ch_data.env_facs_q[i * 48 + j] + delta * sym) & 0xff
          ch_data.env_facs_q[e * 48 + j] = v
          if v > 127 {
            return Err("env_facs_q \{v} is invalid")
          }
        }
      } else if ch_data.bs_freq_res[i + 1] != 0 {
        for j in 0..<self.n[ch_data.bs_freq_res[i + 1]] {
          let k = (j + odd) >> 1
          let sym = match aac_sbr_vlc_decode(gb, t_huff) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          let v = (ch_data.env_facs_q[i * 48 + k] + delta * sym) & 0xff
          ch_data.env_facs_q[e * 48 + j] = v
          if v > 127 {
            return Err("env_facs_q \{v} is invalid")
          }
        }
      } else {
        for j in 0..<self.n[ch_data.bs_freq_res[i + 1]] {
          let k = if j != 0 { 2 * j - odd } else { 0 }
          let sym = match aac_sbr_vlc_decode(gb, t_huff) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          let v = (ch_data.env_facs_q[i * 48 + k] + delta * sym) & 0xff
          ch_data.env_facs_q[e * 48 + j] = v
          if v > 127 {
            return Err("env_facs_q \{v} is invalid")
          }
        }
      }
    } else {
      let v = (delta * gb.read(bits).reinterpret_as_int()) & 0xff
      ch_data.env_facs_q[e * 48] = v
      if v > 127 {
        return Err("env_facs_q \{v} is invalid")
      }
      for j in 1..<self.n[ch_data.bs_freq_res[i + 1]] {
        let sym = match aac_sbr_vlc_decode(gb, f_huff) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let v2 = (ch_data.env_facs_q[e * 48 + j - 1] + delta * sym) & 0xff
        ch_data.env_facs_q[e * 48 + j] = v2
        if v2 > 127 {
          return Err("env_facs_q \{v2} is invalid")
        }
      }
    }
  }
  for j in 0..<48 {
    ch_data.env_facs_q[j] = ch_data.env_facs_q[ch_data.bs_num_env * 48 + j]
  }
  Ok(())
}

///|
/// `read_sbr_noise`.
fn AacSbr::read_noise(
  self : AacSbr,
  gb : BitReader,
  ch_data : AacSbrData,
  ch : Int32,
) -> Result[Unit, String] {
  let mut t_huff : Int32 = 0
  let mut f_huff : Int32 = 0
  let delta : Int32 = (if ch == 1 && self.bs_coupling == 1 { 1 } else { 0 }) + 1
  if self.bs_coupling != 0 && ch != 0 {
    t_huff = aac_sbr_t_huffman_noise_bal_3_0db
    f_huff = aac_sbr_f_huffman_env_bal_3_0db
  } else {
    t_huff = aac_sbr_t_huffman_noise_3_0db
    f_huff = aac_sbr_f_huffman_env_3_0db
  }
  for i in 0..<ch_data.bs_num_noise {
    let e = i + 1
    if ch_data.bs_df_noise[i] != 0 {
      for j in 0..<self.n_q {
        let sym = match aac_sbr_vlc_decode(gb, t_huff) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let v = (ch_data.noise_facs_q[i * 5 + j] + delta * sym) & 0xff
        ch_data.noise_facs_q[e * 5 + j] = v
        if v > 30 {
          return Err("noise_facs_q \{v} is invalid")
        }
      }
    } else {
      let v = (delta * gb.read(5).reinterpret_as_int()) & 0xff
      ch_data.noise_facs_q[e * 5] = v
      if v > 30 {
        return Err("noise_facs_q \{v} is invalid")
      }
      for j in 1..<self.n_q {
        let sym = match aac_sbr_vlc_decode(gb, f_huff) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let v2 = (ch_data.noise_facs_q[e * 5 + j - 1] + delta * sym) & 0xff
        ch_data.noise_facs_q[e * 5 + j] = v2
        if v2 > 30 {
          return Err("noise_facs_q \{v2} is invalid")
        }
      }
    }
  }
  for j in 0..<5 {
    ch_data.noise_facs_q[j] = ch_data.noise_facs_q[ch_data.bs_num_noise * 5 + j]
  }
  Ok(())
}

///|
/// `read_sbr_extension`: EXTENSION_ID_PS feeds `ff_ps_read_data`; reserved
/// ids consume the remaining bits as the C does.
fn AacSbr::read_extension(
  self : AacSbr,
  gb : BitReader,
  bs_extension_id : Int32,
  num_bits_left : Ref[Int32],
  ps_allowed : Bool,
) -> Unit {
  match bs_extension_id {
    2 =>
      // EXTENSION_ID_PS
      if !ps_allowed {
        // "Parametric Stereo signaled to be not-present but was found"
        gb.skip(num_bits_left.val)
        num_bits_left.val = 0
      } else {
        num_bits_left.val = num_bits_left.val -
          self.ps.common.read_data(gb, num_bits_left.val)
      }
    _ => {
      gb.skip(num_bits_left.val)
      num_bits_left.val = 0
    }
  }
}

///|
/// `read_sbr_single_channel_element`.
fn AacSbr::read_single_channel_element(
  self : AacSbr,
  gb : BitReader,
  num_time_slots : Int32,
  ps_allowed : Bool,
) -> Result[Unit, String] {
  if gb.read1().reinterpret_as_int() != 0 {
    gb.skip(4) // bs_reserved
  }
  match self.read_grid(gb, self.data[0], num_time_slots) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.read_dtdf(gb, self.data[0])
  self.read_invf(gb, self.data[0])
  match self.read_envelope(gb, self.data[0], 0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  match self.read_noise(gb, self.data[0], 0) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.data[0].bs_add_harmonic_flag = gb.read1().reinterpret_as_int()
  if self.data[0].bs_add_harmonic_flag != 0 {
    for i in 0..<self.n[1] {
      self.data[0].bs_add_harmonic[i] = gb.read1().reinterpret_as_int()
    }
  }
  ignore(ps_allowed)
  Ok(())
}

///|
/// `read_sbr_channel_pair_element`.
fn AacSbr::read_channel_pair_element(
  self : AacSbr,
  gb : BitReader,
  num_time_slots : Int32,
  ps_allowed : Bool,
) -> Result[Unit, String] {
  if gb.read1().reinterpret_as_int() != 0 {
    gb.skip(8) // bs_reserved
  }
  self.bs_coupling = gb.read1().reinterpret_as_int()
  if self.bs_coupling != 0 {
    match self.read_grid(gb, self.data[0], num_time_slots) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    aac_sbr_copy_grid(self.data[1], self.data[0])
    self.read_dtdf(gb, self.data[0])
    self.read_dtdf(gb, self.data[1])
    self.read_invf(gb, self.data[0])
    for i in 0..<5 {
      self.data[1].bs_invf_mode[1][i] = self.data[1].bs_invf_mode[0][i]
      self.data[1].bs_invf_mode[0][i] = self.data[0].bs_invf_mode[0][i]
    }
    match self.read_envelope(gb, self.data[0], 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_noise(gb, self.data[0], 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_envelope(gb, self.data[1], 1) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_noise(gb, self.data[1], 1) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    match self.read_grid(gb, self.data[0], num_time_slots) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_grid(gb, self.data[1], num_time_slots) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    self.read_dtdf(gb, self.data[0])
    self.read_dtdf(gb, self.data[1])
    self.read_invf(gb, self.data[0])
    self.read_invf(gb, self.data[1])
    match self.read_envelope(gb, self.data[0], 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_envelope(gb, self.data[1], 1) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_noise(gb, self.data[0], 0) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.read_noise(gb, self.data[1], 1) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  self.data[0].bs_add_harmonic_flag = gb.read1().reinterpret_as_int()
  if self.data[0].bs_add_harmonic_flag != 0 {
    for i in 0..<self.n[1] {
      self.data[0].bs_add_harmonic[i] = gb.read1().reinterpret_as_int()
    }
  }
  self.data[1].bs_add_harmonic_flag = gb.read1().reinterpret_as_int()
  if self.data[1].bs_add_harmonic_flag != 0 {
    for i in 0..<self.n[1] {
      self.data[1].bs_add_harmonic[i] = gb.read1().reinterpret_as_int()
    }
  }
  ignore(ps_allowed)
  Ok(())
}

///|
/// `read_sbr_data` (bs_extended_data loop included); `ps_allowed` mirrors
/// `ac->oc[1].m4ac.ps != 0`.
fn AacSbr::read_data(
  self : AacSbr,
  gb : BitReader,
  id_aac : Int32,
  num_time_slots : Int32,
  ps_allowed : Bool,
) -> Result[Int32, String] {
  let cnt = gb.count()
  self.id_aac = id_aac
  self.ready_for_dequant = true
  if id_aac == aac_id_sce || id_aac == aac_id_cce {
    match self.read_single_channel_element(gb, num_time_slots, ps_allowed) {
      Ok(_) => ()
      Err(_) => {
        self.turnoff()
        return Ok(gb.count() - cnt)
      }
    }
  } else if id_aac == aac_id_cpe {
    match self.read_channel_pair_element(gb, num_time_slots, ps_allowed) {
      Ok(_) => ()
      Err(e) => {
        ignore(e)
        self.turnoff()
        return Ok(gb.count() - cnt)
      }
    }
  } else {
    self.turnoff()
    return Ok(gb.count() - cnt)
  }
  if gb.read1().reinterpret_as_int() != 0 {
    // bs_extended_data
    let mut num_bits_left = gb.read(4).reinterpret_as_int()
    if num_bits_left == 15 {
      num_bits_left = num_bits_left + gb.read(8).reinterpret_as_int()
    }
    num_bits_left = num_bits_left << 3
    let left : Ref[Int32] = { val: num_bits_left, }
    while left.val > 7 {
      left.val = left.val - 2
      let id = gb.read(2).reinterpret_as_int()
      self.read_extension(gb, id, left, ps_allowed)
    }
    if left.val < 0 {
      // "SBR Extension over read." — the C logs and continues.
      ()
    }
    if left.val > 0 {
      gb.skip(left.val)
    }
  }
  Ok(gb.count() - cnt)
}

///|
/// `ff_aac_sbr_decode_extension`: `gb` is positioned after the 4-bit
/// extension type of the FIL payload; `cnt` is the whole FIL byte count.
/// Consumes exactly `cnt` bytes worth of payload from the host reader on
/// success paths, mirroring `skip_bits_long(gb_host, cnt*8 - 4)`.
pub fn AacSbr::decode_extension(
  self : AacSbr,
  gb_host : BitReader,
  crc : Bool,
  cnt : Int32,
  id_aac : Int32,
  fl960 : Bool,
) -> Result[Unit, String] {
  let start = gb_host.count()
  let num_time_slots = if fl960 { 15 } else { 16 }
  let mut num_sbr_bits = 0
  self.reset = false
  if self.sample_rate == 0 {
    self.sample_rate = 2 * self.core_sample_rate
  }
  if crc {
    gb_host.skip(10) // bs_sbr_crc_bits; TODO - implement CRC check
    num_sbr_bits = num_sbr_bits + 10
  }
  // Save some state from the previous frame.
  self.kx[0] = self.kx[1]
  self.m[0] = self.m[1]
  self.kx_and_m_pushed = true
  num_sbr_bits = num_sbr_bits + 1
  if gb_host.read1().reinterpret_as_int() != 0 {
    // bs_header_flag
    num_sbr_bits = num_sbr_bits + self.read_header(gb_host)
  }
  if self.reset {
    self.sbr_reset()
  }
  if self.start {
    let consumed = match
      self.read_data(gb_host, id_aac, num_time_slots, self.ps_allowed) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    num_sbr_bits = num_sbr_bits + consumed
  }
  let num_align_bits = ((cnt << 3) - 4 - num_sbr_bits) & 7
  let bytes_read = (num_sbr_bits + num_align_bits + 4) >> 3
  if bytes_read > cnt {
    self.turnoff()
  }
  // The host consumes the whole FIL payload regardless.
  gb_host.pos = start - 4 + cnt * 8
  ignore(num_align_bits)
  Ok(())
}

///|
/// Core sample rate of the LC coder, assigned by the frame entry
/// (`sbr->sample_rate = 2 * m4ac.sample_rate` on the first payload).
pub fn AacSbr::set_core_sample_rate(self : AacSbr, rate : Int32) -> Unit {
  self.core_sample_rate = rate
}
