///|
/// SIPR / ACELP.NET decoder (RealAudio "Sipro", also Audible format 4): a
/// port of FFmpeg 9.0.2 `libavcodec/sipr.c` and `libavcodec/sipr16k.c` with
/// the `lsp.c` / `acelp_*` / `celp_*` helpers they call. Original FFmpeg
/// code is LGPL-2.1-or-later; this port keeps the same license.
///
/// All four modes are ported: 16k (20-byte packets, 160 samples), 8k5
/// (19 bytes, 144 samples), 6k5 (29 bytes, two frames, 288 samples) and 5k0
/// (37 bytes, two frames, 480 samples). The output is mono, in samples
/// (the C decoder's FLT range is not clipped and neither is this one).
///
/// Arithmetic notes:
///   * The C decoder is a float pipeline; the port evaluates it in doubles
///     on the exact C table values. Every decision is read from the
///     bitstream, so what differs from the C output is rounding only; the
///     real-data tests bound the s16 output by one LSB.
///   * The shared ACELP / CELP helpers are the ones the AMR-NB port already
///     carries (`amr_*` in `amr.mbt`, ports of the same C functions).
///   * `PITCH_MAX` is SIPR's own 281 (`sipr.h`), not the 143 that
///     `acelp_pitch_delay.h` names the same; the decoder uses the latter as
///     `PITCH_DELAY_MAX` (`amr_pitch_delay_max`).
///
/// The port is split over three files: this one holds the mode table, the
/// bit reader and the decoder object; `sipr_frame.mbt` is the below-16k
/// frame; `sipr16k.mbt` is the 16k frame.

// ---------------------------------------------------------------------------
// constants and mode table
// ---------------------------------------------------------------------------

///|
/// `LP_FILTER_ORDER_16k`.
let sipr_lp_filter_order_16k : Int32 = 16

///|
/// `L_SUBFR_16k`.
let sipr_l_subfr_16k : Int32 = 80

///|
/// `PITCH_MIN` (`sipr.h`).
let sipr_pitch_min : Int32 = 30

///|
/// `PITCH_MAX` (`sipr.h`).
let sipr_pitch_max : Int32 = 281

///|
/// `LSFQ_DIFF_MIN` (0.0125 * M_PI).
let sipr_lsfq_diff_min : Double = 0.0125 * 3.14159265358979323846

///|
/// `LP_FILTER_ORDER`.
let sipr_lp_filter_order : Int32 = 10

///|
/// `L_INTERPOL`.
let sipr_l_interpol : Int32 = 11

///|
/// `SUBFR_SIZE`.
let sipr_subfr_size : Int32 = 48

///|
/// `PITCH_DELAY_MAX + L_INTERPOL`: the history the adaptive codebook
/// interpolation reads behind the current subframe.
let sipr_excitation_history : Int32 = amr_pitch_delay_max + sipr_l_interpol

///|
/// `PITCH_MAX + L_INTERPOL`: where the 16k mode starts its subframes in
/// `excitation`.
let sipr_excitation_16k : Int32 = sipr_pitch_max + sipr_l_interpol

///|
/// `M_LN10`.
let sipr_ln10 : Double = 2.3025850929940456840179914546843642

///|
/// `M_LN2`.
let sipr_ln2 : Double = 0.693147180559945309417232121458176568

///|
/// `M_PI`.
let sipr_pi : Double = 3.14159265358979323846

///|
/// The energy mean the fixed-gain predictor uses: `offset - 15.0 / (0.05 *
/// M_LN10 / M_LN2)` (34 below 16 kHz, 19 for the 16k mode).
fn sipr_energy_mean(offset : Double) -> Double {
  offset - 15.0 / (0.05 * sipr_ln10 / sipr_ln2)
}

///|
/// `SiprMode`: the four bitstream modes, in the order of the C enum.
pub(all) enum SiprMode {
  Sipr16k
  Sipr8k5
  Sipr6k5
  Sipr5k0
}

///|
/// `SiprModeParam`.
priv struct SiprModeParam {
  bits_per_frame : Int32
  subframe_count : Int32
  frames_per_packet : Int32
  pitch_sharp_factor : Double
  number_of_fc_indexes : Int32
  ma_predictor_bits : Int32
  vq_indexes_bits : FixedArray[Int32]
  pitch_delay_bits : FixedArray[Int32]
  gp_index_bits : Int32
  fc_index_bits : FixedArray[Int32]
  gc_index_bits : Int32
}

