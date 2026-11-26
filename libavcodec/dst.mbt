///|
/// Direct Stream Transfer decoder from FFmpeg dstdec.c, copyright 2014
/// Peter Ross. LGPL-2.1-or-later. Supports the common shared segmentation.
pub struct DstDecoder {
  dsd : DsdDecoder
  channels : Int32
  frame_samples : Int32
}

///|
/// Number of decoded PCM samples per 1/75-second DST packet.
pub fn dst_frame_samples(sample_rate : Int32) -> Int32 {
  match sample_rate {
    352800 | 705600 | 1411200 => sample_rate / 75
    _ => 0
  }
}

///|
/// Open the DST filter bank for DSD64, DSD128 or DSD256.
///
/// ```mbt check
/// test {
///   assert_true(@libavcodec.dst_decoder_new(0, 352800) is Err(_))
/// }
/// ```
pub fn dst_decoder_new(
  channels : Int32,
  sample_rate : Int32,
) -> Result[DstDecoder, String] {
  let frame_samples = dst_frame_samples(sample_rate)
  if channels < 1 || channels > 6 || frame_samples == 0 {
    return Err("dst: unsupported stream parameters")
  }
  match dsd_decoder_new(channels) {
    Ok(dsd) => Ok({ channels, frame_samples, dsd, })
    Err(e) => Err(e)
  }
}

///|
priv suberror DstSyntaxError {
  DstSyntaxError(String)
}

///|
fn dst_read(bits : BitReader, width : Int32) -> Int32 raise DstSyntaxError {
  if bits.bits_left() < width {
    raise DstSyntaxError("dst: truncated frame syntax")
  }
  bits.read(width).reinterpret_as_int()
}

///|
fn dst_read_map(
  bits : BitReader,
  channels : Int32,
) -> (FixedArray[Int32], Int32) raise DstSyntaxError {
  let map = FixedArray::make(channels, 0)
  let mut count = 1
  if dst_read(bits, 1) == 0 {
    for ch in 1..<channels {
      let entry = dst_read(
        bits,
        if count < 2 {
          1
        } else if count < 4 {
          2
        } else {
          3
        },
      )
      if entry > count {
        raise DstSyntaxError("dst: invalid table mapping")
      }
      map[ch] = entry
      if entry == count {
        count += 1
      }
    }
  }
  (map, count)
}

///|
let dst_filter_predictors : FixedArray[FixedArray[Int32]] = [
  [-8],
  [-16, 8],
  [-9, -5, 6],
]

///|
let dst_probability_predictors : FixedArray[FixedArray[Int32]] = [
  [-8],
  [-16, 8],
  [-24, 24, -8],
]

///|
fn dst_read_rice(bits : BitReader, width : Int32) -> Int32 raise DstSyntaxError {
  let mut unary = 0
  while dst_read(bits, 1) == 0 {
    unary += 1
    if unary > 0x00ffffff {
      raise DstSyntaxError("dst: invalid Rice value")
    }
  }
  let value = (unary << width) | dst_read(bits, width)
  if value != 0 && dst_read(bits, 1) != 0 {
    -value
  } else {
    value
  }
}

///|
fn dst_read_table(
  bits : BitReader,
  elements : Int32,
  filter : Bool,
) -> Array[Array[Int32]] raise DstSyntaxError {
  let predictors = if filter {
    dst_filter_predictors
  } else {
    dst_probability_predictors
  }
  let length_bits = if filter { 7 } else { 6 }
  let coeff_bits = if filter { 9 } else { 7 }
  let tables : Array[Array[Int32]] = []
  for _ in 0..<elements {
    let length = dst_read(bits, length_bits) + 1
    let coded = dst_read(bits, 1) != 0
    let predictor = if coded { dst_read(bits, 2) } else { 0 }
    if predictor == 3 {
      raise DstSyntaxError("dst: invalid coefficient method")
    }
    let initial = if coded { predictor + 1 } else { length }
    let table : Array[Int32] = []
    for i in 0..<initial {
      let raw = dst_read(bits, coeff_bits)
      if i < length {
        table.push(if filter { raw << 23 >> 23 } else { raw + 1 })
      }
    }
    if coded {
      let width = dst_read(bits, 3)
      for i in initial..<length {
        let mut prediction = 0
        for k in 0..<(predictor + 1) {
          prediction += predictors[predictor][k] * table[i - k - 1]
        }
        let residual = dst_read_rice(bits, width)
        let value = if prediction >= 0 {
          residual - (prediction + 4) / 8
        } else {
          residual + (-prediction + 3) / 8
        }
        if !filter && (value < 1 || value > 128) {
          raise DstSyntaxError("dst: invalid probability")
        }
        // A valid table row must fit a signed 16-bit lookup for every sign.
        if filter && (value < -32767 || value > 32767) {
          raise DstSyntaxError("dst: filter coefficient out of range")
        }
        table.push(value)
      }
    }
    tables.push(table)
  }
  tables
}

