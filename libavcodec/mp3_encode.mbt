/// MoonBit port of the shine 3.1.1 Layer III (MP3) encoder
/// (`layer3.c`, `reservoir.c` and the shared state of `types.h`).
///
/// FFmpeg 9.0.2 ships no native Layer III encoder: `libavcodec/libshine.c`
/// wraps the external shine library, which is a fixed-point ISO-11172
/// derivative. This port follows shine 3.1.1 (`src/lib/*.c`) exactly, so the
/// produced bitstream is byte-identical to the C reference for the same PCM
/// input; shine is LGPL-2.1-or-later, Copyright (c) 2002-2009 Gabriel
/// Bouvigne and the shine contributors.
///
/// Numeric path: all multiplications are the shine `mul` family —
/// `mul(a,b) = (a*b)>>32`, `mulr(a,b) = (a*b + 0x80000000)>>32`,
/// `mulsr(a,b) = (a*a + 0x40000000)>>31` — evaluated in Int64 and truncated
/// to Int32. The psychoacoustic model is shine's stub: `ratio`/`xmin` are all
/// zero, `scalefac_compress` stays 0 (so no scalefactor bits are emitted) and
/// the bit reservoir is disabled (`ResvMax == 0`, `main_data_begin == 0`);
/// `calc_scfsi` still runs and can share scalefactors between the two MPEG-1
/// granules. The frame tail is written through a 32-bit cache that carries
/// across frames (bit-continuity is what makes the concatenated per-frame
/// outputs byte-identical to the C encoder), exactly like `bitstream.c`.

///|
/// `MAX_CHANNELS` (shine supports mono/stereo only).
let mp3enc_max_channels : Int32 = 2

///|
/// `GRANULE_SIZE`.
let mp3enc_granule_size : Int32 = 576

///|
/// `SBLIMIT`.
let mp3enc_sblimit : Int32 = 32

///|
/// `HAN_SIZE` (subband window buffer, power of two).
let mp3enc_han_size : Int32 = 512

///|
/// `MAX_GRANULES`.
let mp3enc_max_granules : Int32 = 2

///|
/// `SFB_LMAX`.
let mp3enc_sfb_lmax : Int32 = 22

///|
/// MPEG versions (`layer3.h`).
let mp3enc_mpeg_25 : Int32 = 0

///|
let mp3enc_mpeg_ii : Int32 = 2

///|
let mp3enc_mpeg_i : Int32 = 3

///|
/// Channel modes (`layer3.h`).
pub let mp3enc_mode_stereo : Int32 = 0

///|
pub let mp3enc_mode_mono : Int32 = 3

///|
/// Encoder configuration; `bit_rate` is in bits per second (as in
/// `AVCodecContext.bit_rate`) and must map to a shine-supported bitrate
/// after division by 1000.
pub struct Mp3EncodeConfig {
  sample_rate : Int32
  channels : Int32
  bit_rate : Int32
}

///|
/// Build an MP3 (Layer III) encoder configuration.
pub fn mp3_encode_config(
  sample_rate : Int32,
  channels : Int32,
  bit_rate : Int32,
) -> Mp3EncodeConfig {
  { sample_rate, channels, bit_rate, }
}

///|
/// Per-granule side information (`gr_info` in `types.h`). The C fields are
/// `unsigned`, but every value stays small (|ix| <= 8192, lengths <= 4095),
/// so they are plain `Int` here; `quantizer_step_size` is signed like the C
/// `int quantizerStepSize`.
struct Mp3EncGranule {
  mut part2_3_length : Int32
  mut big_values : Int32
  mut count1 : Int32
  mut global_gain : Int32
  mut scalefac_compress : Int32
  table_select : Array[Int32]
  mut region0_count : Int32
  mut region1_count : Int32
  mut preflag : Int32
  mut scalefac_scale : Int32
  mut count1table_select : Int32
  mut part2_length : Int32
  mut address1 : Int32
  mut address2 : Int32
  mut address3 : Int32
  mut quantizer_step_size : Int32
}

///|
fn Mp3EncGranule::new() -> Mp3EncGranule {
  {
    part2_3_length: 0,
    big_values: 0,
    count1: 0,
    global_gain: 0,
    scalefac_compress: 0,
    table_select: [0, 0, 0],
    region0_count: 0,
    region1_count: 0,
    preflag: 0,
    scalefac_scale: 0,
    count1table_select: 0,
    part2_length: 0,
    address1: 0,
    address2: 0,
    address3: 0,
    quantizer_step_size: 0,
  }
}

