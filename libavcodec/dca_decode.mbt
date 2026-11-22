/// MoonBit port of FFmpeg 9.0.2 DCA (DTS Coherent Acoustics) core decoder:
/// `dca_core.c` frame/header/subframe parsing, the residual coders, ADPCM
/// inversion, joint intensity, LFE and the fixed-point filter/output stage
/// (`ff_dca_core_filter_fixed` + `filter_frame_fixed`), plus the raw-stream
/// framing of `dcadec.c`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2016 foo86.
/// This port keeps the same license.
///
/// Scope of this slice: plain CORE frames (the XCH / XXCH / X96 / XBR / EXSS
/// extensions are detected but not decoded — a later slice). The output is
/// the fixed-point (`AV_CODEC_FLAG_BITEXACT`) path: planar S32 in FFmpeg's
/// channel order, interleaved here, each sample `clip23(x) << 8`.

///|
/// `DCA_CHANNELS` etc. */
let dca_max_channels : Int32 = 7

///|
let dca_subbands : Int32 = 32

///|
let dca_subframes : Int32 = 16

///|
let dca_subband_samples : Int32 = 8

///|
let dca_pcmblock_samples : Int32 = 32

///|
let dca_lfe_history : Int32 = 8

///|
let dca_abits_max : Int32 = 26

///|
let dca_adpcm_coeffs : Int32 = 4

///|
let dca_code_books : Int32 = 10

///|
let dca_speaker_count : Int32 = 32

// Speaker indices (DCA_SPEAKER_*).
///| removed
let _unused_dca_spk_c : Int32 = 0

///|
let dca_spk_l : Int32 = 1

///|
let dca_spk_r : Int32 = 2

///|
let dca_spk_ls : Int32 = 3

///|
let dca_spk_rs : Int32 = 4

///|
let dca_spk_lfe1 : Int32 = 5

///| removed
let _unused_dca_spk_cs : Int32 = 6

///| removed
let _unused_dca_spk_lss : Int32 = 9

///| removed
let _unused_dca_spk_rss : Int32 = 10

///|
/// `audio_mode_ch_mask` in dca_core.c. */
let dca_audio_mode_ch_mask : FixedArray[Int32] = [
  0x1, // mono: C
  0x6, // stereo
  0x6,
  0x6,
  0x6,
  0x7, // 3_0
  0x46, // 2_1 (L R Cs)
  0x47, // 3_1
  0x1E, // 2_2
  0x1F, // 5POINT0
]

///|
/// `prm_ch_to_spkr_map` in dca_core.c, flattened [amode][5]. */
let dca_prm_ch_to_spkr : FixedArray[Int32] = [
  0, -1, -1, -1, -1, 1, 2, -1, -1, -1, 1, 2, -1, -1, -1, 1, 2, -1, -1, -1, 1, 2, -1, -1, -1,
  0, 1, 2, -1, -1, 1, 2, 6, -1, -1, 0, 1, 2, 6, -1, 1, 2, 3, 4, -1, 0, 1, 2, 3, 4,
]

///|
/// `dca2wav_norm` in dcadec.c: DCA speaker → WAV channel bit. */
let dca_dca2wav_norm : FixedArray[Int32] = [
  2, 0, 1, 9, 10, 3, 8, 4, 5, 9, 10, 6, 7, 12, 13, 14, 3, 6, 7, 11, 12, 14, 16, 15, 17, 8,
  4, 5,
]

///|
/// One decoded core frame: interleaved PCM (`clip23 << 8`), so full scale is
/// 24-bit left-justified in S32, matching `ffmpeg -bitexact -f s32le`. */
pub struct DcaAudio {
  sample_rate : Int32
  channels : Int32
  samples : Array[Int32]
}