///|
/// `modes[]`.
let sipr_modes : FixedArray[SiprModeParam] = [
  {
    bits_per_frame: 160,
    subframe_count: 2,
    frames_per_packet: 1,
    pitch_sharp_factor: 0.00,
    number_of_fc_indexes: 10,
    ma_predictor_bits: 1,
    vq_indexes_bits: [7, 8, 7, 7, 7],
    pitch_delay_bits: [9, 6],
    gp_index_bits: 4,
    fc_index_bits: [4, 5, 4, 5, 4, 5, 4, 5, 4, 5],
    gc_index_bits: 5,
  },
  {
    bits_per_frame: 152,
    subframe_count: 3,
    frames_per_packet: 1,
    pitch_sharp_factor: 0.8,
    number_of_fc_indexes: 3,
    ma_predictor_bits: 0,
    vq_indexes_bits: [6, 7, 7, 7, 5],
    pitch_delay_bits: [8, 5, 5],
    gp_index_bits: 0,
    fc_index_bits: [9, 9, 9],
    gc_index_bits: 7,
  },
  {
    bits_per_frame: 232,
    subframe_count: 3,
    frames_per_packet: 2,
    pitch_sharp_factor: 0.8,
    number_of_fc_indexes: 3,
    ma_predictor_bits: 0,
    vq_indexes_bits: [6, 7, 7, 7, 5],
    pitch_delay_bits: [8, 5, 5],
    gp_index_bits: 0,
    fc_index_bits: [5, 5, 5],
    gc_index_bits: 7,
  },
  {
    bits_per_frame: 296,
    subframe_count: 5,
    frames_per_packet: 2,
    pitch_sharp_factor: 0.85,
    number_of_fc_indexes: 1,
    ma_predictor_bits: 0,
    vq_indexes_bits: [6, 7, 7, 7, 5],
    pitch_delay_bits: [8, 5, 8, 5, 5],
    gp_index_bits: 0,
    fc_index_bits: [10],
    gc_index_bits: 7,
  },
]

// ---------------------------------------------------------------------------
// bit reader
// ---------------------------------------------------------------------------

///|
/// `GetBitContext` with `BITSTREAM_READER_LE`: the first bit of a byte is
/// its least significant one, and the first bit of a multi-bit field lands
/// in the least significant position of the value. Reads past the end yield
/// zero.
priv struct RealAudioBits {
  data : Bytes
  mut pos : Int32
}

///|
fn RealAudioBits::new(data : Bytes) -> RealAudioBits {
  { data, pos: 0, }
}

///|
/// `get_bits(n)` for the little-endian reader.
fn RealAudioBits::read(self : RealAudioBits, n : Int32) -> UInt32 {
  let mut v = 0U
  for i = 0; i < n; i = i + 1 {
    let p = self.pos + i
    let bit = if p < 0 || p >= self.data.length() * 8 {
      0U
    } else {
      (self.data[p >> 3].to_int().reinterpret_as_uint() >> (p & 7)) & 1U
    }
    v = v | (bit << i)
  }
  self.pos += n
  v
}

// ---------------------------------------------------------------------------
// parameters and fixed codebook
// ---------------------------------------------------------------------------

///|
/// `SiprParameters`: what `decode_parameters` reads from one frame.
priv struct SiprParameters {
  ma_pred_switch : Int32
  vq_indexes : FixedArray[Int32]
  pitch_delay : FixedArray[Int32]
  gp_index : FixedArray[Int32]
  fc_indexes : FixedArray[FixedArray[Int32]]
  gc_index : FixedArray[Int32]
}

///|
/// `AMRFixed`.
priv struct SiprFixed {
  mut n : Int32
  x : FixedArray[Int32]
  y : FixedArray[Double]
  mut no_repeat_mask : Int32
  mut pitch_lag : Int32
  mut pitch_fac : Double
}

///|
fn SiprFixed::new() -> SiprFixed {
  {
    n: 0,
    x: FixedArray::make(10, 0),
    y: FixedArray::make(10, 0.0),
    no_repeat_mask: 0,
    pitch_lag: 0,
    pitch_fac: 0.0,
  }
}

// ---------------------------------------------------------------------------
// the decoder
// ---------------------------------------------------------------------------

