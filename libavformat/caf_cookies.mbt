///|
/// Read a descriptor bounded by the containing ESDS descriptor.
fn caf_es_descriptor(
  cookie : Bytes,
  offset : Int32,
  end : Int32,
) -> (Int32, Int32, Int32)? {
  guard offset < end else { return None }
  guard caf_descr_len(cookie, offset + 1, end) is Some((size, start)) &&
    size <= end - start else {
    return None
  }
  Some((cookie[offset].to_int(), start, start + size))
}

///|
/// The AAC cookie is the body of the ESDS FullBox. Extract its ASC.
fn caf_aac_cookie(cookie : Bytes) -> Bytes? {
  guard caf_es_descriptor(cookie, 4, cookie.length())
    is Some((es_tag, es_start, es_end)) &&
    es_tag == mp4_es_descr_tag &&
    es_end - es_start >= 3 else {
    return None
  }
  let flags = cookie[es_start + 2].to_int()
  let mut offset = es_start + 3
  if (flags & 0x80) != 0 {
    offset += 2
  }
  if (flags & 0x40) != 0 {
    guard offset < es_end else { return None }
    offset += 1 + cookie[offset].to_int()
  }
  if (flags & 0x20) != 0 {
    offset += 2
  }
  guard caf_es_descriptor(cookie, offset, es_end)
    is Some((config_tag, config_start, config_end)) &&
    config_tag == mp4_dec_config_descr_tag &&
    config_end - config_start >= 13 &&
    mp4_obj_type_codec(cookie[config_start].to_int()) == Some("aac") else {
    return None
  }
  guard caf_es_descriptor(cookie, config_start + 13, config_end)
    is Some((specific_tag, start, end)) &&
    specific_tag == mp4_dec_specific_descr_tag &&
    end > start else {
    return None
  }
  Some(cookie[start:end].to_owned())
}

///|
/// FLAC's CAF cookie wraps a dfLa FullBox body containing STREAMINFO.
fn caf_flac_cookie(cookie : Bytes) -> Bytes? {
  guard cookie.length() >= 50 &&
    cookie[0] == 0 &&
    caf_tag(cookie, 4) == "dfLa" &&
    cookie[8] == 0 &&
    (caf_u32be(cookie, 12) & 0x7FFFFFFF) == 34 else {
    return None
  }
  Some(cookie[16:50].to_owned())
}

///|
/// FFmpeg synthesizes a family-0 OpusHead from CAF stream parameters.
fn caf_opus_head(channels : Int32, rate : Int32, priming : Int32) -> Bytes {
  let head = b"OpusHead\x01".to_array()
  head.push(channels.to_byte())
  head.push(priming.to_byte())
  head.push((priming >> 8).to_byte())
  for byte in 0..<4 {
    head.push((rate >> (8 * byte)).to_byte())
  }
  head.append([0, 0, 0]) // output gain and channel mapping family
  Bytes::from_array(head)
}
