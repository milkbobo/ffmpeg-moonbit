///|
/// SV8 chunk framing follows FFmpeg libavformat/mpc8.c (LGPL-2.1-or-later).
pub struct Mpc8Demux {
  priv data : Bytes
  priv spans : Array[(Int32, Int32)]
  sample_rate : Int32
  channels : Int32
  extradata : Bytes
  samples : Int64
  frames_per_packet : Int32
}

///|
fn probe_mpc8(pd : ProbeData) -> Int32 {
  if pd.buf.length() >= 4 && pd.buf[:4] == b"MPCK"[:] {
    probe_score_max
  } else {
    0
  }
}

///|
fn mpc8_varlen(data : Bytes, start : Int32, end : Int32) -> (Int64, Int32)? {
  let mut value = 0L
  for p in start..<end {
    guard value <= 72057594037927935L else { return None }
    let b = data[p].to_int()
    value = (value << 7) | (b & 127).to_int64()
    if b < 128 {
      return Some((value, p + 1))
    }
  }
  None
}

///|
/// Index complete AP payloads after validating the SV8 stream header.
pub fn av_mpc8_open(data : Bytes) -> Result[Mpc8Demux, String] {
  let start = id3_skip(data)
  guard data.length() - start >= 4 && data[start:start + 4] == b"MPCK"[:] else {
    return Err("musepack: missing SV8 signature")
  }
  let spans = []
  let mut extra = b""
  let mut samples = 0L
  let mut pos = start + 4
  let mut ended = false
  while data.length() - pos >= 3 {
    let tag = data[pos:pos + 2]
    guard mpc8_varlen(data, pos + 2, data.length()) is Some((size, payload)) &&
      size >= (payload - pos).to_int64() &&
      size <= (data.length() - pos).to_int64() else {
      return Err("musepack: invalid SV8 chunk length")
    }
    let end = pos + size.to_int()
    if tag == b"SH"[:] {
      guard extra.is_empty() &&
        end - payload >= 9 &&
        data[payload + 4] == b'\x08' &&
        mpc8_varlen(data, payload + 5, end) is Some((count, p)) &&
        mpc8_varlen(data, p, end) is Some((_, config)) &&
        end - config >= 2 else {
        return Err("musepack: invalid SV8 stream header")
      }
      samples = count
      extra = data[config:config + 2].to_owned()
    } else if tag == b"AP"[:] {
      guard !extra.is_empty() && end > payload else {
        return Err("musepack: invalid SV8 audio packet")
      }
      spans.push((payload, end))
    } else if tag == b"SE"[:] {
      ended = true
      break
    }
    pos = end
  }
  guard ended && !spans.is_empty() && !extra.is_empty() else {
    return Err("musepack: incomplete SV8 file")
  }
  let rate_code = extra[0].to_int() >> 5
  let channels = (extra[1].to_int() >> 4) + 1
  guard rate_code < 4 && channels <= 2 else {
    return Err("musepack: unsupported SV8 audio parameters")
  }
  Ok({
    data,
    spans,
    sample_rate: mpc7_sample_rates[rate_code],
    channels,
    extradata: extra,
    samples,
    frames_per_packet: 1 << ((extra[1].to_int() & 7) * 2),
  })
}

///|
pub fn Mpc8Demux::packet(self : Mpc8Demux, index : Int32) -> Bytes? {
  self.spans.get(index).map(span => self.data[span.0:span.1].to_owned())
}
