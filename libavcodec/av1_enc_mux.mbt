///|
/// §453 container glue for the encoder session: the `av1C` record for
/// MP4 (`av01`/`av1C` sample entry) and the OBU-level sample format.
///
/// The `av1C` layout (ISO/IEC 14496-15 AV1-in-ISOBMFF):
///   byte0 = marker(1)<<7 | version(1) — 0x81
///   byte1 = seq_profile(3)<<5 | seq_level_idx_0(5)
///   byte2 = seq_tier_0(1)<<7 | high_bitdepth(1)<<6 | twelve_bit(1)<<5
///           | monochrome(1)<<4 | chroma_subsampling_x(1)<<3
///           | chroma_subsampling_y(1)<<2 | chroma_sample_position(2)
///   byte3 = reserved(3)<<5 | initial_presentation_delay_present(1)<<4
///           | initial_presentation_delay_minus_one(4) — 0 (absent)
///   then configOBUs — the sequence header OBU with its own header.
///
/// Samples are stored as raw self-delimited OBUs (the repository's
/// pinned convention: the demuxer slices by stsz and the decoder's
/// `decode_packet` walks the OBU size fields — Matroska-shaped, no
/// length prefixes). The temporal delimiter serves raw-stream framing
/// only and is dropped per sample; the sequence header stays in-band
/// in the first sample (legal per spec, and what the playback path
/// consumes since it never seeds from extradata).

///|
/// Build the `av1C` record from the session's parsed sequence
/// parameters plus the emitted sequence-header OBU.
pub fn Av1Encoder::av1c(self : Av1Encoder) -> Bytes {
  let s = self.seq
  let high_bitdepth = if s.bitdepth > 8 { 1 } else { 0 }
  let twelve_bit = if s.bitdepth == 12 { 1 } else { 0 }
  let mono = if s.monochrome { 1 } else { 0 }
  let ssx = if s.chroma_subsampling_x { 1 } else { 0 }
  let ssy = if s.chroma_subsampling_y { 1 } else { 0 }
  let byte1 = (s.profile << 5) | (s.level & 0x1F)
  let byte2 = ((s.tier & 1) << 7) |
    (high_bitdepth << 6) |
    (twelve_bit << 5) |
    (mono << 4) |
    (ssx << 3) |
    (ssy << 2) |
    (s.chroma_sample_position & 3)
  let out : Array[Byte] = [
    (0x81).to_byte(),
    byte1.to_byte(),
    byte2.to_byte(),
    0,
  ]
  for b in self.seq_obu {
    out.push(b)
  }
  Bytes::from_array(out)
}

///|
/// Convert one encoder packet (TD + [seq] + frame OBUs) into an MP4
/// sample: drop the temporal delimiters, keep every other OBU
/// verbatim (self-delimited by their leb128 size fields).
pub fn av1_enc_mp4_sample(packet : Bytes) -> Result[Bytes, String] {
  let out : Array[Byte] = []
  let mut pos = 0
  while pos < packet.length() {
    let byte = packet[pos].to_int()
    if (byte & 0x81) != 0 || (byte & 2) == 0 {
      return Err("av1: invalid size-delimited OBU header")
    }
    let extension = (byte & 4) != 0
    if extension &&
      (pos + 1 >= packet.length() || (packet[pos + 1].to_int() & 7) != 0) {
      return Err("av1: invalid OBU extension")
    }
    let off = Ref(pos + 1 + (if extension { 1 } else { 0 }))
    let size = av1_leb128(packet[:], off)
    if size < 0 || off.val > packet.length() - size {
      return Err("av1: bad OBU size")
    }
    let typ = (byte >> 3) & 15
    let end = off.val + size
    if typ != 2 {
      // OBU_TEMPORAL_DELIMITER is the only dropped type.
      for i = pos; i < end; i = i + 1 {
        out.push(packet[i])
      }
    }
    pos = end
  }
  Ok(Bytes::from_array(out))
}