///|
/// Interleaved PCM bytes (s32le), matching FFmpeg's interleaved conversion. */
pub fn DcaAudio::pcm_bytes(self : DcaAudio) -> Bytes {
  let out : Array[Byte] = []
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
    out.push(((v >> 16) & 0xFF).to_byte())
    out.push(((v >> 24) & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// Per-channel QMF filter history (`DCADSPData`, fixed-point variant). */
struct DcaDspData {
  hist1 : FixedArray[Int32]
  mut offset : Int32
  hist2 : FixedArray[Int32]
}

///|
fn dca_dsp_data_new() -> DcaDspData {
  { hist1: FixedArray::make(1024, 0), offset: 0, hist2: FixedArray::make(64, 0) }
}

///|
/// The core decoder state. */
pub struct DcaCoreDecoder {
  // Bit stream header
  mut crc_present : Bool
  mut npcmblocks : Int32
  mut frame_size : Int32
  mut audio_mode : Int32
  mut sample_rate : Int32
  mut bit_rate : Int32
  mut drc_present : Bool
  mut ts_present : Bool
  mut aux_present : Bool
  mut ext_audio_type : Int32
  mut ext_audio_present : Bool
  mut sync_ssf : Bool
  mut lfe_present : Int32
  mut predictor_history : Bool
  mut filter_perfect : Bool
  mut source_pcm_res : Int32
  mut es_format : Int32
  mut sumdiff_front : Bool
  mut sumdiff_surround : Bool
  // Primary audio coding header
  mut nsubframes : Int32
  mut nchannels : Int32
  mut ch_mask : Int32
  nsubbands : FixedArray[Int32]
  subband_vq_start : FixedArray[Int32]
  joint_intensity_index : FixedArray[Int32]
  transition_mode_sel : FixedArray[Int32]
  scale_factor_sel : FixedArray[Int32]
  bit_allocation_sel : FixedArray[Int32]
  quant_index_sel : FixedArray[Int32] // [ch][book]
  scale_factor_adj : FixedArray[Int32] // [ch][book]
  // Side information
  nsubsubframes : FixedArray[Int32]
  prediction_mode : FixedArray[Int32] // [ch][band]
  prediction_vq_index : FixedArray[Int32]
  bit_allocation : FixedArray[Int32] // [ch][band]
  transition_mode : FixedArray[Int32] // [sf][ch][band]
  scale_factors : FixedArray[Int32] // [ch][band][2]
  joint_scale_sel : FixedArray[Int32]
  joint_scale_factors : FixedArray[Int32] // [ch][band]
  // Auxiliary data
  prim_dmix_embedded : Bool
  // Sample buffers: [ch][band] rows of ADPCM_COEFFS + npcmblocks samples
  subband_samples : Array[Array[FixedArray[Int32]]]
  lfe_samples : FixedArray[Int32]
  // Filter state
  dsp : Array[DcaDspData]
  // Output
  output_samples : Array[FixedArray[Int32]] // per speaker
  ch_remap : FixedArray[Int32]
  mut npcmsamples : Int32
  mut ext_audio_mask : Int32
}

///|
pub fn DcaCoreDecoder::new() -> DcaCoreDecoder {
  let subbands : Array[Array[FixedArray[Int32]]] = []
  for ch = 0; ch < dca_max_channels; ch = ch + 1 {
    let rows : Array[FixedArray[Int32]] = []
    for band = 0; band < dca_subbands; band = band + 1 {
      rows.push(FixedArray::make(dca_adpcm_coeffs + 128, 0))
    }
    subbands.push(rows)
  }
  let dsp : Array[DcaDspData] = []
  for ch = 0; ch < dca_max_channels; ch = ch + 1 {
    dsp.push(dca_dsp_data_new())
  }
  let outputs : Array[FixedArray[Int32]] = []
  for spkr = 0; spkr < dca_speaker_count; spkr = spkr + 1 {
    outputs.push(FixedArray::make(1, 0))
  }
  {
    crc_present: false,
    npcmblocks: 0,
    frame_size: 0,
    audio_mode: 0,
    sample_rate: 0,
    bit_rate: 0,
    drc_present: false,
    ts_present: false,
    aux_present: false,
    ext_audio_type: 0,
    ext_audio_present: false,
    sync_ssf: false,
    lfe_present: 0,
    predictor_history: false,
    filter_perfect: false,
    source_pcm_res: 16,
    es_format: 0,
    sumdiff_front: false,
    sumdiff_surround: false,
    nsubframes: 0,
    nchannels: 0,
    ch_mask: 0,
    nsubbands: FixedArray::make(dca_max_channels, 0),
    subband_vq_start: FixedArray::make(dca_max_channels, 0),
    joint_intensity_index: FixedArray::make(dca_max_channels, 0),
    transition_mode_sel: FixedArray::make(dca_max_channels, 0),
    scale_factor_sel: FixedArray::make(dca_max_channels, 0),
    bit_allocation_sel: FixedArray::make(dca_max_channels, 0),
    quant_index_sel: FixedArray::make(dca_max_channels * dca_code_books, 0),
    scale_factor_adj: FixedArray::make(dca_max_channels * dca_code_books, 0),
    nsubsubframes: FixedArray::make(dca_subframes, 0),
    prediction_mode: FixedArray::make(dca_max_channels * dca_subbands, 0),
    prediction_vq_index: FixedArray::make(dca_max_channels * dca_subbands, 0),
    bit_allocation: FixedArray::make(dca_max_channels * dca_subbands, 0),
    transition_mode: FixedArray::make(dca_subframes * dca_max_channels * dca_subbands, 0),
    scale_factors: FixedArray::make(dca_max_channels * dca_subbands * 2, 0),
    joint_scale_sel: FixedArray::make(dca_max_channels, 0),
    joint_scale_factors: FixedArray::make(dca_max_channels * dca_subbands, 0),
    prim_dmix_embedded: false,
    subband_samples: subbands,
    lfe_samples: FixedArray::make(
      dca_lfe_history + 64,
      0,
    ),
    dsp,
    output_samples: outputs,
    ch_remap: FixedArray::make(dca_speaker_count, 0),
    npcmsamples: 0,
    ext_audio_mask: 0,
  }
}

///|
/// `get_array`: `size` signed `n`-bit values. */
fn dca_get_array(
  gb : BitReader,
  array : FixedArray[Int32],
  size : Int32,
  n : Int32,
) -> Unit {
  for i = 0; i < size; i = i + 1 {
    let v = gb.read(n).reinterpret_as_int()
    array[i] = if (v & (1 << (n - 1))) != 0 {
      v - (1 << n)
    } else {
      v
    }
  }
}

///|
/// `ff_dca_parse_core_frame_header` (dca.c). Returns Err on the parse
/// errors that are fatal for well-formed core streams. */
fn DcaCoreDecoder::parse_frame_header(
  self : DcaCoreDecoder,
  gb : BitReader,
) -> Result[Unit, String] {
  if gb.read(32) != 0x7FFE8001U {
    return Err("dca: bad sync word")
  }
  let _normal_frame = gb.read1()
  let deficit = gb.read(5).reinterpret_as_int() + 1
  if deficit != dca_pcmblock_samples {
    return Err("dca: deficit samples not supported")
  }
  self.crc_present = gb.read1() != 0
  self.npcmblocks = gb.read(7).reinterpret_as_int() + 1
  if (self.npcmblocks & (dca_subband_samples - 1)) != 0 {
    return Err("dca: unsupported pcm block count")
  }
  self.frame_size = gb.read(14).reinterpret_as_int() + 1
  if self.frame_size < 96 {
    return Err("dca: invalid core frame size")
  }
  self.audio_mode = gb.read(6).reinterpret_as_int()
  if self.audio_mode >= 10 {
    return Err("dca: unsupported audio channel arrangement")
  }
  let sr_code = gb.read(4).reinterpret_as_int()
  if dca_sample_rates[sr_code] == 0 {
    return Err("dca: invalid sample rate")
  }
  let br_code = gb.read(5).reinterpret_as_int()
  if gb.read1() != 0 {
    return Err("dca: reserved bit set")
  }
  self.sample_rate = dca_sample_rates[sr_code]
  self.bit_rate = dca_bit_rates[br_code]
  self.drc_present = gb.read1() != 0
  self.ts_present = gb.read1() != 0
  self.aux_present = gb.read1() != 0
  let _hdcd = gb.read1()
  self.ext_audio_type = gb.read(3).reinterpret_as_int()
  self.ext_audio_present = gb.read1() != 0
  self.sync_ssf = gb.read1() != 0
  self.lfe_present = gb.read(2).reinterpret_as_int()
  if self.lfe_present == 3 {
    return Err("dca: invalid LFE flag")
  }
  self.predictor_history = gb.read1() != 0
  if self.crc_present {
    gb.skip(16)
  }
  self.filter_perfect = gb.read1() != 0
  let _enc_rev = gb.read(4)
  let _copy_hist = gb.read(2)
  let pcmr_code = gb.read(3).reinterpret_as_int()
  if dca_bits_per_sample[pcmr_code] == 0 {
    return Err("dca: invalid PCM resolution")
  }
  self.source_pcm_res = dca_bits_per_sample[pcmr_code]
  self.es_format = pcmr_code & 1
  self.sumdiff_front = gb.read1() != 0
  self.sumdiff_surround = gb.read1() != 0
  let _dn = gb.read(4)
  Ok(())
}

///|
/// `parse_coding_header` for the core frame. */
fn DcaCoreDecoder::parse_coding_header(
  self : DcaCoreDecoder,
  gb : BitReader,
) -> Result[Unit, String] {
  if gb.bits_left() < 0 {
    return Err("dca: read past end")
  }
  // Number of subframes
  self.nsubframes = gb.read(4).reinterpret_as_int() + 1
  // Number of primary audio channels
  self.nchannels = gb.read(3).reinterpret_as_int() + 1
  if self.nchannels != dca_channels[self.audio_mode] {
    return Err("dca: invalid channel count for audio mode")
  }
  self.ch_mask = dca_audio_mode_ch_mask[self.audio_mode]
  if self.lfe_present != 0 {
    self.ch_mask = self.ch_mask | (1 << dca_spk_lfe1)
  }
  // Subband activity count
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let n = gb.read(5).reinterpret_as_int() + 2
    if n > dca_subbands {
      return Err("dca: invalid subband activity count")
    }
    self.nsubbands[ch] = n
  }
  // High frequency VQ start subband
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    self.subband_vq_start[ch] = gb.read(5).reinterpret_as_int() + 1
  }
  // Joint intensity coding index
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let n = gb.read(3).reinterpret_as_int()
    if n > self.nchannels {
      return Err("dca: invalid joint intensity coding index")
    }
    self.joint_intensity_index[ch] = n
  }
  // Transient mode code book
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    self.transition_mode_sel[ch] = gb.read(2).reinterpret_as_int()
  }
  // Scale factor code book
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let sel = gb.read(3).reinterpret_as_int()
    if sel == 7 {
      return Err("dca: invalid scale factor code book")
    }
    self.scale_factor_sel[ch] = sel
  }
  // Bit allocation quantizer select
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let sel = gb.read(3).reinterpret_as_int()
    if sel == 7 {
      return Err("dca: invalid bit allocation quantizer select")
    }
    self.bit_allocation_sel[ch] = sel
  }
  // Quantization index codebook select
  for n = 0; n < dca_code_books; n = n + 1 {
    for ch = 0; ch < self.nchannels; ch = ch + 1 {
      self.quant_index_sel[ch * dca_code_books + n] = gb.read(
        dca_quant_index_sel_nbits[n],
      ).reinterpret_as_int()
    }
  }
  // Scale factor adjustment index
  for n = 0; n < dca_code_books; n = n + 1 {
    for ch = 0; ch < self.nchannels; ch = ch + 1 {
      if self.quant_index_sel[ch * dca_code_books + n] < dca_quant_index_group_size[n] {
        self.scale_factor_adj[ch * dca_code_books + n] = dca_scale_factor_adj[gb.read(
          2,
        ).reinterpret_as_int()]
      }
    }
  }
  // Audio header CRC check word
  if self.crc_present {
    gb.skip(16)
  }
  Ok(())
}

