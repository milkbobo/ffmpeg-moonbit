///|
/// ALAC (Apple Lossless Audio Codec) decoder, ported from FFmpeg 9.0.2
/// `libavcodec/alac.c`, `alac_data.c` and `alacdsp.c`.
///
/// `extradata` is the 36-byte QuickTime `alac` atom (size, tag, version and
/// the 24-byte ALACSpecificConfig) exactly as FFmpeg's MOV demuxer rebuilds
/// it from the sample entry. Packets are raw ALAC frames holding one or more
/// SCE/CPE/LFE elements; the decoded PCM is returned interleaved in FFmpeg's
/// output form (S16 for 16-bit streams, S32 left-justified for 20/24/32-bit).
///
/// Scope: 16/20/24/32-bit, 1-8 channels, compressed (Rice residuals + adaptive
/// LPC, including prediction type 15) and uncompressed elements. The
/// non-standard `extra_bits_bug` decoding mode is not reproduced.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
/// `ALAC_MAX_CHANNELS`.
let alac_max_channels : Int32 = 8

///|
/// `ff_alac_channel_layout_offsets`: Apple element channel order to the
/// standard channel order of the output.
let alac_channel_offsets : FixedArray[FixedArray[Int32]] = [
  [0, 0, 0, 0, 0, 0, 0, 0],
  [0, 1, 0, 0, 0, 0, 0, 0],
  [2, 0, 1, 0, 0, 0, 0, 0],
  [2, 0, 1, 3, 0, 0, 0, 0],
  [2, 0, 1, 3, 4, 0, 0, 0],
  [2, 0, 1, 4, 5, 3, 0, 0],
  [2, 0, 1, 4, 5, 6, 3, 0],
  [2, 6, 7, 0, 1, 4, 5, 3],
]

///|
/// Element type tags (`AlacRawDataBlockType`).
let alac_type_cpe : Int32 = 1

///|
let alac_type_lfe : Int32 = 3

///|
let alac_type_end : Int32 = 7

///|
/// Parsed ALACSpecificConfig plus the derived decoder parameters.
pub struct AlacDecoder {
  channels : Int32
  max_samples_per_frame : Int32
  sample_size : Int32
  rice_history_mult : Int32
  rice_initial_history : Int32
  rice_limit : Int32
  sample_rate : Int32
}

///|
/// One decoded ALAC frame. `samples` is interleaved in the standard channel
/// order and already shifted like FFmpeg's `S16`/`S32` output.
pub struct AlacFrame {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  nb_samples : Int32
  samples : Array[Int32]
}

///|
/// `bytestream2_get_be32` over a plain byte buffer.
fn alac_be32(data : Bytes, off : Int32) -> UInt32 {
  (data[off].to_uint() << 24) |
  (data[off + 1].to_uint() << 16) |
  (data[off + 2].to_uint() << 8) |
  data[off + 3].to_uint()
}

///|
/// `av_log2`.
fn alac_log2(x : UInt32) -> Int32 {
  let mut n = 0
  let mut v = x
  while v > 1U {
    v = v >> 1
    n = n + 1
  }
  n
}

///|
/// `sign_extend(x, bits)` for `1 <= bits <= 32`.
fn alac_sign_extend(x : Int32, bits : Int32) -> Int32 {
  if bits >= 32 {
    return x
  }
  let mask = (1 << bits) - 1
  let v = x & mask
  if (v & (1 << (bits - 1))) != 0 {
    v - (1 << bits)
  } else {
    v
  }
}

///|
/// `sign_only`.
fn alac_sign_only(v : Int32) -> Int32 {
  if v > 0 {
    1
  } else if v < 0 {
    -1
  } else {
    0
  }
}

