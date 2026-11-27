///|
/// Adaptive Rice encoder from FFmpeg 9.0.2 `ttaenc.c` (LGPL-2.1-or-later).
fn tta_write_residual(
  writer : VorbisBitWriter,
  rice : TtaRice,
  residual : Int32,
) -> Unit {
  let raw = residual.reinterpret_as_uint()
  let mut value = if residual > 0 { (raw << 1) - 1U } else { (0U - raw) << 1 }
  let mut k = rice.k0
  let threshold = tta_shift1(k)
  let (k0, sum0) = tta_rice_adjust(k, rice.sum0, value)
  rice.k0 = k0
  rice.sum0 = sum0
  if value >= threshold {
    value -= threshold
    k = rice.k1
    let (k1, sum1) = tta_rice_adjust(k, rice.sum1, value)
    rice.k1 = k1
    rice.sum1 = sum1
    for left = (value >> k) + 1U; left > 0U; {
      let count = left.min(32U)
      writer.put(0xFFFFFFFFU, count.reinterpret_as_int())
      continue left - count
    }
  }
  writer.put(0U, 1)
  writer.put(value & (tta_shift1(k) - 1U), k)
}

///|
fn tta_section_with_crc(writer : VorbisBitWriter) -> Bytes {
  let payload = writer.finish()
  let crc = tta_crc32(payload)
  Bytes::makei(payload.length() + 4, i => {
    if i < payload.length() {
      payload[i]
    } else {
      (crc >> ((i - payload.length()) * 8)).to_byte()
    }
  })
}

///|
fn tta_encode_frame(
  samples : ArrayView[Int32],
  channels : Int32,
  bits : Int32,
) -> Bytes {
  let shift = tta_filter_configs[bits / 8 - 1]
  let predictor_shift = if bits == 8 { 4 } else { 5 }
  let filters = Array::makei(channels, _ => tta_filter_new(shift))
  let rices = Array::makei(channels, _ => tta_rice_new())
  let predictors = FixedArray::make(channels, 0)
  let writer = VorbisBitWriter::new()
  for base = 0; base < samples.length(); base = base + channels {
    let mut difference = 0
    for ch in 0..<channels {
      let sample = samples[base + ch]
      let signal = if ch + 1 < channels {
        difference = samples[base + ch + 1] - sample
        difference
      } else {
        sample - difference / 2
      }
      let predicted = signal - tta_pred(predictors[ch], predictor_shift)
      predictors[ch] = signal
      let filter = filters[ch]
      let residual = tta_filter_process(
        filter,
        predicted,
        shift,
        filter.round,
        encode=true,
      )
      tta_write_residual(writer, rices[ch], residual)
    }
  }
  tta_section_with_crc(writer)
}

///|
/// Encode a complete TTA1 file from interleaved, signed, right-justified PCM.
/// Each CRC covers the preceding header, seek table or frame payload.
pub fn encode_tta(
  samples : ArrayView[Int32],
  sample_rate : Int32,
  channels : Int32,
  bits : Int32,
) -> Result[Bytes, String] {
  guard channels >= 1 && channels <= 16 else {
    return Err("tta: invalid channel count")
  }
  guard sample_rate > 0 && sample_rate <= 1000000 else {
    return Err("tta: invalid sample rate")
  }
  guard bits == 8 || bits == 16 || bits == 24 else {
    return Err("tta: unsupported sample format")
  }
  guard !samples.is_empty() && samples.length() % channels == 0 else {
    return Err("tta: expected complete PCM samples")
  }
  let limit = 1 << (bits - 1)
  for sample in samples {
    if sample < -limit || sample >= limit {
      return Err("tta: sample out of range for selected bit depth")
    }
  }
  let total_samples = samples.length() / channels
  let frame_size = sample_rate * 256 / 245
  let header = VorbisBitWriter::new()
  header.put32(0x31415454U) // TTA1
  header.put(1U, 16)
  header.put(channels.reinterpret_as_uint(), 16)
  header.put(bits.reinterpret_as_uint(), 16)
  header.put32(sample_rate.reinterpret_as_uint())
  header.put32(total_samples.reinterpret_as_uint())
  let seek = VorbisBitWriter::new()
  let packets : Array[Bytes] = []
  for start = 0; start < total_samples; {
    let end = start + frame_size.min(total_samples - start)
    let frame = tta_encode_frame(
      samples[start * channels:end * channels],
      channels,
      bits,
    )
    seek.put32(frame.length().reinterpret_as_uint())
    packets.push(frame)
    continue end
  }
  let out : Array[Byte] = []
  for section in [tta_section_with_crc(header), tta_section_with_crc(seek)] {
    for byte in section {
      out.push(byte)
    }
  }
  for packet in packets {
    for byte in packet {
      out.push(byte)
    }
  }
  Ok(Bytes::from_array(out))
}
