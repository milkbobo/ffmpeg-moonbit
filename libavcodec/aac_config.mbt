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
