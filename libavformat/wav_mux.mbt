///|
/// Minimal in-memory WAV/PCM writer following FFmpeg 9.0.2 `wavenc.c`
/// (`wav_write_header`, `wav_write_trailer`) for the PCM sample formats the
/// demuxer already understands.  The payload is accumulated in memory and the
/// RIFF sizes are patched by `finish`.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2001 Fabrice Bellard.
/// This port keeps the same license.

///|
pub struct WavMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  channel_mask : UInt32
  extensible : Bool
  float_samples : Bool
  /// "" for linear PCM, "alaw"/"mulaw" for ITU G.711 companding.
  companding : String
  /// Emit a `RF64`/`ds64` header for files beyond the 4 GiB RIFF limit.
  rf64 : Bool
  /// Emit a big-endian `RIFX` container (payload bytes swapped accordingly).
  big_endian : Bool
  data : Array[Byte]
}

///|
/// Create a PCM WAV writer. 8-bit samples are unsigned (WAV convention);
/// 16/24/32-bit samples are signed. A non-zero `channel_mask` or more than two
/// channels selects WAVE_FORMAT_EXTENSIBLE. `rf64=true` switches the container
/// header to RF64 (the payload layout is unchanged); `big_endian=true` writes
/// a `RIFX` file (only plain 16-byte WAVEFORMAT, so no extensible layout).
pub fn wav_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
  channel_mask~ : UInt32 = 0U,
  float~ : Bool = false,
  rf64~ : Bool = false,
  big_endian~ : Bool = false,
  companding~ : String = "",
) -> Result[WavMuxer, String] {
  if sample_rate <= 0 || channels <= 0 {
    return Err("EINVAL: invalid WAV sample rate or channel count")
  }
  if companding != "" && companding != "alaw" && companding != "mulaw" {
    return Err("EINVAL: WAV companding must be alaw or mulaw")
  }
  if companding != "" && (float || bits != 8 || big_endian) {
    return Err("EINVAL: A-law/mu-law requires 8-bit little-endian PCM")
  }
  if float && bits != 32 {
    return Err("EINVAL: IEEE float WAV requires 32-bit samples")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: WAV muxer supports 8/16/24/32-bit PCM")
  }
  if big_endian && (rf64 || channels > 2 || channel_mask != 0U) {
    return Err("EINVAL: RIFX supports only plain WAVEFORMAT without RF64")
  }
  Ok({
    sample_rate,
    channels,
    bits,
    channel_mask,
    extensible: channels > 2 || channel_mask != 0U,
    float_samples: float,
    companding,
    rf64,
    big_endian,
    data: [],
  })
}

///|
fn wav_mux_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push((v & 0xFF).to_byte())
  dst.push(((v >> 8) & 0xFF).to_byte())
}

///|
fn wav_mux_w16(dst : Array[Byte], v : Int32, big_endian : Bool) -> Unit {
  if big_endian {
    dst.push(((v >> 8) & 0xFF).to_byte())
    dst.push((v & 0xFF).to_byte())
  } else {
    wav_mux_u16(dst, v)
  }
}

///|
fn wav_mux_u32(dst : Array[Byte], v : UInt32) -> Unit {
  for i in 0..<4 {
    dst.push(((v >> (8 * i)) & 0xFFU).to_byte())
  }
}

///|
fn wav_mux_w32(dst : Array[Byte], v : UInt32, big_endian : Bool) -> Unit {
  if big_endian {
    for i in 0..<4 {
      dst.push(((v >> (8 * (3 - i))) & 0xFFU).to_byte())
    }
  } else {
    wav_mux_u32(dst, v)
  }
}

///|
fn wav_mux_u64(dst : Array[Byte], v : Int64) -> Unit {
  for i in 0..<8 {
    dst.push(((v >> (8 * i)) & 0xFFL).to_int().to_byte())
  }
}

///|
fn wav_mux_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
/// Append interleaved samples. Values are written in the low `bits` bits,
/// little-endian for RIFF/RF64 and big-endian for RIFX; callers provide
/// signed samples already in the PCM range. 8-bit output is offset to the
/// unsigned range. With `companding` set the values are G.711-encoded to one
/// byte per sample instead.
pub fn WavMuxer::write_samples(
  self : WavMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  if self.companding != "" {
    let encoded = if self.companding == "alaw" {
      @libavcodec.pcm_alaw_encode(samples)
    } else {
      @libavcodec.pcm_mulaw_encode(samples)
    }
    for b in encoded {
      self.data.push(b)
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
      let shift = if self.big_endian { 8 * (bytes - 1 - i) } else { 8 * i }
      self.data.push(((v >> shift) & 0xFFU).to_byte())
    }
  }
}

