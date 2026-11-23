///|
/// Musepack SV8 decoding follows FFmpeg libavcodec/mpc8.c.
/// Copyright (c) 2007 Konstantin Shishkov. LGPL-2.1-or-later.
fn mpc8_book(
  counts : FixedArray[Int32],
  index : Int32,
  symbols : FixedArray[Int32],
  cursor : Ref[Int32],
  bias : Int32,
) -> DcaVlcBook {
  let pairs = []
  for len = 16; len > 0; len = len - 1 {
    for _ in 0..<counts[index * 16 + len - 1] {
      pairs.push(symbols[cursor.val])
      pairs.push(len)
      cursor.val += 1
    }
  }
  dca_vlc_build(FixedArray::from_array(pairs), 0, pairs.length() / 2, bias)
}

///|
priv struct Mpc8Books {
  band : DcaVlcBook
  scfi : FixedArray[DcaVlcBook]
  scales : FixedArray[DcaVlcBook]
  resolutions : FixedArray[DcaVlcBook]
  q1 : DcaVlcBook
  q9 : DcaVlcBook
  quant : Array[DcaVlcBook]
}

///|
fn mpc8_make_books() -> Mpc8Books {
  let q = Ref(0)
  let q1 = mpc8_book(mpc8_q1_len_counts, 0, mpc8_q_syms, q, 0)
  let q9 = mpc8_book(mpc8_q9up_len_counts, 0, mpc8_q_syms, q, 0)
  let quant = []
  for i in 0..<2 {
    quant.push(mpc8_book(mpc8_q2_len_counts, i, mpc8_q_syms, q, 0))
    quant.push(mpc8_book(mpc8_q34_len_counts, i, mpc8_q_syms, q, -48 - 16 * i))
    for j in 0..<4 {
      quant.push(
        mpc8_book(mpc8_q5_8_len_counts, i * 4 + j, mpc8_q_syms, q, 1 - (8 << j)),
      )
    }
  }
  let scfi = Ref(0)
  let scales = Ref(0)
  let resolutions = Ref(0)
  {
    band: mpc8_book(mpc8_bands_len_counts, 0, mpc8_bands_syms, Ref(0), 0),
    scfi: FixedArray::makei(2, i => {
      mpc8_book(mpc8_scfi_len_counts, i, mpc8_scfi_syms, scfi, 0)
    }),
    scales: FixedArray::makei(2, i => {
      mpc8_book(mpc8_dscf_len_counts, i, mpc8_dscf_syms, scales, 0)
    }),
    resolutions: FixedArray::makei(2, i => {
      mpc8_book(mpc8_res_len_counts, i, mpc8_res_syms, resolutions, 0)
    }),
    q1,
    q9,
    quant,
  }
}

///|
let mpc8_books : Mpc8Books = mpc8_make_books()

///|
fn mpc8_binomial() -> FixedArray[FixedArray[Int32]] {
  let rows = FixedArray::makei(34, _ => FixedArray::make(17, 0))
  for n in 0..<34 {
    rows[n][0] = 1
    if n > 0 {
      for k in 1..<=n.min(16) {
        rows[n][k] = rows[n - 1][k - 1] + rows[n - 1][k]
      }
    }
  }
  rows
}

///|
let mpc8_choose : FixedArray[FixedArray[Int32]] = mpc8_binomial()

///|
fn mpc8_base(reader : BitReader, count : Int32) -> Int32 {
  if count <= 1 {
    return 0
  }
  let width = 31 - (count - 1).clz()
  let lost = (2 << width) - count
  let code = reader.read(width).reinterpret_as_int()
  if code < lost {
    code
  } else {
    code * 2 + reader.read1().reinterpret_as_int() - lost
  }
}

///|
fn mpc8_mask(reader : BitReader, size : Int32, count : Int32) -> Int32 {
  let mut remaining = count.min(size - count)
  let mut mask = 0
  let mut code = mpc8_base(reader, mpc8_choose[size][remaining])
  for i = size - 1; i >= 0 && remaining > 0; i = i - 1 {
    let limit = mpc8_choose[i][remaining]
    if code >= limit {
      mask = mask | (1 << i)
      code -= limit
      remaining -= 1
    }
  }
  if count * 2 > size {
    mask ^ -1
  } else {
    mask
  }
}