///|
/// `parse_scale`: differential scale factors with the selected book.
/// Returns the scale value and the updated differential index (the C keeps
/// the index alive across bands through a pointer). */
fn dca_parse_scale(
  gb : BitReader,
  scale_index : Int32,
  sel : Int32,
) -> Result[(Int32, Int32), String] {
  let (scale_table, scale_size) = if sel > 5 {
    (dca_scale_factor_quant7, 128)
  } else {
    (dca_scale_factor_quant6, 64)
  }
  let idx = if sel < 5 {
    scale_index + dca_vlc_scale_factor[sel].decode(gb)
  } else {
    gb.read(sel + 1).reinterpret_as_int()
  }
  if idx < 0 || idx >= scale_size {
    return Err("dca: invalid scale factor index")
  }
  Ok((scale_table[idx], idx))
}

///|
/// `parse_joint_scale`. */
fn dca_parse_joint_scale(gb : BitReader, sel : Int32) -> Result[Int32, String] {
  let scale_index = (if sel < 5 {
    dca_vlc_scale_factor[sel].decode(gb)
  } else {
    gb.read(sel + 1).reinterpret_as_int()
  }) + 64
  if scale_index < 0 || scale_index >= 129 {
    return Err("dca: invalid joint scale factor index")
  }
  Ok(dca_joint_scale_factors[scale_index])
}

