///|
let roq_file_header : Bytes = b"\x84\x10\xff\xff\xff\xff\x1e\x00"

///|
fn probe_roq(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 8 && pd.buf[:6] == roq_file_header[:6] {
    probe_score_max
  } else {
    0
  }
}

///|
/// Index RoQ audio chunks and skip the video info, codebook and frame chunks.
fn roq_audio_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard data.length() >= 8 && data[:6] == roq_file_header[:6] else {
    return Err("roq: missing file header")
  }
  let frames : Array[RawAudioFrame] = []
  let mut channels = 0
  let mut pts = 0L
  for pos = 8; pos < data.length(); {
    guard pos <= data.length() - 8 else {
      return Err("roq: incomplete chunk header")
    }
    let id = wav_u16(data[:], pos, false)
    let length = wav_u32(data[:], pos + 2, false)
    guard length <= (data.length() - pos - 8).to_int64() else {
      return Err("roq: truncated chunk")
    }
    let size = length.to_int() + 8
    match id {
      0x1020 | 0x1021 => {
        let packet_channels = id - 0x101f
        guard channels == 0 || channels == packet_channels else {
          return Err("roq: audio channel layout changed")
        }
        channels = packet_channels
        guard length.to_int() % channels == 0 else {
          return Err("roq: incomplete audio sample")
        }
        if length > 0L {
          let duration = length.to_int() / channels
          frames.push({
            pos: pos.to_int64(),
            size,
            pts,
            duration,
            is_keyframe: true,
          })
          pts += duration.to_int64()
        }
      }
      0x1001 | 0x1002 | 0x1011 => ()
      _ => return Err("roq: unsupported chunk type \{id}")
    }
    continue pos + size
  }
  guard !frames.is_empty() else { return Err("roq: no audio chunks") }
  Ok({
    codec: "roq_dpcm",
    profile: "",
    sample_rate: 22050,
    channels,
    frame_size: 735,
    frames,
    total_samples: pts,
    bit_rate: 22050 * 8 * channels,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Convert the track to 22.05 kHz and write an audio-only RoQ file.
pub fn DecodedAudio::to_roq(self : DecodedAudio) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("RoQ export requires mono or stereo")
  }
  let audio = self.resample_to(22050)
  let pcm = @swr.swr_flt_planar_to_s16(audio.samples, audio.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  let payload = match @libavcodec.encode_roq_dpcm(pcm[:], audio.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
  Bytes::makei(roq_file_header.length() + payload.length(), i => {
    if i < roq_file_header.length() {
      roq_file_header[i]
    } else {
      payload[i - roq_file_header.length()]
    }
  })
}
