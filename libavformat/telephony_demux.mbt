///|
/// Use an extension for headerless audio when there is no stronger match.
fn probe_telephony(pd : ProbeData, format : FormatId) -> Int32 {
  if probe_match_ext(pd.filename, format.extensions()) {
    probe_score_extension
  } else {
    0
  }
}

///|
/// Fixed-size raw reads from FFmpeg's g722.c and g726.c. A 1020-byte
/// G.726 packet ends on a codeword boundary at every supported width.
fn telephony_open(
  data : Bytes,
  format : FormatId,
  codeword_bits : Int32,
) -> Result[RawAudioTrack, String] {
  let (codec, bits, rate, packet_size) = match format {
    G722 => {
      guard codeword_bits >= 6 && codeword_bits <= 8 else {
        return Err("g722: codeword width must be 6, 7 or 8 bits")
      }
      // One byte always encodes two samples, including the 6/7-bit modes.
      ("adpcm_g722", 4, 16000, 1024)
    }
    G726 => ("adpcm_g726", codeword_bits, 8000, 1020)
    G726Le => ("adpcm_g726le", codeword_bits, 8000, 1020)
    _ => return Err("unsupported raw telephony format")
  }
  if bits < 2 || bits > 5 {
    return Err("g726: code width must be 2, 3, 4 or 5 bits")
  }
  if data.is_empty() {
    return Err("empty raw telephony stream")
  }
  let frames : Array[RawAudioFrame] = []
  let mut pos = 0
  let mut pts = 0L
  while pos < data.length() {
    let size = packet_size.min(data.length() - pos)
    let duration = size * 8 / bits
    frames.push({ pos: pos.to_int64(), size, pts, duration, is_keyframe: true, })
    pos += size
    pts += duration.to_int64()
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels: 1,
    frame_size: packet_size * 8 / bits,
    frames,
    total_samples: pts,
    bit_rate: rate * bits,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Convert mono audio to 16 kHz and encode a raw 64 kbit/s G.722 stream.
pub fn DecodedAudio::to_g722(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("raw G.722 export requires a mono track")
  }
  let audio = self.resample_to(16000)
  let pcm = audio.samples[0].map(@swr.swr_flt_to_s16)
  @libavcodec.encode_g722(pcm[:])
}

///|
/// Convert mono audio to 8 kHz and encode a raw G.726 or G.726LE stream.
pub fn DecodedAudio::to_g726(
  self : DecodedAudio,
  code_size : Int32,
  little_endian~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 else {
    raise UnsupportedCodec("raw G.726 export requires a mono track")
  }
  let audio = self.resample_to(8000)
  let pcm = audio.samples[0].map(@swr.swr_flt_to_s16)
  match @libavcodec.encode_g726(pcm[:], code_size, little_endian~) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
}