///|
/// `shine_global_config`. All state lives inline, like the C struct.
pub struct Mp3Encoder {
  // wave
  channels : Int32
  samplerate : Int32
  // mpeg (`priv_shine_mpeg_t`)
  version : Int32
  granules_per_frame : Int32
  mode : Int32
  bitr : Int32
  emph : Int32
  mut padding : Int32
  mut bits_per_frame : Int32
  frac_slots_per_frame : Double
  mut slot_lag : Double
  whole_slots_per_frame : Int32
  bitrate_index : Int32
  samplerate_index : Int32
  copyright : Int32
  original : Int32
  // bitstream (`bitstream_t`) - the 32-bit cache carries across frames
  bs_data : Array[Byte]
  mut bs_position : Int32
  mut bs_cache : UInt32
  mut bs_cache_bits : Int32
  // side info
  sideinfo_len : Int32
  scfsi : Array[Array[Int32]]
  gr : Array[Array[Mp3EncGranule]]
  mut mean_bits : Int32
  mut resv_size : Int32
  // analysis / coding buffers
  l3_enc : Array[Array[Array[Int32]]]
  l3_sb_sample : Array[Array[Array[Array[Int32]]]]
  mdct_freq : Array[Array[Array[Int32]]]
  scalefac_l : Array[Array[Array[Int32]]]
  // l3loop scratch (`l3loop_t`)
  xrsq : Array[Int32]
  xrabs : Array[Int32]
  mut xrmax : Int32
  en_tot : Array[Int32]
  en : Array[Array[Int32]]
  xm : Array[Array[Int32]]
  xrmaxl : Array[Int32]
  // subband state (`subband_t`)
  subband_off : Array[Int32]
  subband_x : Array[Array[Int32]]
  // input cursor per channel (interleaved input, one cursor per channel)
  in_pos : Array[Int32]
  mut cur_input : Array[Int32]
  // reusable scratch
  sb_y : Array[Int32]
  mdct_in : Array[Int32]
}

///|
/// `shine_find_samplerate_index`.
pub fn mp3_encode_find_samplerate_index(freq : Int32) -> Int32 {
  for i in 0..<9 {
    if mp3enc_samplerates[i] == freq {
      return i
    }
  }
  -1
}

///|
/// `shine_mpeg_version`.
pub fn mp3_encode_mpeg_version(samplerate_index : Int32) -> Int32 {
  if samplerate_index < 3 {
    mp3enc_mpeg_i
  } else if samplerate_index < 6 {
    mp3enc_mpeg_ii
  } else {
    mp3enc_mpeg_25
  }
}

///|
/// `shine_find_bitrate_index`.
pub fn mp3_encode_find_bitrate_index(
  bitr : Int32,
  mpeg_version : Int32,
) -> Int32 {
  for i in 0..<16 {
    if mp3enc_bitrates[i * 4 + mpeg_version] == bitr {
      return i
    }
  }
  -1
}

///|
/// `shine_check_config`: -1 on error, the mpeg version on success.
pub fn mp3_encode_check_config(freq : Int32, bitr : Int32) -> Int32 {
  let samplerate_index = mp3_encode_find_samplerate_index(freq)
  if samplerate_index < 0 {
    return -1
  }
  let mpeg_version = mp3_encode_mpeg_version(samplerate_index)
  let bitrate_index = mp3_encode_find_bitrate_index(bitr, mpeg_version)
  if bitrate_index < 0 {
    return -1
  }
  mpeg_version
}