///|
/// Append interleaved IEEE-float samples (32-bit). The muxer must have been
/// created with `float=true`.
pub fn WavMuxer::write_float_samples(
  self : WavMuxer,
  samples : ArrayView[Float],
) -> Unit {
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i in 0..<4 {
      let shift = if self.big_endian { 8 * (3 - i) } else { 8 * i }
      self.data.push(((v >> shift) & 0xFFU).to_byte())
    }
  }
}

///|
/// Finish the RIFF/WAVE file. The muxer should not be written to afterwards.
pub fn WavMuxer::finish(self : WavMuxer) -> Bytes {
  let data_size = self.data.length()
  let pad = data_size & 1
  let out : Array[Byte] = []
  let block_align = self.channels * (self.bits / 8)
  let byte_rate = self.sample_rate * block_align
  let fmt_size = if self.extensible {
    40
  } else if self.companding != "" {
    // WAVEFORMATEX with cbSize=0, as ff_put_wav_header writes for G.711.
    18
  } else {
    16
  }
  // `ff_put_wav_header` writes WAVE_FORMAT_EXTENSIBLE whenever the layout is
  // non-mono/stereo; IEEE float and G.711 are selected through the subformat.
  let format_tag = if self.extensible {
    0xFFFE
  } else if self.companding == "alaw" {
    6
  } else if self.companding == "mulaw" {
    7
  } else if self.float_samples {
    3
  } else {
    1
  }
  // Non-PCM formats (`codec_tag != 1`) carry a `fact` chunk, as in
  // `wav_write_header`; its payload is the frame count patched in the trailer.
  let fact_size = if self.float_samples || self.companding != "" {
    12
  } else {
    0
  }
  // Size of everything after the 8-byte RIFF/RF64 header.
  let riff_size = 20 + fmt_size + fact_size + data_size + pad
  let ds64_size = if self.rf64 { 36 } else { 0 }
  if self.rf64 {
    wav_mux_tag(out, "RF64")
    wav_mux_u32(out, 0xFFFFFFFFU)
  } else if self.big_endian {
    wav_mux_tag(out, "RIFX")
    wav_mux_w32(out, riff_size.reinterpret_as_uint(), true)
  } else {
    wav_mux_tag(out, "RIFF")
    wav_mux_u32(out, riff_size.reinterpret_as_uint())
  }
  wav_mux_tag(out, "WAVE")
  if self.rf64 {
    wav_mux_tag(out, "ds64")
    wav_mux_u32(out, 28U)
    wav_mux_u64(out, (riff_size + ds64_size).to_int64())
    wav_mux_u64(out, data_size.to_int64())
    wav_mux_u64(out, (data_size / block_align).to_int64())
    wav_mux_u32(out, 0U) // table entries
  }
  wav_mux_tag(out, "fmt ")
  wav_mux_w32(out, fmt_size.reinterpret_as_uint(), self.big_endian)
  wav_mux_w16(out, format_tag, self.big_endian)
  wav_mux_w16(out, self.channels, self.big_endian)
  wav_mux_w32(out, self.sample_rate.reinterpret_as_uint(), self.big_endian)
  wav_mux_w32(out, byte_rate.reinterpret_as_uint(), self.big_endian)
  wav_mux_w16(out, block_align, self.big_endian)
  wav_mux_w16(out, self.bits, self.big_endian)
  if self.extensible {
    wav_mux_u16(out, 22) // cbSize
    wav_mux_u16(out, self.bits) // valid bits
    wav_mux_u32(out, self.channel_mask)
    // KSDATAFORMAT_SUBTYPE_PCM / IEEE_FLOAT / ALAW / MULAW
    let subformat = if self.companding == "alaw" {
      6
    } else if self.companding == "mulaw" {
      7
    } else if self.float_samples {
      3
    } else {
      1
    }
    let guid : Array[Int32] = [
      subformat, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA,
      0x00, 0x38, 0x9B, 0x71,
    ]
    for b in guid {
      out.push(b.to_byte())
    }
  } else if self.companding != "" {
    wav_mux_w16(out, 0, self.big_endian) // cbSize, WAVEFORMATEX
  }
  if fact_size != 0 {
    wav_mux_tag(out, "fact")
    wav_mux_w32(out, 4U, self.big_endian)
    // Sample frames, matching `number_of_samples` in `wav_write_trailer`.
    wav_mux_w32(
      out,
      (data_size / block_align).reinterpret_as_uint(),
      self.big_endian,
    )
  }
  wav_mux_tag(out, "data")
  wav_mux_w32(
    out,
    if self.rf64 {
      0xFFFFFFFFU
    } else {
      data_size.reinterpret_as_uint()
    },
    self.big_endian,
  )
  out.append(self.data)
  if pad != 0 {
    out.push(b'\x00')
  }
  Bytes::from_array(out)
}
