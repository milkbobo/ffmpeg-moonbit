///|
/// Minimal AIFF PCM writer following FFmpeg 9.0.2 `aiffenc.c`: `FORM`/`AIFF`
/// with `COMM` and `SSND`, big-endian samples and the 80-bit extended sample
/// rate. The whole file is built in memory by `finish`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
pub struct AiffMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  data : Array[Byte]
}

///|
fn aiff_mux_u16be(dst : Array[Byte], v : Int32) -> Unit {
  dst.push(((v >> 8) & 0xFF).to_byte())
  dst.push((v & 0xFF).to_byte())
}

///|
fn aiff_mux_u32be(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push(((v >> 24) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push((v & 0xFFU).to_byte())
}

///|
fn aiff_mux_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
/// Encode a positive integer sample rate as an 80-bit extended float.
fn aiff_mux_ext80(rate : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  let mut k = 0
  let mut v = rate
  while v > 1 {
    v = v >> 1
    k = k + 1
  }
  aiff_mux_u16be(out, 16383 + k)
  let mant = rate.to_int64() << (63 - k)
  for i = 0; i < 8; i = i + 1 {
    out.push(((mant >> (56 - 8 * i)) & 0xFFL).to_int().to_byte())
  }
  out
}

///|
/// Create an AIFF writer for 8/16/24/32-bit signed PCM. AIFF stores 8-bit
/// samples signed (unlike WAV).
pub fn aiff_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits~ : Int32 = 16,
) -> Result[AiffMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 32 {
    return Err("EINVAL: invalid AIFF stream parameters")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: AIFF muxer supports 8/16/24/32-bit PCM")
  }
  Ok({ sample_rate, channels, bits, data: [], })
}

///|
pub fn AiffMuxer::write_samples(
  self : AiffMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  let bytes = self.bits / 8
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i = 0; i < bytes; i = i + 1 {
      self.data.push(((v >> (8 * (bytes - 1 - i))) & 0xFFU).to_byte())
    }
  }
}

///|
pub fn AiffMuxer::finish(self : AiffMuxer) -> Bytes {
  let block_align = self.channels * (self.bits / 8)
  let frames = self.data.length() / block_align
  let comm : Array[Byte] = []
  aiff_mux_u16be(comm, self.channels)
  aiff_mux_u32be(comm, frames.reinterpret_as_uint())
  aiff_mux_u16be(comm, self.bits)
  comm.append(aiff_mux_ext80(self.sample_rate))
  let ssnd : Array[Byte] = []
  aiff_mux_u32be(ssnd, 0U)
  aiff_mux_u32be(ssnd, 0U)
  ssnd.append(self.data)
  let out : Array[Byte] = []
  aiff_mux_tag(out, "FORM")
  aiff_mux_u32be(out, 0U) // patched below
  aiff_mux_tag(out, "AIFF")
  aiff_mux_tag(out, "COMM")
  aiff_mux_u32be(out, comm.length().reinterpret_as_uint())
  out.append(comm)
  aiff_mux_tag(out, "SSND")
  aiff_mux_u32be(out, ssnd.length().reinterpret_as_uint())
  out.append(ssnd)
  if (ssnd.length() & 1) != 0 {
    out.push(b'\x00')
  }
  let total = out.length()
  out[4] = (((total - 8) >> 24) & 0xFF).to_byte()
  out[5] = (((total - 8) >> 16) & 0xFF).to_byte()
  out[6] = (((total - 8) >> 8) & 0xFF).to_byte()
  out[7] = ((total - 8) & 0xFF).to_byte()
  Bytes::from_array(out)
}

///|
fn DecodedAudio::encode_ima4(
  self : DecodedAudio,
  container : String,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("\{container} IMA4 export requires mono or stereo")
  }
  guard self.sample_rate > 0 else {
    raise DecodeError("\{container}: invalid sample rate")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  match @libavcodec.encode_adpcm_ima_qt(samples[:], self.channels) {
    Ok(data) => data
    Err(error) => raise DecodeError(error)
  }
}

///|
/// Write mono or stereo Apple IMA4 in an AIFF-C container at the track rate.
/// The final block is padded with silence to 64 samples per channel.
pub fn DecodedAudio::to_aifc_ima4(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  let payload = self.encode_ima4("AIFF-C")
  aifc_mux_compressed(
    payload,
    self.sample_rate,
    self.channels,
    "ima4",
    4,
    34 * self.channels,
  )
}