///|
/// A stateful Musepack SV8 decoder for complete AP packets.
pub struct Mpc8Decoder {
  channels : Int32
  max_band : Int32
  mid_side : Bool
  frames_per_packet : Int32
  priv mut synth : Array[Array[Int32]]
  priv mut offsets : FixedArray[Int32]
  priv noise : FixedArray[UInt32]
  priv mut noise_index : Int32
}

///|
pub fn Mpc8Decoder::new(extra : Bytes) -> Result[Mpc8Decoder, String] {
  guard extra.length() >= 2 else { return Err("musepack: missing SV8 header") }
  let channels = (extra[1].to_int() >> 4) + 1
  let max_band = (extra[0].to_int() & 31) + 1
  guard channels <= 2 && max_band < 32 && extra[0].to_int() >> 5 < 4 else {
    return Err("musepack: unsupported SV8 stream parameters")
  }
  Ok({
    channels,
    max_band,
    mid_side: (extra[1].to_int() & 8) != 0,
    frames_per_packet: 1 << ((extra[1].to_int() & 7) * 2),
    synth: Array::makei(channels, _ => Array::make(1024, 0)),
    offsets: FixedArray::make(channels, 0),
    noise: mpc7_noise_seed(),
    noise_index: 0,
  })
}

///|
fn Mpc8Decoder::quantize(
  self : Mpc8Decoder,
  reader : BitReader,
  res : Int32,
  dst : FixedArray[Int32],
) -> Unit raise Mpc7Error {
  match res {
    -1 =>
      for i in 0..<36 {
        let index = self.noise_index
        let n = self.noise[(index - 24) & 63] + self.noise[(index - 55) & 63]
        self.noise[index] = n
        self.noise_index = (index + 1) & 63
        dst[i] = (n & 1020U).reinterpret_as_int() - 510
      }
    1 =>
      for start in [0, 18] {
        let count = mpc7_vlc(mpc8_books.q1, reader)
        let mask = mpc8_mask(reader, 18, count)
        for i in 0..<18 {
          dst[start + i] = if (mask & (1 << (17 - i))) != 0 {
            reader.read1().reinterpret_as_int() * 2 - 1
          } else {
            0
          }
        }
      }
    2 => {
      let mut context = 6
      for i = 0; i < 36; i = i + 3 {
        let index = mpc7_vlc(
          mpc8_books.quant[if context > 3 { 6 } else { 0 }],
          reader,
        )
        dst[i] = mpc8_idx50[index]
        dst[i + 1] = mpc8_idx51[index]
        dst[i + 2] = mpc8_idx52[index]
        context = (context >> 1) + mpc8_huffq2[index]
      }
    }
    3 | 4 =>
      for i = 0; i < 36; i = i + 2 {
        let pair = mpc7_vlc(mpc8_books.quant[1 + 6 * (res - 3)], reader)
        dst[i] = pair << 28 >> 28
        dst[i + 1] = pair >> 4
      }
    5..<=8 => {
      let threshold = mpc8_thres[res]
      let mut context = threshold * 2
      for i in 0..<36 {
        let index = res - 3 + (if context > threshold { 6 } else { 0 })
        let sample = mpc7_vlc(mpc8_books.quant[index], reader)
        dst[i] = sample
        context = (context >> 1) + sample.abs()
      }
    }
    _ =>
      for i in 0..<36 {
        let high = mpc7_vlc(mpc8_books.q9, reader)
        let low = reader.read(res - 9).reinterpret_as_int()
        dst[i] = (high << (res - 9)) + low - ((1 << (res - 2)) - 1)
      }
  }
}