///|
/// One SIPR decoder. The mode is fixed at construction; the decoder is
/// stateful, so the packets of a stream go in from its start.
pub struct SiprDecoder {
  /// Index into `sipr_modes`, the value of the `SiprMode` of the stream.
  mode : Int32
  mut past_pitch_gain : Double
  lsf_history : Array[Double]
  /// `excitation[L_INTERPOL + PITCH_MAX + 2 * L_SUBFR_16k]`
  excitation : Array[Double]
  /// `synth_buf[LP_FILTER_ORDER + 5*SUBFR_SIZE + 6]`; the synthesis of a
  /// frame starts at offset 16 (the C's alignment slack).
  synth_buf : Array[Double]
  lsp_history : Array[Double]
  mut gain_mem : Double
  energy_history : Array[Double]
  highpass_filt_mem : Array[Double]
  /// `postfilter_mem`, `postfilter_mem5k0`: only the first
  /// `LP_FILTER_ORDER` entries of the C arrays are used.
  postfilter_mem : Array[Double]
  postfilter_mem5k0 : Array[Double]
  postfilter_syn5k0 : Array[Double]
  tilt_mem : Ref[Double]
  postfilter_agc : Ref[Double]
  mut pitch_lag_prev : Int32
  iir_mem : Array[Double]
  /// `filt_buf[2]`; `filt_sel` says which one is `filt_mem[0]` (the C
  /// swaps the two pointers after every frame).
  filt_buf : FixedArray[Array[Double]]
  mut filt_sel : Int32
  mem_preemph : Array[Double]
  synth : Array[Double]
  lsp_history_16k : Array[Double]
  /// `ir_buf[SUBFR_SIZE + LP_FILTER_ORDER]`: ten zeros of history, then
  /// the impulse response of the current subframe.
  ir_buf : Array[Double]
}

///|
/// The mode of the stream.
pub fn SiprDecoder::sipr_mode(self : SiprDecoder) -> SiprMode {
  match self.mode {
    0 => Sipr16k
    1 => Sipr8k5
    2 => Sipr6k5
    _ => Sipr5k0
  }
}

///|
/// `SiprMode` as the index the mode table uses.
fn sipr_mode_index(mode : SiprMode) -> Int32 {
  match mode {
    Sipr16k => 0
    Sipr8k5 => 1
    Sipr6k5 => 2
    Sipr5k0 => 3
  }
}

///|
/// The sample rate of a mode: 16 kHz for `Sipr16k`, 8 kHz otherwise.
pub fn SiprMode::sample_rate(self : SiprMode) -> Int32 {
  match self {
    Sipr16k => 16000
    _ => 8000
  }
}

///|
/// Bytes per packet (the RealMedia demuxer's `ff_sipr_subpk_size`).
pub fn SiprMode::packet_size(self : SiprMode) -> Int32 {
  sipr_modes[sipr_mode_index(self)].bits_per_frame >> 3
}

///|
/// Samples one packet decodes to.
pub fn SiprMode::samples_per_packet(self : SiprMode) -> Int32 {
  sipr_frames_per_packet(sipr_mode_index(self)) *
  sipr_frame_samples(sipr_mode_index(self))
}

///|
fn sipr_frame_samples(mode : Int32) -> Int32 {
  let subframe_size = if mode == 0 { sipr_l_subfr_16k } else { sipr_subfr_size }
  sipr_modes[mode].subframe_count * subframe_size
}

///|
fn sipr_frames_per_packet(mode : Int32) -> Int32 {
  sipr_modes[mode].frames_per_packet
}

///|
/// The sample rate of the decoded PCM.
pub fn SiprDecoder::sample_rate(self : SiprDecoder) -> Int32 {
  self.sipr_mode().sample_rate()
}

///|
/// Bytes one packet holds.
pub fn SiprDecoder::packet_size(self : SiprDecoder) -> Int32 {
  sipr_modes[self.mode].bits_per_frame >> 3
}

///|
/// Samples one packet decodes to.
pub fn SiprDecoder::samples_per_packet(self : SiprDecoder) -> Int32 {
  sipr_frames_per_packet(self.mode) * sipr_frame_samples(self.mode)
}