///|
/// `alac_set_info`: parse the magic cookie.
pub fn alac_decoder_new(extradata : Bytes) -> Result[AlacDecoder, String] {
  if extradata.length() < 36 {
    return Err("alac: extradata is too small")
  }
  let max_samples = alac_be32(extradata, 12)
  if max_samples == 0U || max_samples > 16777216U {
    return Err("alac: invalid max samples per frame")
  }
  let sample_size = extradata[17].to_int()
  let channels = extradata[21].to_int()
  if sample_size != 16 &&
    sample_size != 20 &&
    sample_size != 24 &&
    sample_size != 32 {
    return Err("alac: unsupported sample depth \{sample_size}")
  }
  if channels < 1 || channels > alac_max_channels {
    return Err("alac: unsupported channel count \{channels}")
  }
  Ok({
    channels,
    max_samples_per_frame: max_samples.reinterpret_as_int(),
    sample_size,
    rice_history_mult: extradata[18].to_int(),
    rice_initial_history: extradata[19].to_int(),
    rice_limit: extradata[20].to_int(),
    sample_rate: alac_be32(extradata, 32).reinterpret_as_int(),
  })
}

///|
/// `decode_scalar`: unary prefix plus `k` low bits, or a raw `bps`-bit escape.
fn alac_decode_scalar(gb : BitReader, k : Int32, bps : Int32) -> UInt32 {
  let mut x = 0
  while x < 9 && gb.read1() == 1U {
    x = x + 1
  }
  if x > 8 {
    gb.read(bps)
  } else if k != 1 {
    let extrabits = gb.show(k).reinterpret_as_int()
    let mut v = (x << k) - x
    if extrabits > 1 {
      v = v + extrabits - 1
      gb.skip(k)
    } else {
      gb.skip(k - 1)
    }
    v.reinterpret_as_uint()
  } else {
    x.reinterpret_as_uint()
  }
}

///|
/// `rice_decompress`.
fn alac_rice_decompress(
  gb : BitReader,
  output : Array[Int32],
  nb_samples : Int32,
  bps : Int32,
  rice_history_mult : UInt32,
  dec : AlacDecoder,
) -> Result[Unit, String] {
  let mut history = dec.rice_initial_history.reinterpret_as_uint()
  let mut sign_modifier : UInt32 = 0
  let mut i = 0
  while i < nb_samples {
    if gb.bits_left() <= 0 {
      return Err("alac: truncated rice data")
    }
    let mut k = alac_log2((history >> 9) + 3U)
    if k > dec.rice_limit {
      k = dec.rice_limit
    }
    let mut x = alac_decode_scalar(gb, k, bps)
    x = x + sign_modifier
    sign_modifier = 0
    output[i] = ((x >> 1) ^ (0U - (x & 1U))).reinterpret_as_int()
    if x > 0xFFFFU {
      history = 0xFFFFU
    } else {
      history = history +
        x * rice_history_mult -
        ((history * rice_history_mult) >> 9)
    }
    if history < 128U && i + 1 < nb_samples {
      let mut k2 = 7 -
        alac_log2(history) +
        ((history + 16U) >> 6).reinterpret_as_int()
      if k2 > dec.rice_limit {
        k2 = dec.rice_limit
      }
      let mut block_size = alac_decode_scalar(gb, k2, 16).reinterpret_as_int()
      if block_size > 0 {
        if block_size >= nb_samples - i {
          block_size = nb_samples - i - 1
        }
        for j = i + 1; j <= i + block_size; j = j + 1 {
          output[j] = 0
        }
        i = i + block_size
      }
      if block_size <= 0xFFFF {
        sign_modifier = 1U
      }
      history = 0
    }
    i = i + 1
  }
  Ok(())
}