///|
fn Mpc8Decoder::read_frame(
  self : Mpc8Decoder,
  reader : BitReader,
  band_count : Int32,
  scales : FixedArray[Int32],
  fresh : FixedArray[Bool],
) -> Array[Array[Int32]] raise Mpc7Error {
  let res = FixedArray::make(band_count * 2, 0)
  let previous = FixedArray::make(2, 0)
  let mut active = 0
  for band = band_count - 1; band >= 0; band = band - 1 {
    for ch in 0..<2 {
      let prior = previous[ch]
      let value = prior +
        mpc7_vlc(mpc8_books.resolutions[if prior > 2 { 1 } else { 0 }], reader)
      let value = if value > 15 { value - 17 } else { value }
      res[band * 2 + ch] = value
      previous[ch] = value
    }
    if res[band * 2] != 0 || res[band * 2 + 1] != 0 {
      active += 1
    }
  }
  let mut mask = if self.mid_side && active > 0 {
    mpc8_mask(reader, active, mpc8_base(reader, active + 1))
  } else {
    0
  }
  let ms = FixedArray::make(band_count, false)
  let modes = FixedArray::make(band_count * 2, 0)
  for band = band_count - 1; band >= 0; band = band - 1 {
    if res[band * 2] != 0 || res[band * 2 + 1] != 0 {
      ms[band] = (mask & 1) != 0
      mask = mask >> 1
    }
  }
  for band in 0..<band_count {
    let i = band * 2
    if res[i] == 0 && res[i + 1] == 0 {
      continue
    }
    let both = if res[i] != 0 && res[i + 1] != 0 { 1 } else { 0 }
    let value = mpc7_vlc(mpc8_books.scfi[both], reader)
    modes[i] = value >> (2 * both)
    modes[i + 1] = value & 3
  }
  let factors = FixedArray::make(band_count * 6, (0.0 : Float))
  for i in 0..<res.length() {
    if res[i] == 0 {
      continue
    }
    let mut scale = if fresh[i] {
      fresh[i] = false
      reader.read(7).reinterpret_as_int() - 6
    } else {
      let delta = mpc7_vlc(mpc8_books.scales[1], reader)
      let delta = if delta == 64 {
        delta + reader.read(6).reinterpret_as_int()
      } else {
        delta
      }
      ((scales[i] + delta - 25) & 127) - 6
    }
    for j in 0..<3 {
      if j > 0 && (modes[i] & (1 << (2 - j))) == 0 {
        let delta = mpc7_vlc(mpc8_books.scales[0], reader)
        let delta = if delta == 31 {
          64 + reader.read(6).reinterpret_as_int()
        } else {
          delta
        }
        scale = ((scale + delta - 25) & 127) - 6
      }
      factors[i * 3 + j] = mpc_cc[res[i] + 1] * mpc_scf[scale & 255]
    }
    scales[i] = scale
  }
  let subbands = Array::makei(2, _ => Array::make(1152, 0))
  let values = FixedArray::make(36, 0)
  for i in 0..<res.length() {
    if res[i] == 0 {
      continue
    }
    self.quantize(reader, res[i], values)
    for j in 0..<36 {
      subbands[i % 2][j * 32 + i / 2] = (factors[i * 3 + j / 12] *
      Float::from_int(values[j])).to_int()
    }
  }
  guard reader.bits_left() >= 0 else {
    raise Mpc7Invalid("truncated SV8 frame")
  }
  for band in 0..<band_count {
    if ms[band] {
      for row in 0..<36 {
        let i = row * 32 + band
        let left = subbands[0][i]
        let right = subbands[1][i]
        subbands[0][i] = left + right
        subbands[1][i] = left - right
      }
    }
  }
  subbands
}

///|
/// Decode an AP packet into consecutive planar S16 sample rows.
pub fn Mpc8Decoder::decode_packet(
  self : Mpc8Decoder,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  guard !data.is_empty() && data.length() <= 268435455 else {
    return Err("musepack: invalid SV8 packet size")
  }
  let reader = BitReader::new(data)
  let scales = FixedArray::make(64, 0)
  let fresh = FixedArray::make(64, true)
  let synth = self.synth.map(channel => channel.copy())
  let offsets = self.offsets.copy()
  let out : Array[Array[Int32]] = Array::makei(self.channels, _ => [])
  let saved_noise = self.noise.copy()
  let saved_index = self.noise_index
  try {
    let mut count = mpc8_base(reader, self.max_band + 2)
    for i in 0..<self.frames_per_packet {
      if i > 0 {
        if reader.bits_left() < 8 && reader.show(reader.bits_left()) == 0U {
          break
        }
        count = (count + mpc7_vlc(mpc8_books.band, reader)) % 33
      }
      guard count <= self.max_band + 1 else {
        raise Mpc7Invalid("invalid SV8 subband count")
      }
      let subbands = self.read_frame(reader, count, scales, fresh)
      let samples = mpc_synthesize(synth, offsets, subbands)
      for ch in 0..<self.channels {
        for sample in samples[ch] {
          out[ch].push(sample)
        }
      }
    }
    guard reader.bits_left() < 8 else {
      raise Mpc7Invalid("trailing bits in SV8 packet")
    }
    self.synth = synth
    self.offsets = offsets
    Ok(out)
  } catch {
    Mpc7Invalid(message) => {
      for i in 0..<64 {
        self.noise[i] = saved_noise[i]
      }
      self.noise_index = saved_index
      Err("musepack: \{message}")
    }
  }
}
