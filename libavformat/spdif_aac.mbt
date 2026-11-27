///|
fn spdif_aac_kind(blocks : Int32) -> Int32? {
  match blocks {
    1 => Some(0x07)
    2 => Some(0x13)
    4 => Some(0x33)
    _ => None
  }
}

///|
fn spdif_adts_header(coded : Bytes) -> @libavcodec.AacAdtsHeaderInfo? {
  guard @libavcodec.ff_adts_header_parse_buf(coded) is Ok(header) &&
    (coded[1].to_int() & 6) == 0 &&
    header.object_type == 2 &&
    header.chan_config != 0 else {
    return None
  }
  let crc_bytes = if header.crc_absent == 0 {
    2 * header.num_aac_frames
  } else {
    0
  }
  guard header.frame_length > @libavcodec.av_aac_adts_header_size + crc_bytes else {
    return None
  }
  Some(header)
}

///|
fn spdif_aac_burst(
  coded : Bytes,
  kind : Int32,
  period : Int32,
  big_endian : Bool,
) -> SpdifBurst? {
  guard spdif_adts_header(coded) is Some(header) &&
    spdif_aac_kind(header.num_aac_frames) == Some(kind) &&
    ((header.frame_length + 1) & -2) == coded.length() else {
    return None
  }
  Some({
    codec: "aac",
    sample_rate: header.sample_rate,
    channels: adts_channels(header.chan_config),
    period,
    big_endian,
    samples: header.samples,
    frames: [
      {
        pos: 0L,
        size: header.frame_length,
        pts: 0L,
        duration: header.samples,
        is_keyframe: true,
      },
    ],
  })
}