///|
/// `lpc_prediction`: adaptive FIR reconstruction. Both buffers hold 32-bit
/// sample bit patterns; arithmetic wraps like the C `int32_t`/`uint32_t` mix.
fn alac_lpc_prediction(
  error_buffer : Array[Int32],
  buffer_out : Array[Int32],
  nb_samples : Int32,
  bps : Int32,
  lpc_coefs : Array[Int32],
  lpc_order : Int32,
  lpc_quant : Int32,
) -> Unit {
  buffer_out[0] = error_buffer[0]
  if nb_samples <= 1 {
    return
  }
  if lpc_order == 0 {
    for i = 1; i < nb_samples; i = i + 1 {
      buffer_out[i] = error_buffer[i]
    }
    return
  }
  if lpc_order == 31 {
    for i = 1; i < nb_samples; i = i + 1 {
      buffer_out[i] = alac_sign_extend(buffer_out[i - 1] + error_buffer[i], bps)
    }
    return
  }
  let mut i = 1
  while i <= lpc_order && i < nb_samples {
    buffer_out[i] = alac_sign_extend(buffer_out[i - 1] + error_buffer[i], bps)
    i = i + 1
  }
  let mut pred = 0
  while i < nb_samples {
    let d = buffer_out[pred]
    pred = pred + 1
    let mut val = 0
    let mut error_val = error_buffer[i].reinterpret_as_uint()
    for j = 0; j < lpc_order; j = j + 1 {
      val = val + (buffer_out[pred + j] - d) * lpc_coefs[j]
    }
    let rounded = (val.to_int64() + (1L << (lpc_quant - 1))) >> lpc_quant
    val = rounded.to_int() + d + error_buffer[i]
    buffer_out[i] = alac_sign_extend(val, bps)
    let error_sign = alac_sign_only(error_buffer[i])
    if error_sign != 0 {
      let mut j = 0
      while j < lpc_order &&
            (error_val * error_sign.reinterpret_as_uint()).reinterpret_as_int() >
            0 {
        let v = d - buffer_out[pred + j]
        let sign = alac_sign_only(v) * error_sign
        lpc_coefs[j] = alac_sign_extend(lpc_coefs[j] - sign, 16)
        let shifted = (v * sign) >> lpc_quant
        error_val = error_val -
          shifted.reinterpret_as_uint() * (j + 1).reinterpret_as_uint()
        j = j + 1
      }
    }
    i = i + 1
  }
}

///|
/// Working buffers for one packet; `nb_samples` is shared by all elements.
priv struct AlacPacket {
  mut nb_samples : Int32
  outputs : Array[Array[Int32]]
  error_buf : Array[Int32]
  sample_buf : Array[Int32]
  extra_buf : Array[Int32]
}

