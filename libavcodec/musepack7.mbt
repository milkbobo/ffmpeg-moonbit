///|
/// Musepack SV7, ported from FFmpeg libavcodec/mpc7.c and mpc.c.
/// Copyright (c) 2006 Konstantin Shishkov. LGPL-2.1-or-later.
priv suberror Mpc7Error {
  Mpc7Invalid(String)
}

///|
let mpc7_band_book : DcaVlcBook = dca_vlc_build(mpc7_hdr, 0, 10, -5)

///|
let mpc7_scfi_book : DcaVlcBook = dca_vlc_build(mpc7_scfi, 0, 4, 0)

///|
let mpc7_scale_book : DcaVlcBook = dca_vlc_build(mpc7_dscf, 0, 16, -7)

///|
fn mpc7_build_quant_books() -> Array[DcaVlcBook] {
  let books = []
  let mut offset = 0
  for i in 0..<7 {
    let length = mpc7_quant_vlc_sizes[i]
    for _ in 0..<2 {
      books.push(
        dca_vlc_build(mpc7_quant_vlcs, offset, length, mpc7_quant_vlc_off[i]),
      )
      offset += length
    }
  }
  books
}

///|
let mpc7_quant_books : Array[DcaVlcBook] = mpc7_build_quant_books()

///|
fn mpc7_vlc(book : DcaVlcBook, reader : BitReader) -> Int32 raise Mpc7Error {
  let mut node = 0
  while reader.bits_left() > 0 {
    let child = book.nodes[node * 2 + reader.read1().reinterpret_as_int()]
    if child < -1 {
      return book.syms[-2 - child]
    }
    if child < 0 {
      break
    }
    node = child
  }
  raise Mpc7Invalid("invalid or truncated VLC")
}

///|
fn mpc7_word_swap(data : BytesView) -> Bytes {
  Bytes::makei(data.length() & -4, i => data[i ^ 3])
}

///|
fn mpc7_noise_seed() -> FixedArray[UInt32] {
  let state = FixedArray::make(64, 0U)
  let temp = FixedArray::make(16, b'\x00')
  for i = 8; i < 64; i = i + 4 {
    temp[0] = b'\xef'
    temp[1] = b'\xbe'
    temp[2] = b'\xad'
    temp[3] = b'\xde'
    temp[4] = i.to_byte()
    let input = Bytes::makei(16, j => temp[j])
    @libavutil.av_md5_sum(temp, input, 16)
    for j in 0..<4 {
      let p = j * 4
      state[i + j] = temp[p].to_uint() |
        (temp[p + 1].to_uint() << 8) |
        (temp[p + 2].to_uint() << 16) |
        (temp[p + 3].to_uint() << 24)
    }
  }
  state
}

///|
/// Stateful decoder. Create one decoder per SV7 stream.
pub struct Mpc7Decoder {
  max_band : Int32
  mid_side : Bool
  last_samples : Int32
  old_scale : FixedArray[Int32]
  noise_state : FixedArray[UInt32]
  mut noise_index : Int32
  synth : Array[Array[Int32]]
  synth_offset : FixedArray[Int32]
}

///|
/// Open an SV7 decoder with the 16 bytes following the file's frame count.
pub fn Mpc7Decoder::new(extradata : Bytes) -> Result[Mpc7Decoder, String] {
  if extradata.length() < 16 {
    return Err("musepack: missing SV7 stream header")
  }
  let reader = BitReader::new(mpc7_word_swap(extradata[:16]))
  reader.skip(1)
  let mid_side = reader.read1() != 0U
  let max_band = reader.read(6).reinterpret_as_int()
  if max_band >= 32 {
    return Err("musepack: invalid maximum band")
  }
  reader.skip(89)
  let last_samples = reader.read(11).reinterpret_as_int()
  Ok({
    max_band,
    mid_side,
    last_samples,
    old_scale: FixedArray::make(64, 0),
    noise_state: mpc7_noise_seed(),
    noise_index: 0,
    synth: Array::makei(2, _ => Array::make(1024, 0)),
    synth_offset: [0, 0],
  })
}

///|
fn Mpc7Decoder::noise(self : Mpc7Decoder) -> Int32 {
  let i = self.noise_index
  let value = self.noise_state[(i - 24) & 63] + self.noise_state[(i - 55) & 63]
  self.noise_state[i] = value
  self.noise_index = (i + 1) & 63
  (value & 0x3FCU).reinterpret_as_int() - 510
}

///|
fn mpc7_scale(reader : BitReader, reference : Int32) -> Int32 raise Mpc7Error {
  let delta = mpc7_vlc(mpc7_scale_book, reader)
  if delta == 8 {
    reader.read(6).reinterpret_as_int()
  } else {
    reference + delta
  }
}

///|
fn Mpc7Decoder::quantize(
  self : Mpc7Decoder,
  reader : BitReader,
  res : Int32,
  dst : FixedArray[Int32],
) -> Unit raise Mpc7Error {
  if res == -1 {
    for i in 0..<36 {
      dst[i] = self.noise()
    }
  } else if res <= 7 {
    let book = mpc7_quant_books[(res - 1) * 2 +
      reader.read1().reinterpret_as_int()]
    if res <= 2 {
      let (group, base) = if res == 1 { (3, 3) } else { (2, 5) }
      for start = 0; start < 36; start = start + group {
        let mut index = mpc7_vlc(book, reader)
        for i in 0..<group {
          dst[start + i] = index % base - base / 2
          index /= base
        }
      }
    } else {
      for i in 0..<36 {
        dst[i] = mpc7_vlc(book, reader)
      }
    }
  } else {
    let center = (1 << (res - 2)) - 1
    for i in 0..<36 {
      dst[i] = reader.read(res - 1).reinterpret_as_int() - center
    }
  }
}