///|
/// `parse_subframe_header`. */
fn DcaCoreDecoder::parse_subframe_header(
  self : DcaCoreDecoder,
  gb : BitReader,
  sf : Int32,
) -> Result[Unit, String] {
  if gb.bits_left() < 0 {
    return Err("dca: read past end")
  }
  // Subsubframe count, partial sample count
  self.nsubsubframes[sf] = gb.read(2).reinterpret_as_int() + 1
  gb.skip(3)
  // Prediction mode
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    for band = 0; band < self.nsubbands[ch]; band = band + 1 {
      self.prediction_mode[ch * dca_subbands + band] = gb.read1().reinterpret_as_int()
    }
  }
  // Prediction coefficients VQ address
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    for band = 0; band < self.nsubbands[ch]; band = band + 1 {
      if self.prediction_mode[ch * dca_subbands + band] != 0 {
        self.prediction_vq_index[ch * dca_subbands + band] = gb.read(
          12,
        ).reinterpret_as_int()
      }
    }
  }
  // Bit allocation index
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let sel = self.bit_allocation_sel[ch]
    for band = 0; band < self.subband_vq_start[ch]; band = band + 1 {
      let abits = if sel < 5 {
        dca_vlc_bit_allocation[sel].decode(gb)
      } else {
        gb.read(sel - 1).reinterpret_as_int()
      }
      if abits > dca_abits_max {
        return Err("dca: invalid bit allocation index")
      }
      self.bit_allocation[ch * dca_subbands + band] = abits
    }
  }
  // Transition mode
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    for band = 0; band < dca_subbands; band = band + 1 {
      self.transition_mode[(sf * dca_max_channels + ch) * dca_subbands + band] = 0
    }
    if self.nsubsubframes[sf] > 1 {
      let sel = self.transition_mode_sel[ch]
      for band = 0; band < self.subband_vq_start[ch]; band = band + 1 {
        if self.bit_allocation[ch * dca_subbands + band] != 0 {
          self.transition_mode[(sf * dca_max_channels + ch) * dca_subbands + band] = dca_vlc_transition_mode[sel].decode(
            gb,
          )
        }
      }
    }
  }
  // Scale factors
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let sel = self.scale_factor_sel[ch]
    let mut scale_index = 0
    // Subbands up to VQ
    for band = 0; band < self.subband_vq_start[ch]; band = band + 1 {
      if self.bit_allocation[ch * dca_subbands + band] != 0 {
        let (sc, idx) = match dca_parse_scale(gb, scale_index, sel) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        scale_index = idx
        self.scale_factors[(ch * dca_subbands + band) * 2] = sc
        if self.transition_mode[(sf * dca_max_channels + ch) * dca_subbands + band] != 0 {
          let (sc2, idx2) = match dca_parse_scale(gb, scale_index, sel) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          scale_index = idx2
          self.scale_factors[(ch * dca_subbands + band) * 2 + 1] = sc2
        }
      } else {
        self.scale_factors[(ch * dca_subbands + band) * 2] = 0
      }
    }
    // High frequency VQ subbands
    for band = self.subband_vq_start[ch]; band < self.nsubbands[ch]; band = band + 1 {
      let (sc, idx) = match dca_parse_scale(gb, scale_index, sel) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      scale_index = idx
      self.scale_factors[(ch * dca_subbands + band) * 2] = sc
    }
  }
  // Joint subband codebook select
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    if self.joint_intensity_index[ch] != 0 {
      let sel = gb.read(3).reinterpret_as_int()
      if sel == 7 {
        return Err("dca: invalid joint scale factor code book")
      }
      self.joint_scale_sel[ch] = sel
    }
  }
  // Scale factors for joint subband coding
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let src_ch = self.joint_intensity_index[ch] - 1
    if src_ch >= 0 {
      let sel = self.joint_scale_sel[ch]
      for band = self.nsubbands[ch]; band < self.nsubbands[src_ch]; band = band + 1 {
        let sc = match dca_parse_joint_scale(gb, sel) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        self.joint_scale_factors[ch * dca_subbands + band] = sc
      }
    }
  }
  // Dynamic range coefficient
  if self.drc_present {
    gb.skip(8)
  }
  // Side information CRC
  if self.crc_present {
    gb.skip(16)
  }
  Ok(())
}

///|
/// `decode_blockcodes`: 4+4 samples packed as two integer codes. Returns the
/// leftover code bits (nonzero means an invalid code). */
fn dca_decode_blockcodes(
  code1 : Int32,
  code2 : Int32,
  levels : Int32,
  audio : FixedArray[Int32],
) -> Int32 {
  let offset = (levels - 1) / 2
  let mut c1 = code1
  let mut c2 = code2
  for n = 0; n < dca_subband_samples / 2; n = n + 1 {
    let div = c1 / levels
    audio[n] = c1 - div * levels - offset
    c1 = div
  }
  for n = dca_subband_samples / 2; n < dca_subband_samples; n = n + 1 {
    let div = c2 / levels
    audio[n] = c2 - div * levels - offset
    c2 = div
  }
  c1 | c2
}