///|
/// `decode_element`: one SCE/CPE/LFE element writing `channels` planes.
fn alac_decode_element(
  gb : BitReader,
  pkt : AlacPacket,
  dec : AlacDecoder,
  ch_index : Int32,
  channels : Int32,
) -> Result[Unit, String] {
  let _ = gb.read(4) // element instance tag
  let _ = gb.read(12) // unused header bits
  let has_size = gb.read1() != 0U
  let extra_bits = gb.read(2).reinterpret_as_int() << 3
  let bps = dec.sample_size - extra_bits + channels - 1
  if bps > 32 {
    return Err("alac: unsupported bits per sample \{bps}")
  }
  if bps < 1 {
    return Err("alac: invalid bits per sample \{bps}")
  }
  let is_compressed = gb.read1() == 0U
  let output_samples = if has_size {
    gb.read(32)
  } else {
    dec.max_samples_per_frame.reinterpret_as_uint()
  }
  if output_samples == 0U ||
    output_samples > dec.max_samples_per_frame.reinterpret_as_uint() {
    return Err("alac: invalid samples per frame \{output_samples}")
  }
  if pkt.nb_samples == 0 {
    pkt.nb_samples = output_samples.reinterpret_as_int()
    for _ch = 0; _ch < dec.channels; _ch = _ch + 1 {
      pkt.outputs.push(Array::make(pkt.nb_samples, 0))
    }
  } else if output_samples.reinterpret_as_int() != pkt.nb_samples {
    return Err("alac: sample count mismatch")
  }
  let nb_samples = pkt.nb_samples
  let mut decorr_shift = 0
  let mut decorr_left_weight = 0
  let mut extra_bits = extra_bits
  if is_compressed {
    if dec.rice_limit == 0 {
      return Err("alac: compression with rice limit 0")
    }
    decorr_shift = gb.read(8).reinterpret_as_int()
    decorr_left_weight = gb.read(8).reinterpret_as_int()
    if channels == 2 && decorr_left_weight != 0 && decorr_shift > 31 {
      return Err("alac: invalid decorrelation shift")
    }
    let lpc_coefs : Array[Array[Int32]] = [
      Array::make(32, 0),
      Array::make(32, 0),
    ]
    let lpc_order : Array[Int32] = [0, 0]
    let prediction_type : Array[Int32] = [0, 0]
    let lpc_quant : Array[Int32] = [0, 0]
    let rice_mult : Array[UInt32] = [0U, 0U]
    for ch = 0; ch < channels; ch = ch + 1 {
      prediction_type[ch] = gb.read(4).reinterpret_as_int()
      lpc_quant[ch] = gb.read(4).reinterpret_as_int()
      rice_mult[ch] = gb.read(3).reinterpret_as_int().reinterpret_as_uint()
      lpc_order[ch] = gb.read(5).reinterpret_as_int()
      if lpc_order[ch] >= dec.max_samples_per_frame || lpc_quant[ch] == 0 {
        return Err("alac: invalid predictor order")
      }
      let mut i = lpc_order[ch] - 1
      while i >= 0 {
        lpc_coefs[ch][i] = alac_sign_extend(
          gb.read(16).reinterpret_as_int(),
          16,
        )
        i = i - 1
      }
    }
    if extra_bits != 0 {
      if gb.bits_left() < nb_samples * channels * extra_bits {
        return Err("alac: truncated extra bits")
      }
      for i = 0; i < nb_samples; i = i + 1 {
        for ch = 0; ch < channels; ch = ch + 1 {
          pkt.extra_buf[i * channels + ch] = gb
            .read(extra_bits)
            .reinterpret_as_int()
        }
      }
    }
    for ch = 0; ch < channels; ch = ch + 1 {
      let mult = rice_mult[ch] *
        dec.rice_history_mult.reinterpret_as_uint() /
        4U
      match
        alac_rice_decompress(gb, pkt.error_buf, nb_samples, bps, mult, dec) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      if prediction_type[ch] == 15 {
        alac_lpc_prediction(
          pkt.error_buf,
          pkt.error_buf,
          nb_samples,
          bps,
          lpc_coefs[ch],
          31,
          0,
        )
      }
      alac_lpc_prediction(
        pkt.error_buf,
        pkt.sample_buf,
        nb_samples,
        bps,
        lpc_coefs[ch],
        lpc_order[ch],
        lpc_quant[ch],
      )
      let dst = pkt.outputs[ch_index + ch]
      for i = 0; i < nb_samples; i = i + 1 {
        dst[i] = pkt.sample_buf[i]
      }
    }
  } else {
    let sample_size = dec.sample_size
    if gb.bits_left() < nb_samples * channels * sample_size {
      return Err("alac: truncated uncompressed samples")
    }
    for i = 0; i < nb_samples; i = i + 1 {
      for ch = 0; ch < channels; ch = ch + 1 {
        pkt.outputs[ch_index + ch][i] = alac_sign_extend(
          gb.read(sample_size).reinterpret_as_int(),
          sample_size,
        )
      }
    }
    extra_bits = 0
    decorr_shift = 0
    decorr_left_weight = 0
  }
  if channels == 2 {
    if decorr_left_weight != 0 {
      let out0 = pkt.outputs[ch_index]
      let out1 = pkt.outputs[ch_index + 1]
      for i = 0; i < nb_samples; i = i + 1 {
        let a0 = out0[i].reinterpret_as_uint()
        let b0 = out1[i].reinterpret_as_uint()
        let weighted = (b0 * decorr_left_weight.reinterpret_as_uint()).reinterpret_as_int() >>
          decorr_shift
        let a = a0 - weighted.reinterpret_as_uint()
        let b = b0 + a
        out0[i] = b.reinterpret_as_int()
        out1[i] = a.reinterpret_as_int()
      }
    }
    if extra_bits != 0 {
      for ch = 0; ch < 2; ch = ch + 1 {
        let out = pkt.outputs[ch_index + ch]
        for i = 0; i < nb_samples; i = i + 1 {
          let ext = pkt.extra_buf[i * 2 + ch]
          out[i] = ((out[i].reinterpret_as_uint() << extra_bits) |
          ext.reinterpret_as_uint()).reinterpret_as_int()
        }
      }
    }
  } else if extra_bits != 0 {
    let out = pkt.outputs[ch_index]
    for i = 0; i < nb_samples; i = i + 1 {
      let ext = pkt.extra_buf[i]
      out[i] = ((out[i].reinterpret_as_uint() << extra_bits) |
      ext.reinterpret_as_uint()).reinterpret_as_int()
    }
  }
  Ok(())
}