///|
/// `sipr_decoder_init`. The mode follows `block_align` (20 / 19 / 29 / 37
/// bytes); any other value picks the mode from the bit rate, as the C does.
pub fn SiprDecoder::new(
  block_align : Int32,
  bit_rate~ : Int64 = 0L,
) -> SiprDecoder {
  let mode = match block_align {
    20 => 0
    19 => 1
    29 => 2
    37 => 3
    _ =>
      if bit_rate > 12200L {
        0
      } else if bit_rate > 7500L {
        1
      } else if bit_rate > 5750L {
        2
      } else {
        3
      }
  }
  let lsp_history = Array::make(sipr_lp_filter_order, 0.0)
  for i = 0; i < sipr_lp_filter_order; i = i + 1 {
    lsp_history[i] = @math.cos(
      (i + 1).to_double() * sipr_pi / (sipr_lp_filter_order + 1).to_double(),
    )
  }
  let lsp_history_16k = Array::make(16, 0.0)
  // ff_sipr_init_16k
  for i = 0; i < 16; i = i + 1 {
    lsp_history_16k[i] = @math.cos((i + 1).to_double() * sipr_pi / 17.0)
  }
  {
    mode,
    past_pitch_gain: 0.0,
    lsf_history: Array::make(16, 0.0),
    excitation: Array::make(
      sipr_l_interpol + sipr_pitch_max + 2 * sipr_l_subfr_16k,
      0.0,
    ),
    synth_buf: Array::make(sipr_lp_filter_order + 5 * sipr_subfr_size + 6, 0.0),
    lsp_history,
    gain_mem: 0.0,
    energy_history: Array::make(4, -14.0),
    highpass_filt_mem: Array::make(2, 0.0),
    postfilter_mem: Array::make(sipr_lp_filter_order, 0.0),
    postfilter_mem5k0: Array::make(sipr_lp_filter_order, 0.0),
    postfilter_syn5k0: Array::make(
      sipr_lp_filter_order + sipr_subfr_size * 5,
      0.0,
    ),
    tilt_mem: Ref(0.0),
    postfilter_agc: Ref(0.0),
    pitch_lag_prev: 180,
    iir_mem: Array::make(sipr_lp_filter_order_16k + 1, 0.0),
    filt_buf: [
      Array::make(sipr_lp_filter_order_16k + 1, 0.0),
      Array::make(sipr_lp_filter_order_16k + 1, 0.0),
    ],
    filt_sel: 0,
    mem_preemph: Array::make(sipr_lp_filter_order_16k, 0.0),
    synth: Array::make(sipr_lp_filter_order_16k, 0.0),
    lsp_history_16k,
    ir_buf: Array::make(sipr_subfr_size + sipr_lp_filter_order, 0.0),
  }
}

///|
/// `decode_parameters`: the fields of one frame, in bitstream order.
fn sipr_decode_parameters(
  gb : RealAudioBits,
  p : SiprModeParam,
) -> SiprParameters {
  let vq = FixedArray::make(5, 0)
  let pitch = FixedArray::make(5, 0)
  let gp = FixedArray::make(5, 0)
  let fc : FixedArray[FixedArray[Int32]] = FixedArray::makei(5, _ => {
    FixedArray::make(10, 0)
  })
  let gc = FixedArray::make(5, 0)
  let ma = if p.ma_predictor_bits != 0 {
    gb.read(p.ma_predictor_bits).reinterpret_as_int()
  } else {
    0
  }
  for i = 0; i < 5; i = i + 1 {
    vq[i] = gb.read(p.vq_indexes_bits[i]).reinterpret_as_int()
  }
  for i = 0; i < p.subframe_count; i = i + 1 {
    pitch[i] = gb.read(p.pitch_delay_bits[i]).reinterpret_as_int()
    if p.gp_index_bits != 0 {
      gp[i] = gb.read(p.gp_index_bits).reinterpret_as_int()
    }
    for j = 0; j < p.number_of_fc_indexes; j = j + 1 {
      fc[i][j] = gb.read(p.fc_index_bits[j]).reinterpret_as_int()
    }
    gc[i] = gb.read(p.gc_index_bits).reinterpret_as_int()
  }
  {
    ma_pred_switch: ma,
    vq_indexes: vq,
    pitch_delay: pitch,
    gp_index: gp,
    fc_indexes: fc,
    gc_index: gc,
  }
}

///|
/// `sipr_decode_frame`: decode one packet (`packet_size` bytes) into its
/// `samples_per_packet` samples. A packet below the mode's size is
/// rejected, as in the C.
pub fn SiprDecoder::decode_packet(
  self : SiprDecoder,
  pkt : Bytes,
) -> Result[Array[Double], String] {
  let p = sipr_modes[self.mode]
  if pkt.length() < p.bits_per_frame >> 3 {
    return Err("sipr: packet size (\{pkt.length()}) too small")
  }
  let frame_size = sipr_frame_samples(self.mode)
  let samples = Array::make(p.frames_per_packet * frame_size, 0.0)
  let gb = RealAudioBits::new(pkt)
  let mut out = 0
  for _i = 0; _i < p.frames_per_packet; _i = _i + 1 {
    let params = sipr_decode_parameters(gb, p)
    if self.mode == 0 {
      self.decode_frame_16k(params, samples, out)
    } else {
      self.decode_frame(params, samples, out)
    }
    out += frame_size
  }
  Ok(samples)
}
