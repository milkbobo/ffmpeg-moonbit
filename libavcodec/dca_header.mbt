///|
/// DTS core header parsing and packed-word conversion from FFmpeg `dca.c`
/// (LGPL-2.1-or-later; copyright Gildas Bazin, Benjamin Zores,
/// Benjamin Larsson and Konstantin Shishkov). Only core sync words are valid.
pub struct DcaCoreHeader {
  /// Frame length in source bytes, including any packing bits.
  frame_size : Int32
  /// Per-channel decoded PCM sample count.
  samples : Int32
  sample_rate : Int32
  /// Core channels including LFE, excluding any extension channels.
  channels : Int32
  /// Speaker mask in the decoder's WAV channel order.
  channel_mask : UInt32
}

///|
priv enum DcaPacking {
  Be16
  Le16
  Be14
  Le14
}

///|
fn dca_packing(src : BytesView) -> DcaPacking? {
  match src {
    [0x7f, 0xfe, 0x80, 0x01, ..] => Some(Be16)
    [0xfe, 0x7f, 0x01, 0x80, ..] => Some(Le16)
    [0x1f, 0xff, 0xe8, 0x00, ..] => Some(Be14)
    [0xff, 0x1f, 0x00, 0xe8, ..] => Some(Le14)
    _ => None
  }
}

///|
/// Convert a complete word sequence to the decoder's native 16-bit BE form.
fn DcaPacking::normalize(self : DcaPacking, src : BytesView) -> Bytes {
  match self {
    Be16 => src.to_owned()
    Le16 => Bytes::makei(src.length(), i => src[i ^ 1])
    Be14 | Le14 => {
      let out : Array[Byte] = []
      let mut acc : UInt32 = 0
      let mut bits = 0
      for i in 0..<(src.length() / 2) {
        let a = src[2 * i].to_int().reinterpret_as_uint()
        let b = src[2 * i + 1].to_int().reinterpret_as_uint()
        let word = match self {
          Be14 => (a << 8) | b
          _ => (b << 8) | a
        }
        acc = (acc << 14) | (word & 0x3FFFU)
        bits += 14
        while bits >= 8 {
          bits -= 8
          out.push((acc >> bits).to_byte())
        }
      }
      if bits > 0 {
        out.push((acc << (8 - bits)).to_byte())
      }
      Bytes::from_array(out)
    }
  }
}

