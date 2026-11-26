///|
/// Parse Amiga 8SVX/16SV audio IFF. Layout follows FFmpeg iff.c; BODY is
/// passed whole because stereo samples (including compressed ones) are planar.
///
/// ```mbt check
/// test {
///   assert_true(@libavformat.av_svx_open(b"FORM") is Err(_))
/// }
/// ```
pub fn av_svx_open(data : Bytes) -> Result[RawAudioTrack, String] {
  if data.length() < 12 ||
    data[:4] != b"FORM" ||
    (data[8:12] != b"8SVX" && data[8:12] != b"16SV") {
    return Err("svx: missing voice FORM")
  }
  let size = pb_be32(data, 4).to_int64()
  if size < 4L || size > (data.length() - 8).to_int64() {
    return Err("svx: invalid FORM size")
  }
  let end = 8 + size.to_int()
  let mut rate = 0
  let mut compression = 0
  let mut channels = 1
  let mut body = -1
  let mut body_size = 0
  for pos = 12; pos < end; {
    if end - pos < 8 {
      return Err("svx: truncated chunk header")
    }
    let start = pos + 8
    let length = pb_be32(data, pos + 4).to_int64()
    let padded = length + (length & 1L)
    if padded > (end - start).to_int64() {
      return Err("svx: truncated chunk")
    }
    match wav_fourcc(data[:], pos) {
      "VHDR" if length >= 16L => {
        rate = pb_be16(data, start + 12).reinterpret_as_int()
        compression = data[start + 15].to_int()
      }
      "CHAN" if length >= 4L =>
        channels = if pb_be32(data, start) >= 6U { 2 } else { 1 }
      "BODY" => {
        body = start
        body_size = length.to_int()
      }
      _ => ()
    }
    continue start + padded.to_int()
  }
  if rate == 0 || body < 0 || body_size == 0 {
    return Err("svx: missing voice parameters or BODY")
  }
  let plane = body_size / channels
  let (codec, duration) = if data[8:12] == b"16SV" {
    if body_size % (2 * channels) != 0 || compression != 0 {
      return Err("svx: invalid 16SV PCM body")
    }
    ("pcm_s16be_planar", plane / 2)
  } else {
    match compression {
      0 => ("pcm_s8_planar", plane)
      1 | 2 => {
        if plane < 3 || plane - 2 > 0x3fffffff {
          return Err("svx: invalid delta body")
        }
        (
          if compression == 1 {
            "8svx_fib"
          } else {
            "8svx_exp"
          },
          (plane - 2) * 2,
        )
      }
      _ => return Err("svx: unsupported compression")
    }
  }
  if duration == 0 {
    return Err("svx: empty channel plane")
  }
  Ok({
    codec,
    profile: "",
    sample_rate: rate,
    channels,
    frame_size: duration,
    frames: [
      {
        pos: body.to_int64(),
        size: body_size,
        pts: 0L,
        duration,
        is_keyframe: true,
      },
    ],
    total_samples: duration.to_int64(),
    bit_rate: 0,
    id3v2_size: 0,
    info_frame_size: 0,
  })
}

///|
fn probe_svx(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 12 &&
    pd.buf[:4] == b"FORM" &&
    (pd.buf[8:12] == b"8SVX" || pd.buf[8:12] == b"16SV") {
    probe_score_max
  } else {
    0
  }
}