///|
/// `alac_decode_frame`: decode one packet into interleaved PCM.
pub fn AlacDecoder::decode_frame(
  self : AlacDecoder,
  packet : Bytes,
) -> Result[AlacFrame, String] {
  let gb = BitReader::new(packet)
  let pkt : AlacPacket = {
    nb_samples: 0,
    outputs: [],
    error_buf: Array::make(self.max_samples_per_frame, 0),
    sample_buf: Array::make(self.max_samples_per_frame, 0),
    extra_buf: Array::make(self.max_samples_per_frame * alac_max_channels, 0),
  }
  let mut got_end = false
  let mut ch = 0
  while gb.bits_left() >= 3 {
    let element = gb.read(3).reinterpret_as_int()
    if element == alac_type_end {
      got_end = true
      break
    }
    if element > alac_type_cpe && element != alac_type_lfe {
      return Err("alac: unsupported syntax element \{element}")
    }
    let channels = if element == alac_type_cpe { 2 } else { 1 }
    let offset = alac_channel_offsets[self.channels - 1][ch]
    if ch + channels > self.channels || offset + channels > self.channels {
      return Err("alac: invalid element channel count")
    }
    match alac_decode_element(gb, pkt, self, offset, channels) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    ch = ch + channels
  }
  if !got_end {
    return Err("alac: no end tag found")
  }
  if ch != self.channels || pkt.nb_samples == 0 {
    return Err("alac: failed to decode all channels")
  }
  let nb_samples = pkt.nb_samples
  let samples : Array[Int32] = []
  for i = 0; i < nb_samples; i = i + 1 {
    for c = 0; c < self.channels; c = c + 1 {
      let v = pkt.outputs[c][i]
      samples.push(
        match self.sample_size {
          16 => v
          20 => (v.reinterpret_as_uint() << 12).reinterpret_as_int()
          24 => (v.reinterpret_as_uint() << 8).reinterpret_as_int()
          _ => v
        },
      )
    }
  }
  Ok({
    sample_rate: self.sample_rate,
    channels: self.channels,
    bits: self.sample_size,
    nb_samples,
    samples,
  })
}

///|
/// Interleaved PCM bytes matching FFmpeg's ALAC output format: 2 bytes per
/// sample for 16-bit streams, 4 bytes (left-justified) for wider ones.
pub fn AlacFrame::pcm_bytes(self : AlacFrame) -> Bytes {
  let out : Array[Byte] = []
  let wide = self.bits > 16
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    if wide {
      out.push(((v >> 8) & 0xFF).to_byte())
      out.push(((v >> 16) & 0xFF).to_byte())
      out.push(((v >> 24) & 0xFF).to_byte())
    } else {
      out.push(((v >> 8) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(out)
}