///|
/// Parse a DTS core header at the start of `src`. The frame body need not be
/// present: compare `frame_size` to available bytes before slicing a packet.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.parse_dca_core_header(b"\x7f\xfe\x80\x01") is Err(_))
/// }
/// ```
pub fn parse_dca_core_header(src : BytesView) -> Result[DcaCoreHeader, String] {
  guard dca_packing(src) is Some(packing) else {
    return Err("dca: bad sync word")
  }
  // The longest canonical header is 120 bits, so 18 source bytes are enough
  // even with 14 payload bits per word. Use only the prefix, not the payload.
  let n = match packing {
    Be16 => src.length().min(16)
    Le16 => src.length().min(16) & -2
    Be14 | Le14 => src.length().min(18) & -2
  }
  let gb = BitReader::new(packing.normalize(src[:n]))
  let h = match dca_parse_core_fields(gb) {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  let frame_size = match packing {
    Be16 => h.frame_size
    Le16 => (h.frame_size + 1) & -2
    Be14 | Le14 => (h.frame_size * 8 + 13) / 14 * 2
  }
  let speakers = dca_audio_mode_ch_mask[h.audio_mode] |
    (if h.lfe_present != 0 { 1 << dca_spk_lfe1 } else { 0 })
  let mut channel_mask = 0U
  for i in 0..<dca_dca2wav_norm.length() {
    if (speakers & (1 << i)) != 0 {
      channel_mask = channel_mask | (1U << dca_dca2wav_norm[i])
    }
  }
  Ok({
    frame_size,
    samples: h.npcmblocks * dca_pcmblock_samples,
    sample_rate: h.sample_rate,
    channels: dca_channels[h.audio_mode] +
    (if h.lfe_present != 0 { 1 } else { 0 }),
    channel_mask,
  })
}

///|
priv struct DcaCoreFields {
  crc_present : Bool
  npcmblocks : Int32
  frame_size : Int32
  audio_mode : Int32
  sample_rate : Int32
  bit_rate : Int32
  drc_present : Bool
  ts_present : Bool
  aux_present : Bool
  ext_audio_type : Int32
  ext_audio_present : Bool
  sync_ssf : Bool
  lfe_present : Int32
  predictor_history : Bool
  filter_perfect : Bool
  source_pcm_res : Int32
  es_format : Int32
  sumdiff_front : Bool
  sumdiff_surround : Bool
}

///|
fn dca_parse_core_fields(gb : BitReader) -> Result[DcaCoreFields, String] {
  if gb.bits_left() < 104 {
    return Err("dca: truncated core header")
  }
  if gb.read(32) != 0x7FFE8001U {
    return Err("dca: bad sync word")
  }
  gb.skip(1) // normal_frame
  let deficit = gb.read(5).reinterpret_as_int() + 1
  if deficit != dca_pcmblock_samples {
    return Err("dca: deficit samples not supported")
  }
  let crc_present = gb.read1() != 0
  let npcmblocks = gb.read(7).reinterpret_as_int() + 1
  if (npcmblocks & (dca_subband_samples - 1)) != 0 {
    return Err("dca: unsupported pcm block count")
  }
  let frame_size = gb.read(14).reinterpret_as_int() + 1
  if frame_size < 96 {
    return Err("dca: invalid core frame size")
  }
  let audio_mode = gb.read(6).reinterpret_as_int()
  if audio_mode >= 10 {
    return Err("dca: unsupported audio channel arrangement")
  }
  let sr_code = gb.read(4).reinterpret_as_int()
  let sample_rate = dca_sample_rates[sr_code]
  if sample_rate == 0 {
    return Err("dca: invalid sample rate")
  }
  let br_code = gb.read(5).reinterpret_as_int()
  if gb.read1() != 0 {
    return Err("dca: reserved bit set")
  }
  let drc_present = gb.read1() != 0
  let ts_present = gb.read1() != 0
  let aux_present = gb.read1() != 0
  gb.skip(1) // hdcd_master
  let ext_audio_type = gb.read(3).reinterpret_as_int()
  let ext_audio_present = gb.read1() != 0
  let sync_ssf = gb.read1() != 0
  let lfe_present = gb.read(2).reinterpret_as_int()
  if lfe_present == 3 {
    return Err("dca: invalid LFE flag")
  }
  let predictor_history = gb.read1() != 0
  if crc_present {
    if gb.bits_left() < 32 {
      return Err("dca: truncated core header")
    }
    gb.skip(16)
  }
  let filter_perfect = gb.read1() != 0
  gb.skip(6) // encoder_rev and copy_hist
  let pcmr_code = gb.read(3).reinterpret_as_int()
  let source_pcm_res = dca_bits_per_sample[pcmr_code]
  if source_pcm_res == 0 {
    return Err("dca: invalid PCM resolution")
  }
  let sumdiff_front = gb.read1() != 0
  let sumdiff_surround = gb.read1() != 0
  gb.skip(4) // dn_code
  Ok({
    crc_present,
    npcmblocks,
    frame_size,
    audio_mode,
    sample_rate,
    bit_rate: dca_bit_rates[br_code],
    drc_present,
    ts_present,
    aux_present,
    ext_audio_type,
    ext_audio_present,
    sync_ssf,
    lfe_present,
    predictor_history,
    filter_perfect,
    source_pcm_res,
    es_format: pcmr_code & 1,
    sumdiff_front,
    sumdiff_surround,
  })
}