///|
/// `parse_block_codes`. */
fn dca_parse_block_codes(
  gb : BitReader,
  audio : FixedArray[Int32],
  abits : Int32,
) -> Result[Unit, String] {
  let nbits = dca_block_code_nbits[abits - 1]
  let code1 = gb.read(nbits).reinterpret_as_int()
  let code2 = gb.read(nbits).reinterpret_as_int()
  let levels = dca_quant_levels[abits]
  if dca_decode_blockcodes(code1, code2, levels, audio) != 0 {
    return Err("dca: failed to decode block code")
  }
  Ok(())
}

///|
/// `parse_huffman_codes`: 8 residual values from the selected book. */
fn dca_parse_huffman_codes(
  gb : BitReader,
  audio : FixedArray[Int32],
  abits : Int32,
  sel : Int32,
) -> Unit {
  let book = dca_quant_vlc(abits, sel)
  for i = 0; i < dca_subband_samples; i = i + 1 {
    audio[i] = book.decode(gb)
  }
}

///|
/// `extract_audio`: returns true when Huffman (differential scale adjust). */
fn DcaCoreDecoder::extract_audio(
  self : DcaCoreDecoder,
  gb : BitReader,
  audio : FixedArray[Int32],
  abits : Int32,
  ch : Int32,
) -> Result[Bool, String] {
  if abits == 0 {
    for i = 0; i < dca_subband_samples; i = i + 1 {
      audio[i] = 0
    }
    return Ok(false)
  }
  if abits <= dca_code_books {
    let sel = self.quant_index_sel[ch * dca_code_books + (abits - 1)]
    if sel < dca_quant_index_group_size[abits - 1] {
      dca_parse_huffman_codes(gb, audio, abits, sel)
      return Ok(true)
    }
    if abits <= 7 {
      match dca_parse_block_codes(gb, audio, abits) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      return Ok(false)
    }
  }
  dca_get_array(gb, audio, dca_subband_samples, abits - 3)
  Ok(false)
}

///|
/// `ff_dcaadpcm_predict`. */
fn dca_adpcm_predict(pred_vq : Int32, hist : FixedArray[Int32], hist_off : Int32) -> Int32 {
  let mut pred : Int64 = 0
  for i = 0; i < dca_adpcm_coeffs; i = i + 1 {
    pred += hist[hist_off - 1 - i].to_int64() * dca_adpcm_vb[pred_vq * 4 + i].to_int64()
  }
  dca_clip23(dca_norm13(pred))
}

///|
/// `inverse_adpcm`. */
fn dca_inverse_adpcm(
  subband_samples : Array[FixedArray[Int32]],
  vq_index : FixedArray[Int32],
  prediction_mode : FixedArray[Int32],
  ch : Int32,
  sb_start : Int32,
  sb_end : Int32,
  ofs : Int32,
  len : Int32,
) -> Unit {
  for i = sb_start; i < sb_end; i = i + 1 {
    if prediction_mode[ch * dca_subbands + i] != 0 {
      let pred_id = vq_index[ch * dca_subbands + i]
      let ptr = subband_samples[i]
      for j = 0; j < len; j = j + 1 {
        let pos = dca_adpcm_coeffs + ofs + j
        let x = dca_adpcm_predict(pred_id, ptr, pos)
        ptr[pos] = dca_clip23(ptr[pos] + x)
      }
    }
  }
}

