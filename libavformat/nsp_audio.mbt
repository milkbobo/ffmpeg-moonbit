///|
/// Computerized Speech Lab NSP layout from FFmpeg 9.0.2 nspdec.c.
/// Copyright (c) 2017 Paul B Mahol. LGPL-2.1-or-later.
fn probe_nsp(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 12 && pd.buf[:8] == b"FORMDS16" {
    probe_score_max
  } else {
    0
  }
}

///|
fn nsp_open(data : Bytes) -> Result[RawAudioTrack, String] {
  guard probe_nsp(ProbeData::new(data)) > 0 else {
    return Err("nsp: invalid signature")
  }
  let mut rate = 0
  for pos = 12; pos < data.length(); {
    guard pos <= data.length() - 8 else {
      return Err("nsp: truncated chunk header")
    }
    let body = pos + 8
    let length = pb_le32(data, pos + 4).to_int64()
    guard length <= (data.length() - body).to_int64() else {
      return Err("nsp: truncated chunk")
    }
    let tag = wav_fourcc(data[:], pos)
    match tag {
      "HEDR" | "HDR8" => {
        guard length >= 32L else { return Err("nsp: invalid rate header") }
        rate = pb_le32(data, body + 20).reinterpret_as_int()
      }
      "SDAB" | "SDA_" | "SD_A" => {
        let channels = if tag == "SDAB" { 2 } else { 1 }
        guard rate > 0 &&
          length > 0L &&
          length % (channels * 2).to_int64() == 0L else {
          return Err("nsp: invalid sample rate or incomplete PCM frame")
        }
        return Ok(
          raw_pcm_track(
            body + length.to_int(),
            body,
            "pcm_s16le",
            rate,
            channels,
            2,
          ),
        )
      }
      _ => ()
    }
    let pad = if tag == "HEDR" || tag == "HDR8" { 0L } else { length & 1L }
    guard length + pad <= (data.length() - body).to_int64() else {
      return Err("nsp: missing chunk padding")
    }
    continue body + (length + pad).to_int()
  }
  Err("nsp: missing PCM chunk")
}