///|
/// `shine_initialise`: validate the configuration and precompute everything
/// the tables do not already cover.
pub fn mp3_encoder_new(config : Mp3EncodeConfig) -> Result[Mp3Encoder, String] {
  let freq = config.sample_rate
  let channels = config.channels
  let bitr = config.bit_rate / 1000
  if channels <= 0 || channels > mp3enc_max_channels {
    return Err("MP3 supports 1 or 2 channels")
  }
  if mp3_encode_check_config(freq, bitr) < 0 {
    return Err("MP3 unsupported sample rate / bitrate combination")
  }
  let samplerate_index = mp3_encode_find_samplerate_index(freq)
  let version = mp3_encode_mpeg_version(samplerate_index)
  let bitrate_index = mp3_encode_find_bitrate_index(bitr, version)
  let granules_per_frame : Int32 = if version == mp3enc_mpeg_i { 2 } else { 1 }
  // Figure average number of 'slots' per frame.
  let slots_base = granules_per_frame.to_double() * 576.0 / freq.to_double()
  let avg_slots_per_frame = slots_base * (1000.0 * bitr.to_double() / 8.0)
  let whole_slots_per_frame = avg_slots_per_frame.to_int()
  let frac_slots_per_frame = avg_slots_per_frame -
    whole_slots_per_frame.to_double()
  let sideinfo_len : Int32 = if granules_per_frame == 2 {
    (if channels == 1 { 4 + 17 } else { 4 + 32 }) * 8
  } else {
    (if channels == 1 { 4 + 9 } else { 4 + 17 }) * 8
  }
  let gr : Array[Array[Mp3EncGranule]] = []
  for _g in 0..<mp3enc_max_granules {
    let row : Array[Mp3EncGranule] = []
    for _c in 0..<2 {
      row.push(Mp3EncGranule::new())
    }
    gr.push(row)
  }
  let l3_enc : Array[Array[Array[Int32]]] = []
  let mdct_freq : Array[Array[Array[Int32]]] = []
  for _c in 0..<2 {
    let enc_g : Array[Array[Int32]] = []
    let mdct_g : Array[Array[Int32]] = []
    for _g in 0..<mp3enc_max_granules {
      enc_g.push(Array::make(mp3enc_granule_size, 0))
      mdct_g.push(Array::make(mp3enc_granule_size, 0))
    }
    l3_enc.push(enc_g)
    mdct_freq.push(mdct_g)
  }
  let l3_sb_sample : Array[Array[Array[Array[Int32]]]] = []
  for _c in 0..<2 {
    let slots : Array[Array[Array[Int32]]] = []
    for _s in 0..<(mp3enc_max_granules + 1) {
      let rows : Array[Array[Int32]] = []
      for _k in 0..<18 {
        rows.push(Array::make(mp3enc_sblimit, 0))
      }
      slots.push(rows)
    }
    l3_sb_sample.push(slots)
  }
  let scalefac_l : Array[Array[Array[Int32]]] = []
  for _g in 0..<mp3enc_max_granules {
    let chs : Array[Array[Int32]] = []
    for _c in 0..<2 {
      chs.push(Array::make(mp3enc_sfb_lmax + 1, 0))
    }
    scalefac_l.push(chs)
  }
  let subband_x : Array[Array[Int32]] = [
    Array::make(mp3enc_han_size, 0),
    Array::make(mp3enc_han_size, 0),
  ]
  let en : Array[Array[Int32]] = [Array::make(21, 0), Array::make(21, 0)]
  let xm : Array[Array[Int32]] = [Array::make(21, 0), Array::make(21, 0)]
  let scfsi : Array[Array[Int32]] = [Array::make(4, 0), Array::make(4, 0)]
  let encoder : Mp3Encoder = {
    channels,
    samplerate: freq,
    version,
    granules_per_frame,
    // shine_set_config_mpeg_defaults + shineenc's defaults
    mode: if channels == 1 {
      mp3enc_mode_mono
    } else {
      mp3enc_mode_stereo
    },
    bitr,
    emph: 0, // NONE
    padding: 0,
    bits_per_frame: 0,
    frac_slots_per_frame,
    slot_lag: -frac_slots_per_frame,
    whole_slots_per_frame,
    bitrate_index,
    samplerate_index,
    copyright: 0,
    original: 1,
    bs_data: Array::make(4096, b'\x00'),
    bs_position: 0,
    bs_cache: 0U,
    bs_cache_bits: 32,
    sideinfo_len,
    scfsi,
    gr,
    mean_bits: 0,
    resv_size: 0,
    l3_enc,
    l3_sb_sample,
    mdct_freq,
    scalefac_l,
    xrsq: Array::make(mp3enc_granule_size, 0),
    xrabs: Array::make(mp3enc_granule_size, 0),
    xrmax: 0,
    en_tot: Array::make(mp3enc_max_granules, 0),
    en,
    xm,
    xrmaxl: Array::make(mp3enc_max_granules, 0),
    subband_off: [0, 0],
    subband_x,
    in_pos: [0, 0],
    cur_input: [],
    sb_y: Array::make(64, 0),
    mdct_in: Array::make(36, 0),
  }
  Ok(encoder)
}

///|
/// `shine_samples_per_pass`: PCM samples per channel per frame.
pub fn Mp3Encoder::samples_per_pass(self : Mp3Encoder) -> Int32 {
  self.granules_per_frame * mp3enc_granule_size
}

