///|
/// Musepack SV7 demuxing, ported from FFmpeg libavformat/mpc.c
/// (LGPL-2.1-or-later).
priv struct Mpc7Span {
  start : Int32
  size : Int32
  skip : Int32
}

///|
/// Indexed raw Musepack SV7 file. Packet bytes are copied on demand.
pub struct Mpc7Demux {
  priv data : Bytes
  priv spans : Array[Mpc7Span]
  sample_rate : Int32
  extradata : Bytes
  frame_count : Int32
}

///|
let mpc7_sample_rates : ReadOnlyArray[Int32] = [44100, 48000, 37800, 32000]

///|
fn mpc7_signature(data : BytesView) -> Bool {
  data.length() >= 4 &&
  data[:3] == b"MP+"[:] &&
  (data[3] == b'\x07' || data[3] == b'\x17')
}

///|
fn probe_mpc7(pd : ProbeData) -> Int32 {
  if mpc7_signature(pd.buf[:]) {
    probe_score_max
  } else {
    0
  }
}

///|
fn mpc7_u32le(data : Bytes, pos : Int32) -> UInt32 {
  data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16) |
  (data[pos + 3].to_uint() << 24)
}

///|
/// Open a raw SV7 file and validate every word-aligned frame span.
pub fn av_mpc7_open(data : Bytes) -> Result[Mpc7Demux, String] {
  let start = id3_skip(data)
  guard data.length() - start >= 24 && mpc7_signature(data[start:]) else {
    return Err("musepack: missing SV7 file header")
  }
  let count = mpc7_u32le(data, start + 4).to_uint64()
  let extradata = data[start + 8:start + 24].to_owned()
  let sample_rate = mpc7_sample_rates[extradata[2].to_int() & 3]
  let mut pos = start + 24
  let mut bit = 8
  let spans = []
  while count == 0UL || spans.length().to_uint64() < count {
    let left = data.length() - pos
    if left < (if bit <= 12 { 4 } else { 8 }) {
      if count == 0UL {
        break
      }
      return Err("musepack: truncated SV7 frame header")
    }
    let word = mpc7_u32le(data, pos)
    let length = (if bit <= 12 {
        word >> (12 - bit)
      } else {
        (word << (bit - 12)) | (mpc7_u32le(data, pos + 4) >> (44 - bit))
      }) &
      0xFFFFFU
    let skip = bit + 20
    let end_bit = skip + length.reinterpret_as_int()
    let size = ((end_bit + 31) & -32) / 8
    guard length != 0U && size <= left else {
      return Err("musepack: invalid or truncated SV7 frame")
    }
    spans.push(Mpc7Span::{ start: pos, size, skip, })
    pos += end_bit / 32 * 4
    bit = end_bit & 31
  }
  guard !spans.is_empty() else { return Err("musepack: no SV7 frames") }
  Ok({ data, spans, sample_rate, extradata, frame_count: spans.length(), })
}

///|
/// Return one packet with FFmpeg's four-byte SV7 prefix.
pub fn Mpc7Demux::packet(self : Mpc7Demux, index : Int32) -> Bytes? {
  guard self.spans.get(index) is Some(span) else { return None }
  let packet = Bytes::makei(span.size + 4, i => {
    if i == 0 {
      span.skip.to_byte()
    } else if i < 4 {
      b'\x00'
    } else {
      self.data[span.start + (i - 4)]
    }
  })
  Some(packet)
}
