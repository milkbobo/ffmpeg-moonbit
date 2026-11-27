///|
fn spdif_mpeg_burst(coded : Bytes, kind : Int32, period : Int32, big_endian : Bool) -> SpdifBurst? {
  let word = rb32(coded, 0)
  guard @libavcodec.avpriv_mpegaudio_decode_header(word) is Ok(header) &&
    !header.free_format &&
    ((header.frame_size + 1) & -2) == coded.length() else {
    return None
  }
  let version = ((word >> 19) & 3U).reinterpret_as_int()
  let matches = match kind {
    0x04 => version == 3 && header.layer == 1
    0x05 => version >= 2 && header.layer >= 2
    0x06 => version == 2
    _ => header.lsf != 0 && header.layer == kind - 7
  }
  guard matches && @libavcodec.ff_mpa_decode_header(word) is Ok(info) else {
    return None
  }
  let samples = info.samples_per_frame
  Some({
    codec: info.codec,
    sample_rate: info.sample_rate,
    channels: info.channels,
    period,
    big_endian,
    samples,
    frames: [
      {
        pos: 0L,
        size: header.frame_size,
        pts: 0L,
        duration: samples,
        is_keyframe: true,
      },
    ],
  })
}

///|
fn spdif_mpeg_kind(payload : BytesView) -> Int32 {
  let flags = payload[1].to_int()
  let version = (flags >> 3) & 3
  let layer = 4 - ((flags >> 1) & 3)
  if version == 2 && (payload[2].to_int() & 1) != 0 {
    // Match FFmpeg's MPEG-2 extended burst selection.
    0x06
  } else if version == 3 {
    if layer == 1 {
      0x04
    } else {
      0x05
    }
  } else {
    0x07 + layer
  }
}
