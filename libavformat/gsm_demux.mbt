///|
/// Raw GSM framing from FFmpeg `libavformat/gsmdec.c` (copyright 2011
/// Justin Ruggles, LGPL-2.1-or-later). Exposes PTS in PCM samples.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_gsm_open(b"\xd0") is Err("gsm: incomplete block"))
/// }
/// ```
pub fn av_gsm_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.is_empty() || data.length() % 33 != 0 {
    return Err("gsm: incomplete block")
  }
  let frames : Array[RawAudioFrame] = []
  let count = data.length() / 33
  for i in 0..<count {
    let pos = i * 33
    if (data[pos].to_int() & 0xf0) != 0xd0 {
      return Err("gsm: missing frame magic")
    }
    frames.push({
      pos: pos.to_int64(),
      size: 33,
      pts: i.to_int64() * 160L,
      duration: 160,
      is_keyframe: true,
    })
  }
  Ok({
    codec: "gsm",
    profile: "",
    sample_rate: 8000,
    channels: 1,
    frame_size: 160,
    frames,
    total_samples: count.to_int64() * 160L,
    bit_rate: 13200,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
/// Encode raw 8 kHz mono GSM, padding the final 160-sample frame with silence.
pub fn DecodedAudio::to_gsm(self : DecodedAudio) -> Bytes raise MediaError {
  self.resample_to(8000).encode_gsm(false)
}

///|
fn probe_gsm(pd : ProbeData) -> Int32 {
  let count = pd.buf.length() / 33
  let mut valid = 0
  for i in 0..<count {
    if (pd.buf[i * 33].to_int() & 0xf0) == 0xd0 {
      valid += 1
    }
  }
  if valid >> 5 > count - valid {
    probe_score_extension + 1
  } else {
    0
  }
}
