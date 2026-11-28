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
/// Write Wave64 fmt, fact and data chunks, with eight-byte alignment.
fn w64_mux_fact_data(
  payload : Bytes,
  fmt : Array[Byte],
  frames : Int32,
  include_data_padding~ : Bool = true,
) -> Bytes {
  let fmt_size = w64_align8(24L + fmt.length().to_int64())
  let data_size = 24L + payload.length().to_int64()
  let data_span = w64_align8(data_size)
  let out = w64_guid_riff.to_array()
  w64_le64(out, 40L + fmt_size + 32L + data_span)
  out.append(w64_guid_wave.to_array())
  out.append(w64_guid_fmt.to_array())
  w64_le64(out, fmt_size)
  out.append(fmt)
  while out.length() % 8 != 0 {
    out.push(0)
  }
  out.append(w64_guid_fact.to_array())
  w64_le64(out, 32L)
  w64_le64(out, frames.to_int64())
  out.append(w64_guid_data.to_array())
  w64_le64(out, if include_data_padding { data_span } else { data_size })
  for byte in payload {
    out.push(byte)
  }
  while out.length() % 8 != 0 {
    out.push(0)
  }
  Bytes::from_array(out)
}

///|
/// Honor an ADPCM fact count only when it can describe partial last-block padding.
fn w64_adpcm_tail(demux : WavDemux, frames : Int32) -> Int32 {
  guard demux.sample_count > 0L && demux.sample_count < frames.to_int64() else {
    return 0
  }
  let fmt = demux.format
  let block = fmt.block_align
  let per_block = if fmt.codec == "adpcm_yamaha" &&
    fmt.channels > 0 &&
    block <= 0x3fffffff {
    block * 2 / fmt.channels
  } else {
    @libavcodec.adpcm_wav_block_samples(
      fmt.codec,
      block,
      fmt.channels,
      fmt.bits_per_sample,
    )
  }
  let extra = frames.to_int64() - demux.sample_count
  if extra < per_block.to_int64() {
    extra.to_int()
  } else {
    0
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
  while pos <= data.length() - 24 {
    let guid = data[pos:pos + 16].to_owned()
    let size = wav_u64(data, pos + 16)
    if size <= 24L || size > (data.length() - pos).to_int64() {
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
      if payload >= 8 {
        sample_count = wav_u64(data, body)
      }
    } else if guid == w64_guid_data {
      data_ofs = body.to_int64()
      data_size = payload.to_int64()
    }
    let span = w64_align8(size)
    if span > (data.length() - pos).to_int64() {
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
  // FFmpeg includes alignment padding in the data chunk's size. The fact
  // count distinguishes those bytes from valid float or G.711 samples.
  if sample_count > 0L &&
    fmt.block_align > 0 &&
    (
      fmt.codec == "pcm_f32le" ||
      fmt.codec == "pcm_f64le" ||
      fmt.codec == "pcm_alaw" ||
      fmt.codec == "pcm_mulaw"
    ) {
    let align = fmt.block_align.to_int64()
    if sample_count <= data_size / align {
      let sample_bytes = sample_count * align
      if data_size - sample_bytes < 8L {
        let from = (data_ofs + sample_bytes).to_int()
        let to = (data_ofs + data_size).to_int()
        if data[from:to].iter().all(byte => byte == 0) {
          data_size = sample_bytes
        }
      }
    }
  }
  wav_build_demux(data, fmt, data_ofs, data_size, sample_count, wave64=true)
}

///|
/// PCM/float Wave64 writer: one `fmt ` chunk, an optional `fact` chunk for
/// non-PCM formats and one `data` chunk.
pub struct W64Muxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  float_samples : Bool
  companding : String
  data : Array[Byte]
  tags : Array[(String, String)]
}

///|
pub fn w64_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
  float~ : Bool = false,
  companding~ : String = "",
) -> Result[W64Muxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 2 {
    return Err("EINVAL: invalid Wave64 sample rate or channel count")
  }
  if float {
    guard (bits == 32 || bits == 64) && companding == "" else {
      return Err("EINVAL: IEEE float Wave64 requires 32 or 64 bits")
    }
  } else if companding != "" {
    guard bits == 8 && (companding == "alaw" || companding == "mulaw") else {
      return Err("EINVAL: Wave64 companding requires 8-bit A-law or mu-law")
    }
  } else if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: Wave64 integer PCM requires 8/16/24/32 bits")
  }
  Ok({
    sample_rate,
    channels,
    bits,
    float_samples: float,
    companding,
    data: [],
    tags: [],
  })
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
  if self.companding != "" {
    let payload = if self.companding == "alaw" {
      @libavcodec.pcm_alaw_encode(samples)
    } else {
      @libavcodec.pcm_mulaw_encode(samples)
    }
    for byte in payload {
      self.data.push(byte)
    }
    return
  }
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
/// Append interleaved IEEE float64 samples to a 64-bit float Wave64 muxer.
pub fn W64Muxer::write_float64_samples(
  self : W64Muxer,
  samples : ArrayView[Double],
) -> Unit {
  for sample in samples {
    w64_le64(self.data, sample.reinterpret_as_uint64().reinterpret_as_int64())
  }
}

///|
pub fn W64Muxer::finish(self : W64Muxer) -> Bytes {
  let block_align = self.channels * (self.bits / 8)
  let byte_rate = self.sample_rate * block_align
  let format_tag = match self.companding {
    "alaw" => 6
    "mulaw" => 7
    _ => if self.float_samples { 3 } else { 1 }
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
  if format_tag != 1 {
    // WAVEFORMATEX with cbSize = 0 for float and G.711.
    fmt_payload.push(b'\x00')
    fmt_payload.push(b'\x00')
  }
  let fmt_size = w64_align8(24L + fmt_payload.length().to_int64())
  let fact_size = if format_tag != 1 { 32L } else { 0L }
  let data_size = w64_align8(24L + self.data.length().to_int64())
  let summary = w64_summary_payload(self.tags)
  let summary_size = if summary.length() > 4 {
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
  if format_tag != 1 {
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

///|
/// Export mono or stereo as float64 PCM or G.711 in Wave64.
pub fn DecodedAudio::to_w64_samples(
  self : DecodedAudio,
  codec : String,
) -> Bytes raise MediaError {
  let (bits, float, companding) = match codec {
    "pcm_f64le" => (64, true, "")
    "pcm_alaw" => (8, false, "alaw")
    "pcm_mulaw" => (8, false, "mulaw")
    _ => raise UnsupportedCodec("Wave64 export: " + codec)
  }
  let mux = match
    w64_muxer_new(self.sample_rate, self.channels, bits, float~, companding~) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  let frames = self.samples[0].length()
  let words = frames.to_int64() * self.channels.to_int64()
  guard frames > 0 && words * (bits / 8).to_int64() <= 0x7fffffffL - 160L else {
    raise DecodeError("Wave64: invalid audio payload size")
  }
  if float {
    let samples = Array::makei(words.to_int(), i => {
      self.samples[i % self.channels][i / self.channels]
    })
    mux.write_float64_samples(samples[:])
  } else {
    let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
      error => raise DecodeError(error.to_string())
    }
    mux.write_samples(samples[:])
  }
  mux.finish()
}
