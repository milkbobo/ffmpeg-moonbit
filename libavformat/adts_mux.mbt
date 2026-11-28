///|
/// In-memory ADTS AAC writer.  Each call emits the 7-byte ADTS header from
/// `libavcodec/audio_headers.mbt` followed by one raw AAC access unit, matching
/// the framing consumed by `av_adts_open`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AdtsMuxer {
  sample_rate : Int32
  channels : Int32
  object_type : Int32
  data : Array[Byte]
}

///|
pub fn adts_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  object_type~ : Int32 = 2,
) -> Result[AdtsMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 7 {
    return Err("EINVAL: invalid ADTS stream parameters")
  }
  Ok({ sample_rate, channels, object_type, data: [], })
}

///|
/// Append one AAC access unit. The ADTS frame length includes the 7-byte
/// header, so the payload is limited to 8184 bytes per frame.
pub fn AdtsMuxer::write_frame(
  self : AdtsMuxer,
  payload : Bytes,
) -> Result[Unit, String] {
  let frame_length = payload.length() + @libavcodec.av_aac_adts_header_size
  let header = @libavcodec.aac_adts_header_write(
    self.sample_rate,
    self.channels,
    self.object_type,
    frame_length,
  )
  let header = match header {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  for b in header {
    self.data.push(b)
  }
  for b in payload {
    self.data.push(b)
  }
  Ok(())
}

///|
pub fn AdtsMuxer::finish(self : AdtsMuxer) -> Bytes {
  Bytes::from_array(self.data)
}

///|
/// Encode mono or stereo PCM as AAC-LC with ADTS headers.
///
/// ```mbt check
/// test {
///   let wav = @libavformat.wav_muxer_new(48000, 1, 16).unwrap()
///   wav.write_samples([0][:])
///   let source = @libavformat.decode_audio_file(wav.finish())
///   let audio = @libavformat.decode_audio_file(source.to_adts())
///   assert_eq(audio.codec_id(), "aac")
/// }
/// ```
pub fn DecodedAudio::to_adts(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("ADTS AAC-LC export requires mono or stereo")
  }
  let out : Array[Byte] = []
  self.encode_aac_adts(packet => {
    guard out.length() <= 0x7fffffff - packet.length() else {
      return Err("adts: AAC stream exceeds its size limit")
    }
    for byte in packet {
      out.push(byte)
    }
    Ok(())
  })
  Bytes::from_array(out)
}