///|
fn aifc_mux_compressed(
  payload : Bytes,
  rate : Int32,
  channels : Int32,
  codec_tag : String,
  bits : Int32,
  block_align : Int32,
) -> Bytes {
  let size = payload.length().reinterpret_as_uint()
  let pad = payload.length() & 1
  let out : Array[Byte] = Array(capacity=72 + payload.length() + pad)
  aiff_mux_tag(out, "FORM")
  aiff_mux_u32be(out, size + 64U + pad.reinterpret_as_uint())
  aiff_mux_tag(out, "AIFC")
  aiff_mux_tag(out, "FVER")
  aiff_mux_u32be(out, 4U)
  aiff_mux_u32be(out, 0xa2805140U)
  aiff_mux_tag(out, "COMM")
  aiff_mux_u32be(out, 24U)
  aiff_mux_u16be(out, channels)
  aiff_mux_u32be(out, size / block_align.reinterpret_as_uint())
  aiff_mux_u16be(out, bits)
  out.append(aiff_mux_ext80(rate))
  aiff_mux_tag(out, codec_tag)
  aiff_mux_u16be(out, 0)
  aiff_mux_tag(out, "SSND")
  aiff_mux_u32be(out, size + 8U)
  aiff_mux_u32be(out, 0U)
  aiff_mux_u32be(out, 0U)
  for byte in payload {
    out.push(byte)
  }
  if pad != 0 {
    out.push(0)
  }
  Bytes::from_array(out)
}

///|
/// Encode mono 8 kHz GSM in AIFF-C, padding the final 160-sample block.
pub fn DecodedAudio::to_aifc_gsm(self : DecodedAudio) -> Bytes raise MediaError {
  aifc_mux_compressed(self.to_gsm(), 8000, 1, "GSM ", 16, 33)
}

///|
/// Encode 16 kHz mono G.722 in AIFF-C.
pub fn DecodedAudio::to_aifc_g722(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  let payload = self.to_g722()
  guard !payload.is_empty() else {
    raise DecodeError("AIFF-C G.722: no audio samples")
  }
  aifc_mux_compressed(payload, 16000, 1, "G722", 4, 1)
}

///|
/// Encode 8 kHz mono, 5-bit little-endian G.726 in AIFF-C.
pub fn DecodedAudio::to_aifc_g726le(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  let payload = self.to_g726(5, little_endian=true)
  guard !payload.is_empty() else {
    raise DecodeError("AIFF-C G.726LE: no audio samples")
  }
  aifc_mux_compressed(payload, 8000, 1, "G726", 5, 5)
}

///|
/// Encode mono or stereo Westwood IMA using the AIFF-C ADP4 tag.
pub fn DecodedAudio::to_aifc_adp4(
  self : DecodedAudio,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("AIFF-C ADP4 export requires mono or stereo")
  }
  guard self.sample_rate > 0 else {
    raise DecodeError("AIFF-C ADP4: invalid sample rate")
  }
  let payload = self.encode_westwood_ima()
  // FFmpeg's COMM count uses the encoder packet alignment for this tag.
  aifc_mux_compressed(payload, self.sample_rate, self.channels, "ADP4", 4, 1024)
}

///|
/// Encode mono or stereo G.711 A-law or mu-law in AIFF-C.
pub fn DecodedAudio::to_aifc_g711(
  self : DecodedAudio,
  mulaw~ : Bool = false,
) -> Bytes raise MediaError {
  guard self.channels == 1 || self.channels == 2 else {
    raise UnsupportedCodec("AIFF-C G.711 export requires mono or stereo")
  }
  guard self.sample_rate > 0 else {
    raise DecodeError("AIFF-C G.711: invalid sample rate")
  }
  let samples = @swr.swr_flt_planar_to_s16(self.samples, self.channels) catch {
    error => raise DecodeError(error.to_string())
  }
  guard !samples.is_empty() else {
    raise DecodeError("AIFF-C G.711: no audio samples")
  }
  let payload = if mulaw {
    @libavcodec.pcm_mulaw_encode(samples[:])
  } else {
    @libavcodec.pcm_alaw_encode(samples[:])
  }
  aifc_mux_compressed(
    payload,
    self.sample_rate,
    self.channels,
    if mulaw {
      "ulaw"
    } else {
      "alaw"
    },
    8,
    self.channels,
  )
}
