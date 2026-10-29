///|
/// Raw AAC access-unit splitting.  A packet may hold several concatenated
/// `raw_data_block`s (e.g. WAV `WAVE_FORMAT_AAC` chunks); FFmpeg's decode loop
/// repeatedly calls the AAC decoder and advances by the reported consumed
/// length.  This helper mirrors that loop and returns each frame with its PCM.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AacRawFrame {
  /// Bytes of this raw_data_block (including any trailing zero padding when it
  /// ends the buffer).
  data : Bytes
  /// Decoded channels for the frame.
  pcm : Array[AacPcm]
}

///|
/// Decode a raw AAC byte stream (no ADTS headers) using the AudioSpecificConfig
/// `asc`.  The returned frames are in decode order; frame count and PCM match
/// decoding the same bytes through the packet loop of FFmpeg's AAC decoder.
pub fn aac_decode_raw_stream(
  asc : Bytes,
  data : Bytes,
) -> Result[Array[AacRawFrame], String] {
  let dec = match new_aac_decoder_from_asc(asc) {
    Ok(d) => d
    Err(e) => return Err(e)
  }
  let frames : Array[AacRawFrame] = []
  let mut pos = 0
  while pos < data.length() {
    let chunk = data[pos:].to_owned()
    let (pcm, consumed) = match dec.decode_frame_with_consumed(chunk) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    if consumed <= 0 {
      return Err("aac: decoder consumed no bytes")
    }
    let mut end = pos + consumed
    if end > data.length() {
      end = data.length()
    }
    frames.push({ data: data[pos:end].to_owned(), pcm, })
    pos = end
  }
  Ok(frames)
}