///|
/// `parse_subframe_audio`. */
fn DcaCoreDecoder::parse_subframe_audio(
  self : DcaCoreDecoder,
  gb : BitReader,
  sf : Int32,
  sub_pos_ref : DcaRef,
  lfe_pos_ref : DcaRef,
) -> Result[Unit, String] {
  let audio : FixedArray[Int32] = FixedArray::make(16, 0)
  let vq_index : FixedArray[Int32] = FixedArray::make(dca_subbands, 0)
  let nsamples = self.nsubsubframes[sf] * dca_subband_samples
  let sub_pos = sub_pos_ref.val
  let lfe_pos = lfe_pos_ref.val
  if sub_pos + nsamples > self.npcmblocks {
    return Err("dca: subband sample buffer overflow")
  }
  if gb.bits_left() < 0 {
    return Err("dca: read past end")
  }
  // VQ encoded subbands
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    for band = self.subband_vq_start[ch]; band < self.nsubbands[ch]; band = band + 1 {
      vq_index[band] = gb.read(10).reinterpret_as_int()
    }
    if self.subband_vq_start[ch] < self.nsubbands[ch] {
      dca_decode_hf(
        self.subband_samples[ch],
        vq_index,
        self.scale_factors,
        ch * dca_subbands * 2,
        self.subband_vq_start[ch],
        self.nsubbands[ch],
        sub_pos,
        nsamples,
      )
    }
  }
  // Low frequency effect data
  let mut lfe_ofs = lfe_pos
  if self.lfe_present != 0 {
    let nlfesamples = 2 * self.lfe_present * self.nsubsubframes[sf]
    dca_get_array(gb, audio, nlfesamples, 8)
    let index = gb.read(8).reinterpret_as_int()
    if index >= 128 {
      return Err("dca: invalid LFE scale factor index")
    }
    let mut scale = dca_scale_factor_quant7[index]
    // Quantizer step size 0.035 in 2^27 fixed point
    scale = dca_mul23(4697620, scale)
    for n = 0; n < nlfesamples; n = n + 1 {
      self.lfe_samples[lfe_ofs] = dca_clip23((audio[n] * scale) >> 4)
      lfe_ofs += 1
    }
  }
  // Audio data
  let mut ofs = sub_pos
  for ssf = 0; ssf < self.nsubsubframes[sf]; ssf = ssf + 1 {
    for ch = 0; ch < self.nchannels; ch = ch + 1 {
      if gb.bits_left() < 0 {
        return Err("dca: read past end")
      }
      for band = 0; band < self.subband_vq_start[ch]; band = band + 1 {
        let abits = self.bit_allocation[ch * dca_subbands + band]
        let huff = match self.extract_audio(gb, audio, abits, ch) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let step_size = if self.bit_rate == 3 {
          dca_lossless_quant[abits]
        } else {
          dca_lossy_quant[abits]
        }
        let trans_ssf = self.transition_mode[(sf * dca_max_channels + ch) * dca_subbands + band]
        let mut scale = if trans_ssf == 0 || ssf < trans_ssf {
          self.scale_factors[(ch * dca_subbands + band) * 2]
        } else {
          self.scale_factors[(ch * dca_subbands + band) * 2 + 1]
        }
        if huff {
          let adj = self.scale_factor_adj[ch * dca_code_books + (abits - 1)]
          scale = dca_clip23(((adj.to_int64() * scale.to_int64()) >> 22).to_int())
        }
        let row = self.subband_samples[ch][band]
        dca_core_dequantize(row, dca_adpcm_coeffs + ofs, audio, step_size, scale, false, dca_subband_samples)
      }
    }
    // DSYNC
    if (ssf == self.nsubsubframes[sf] - 1 || self.sync_ssf) && gb.read(16) != 0xFFFFU {
      return Err("dca: DSYNC check failed")
    }
    ofs += dca_subband_samples
  }
  // Inverse ADPCM
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    dca_inverse_adpcm(
      self.subband_samples[ch],
      self.prediction_vq_index,
      self.prediction_mode,
      ch,
      0,
      self.nsubbands[ch],
      sub_pos,
      nsamples,
    )
  }
  // Joint subband coding
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let src_ch = self.joint_intensity_index[ch] - 1
    if src_ch >= 0 {
      dca_decode_joint(
        self.subband_samples[ch],
        self.subband_samples[src_ch],
        self.joint_scale_factors,
        ch * dca_subbands,
        self.nsubbands[ch],
        self.nsubbands[src_ch],
        sub_pos,
        nsamples,
      )
    }
  }
  sub_pos_ref.val = ofs
  lfe_pos_ref.val = lfe_ofs
  Ok(())
}

///|
/// A tiny mutable cell for out-parameters. */
priv struct DcaRef {
  mut val : Int32
}

///|
/// `parse_frame_data` (HEADER_CORE). */
fn DcaCoreDecoder::parse_frame_data(
  self : DcaCoreDecoder,
  gb : BitReader,
) -> Result[Unit, String] {
  match self.parse_coding_header(gb) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  let sub_pos = { val: 0 }
  let lfe_pos = { val: dca_lfe_history }
  for sf = 0; sf < self.nsubframes; sf = sf + 1 {
    match self.parse_subframe_header(gb, sf) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    match self.parse_subframe_audio(gb, sf, sub_pos, lfe_pos) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    // Active subband count for this channel
    let mut nsubbands = self.nsubbands[ch]
    if self.joint_intensity_index[ch] != 0 {
      let src = self.nsubbands[self.joint_intensity_index[ch] - 1]
      if src > nsubbands {
        nsubbands = src
      }
    }
    // Update ADPCM history: last ADPCM_COEFFS samples of this frame become
    // the next frame's history (the row layout keeps `ADPCM_COEFFS + 128`
    // samples; rows are index-adjoined by the caller's row allocation).
    let row_size = dca_adpcm_coeffs + self.npcmblocks
    for band = 0; band < nsubbands; band = band + 1 {
      let row = self.subband_samples[ch][band]
      for i = 0; i < dca_adpcm_coeffs; i = i + 1 {
        row[i] = row[dca_adpcm_coeffs + self.npcmblocks - dca_adpcm_coeffs + i]
      }
      ignore(row_size)
    }
    // Clear inactive subbands
    for band = nsubbands; band < dca_subbands; band = band + 1 {
      let row = self.subband_samples[ch][band]
      for i = 0; i < row.length(); i = i + 1 {
        row[i] = 0
      }
    }
  }
  Ok(())
}

///|
/// Erase ADPCM history when the predictor history switch is disabled. */
fn DcaCoreDecoder::erase_adpcm_history(self : DcaCoreDecoder) -> Unit {
  for ch = 0; ch < dca_max_channels; ch = ch + 1 {
    for band = 0; band < dca_subbands; band = band + 1 {
      let row = self.subband_samples[ch][band]
      for i = 0; i < dca_adpcm_coeffs; i = i + 1 {
        row[i] = 0
      }
    }
  }
}

///|
/// `ff_dca_core_parse` for one core frame (extensions skipped). */
fn DcaCoreDecoder::core_parse(
  self : DcaCoreDecoder,
  data : Bytes,
) -> Result[Unit, String] {
  self.ext_audio_mask = 0
  let gb = BitReader::new(data)
  match self.parse_frame_header(gb) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // The sample rows must fit ADPCM_COEFFS + npcmblocks samples.
  if self.npcmblocks > 128 {
    return Err("dca: too many pcm blocks")
  }
  if !self.predictor_history {
    self.erase_adpcm_history()
  }
  match self.parse_frame_data(gb) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  // Optional info (time stamps, auxiliary data, core extension sync words)
  // is skipped: this slice decodes plain core frames only, and the C parser
  // seeks to the end of the core frame afterwards regardless.
  let frame_size = if self.frame_size > data.length() {
    data.length()
  } else {
    self.frame_size
  }
  ignore(frame_size)
  Ok(())
}