///|
fn Mpc7Decoder::decode(
  self : Mpc7Decoder,
  data : Bytes,
) -> Array[Array[Int32]] raise Mpc7Error {
  guard data.length() >= 8 && data.length() <= 131084 else {
    raise Mpc7Invalid("invalid packet size")
  }
  let reader = BitReader::new(mpc7_word_swap(data[4:]))
  let skip = data[0].to_int()
  guard skip <= 51 && skip < reader.bits_left() else {
    raise Mpc7Invalid("invalid packet bit offset")
  }
  reader.skip(skip)
  let coded = (self.max_band + 1) * 2
  let resolutions = FixedArray::make(coded, 0)
  let is_mid_side = FixedArray::make(self.max_band + 1, false)
  for band in 0..<=self.max_band {
    let slot = band * 2
    for ch in 0..<2 {
      let delta = if band == 0 { 4 } else { mpc7_vlc(mpc7_band_book, reader) }
      let res = if delta == 4 {
        reader.read(4).reinterpret_as_int()
      } else {
        resolutions[slot + ch - 2] + delta
      }
      guard res >= -1 && res <= 17 else {
        raise Mpc7Invalid("invalid subband resolution")
      }
      resolutions[slot + ch] = res
    }
    if self.mid_side && (resolutions[slot] != 0 || resolutions[slot + 1] != 0) {
      is_mid_side[band] = reader.read1() != 0U
    }
  }
  let scfi = FixedArray::make(coded, 0)
  for slot in 0..<coded {
    if resolutions[slot] != 0 {
      scfi[slot] = mpc7_vlc(mpc7_scfi_book, reader)
    }
  }
  let factors : FixedArray[(Float, Float, Float)] = FixedArray::make(
    coded,
    (0.0, 0.0, 0.0),
  )
  for slot in 0..<coded {
    let res = resolutions[slot]
    if res == 0 {
      continue
    }
    let s0 = mpc7_scale(reader, self.old_scale[slot])
    let mode = scfi[slot]
    let s1 = if mode < 2 { mpc7_scale(reader, s0) } else { s0 }
    let s2 = if mode == 0 || mode == 2 { mpc7_scale(reader, s1) } else { s1 }
    self.old_scale[slot] = s2
    let scale = mpc_cc[res + 1]
    factors[slot] = (
      scale * mpc_scf[s0 & 255],
      scale * mpc_scf[s1 & 255],
      scale * mpc_scf[s2 & 255],
    )
  }
  let subbands = Array::makei(2, _ => Array::make(1152, 0))
  let values = FixedArray::make(36, 0)
  for slot in 0..<coded {
    let res = resolutions[slot]
    if res == 0 {
      continue
    }
    self.quantize(reader, res, values)
    let (f0, f1, f2) = factors[slot]
    for row in 0..<36 {
      let factor = if row < 12 { f0 } else if row < 24 { f1 } else { f2 }
      let sample = factor * Float::from_int(values[row])
      subbands[slot % 2][row * 32 + slot / 2] = sample.to_int()
    }
  }
  let last = data[1] != b'\x00'
  guard reader.bits_left() >= 0 && (last || reader.bits_left() < 32) else {
    raise Mpc7Invalid("inconsistent packet bit length")
  }
  for band in 0..<=self.max_band {
    if is_mid_side[band] {
      for row in 0..<36 {
        let i = row * 32 + band
        let l = subbands[0][i]
        let r = subbands[1][i]
        subbands[0][i] = l + r
        subbands[1][i] = l - r
      }
    }
  }
  let output = Array::makei(2, _ => Array::make(1152, 0))
  let mut dither = 0
  for ch in 0..<2 {
    for row in 0..<36 {
      let offset = self.synth_offset[ch]
      let pos = row * 32
      dct32(self.synth[ch], offset, subbands[ch], pos)
      dither = apply_window(
        self.synth[ch],
        offset,
        synth_window,
        dither,
        output[ch],
        pos,
        1,
      )
      self.synth_offset[ch] = (offset - 32) & 511
    }
  }
  if last && self.last_samples < 1152 {
    output.map(ch => ch[:self.last_samples].to_owned())
  } else {
    output
  }
}

///|
/// Decode a demuxed SV7 packet to signed 16-bit PCM in channel order.
/// Its four-byte prefix carries the starting bit offset and final-frame flag.
pub fn Mpc7Decoder::decode_packet(
  self : Mpc7Decoder,
  data : Bytes,
) -> Result[Array[Array[Int32]], String] {
  // Syntax errors leave scale history and the noise generator unchanged.
  // The synthesis state is written only after packet validation.
  let old_scale = self.old_scale.copy()
  let noise_state = self.noise_state.copy()
  let noise_index = self.noise_index
  Ok(self.decode(data)) catch {
    Mpc7Invalid(message) => {
      for i in 0..<64 {
        self.old_scale[i] = old_scale[i]
        self.noise_state[i] = noise_state[i]
      }
      self.noise_index = noise_index
      Err("musepack: \{message}")
    }
  }
}
