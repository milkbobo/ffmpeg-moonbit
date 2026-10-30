///|
/// Sony Wave64 reader and PCM writer (FFmpeg 9.0.2 `w64.c` plus the W64 half
/// of `wavdec.c` / `wavenc.c`): GUID-tagged chunks whose 64-bit size includes
/// the 24-byte chunk header and whose ends are padded to eight bytes.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn w64_bytes(values : Array[Int32]) -> Bytes {
  let out : Array[Byte] = []
  for v in values {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
let w64_guid_riff : Bytes = w64_bytes([
  0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1,
  0x00, 0x00,
])

///|
fn w64_guid(cc : String) -> Bytes {
  let out : Array[Byte] = []
  for c in cc {
    out.push(c.to_int().to_byte())
  }
  for
    v in [
      0xF3, 0xAC, 0xD3, 0x11, 0x8C, 0xD1, 0x00, 0xC0, 0x4F, 0x8E, 0xDB, 0x8A,
    ] {
    out.push(v.to_byte())
  }
  Bytes::from_array(out)
}

///|
let w64_guid_wave : Bytes = w64_guid("wave")

///|
let w64_guid_fmt : Bytes = w64_guid("fmt ")

///|
let w64_guid_fact : Bytes = w64_guid("fact")

///|
let w64_guid_data : Bytes = w64_guid("data")

///|
fn w64_align8(v : Int64) -> Int64 {
  (v + 7L) & -8L
}

///|
fn w64_le64(out : Array[Byte], v : Int64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    out.push(((v >> (8 * i)) & 0xFFL).to_int().to_byte())
  }
}

///|
/// Parse a Wave64 file into the shared WAV demux structure.
pub fn av_w64_open(data : Bytes) -> Result[WavDemux, String] {
  if data.length() < 40 {
    return Err("EINVAL: file too short")
  }
  if data[0:16] != w64_guid_riff {
    return Err("EINVAL: missing Wave64 riff GUID")
  }
  // riff + wave + fmt GUID and both sizes must fit (FFmpeg's 72-byte check).
  if wav_u64(data, 16) < 72L {
    return Err("EINVAL: invalid Wave64 size")
  }
  if data[24:40] != w64_guid_wave {
    return Err("EINVAL: missing Wave64 wave GUID")
  }
  let mut format : WavFormat? = None
  let mut data_ofs = -1L
  let mut data_size = 0L
  let mut sample_count = 0L
  let mut pos = 40
  while pos + 24 <= data.length() {
    let guid = data[pos:pos + 16].to_owned()
    let size = wav_u64(data, pos + 16)
    if size <= 24L || pos.to_int64() + size > data.length().to_int64() {
      break
    }
    let body = pos + 24
    let payload = size.to_int() - 24
    if guid == w64_guid_fmt {
      match wav_parse_fmt(data, body, payload, false) {
        Ok(parsed) => format = Some(parsed)
        Err(e) => return Err(e)
      }
    } else if guid == w64_guid_fact {
      if body + 8 <= data.length() {
        sample_count = wav_u64(data, body)
      }
    } else if guid == w64_guid_data {
      data_ofs = body.to_int64()
      data_size = payload.to_int64()
    }
    let span = w64_align8(size)
    if span <= 0L {
      break
    }
    pos = pos + span.to_int()
  }
  let fmt = match format {
    Some(f) => f
    None => return Err("EINVAL: no Wave64 fmt chunk")
  }
  if data_ofs < 0L {
    return Err("EINVAL: no Wave64 data chunk")
  }
  wav_build_demux(data, fmt, data_ofs, data_size, sample_count)
}

///|
/// PCM/float Wave64 writer: one `fmt ` chunk, an optional `fact` chunk for
/// non-PCM formats and one `data` chunk.
pub struct W64Muxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  float_samples : Bool
  data : Array[Byte]
  tags : Array[(String, String)]
}

///|
pub fn w64_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
  float~ : Bool = false,
) -> Result[W64Muxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 2 {
    return Err("EINVAL: invalid Wave64 sample rate or channel count")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: Wave64 muxer supports 8/16/24/32-bit PCM")
  }
  if float && bits != 32 {
    return Err("EINVAL: IEEE float Wave64 requires 32-bit samples")
  }
  Ok({ sample_rate, channels, bits, float_samples: float, data: [], tags: [], })
}