///|
/// `shine_encode_buffer_internal` for one frame of interleaved input:
/// `samples` holds `samples_per_pass() * channels` int16 values. The returned
/// bytes are the frame's contribution to the continuous MP3 stream; the
/// internal bit cache carries sub-word tails into the next frame exactly like
/// the C encoder (whose `data_position` rewinds but whose `cache` persists).
pub fn Mp3Encoder::encode_frame(
  self : Mp3Encoder,
  samples : Array[Int32],
) -> Result[Bytes, String] {
  let need = self.samples_per_pass() * self.channels
  if samples.length() < need {
    return Err(
      "MP3 encoder needs \{self.samples_per_pass()} samples per channel",
    )
  }
  self.cur_input = samples
  for c in 0..<self.channels {
    self.in_pos[c] = c
  }
  if self.frac_slots_per_frame != 0.0 {
    self.padding = if self.slot_lag <= self.frac_slots_per_frame - 1.0 {
      1
    } else {
      0
    }
    self.slot_lag += self.padding.to_double() - self.frac_slots_per_frame
  }
  self.bits_per_frame = 8 * (self.whole_slots_per_frame + self.padding)
  self.mean_bits = (self.bits_per_frame - self.sideinfo_len) /
    self.granules_per_frame
  self.mdct_sub()
  self.iteration_loop()
  self.format_bitstream()
  let written = self.bs_position
  self.bs_position = 0
  let out : Array[Byte] = Array::make(written, b'\x00')
  for i in 0..<written {
    out[i] = self.bs_data[i]
  }
  Ok(Bytes::from_array(out))
}

///|
/// `shine_max_reservoir_bits`. shine never raises `ResvMax` above its initial
/// 0, so the perceptual-entropy branch is dead code upstream and the budget
/// is always the mean bits per granule per channel, capped at 4095.
fn Mp3Encoder::max_reservoir_bits(self : Mp3Encoder) -> Int32 {
  let mut mean_bits = self.mean_bits
  mean_bits = mean_bits / self.channels
  let mut max_bits = mean_bits
  if max_bits > 4095 {
    max_bits = 4095
  }
  max_bits
}

///|
/// `shine_ResvAdjust`: readjust the reservoir after a granule's allocation.
fn Mp3Encoder::resv_adjust(self : Mp3Encoder, gi : Mp3EncGranule) -> Unit {
  self.resv_size += self.mean_bits / self.channels - gi.part2_3_length
}

///|
/// `shine_ResvFrameEnd`: clamp the reservoir and turn any overflow into
/// stuffing bits appended to the first granule's main data.
fn Mp3Encoder::resv_frame_end(self : Mp3Encoder) -> Unit {
  let mut stuffing_bits = 0
  // just in case mean_bits is odd, this is necessary...
  if self.channels == 2 && (self.mean_bits & 1) == 1 {
    self.resv_size += 1
  }
  let mut over_bits = self.resv_size // - ResvMax, which is always 0
  if over_bits < 0 {
    over_bits = 0
  }
  self.resv_size -= over_bits
  stuffing_bits += over_bits
  // we must be byte aligned
  over_bits = self.resv_size % 8
  if over_bits != 0 {
    stuffing_bits += over_bits
    self.resv_size -= over_bits
  }
  if stuffing_bits != 0 {
    // plan a: put all into the first granule
    let gi = self.gr[0][0]
    if gi.part2_3_length + stuffing_bits < 4095 {
      gi.part2_3_length += stuffing_bits
    } else {
      // plan b: distribute throughout the granules
      for g in 0..<self.granules_per_frame {
        for c in 0..<self.channels {
          if stuffing_bits == 0 {
            break
          }
          let gi = self.gr[g][c]
          let extra_bits = 4095 - gi.part2_3_length
          let bits_this_gr = if extra_bits < stuffing_bits {
            extra_bits
          } else {
            stuffing_bits
          }
          gi.part2_3_length += bits_this_gr
          stuffing_bits -= bits_this_gr
        }
      }
      // any remainder would go to ancillary data (`resvDrain`), which shine
      // never writes; nothing to do here.
    }
  }
}

