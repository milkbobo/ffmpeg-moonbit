///|
/// AAC-LC AudioSpecificConfig bootstrap from FFmpeg 9.0.2
/// libavcodec/aac/aacdec.c: decode_audio_specific_config_gb and
/// decode_ga_specific_config, over mpeg4audio.c's generic ASC header.
/// Copyright (c) 2005-2006 Oded Shimon
/// Copyright (c) 2006-2007 Maxim Gavrilov
/// Copyright (c) 2008-2013 Alex Converse <alex.converse@gmail.com>
/// LGPL-2.1-or-later.
///
/// Other audio object types, active SBR/PS, and layouts not supported by
/// aac_layout.mbt are rejected. Both 1024/128 and 960/120 frames are supported.
pub struct AacAudioSpecificConfig {
  config : Mpeg4AudioConfig
  layout : Array[AacLayoutChannel]
  coupling_tags : Array[Int32]
  /// Bits through GASpecificConfig, excluding optional sync extensions.
  bits_consumed : Int32
}

///|
/// Parse standalone AAC-LC ASC, including an ASC-only PCE when config=0.
/// The PCE alignment reference is the beginning of ASC (bit zero), not
/// the position of its instance tag or the beginning of GASpecificConfig.
pub fn aac_parse_audio_specific_config(
  data : Bytes,
) -> Result[AacAudioSpecificConfig, String] {
  let config = new_mpeg4_audio_config()
  let specific = match ff_mpeg4audio_get_config(config, data, true) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  if config.object_type != 2 {
    return Err("only AAC-LC AudioSpecificConfig is supported")
  }
  if config.sbr == 1 ||
    config.ps == 1 ||
    (config.ext_object_type == 5 && config.sbr != 0) {
    return Err("SBR/PS AudioSpecificConfig is not supported")
  }
  if config.sampling_index > 12 || config.sample_rate <= 0 {
    return Err("invalid AAC sampling rate index")
  }
  let gb = BitReader::new(data)
  if specific < 0 || specific + 3 > gb.size_bits() {
    return Err("truncated AAC GASpecificConfig")
  }
  gb.skip(specific)
  config.frame_length_short = gb.read1() != 0
  config.frame_length = if config.frame_length_short { 960 } else { 1024 }
  if gb.read1() != 0 {
    if gb.bits_left() < 15 {
      return Err("truncated AAC core coder delay")
    }
    gb.skip(14) // coreCoderDelay, parsed and ignored by FFmpeg
  }
  let extension_flag = gb.read1() != 0
  let coupling_tags : Array[Int32] = []
  let layout = if config.chan_config == 0 {
    match aac_decode_pce(gb, coupling_tags~) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  } else {
    match aac_default_layout(config.chan_config) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
  }
  if extension_flag {
    if gb.bits_left() < 1 {
      return Err("truncated AAC extensionFlag3")
    }
    gb.skip(1) // extensionFlag3: consumed but not used by FFmpeg's LC path
  }
  config.channels = layout.length()
  if config.channels > 1 {
    config.ps = 0
  }
  Ok({ config, layout, coupling_tags, bits_consumed: gb.count(), })
}

///|
/// Initialize from a raw ADTS frame header plus the desired output channel
/// count. Implicit SBR/PS is left to the decoder (`sbr`/`ps` = -1), matching
/// the `ffmpeg` native decoder's auto-detection; `output_channels` selects the
/// post-PS channel count (use 2 for HE-AACv2 mono-core streams).
pub fn new_aac_decoder_from_adts(
  data : Bytes,
  output_channels : Int32,
) -> Result[AacDecoder, String] {
  let header = match ff_adts_header_parse_buf(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let config = new_mpeg4_audio_config()
  config.object_type = header.object_type
  config.sampling_index = header.sampling_index
  config.sample_rate = header.sample_rate
  config.chan_config = header.chan_config
  config.channels = header.chan_config
  config.frame_length = 1024
  config.sbr = -1
  config.ps = -1
  Ok(new_aac_decoder(config, output_channels))
}

///|
/// Initialize from raw AAC access units (no ADTS header) using the AudioSpecificConfig
/// channel configuration. ADTS can only carry 3 bits, so configurations 11 (6.1)
/// and 14 (5.1.2) are unreachable through `new_aac_decoder_from_adts`; this entry
/// point accepts the full 4-bit ASC values. Implicit SBR/PS detection is left to
/// the decoder, as for ADTS.
pub fn new_aac_decoder_from_asc_channels(
  chan_config : Int32,
  sampling_index : Int32,
  sample_rate : Int32,
  output_channels : Int32,
) -> Result[AacDecoder, String] {
  if chan_config < 1 ||
    (chan_config > 7 && chan_config < 11) ||
    chan_config > 14 {
    return Err("unsupported AAC channel configuration")
  }
  let config = new_mpeg4_audio_config()
  config.object_type = 2
  config.sampling_index = sampling_index
  config.sample_rate = sample_rate
  config.chan_config = chan_config
  config.channels = output_channels
  config.frame_length = 1024
  config.sbr = -1
  config.ps = -1
  Ok(new_aac_decoder(config, output_channels))
}

///|
/// Initialize directly from MP4/MKV AAC-LC extradata; raw packets do not
/// need to repeat the PCE that established the layout in ASC.
pub fn new_aac_decoder_from_asc(data : Bytes) -> Result[AacDecoder, String] {
  let parsed = match aac_parse_audio_specific_config(data) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let decoder = new_aac_decoder(parsed.config, parsed.layout.length())
  decoder.layout = parsed.layout
  decoder.coupling_tags = parsed.coupling_tags
  Ok(decoder)
}