///|
/// `ff_dca_set_channel_layout` (default WAV order): build `ch_remap` and
/// return the channel count. */
fn DcaCoreDecoder::set_channel_layout(self : DcaCoreDecoder, dca_mask : Int32) -> Int32 {
  let mut nchannels = 0
  let wav_mask : FixedArray[Int32] = FixedArray::make(18, 0)
  let wav_map : FixedArray[Int32] = FixedArray::make(18, 0)
  for dca_ch = 0; dca_ch < 28; dca_ch = dca_ch + 1 {
    if (dca_mask & (1 << dca_ch)) != 0 {
      let wav_ch = dca_dca2wav_norm[dca_ch]
      if (wav_mask[wav_ch] == 0) {
        wav_map[wav_ch] = dca_ch
        wav_mask[wav_ch] = 1
      }
    }
  }
  for wav_ch = 0; wav_ch < 18; wav_ch = wav_ch + 1 {
    if wav_mask[wav_ch] != 0 {
      self.ch_remap[nchannels] = wav_map[wav_ch]
      nchannels += 1
    }
  }
  nchannels
}

///|
/// `map_prm_ch_to_spkr` for the plain core (no XCH/XXCH). */
fn DcaCoreDecoder::map_prm_ch_to_spkr(self : DcaCoreDecoder, ch : Int32) -> Int32 {
  if ch < dca_channels[self.audio_mode] {
    return dca_prm_ch_to_spkr[self.audio_mode * 5 + ch]
  }
  -1
}

///|
/// `ff_dca_core_filter_fixed` + the fixed output stage of
/// `filter_frame_fixed`: QMF per channel, LFE, sum/difference decoding and
/// the clip23<<8 interleaved output. */
fn DcaCoreDecoder::filter_fixed(self : DcaCoreDecoder) -> Result[DcaAudio, String] {
  let nsamples = self.npcmblocks * dca_pcmblock_samples
  self.npcmsamples = nsamples
  // Speaker-mapped planar buffers
  for spkr = 0; spkr < dca_speaker_count; spkr = spkr + 1 {
    if (self.ch_mask & (1 << spkr)) != 0 {
      self.output_samples[spkr] = FixedArray::make(nsamples, 0)
    }
  }
  // Select the prototype filter
  let filter_coeff = if self.filter_perfect {
    dca_fir_32bands_perfect_fixed
  } else {
    dca_fir_32bands_nonperfect_fixed
  }
  // Filter primary channels (sub_qmf32_fixed_c)
  let input : FixedArray[Int32] = FixedArray::make(32, 0)
  for ch = 0; ch < self.nchannels; ch = ch + 1 {
    let spkr = self.map_prm_ch_to_spkr(ch)
    if spkr < 0 {
      return Err("dca: cannot map channel to speaker")
    }
    let out = self.output_samples[spkr]
    let dsp = self.dsp[ch]
    for j = 0; j < self.npcmblocks; j = j + 1 {
      for i = 0; i < 32; i = i + 1 {
        input[i] = self.subband_samples[ch][i][dca_adpcm_coeffs + j]
      }
      dsp.offset = dca_synth_filter_fixed_32(
        dsp.hist1,
        dsp.offset,
        dsp.hist2,
        filter_coeff,
        out,
        j * 32,
        input,
      )
    }
  }
  // Filter LFE channel
  if self.lfe_present != 0 {
    if self.lfe_present == 1 {
      return Err("dca: fixed point mode doesn't support LFF=1")
    }
    let samples = self.output_samples[dca_spk_lfe1]
    let nlfesamples = self.npcmblocks >> 1
    dca_lfe_fir_fixed(samples, 0, self.lfe_samples, dca_lfe_history, self.npcmblocks)
    // Update LFE history
    for n = 0; n < dca_lfe_history; n = n + 1 {
      self.lfe_samples[n] = self.lfe_samples[nlfesamples + n]
    }
  }
  // Front sum/difference decoding
  if self.sumdiff_front && self.audio_mode > 0 {
    dca_butterflies_fixed(
      self.output_samples[dca_spk_l],
      self.output_samples[dca_spk_r],
      nsamples,
    )
  }
  // Surround sum/difference decoding
  if self.sumdiff_surround && self.audio_mode >= 8 {
    dca_butterflies_fixed(
      self.output_samples[dca_spk_ls],
      self.output_samples[dca_spk_rs],
      nsamples,
    )
  }
  // Output: interleave each frame channel in WAV order, clip23 << 8
  let nch = self.set_channel_layout(self.ch_mask)
  let out : Array[Int32] = []
  for n = 0; n < nsamples; n = n + 1 {
    for i = 0; i < nch; i = i + 1 {
      out.push(dca_clip23(self.output_samples[self.ch_remap[i]][n]) * (1 << 8))
    }
  }
  Ok({
    sample_rate: self.sample_rate,
    channels: nch,
    samples: out,
  })
}