///|
/// Platform-independent natural log for `calc_scfsi`: only IEEE-754 double
/// operations (exact power-of-two normalisation into [1,2), then
/// `2·atanh((m-1)/(m+1))` with 25 series terms, plus `e·ln2`). The C
/// reference harness patches shine's `l3loop.c` with the same function
/// (`shine_ref_log`), because libm `log` and wasm `Math.log` differ by ulps
/// and the truncation to `Int` amplifies that into different scfsi
/// decisions near integer boundaries.
fn mp3enc_ln(x : Double) -> Double {
  let mut m = x
  let mut e = 0
  while m >= 2.0 {
    m = m / 2.0
    e += 1
  }
  while m < 1.0 {
    m = m * 2.0
    e -= 1
  }
  let t = (m - 1.0) / (m + 1.0)
  let t2 = t * t
  let mut sum = 0.0
  let mut tp = t
  for k in 0..<25 {
    sum += tp / (2 * k + 1).to_double()
    tp = tp * t2
  }
  2.0 * sum + e.to_double() * 0.6931471805599453094
}

///|
/// `calc_scfsi`: scalefactor-select information. Only the band energies
/// (`en`) carry real data — `xm` is 0 because shine's `xmin` is 0.
fn Mp3Encoder::calc_scfsi(self : Mp3Encoder, ch : Int32, gr : Int32) -> Unit {
  let scfsi_band_long : Array[Int32] = [0, 6, 11, 16, 21]
  let base = self.samplerate_index * 23
  let mut condition = 0
  self.xrmaxl[gr] = self.xrmax
  // the total energy of the granule
  let mut temp : Int32 = 0
  for i in 0..<mp3enc_granule_size {
    temp += self.xrsq[i] >> 10
  }
  // C computes log(x)/LN2 with libm log; this port uses the platform-
  // independent mp3enc_ln (the reference harness patches shine's l3loop.c
  // with the same function), so the truncation to Int is reproducible.
  self.en_tot[gr] = if temp != 0 {
    (mp3enc_ln(temp.to_double() * 4.768371584e-7) / 0.69314718).to_int()
  } else {
    0
  }
  // the energy of each scalefactor band; xm is always 0 (no psy model)
  for sfb in 0..<21 {
    let start = mp3enc_scale_fact_band_index[base + sfb]
    let end = mp3enc_scale_fact_band_index[base + sfb + 1]
    let mut temp : Int32 = 0
    for i in start..<end {
      temp += self.xrsq[i] >> 10
    }
    self.en[gr][sfb] = if temp != 0 {
      (mp3enc_ln(temp.to_double() * 4.768371584e-7) / 0.69314718).to_int()
    } else {
      0
    }
    self.xm[gr][sfb] = 0
  }
  if gr == 1 {
    for gr2 in 0..<2 {
      // The spectral values are not all zero
      if self.xrmaxl[gr2] != 0 {
        condition += 1
      }
      condition += 1
    }
    if (self.en_tot[0] - self.en_tot[1]).abs() < 10 {
      condition += 1
    }
    let mut tp = 0
    for sfb in 0..<21 {
      tp += (self.en[0][sfb] - self.en[1][sfb]).abs()
    }
    if tp < 100 {
      condition += 1
    }
    if condition == 6 {
      for band in 0..<4 {
        let mut sum0 = 0
        let mut sum1 = 0
        self.scfsi[ch][band] = 0
        let start = scfsi_band_long[band]
        let end = scfsi_band_long[band + 1]
        for sfb in start..<end {
          sum0 += (self.en[0][sfb] - self.en[1][sfb]).abs()
          sum1 += (self.xm[0][sfb] - self.xm[1][sfb]).abs()
        }
        if sum0 < 10 && sum1 < 10 {
          self.scfsi[ch][band] = 1
        } else {
          self.scfsi[ch][band] = 0
        }
      }
    } else {
      for band in 0..<4 {
        self.scfsi[ch][band] = 0
      }
    }
  }
}

///|
/// `part2_length`: bits needed for the scalefactors of one granule.
fn Mp3Encoder::part2_length(self : Mp3Encoder, gr : Int32, ch : Int32) -> Int32 {
  let gi = self.gr[gr][ch]
  let slen1 = mp3enc_slen1_tab[gi.scalefac_compress]
  let slen2 = mp3enc_slen2_tab[gi.scalefac_compress]
  let mut bits = 0
  if gr == 0 || self.scfsi[ch][0] == 0 {
    bits += 6 * slen1
  }
  if gr == 0 || self.scfsi[ch][1] == 0 {
    bits += 5 * slen1
  }
  if gr == 0 || self.scfsi[ch][2] == 0 {
    bits += 5 * slen2
  }
  if gr == 0 || self.scfsi[ch][3] == 0 {
    bits += 5 * slen2
  }
  bits
}