///|
priv struct DstArith {
  mut a : Int32
  mut c : Int32
}

///|
fn DstArith::read(
  self : DstArith,
  bits : BitReader,
  probability : Int32,
) -> Int32 {
  let q = ((self.a >> 8) | ((self.a >> 7) & 1)) * probability
  let split = self.a - q
  let value = if self.c < split {
    self.a = split
    1
  } else {
    self.a = q
    self.c -= split
    0
  }
  while self.a < 2048 {
    self.a = self.a << 1
    self.c = (self.c << 1) | bits.read1().reinterpret_as_int()
  }
  value
}

///|
fn dst_filter_lookup(
  coeff : Array[Int32],
) -> FixedArray[Int32] raise DstSyntaxError {
  let lookup = FixedArray::make(16 * 256, 0)
  for row in 0..<((coeff.length() + 7) / 8) {
    let start = row * 8
    let count = (coeff.length() - start).max(0).min(8)
    for byte in 0..<256 {
      let mut sum = 0
      for i in 0..<count {
        sum += (((byte >> i) & 1) * 2 - 1) * coeff[start + i]
      }
      if sum < -32768 || sum > 32767 {
        raise DstSyntaxError("dst: filter exceeds signed 16-bit range")
      }
      lookup[row * 256 + byte] = sum
    }
  }
  lookup
}

///|
fn dst_unpack(
  data : Bytes,
  channels : Int32,
  count : Int32,
) -> Bytes raise DstSyntaxError {
  let bits = BitReader::new(data)
  if dst_read(bits, 1) == 0 {
    raise DstSyntaxError("dst: unsupported uncompressed frame")
  }
  if dst_read(bits, 3) != 7 {
    raise DstSyntaxError("dst: unsupported segmentation")
  }
  let same_map = dst_read(bits, 1) != 0
  let (filter_map, filters) = dst_read_map(bits, channels)
  let (prob_map, probabilities) = if same_map {
    (filter_map, filters)
  } else {
    dst_read_map(bits, channels)
  }
  let half : Array[Bool] = []
  for _ in 0..<channels {
    half.push(dst_read(bits, 1) != 0)
  }
  let coeff = dst_read_table(bits, filters, true)
  let probs = dst_read_table(bits, probabilities, false)
  if dst_read(bits, 1) != 0 {
    raise DstSyntaxError("dst: invalid arithmetic marker")
  }
  let arith : DstArith = { a: 4095, c: dst_read(bits, 12), }
  let lookup : Array[FixedArray[Int32]] = []
  for table in coeff {
    lookup.push(dst_filter_lookup(table))
  }
  let lo = FixedArray::make(channels, 0xaaaaaaaaaaaaaaaaUL)
  let hi = FixedArray::make(channels, 0xaaaaaaaaaaaaaaaaUL)
  let payload = FixedArray::make(count * channels, b'\x00')
  ignore(arith.read(bits, (dsd_reverse_byte[coeff[0][0] & 127] >> 1) + 1))
  for i in 0..<(count * 8) {
    for ch in 0..<channels {
      let f = filter_map[ch]
      let mut sum = 0
      for j in 0..<8 {
        let shift = 8 * j
        sum += lookup[f][j * 256 + ((lo[ch] >> shift) & 255UL).to_int()]
        sum += lookup[f][(j + 8) * 256 + ((hi[ch] >> shift) & 255UL).to_int()]
      }
      let prediction = sum << 16 >> 16
      let table = probs[prob_map[ch]]
      let probability = if half[ch] && i < coeff[f].length() {
        128
      } else {
        table[(prediction.abs() >> 3).min(table.length() - 1)]
      }
      let residual = arith.read(bits, probability)
      let value = ((prediction >> 15) ^ residual) & 1
      let pos = (i >> 3) * channels + ch
      payload[pos] = (payload[pos].to_int() | (value << (7 - (i & 7)))).to_byte()
      hi[ch] = (hi[ch] << 1) | (lo[ch] >> 63)
      lo[ch] = (lo[ch] << 1) | value.to_uint64()
    }
  }
  // FFmpeg's arithmetic decoder can read zero padding past the last byte.
  if bits.bits_left() < -32 {
    raise DstSyntaxError("dst: truncated arithmetic data")
  }
  Bytes::from_array(payload)
}

///|
/// Decode one arithmetic-coded DST frame and advance the DSD filter history.
pub fn DstDecoder::decode_packet(
  self : DstDecoder,
  data : Bytes,
) -> Result[Array[Array[Double]], String] {
  if data.length() <= 1 || data.length() > 0x0fffffff {
    return Err("dst: invalid frame size")
  }
  let dsd = dst_unpack(data, self.channels, self.frame_samples) catch {
    DstSyntaxError(message) => return Err(message)
  }
  self.dsd.decode_packet(dsd)
}