///|
/// Decode one DCA core frame (a `0x7FFE8001`-delimited packet). Returns
/// `None` for packets that carry no core frame. */
pub fn DcaCoreDecoder::decode_packet(
  self : DcaCoreDecoder,
  data : Bytes,
) -> Result[Option[DcaAudio], String] {
  if data.length() < 16 {
    return Err("dca: invalid packet size")
  }
  if dca_rb32(data, 0) == 0x7FFE8001U {
    match self.core_parse(data) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    // Try the 14-bit / little-endian layouts (avpriv_dca_convert_bitstream).
    let converted = match dca_convert_bitstream(data) {
      Some(b) => b
      None => return Err("dca: not a valid DCA frame")
    }
    match self.core_parse(converted) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  match self.filter_fixed() {
    Ok(a) => Ok(Some(a))
    Err(e) => Err(e)
  }
}

///|
fn dca_rb32(b : Bytes, i : Int32) -> UInt32 {
  (b[i].to_uint() << 24) |
  (b[i + 1].to_uint() << 16) |
  (b[i + 2].to_uint() << 8) |
  b[i + 3].to_uint()
}

///|
fn dca_rb16(b : Bytes, i : Int32) -> UInt32 {
  (b[i].to_uint() << 8) | b[i + 1].to_uint()
}

///|
fn dca_rl16(b : Bytes, i : Int32) -> UInt32 {
  b[i].to_uint() | (b[i + 1].to_uint() << 8)
}

///|
fn dca_wb16(b : Array[Byte], i : Int32, v : UInt32) -> Unit {
  b[i] = ((v >> 8) & 0xFF).to_byte()
  b[i + 1] = (v & 0xFF).to_byte()
}

///|
/// `avpriv_dca_convert_bitstream`: 14-bit and little-endian layouts to
/// big-endian 16-bit. */
fn dca_convert_bitstream(src : Bytes) -> Option[Bytes] {
  let mrk = dca_rb32(src, 0)
  if mrk == 0x7FFE8001U || mrk == 0x64582025U {
    return Some(src)
  }
  if mrk == 0x0180FE7FU {
    // little-endian core: byte-swap each 16-bit word
    let out : Array[Byte] = Array::make(src.length(), b'\x00')
    let n = (src.length() + 1) >> 1
    for i = 0; i < n; i = i + 1 {
      dca_wb16(out, i * 2, dca_rl16(src, i * 2))
    }
    return Some(Bytes::from_array(out))
  }
  if mrk == 0x7FF0800FU || mrk == 0xF00F7FF0U || mrk == 0x0F80F07FU || mrk == 0x7F0FF00FU {
    // 14-bit: repack every 14 bits as 16
    let out : Array[Byte] = []
    let big_endian = mrk == 0x7FF0800FU || mrk == 0xF00F7FF0U
    let mut acc : UInt32 = 0
    let mut nbits = 0
    for i = 0; i < (src.length() + 1) >> 1; i = i + 1 {
      let w = if big_endian {
        dca_rb16(src, i * 2)
      } else {
        dca_rl16(src, i * 2)
      }
      let v = w & 0x3FFFU
      acc = (acc << 14) | v
      nbits += 14
      while nbits >= 16 {
        nbits -= 16
        let w = (acc >> nbits) & 0xFFFFU
        out.push(((w >> 8) & 0xFF).to_byte())
        out.push((w & 0xFF).to_byte())
      }
    }
    return Some(Bytes::from_array(out))
  }
  None
}

///|
/// Decode a raw DCA elementary stream: frames are found by the core sync
/// word and stepped by the frame's own size field. */
pub fn DcaCoreDecoder::decode_stream(
  self : DcaCoreDecoder,
  data : Bytes,
) -> Result[DcaAudio, String] {
  let out : Array[Int32] = []
  let mut sample_rate = 0
  let mut channels = 0
  let mut pos = 0
  while pos + 4 <= data.length() {
    if dca_rb32(data, pos) != 0x7FFE8001U {
      // Scan forward to the next core sync word
      let mut next = -1
      let mut p = pos
      while p + 4 <= data.length() {
        if dca_rb32(data, p) == 0x7FFE8001U {
          next = p
          break
        }
        p += 1
      }
      if next < 0 {
        break
      }
      pos = next
    }
    // Frame length from the header: bits 46..59 of the frame (14 bits + 1)
    let frame_size = (((dca_rb32(data, pos + 4) >> 4) & 0x3FFFU) + 1).reinterpret_as_int()
    if frame_size < 96 || pos + frame_size > data.length() {
      // Trust the remaining buffer as one last frame
      let end = data.length()
      if end - pos >= 16 {
        match self.decode_packet(data[pos:end].to_owned()) {
          Ok(Some(au)) => {
            sample_rate = au.sample_rate
            channels = au.channels
            for v in au.samples {
              out.push(v)
            }
          }
          Ok(None) => ()
          Err(e) => return Err(e)
        }
      }
      pos = end
      break
    }
    let frame = data[pos : pos + frame_size].to_owned()
    match self.decode_packet(frame) {
      Ok(Some(au)) => {
        sample_rate = au.sample_rate
        channels = au.channels
        for v in au.samples {
          out.push(v)
        }
      }
      Ok(None) => ()
      Err(e) => return Err(e)
    }
    // Core frames are 4-byte aligned in raw streams
    let step = (frame_size + 3) & -4
    pos += step
  }
  if sample_rate == 0 {
    return Err("dca: no decodable core frames")
  }
  Ok({ sample_rate, channels, samples: out })
}

///|
/// One-shot raw DTS core stream decode. */
pub fn ff_dca_decode_stream(data : Bytes) -> Result[DcaAudio, String] {
  DcaCoreDecoder::new().decode_stream(data)
}