///|
/// Set the `summarylist` tags written by `finish` (RIFF INFO keys such as
/// `title`/`artist`; unknown keys are skipped).
pub fn W64Muxer::set_tags(
  self : W64Muxer,
  tags : Array[(String, String)],
) -> Unit {
  self.tags.clear()
  for pair in tags {
    self.tags.push(pair)
  }
}

///|
/// Append interleaved samples; 8-bit output is offset to unsigned and the
/// sample bits are packed little-endian (`WavMuxer::write_samples`).
pub fn W64Muxer::write_samples(
  self : W64Muxer,
  samples : ArrayView[Int32],
) -> Unit {
  let bytes = self.bits / 8
  for sample in samples {
    let v = if self.bits == 8 {
      (sample + 128).reinterpret_as_uint()
    } else {
      sample.reinterpret_as_uint()
    }
    for i in 0..<bytes {
      self.data.push(((v >> (8 * i)) & 0xFFU).to_byte())
    }
  }
}

///|
pub fn W64Muxer::finish(self : W64Muxer) -> Bytes {
  let block_align = self.channels * (self.bits / 8)
  let byte_rate = self.sample_rate * block_align
  let format_tag = if self.float_samples { 3 } else { 1 }
  let fmt_body : Array[Byte] = []
  for b in b"fmt " {
    fmt_body.push(b)
  }
  let fmt_payload : Array[Byte] = []
  fmt_payload.push((format_tag & 0xFF).to_byte())
  fmt_payload.push(((format_tag >> 8) & 0xFF).to_byte())
  fmt_payload.push((self.channels & 0xFF).to_byte())
  fmt_payload.push(((self.channels >> 8) & 0xFF).to_byte())
  for shift in [0, 8, 16, 24] {
    fmt_payload.push(((self.sample_rate >> shift) & 0xFF).to_byte())
  }
  for shift in [0, 8, 16, 24] {
    fmt_payload.push(((byte_rate >> shift) & 0xFF).to_byte())
  }
  fmt_payload.push((block_align & 0xFF).to_byte())
  fmt_payload.push(((block_align >> 8) & 0xFF).to_byte())
  fmt_payload.push((self.bits & 0xFF).to_byte())
  fmt_payload.push(((self.bits >> 8) & 0xFF).to_byte())
  if self.float_samples {
    // WAVEFORMATEX with cbSize = 0, like ff_put_wav_header for IEEE float.
    fmt_payload.push(b'\x00')
    fmt_payload.push(b'\x00')
  }
  let fmt_size = w64_align8(24L + fmt_payload.length().to_int64())
  let fact_size = if self.float_samples { 32L } else { 0L }
  let data_size = w64_align8(24L + self.data.length().to_int64())
  let summary = w64_summary_payload(self.tags)
  let summary_size = if summary.length() > 0 {
    w64_align8(24L + summary.length().to_int64())
  } else {
    0L
  }
  let total = 40L + fmt_size + fact_size + data_size + summary_size
  let out : Array[Byte] = []
  for b in w64_guid_riff {
    out.push(b)
  }
  w64_le64(out, total)
  for b in w64_guid_wave {
    out.push(b)
  }
  // fmt chunk
  for b in w64_guid_fmt {
    out.push(b)
  }
  w64_le64(out, fmt_size)
  for b in fmt_payload {
    out.push(b)
  }
  while out.length() % 8 != 0 {
    out.push(b'\x00')
  }
  // fact chunk (non-PCM only): sample frame count.
  if self.float_samples {
    for b in w64_guid_fact {
      out.push(b)
    }
    w64_le64(out, 32L)
    w64_le64(out, (self.data.length() / block_align).to_int64())
  }
  // data chunk
  for b in w64_guid_data {
    out.push(b)
  }
  w64_le64(out, data_size)
  for b in self.data {
    out.push(b)
  }
  while out.length() % 8 != 0 {
    out.push(b'\x00')
  }
  if summary_size > 0L {
    for b in w64_summary_guid() {
      out.push(b)
    }
    w64_le64(out, summary_size)
    for b in summary {
      out.push(b)
    }
    while out.length() % 8 != 0 {
      out.push(b'\x00')
    }
  }
  Bytes::from_array(out)
}
