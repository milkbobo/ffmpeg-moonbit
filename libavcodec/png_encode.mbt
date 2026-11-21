///|
/// A full-canvas APNG input frame with delay numerator and denominator.
pub(all) struct ApngEncodeFrame {
  pixels : Bytes
  delay_num : Int32
  delay_den : Int32
}

///|
fn png_enc_layout(
  width : Int32,
  height : Int32,
  format : String,
) -> Result[(Int32, Int32, Int32), String] {
  let (color, depth) = match format {
    "gray" => (0, 8)
    "gray16be" => (0, 16)
    "rgb24" => (2, 8)
    "rgb48be" => (2, 16)
    "ya8" => (4, 8)
    "ya16be" => (4, 16)
    "rgba" => (6, 8)
    "rgba64be" => (6, 16)
    _ => return Err("png: unsupported encoder pixel format")
  }
  let bpp = png_channels(color) * depth / 8
  guard width > 0 &&
    height > 0 &&
    width <= 32768 &&
    height <= 32768 &&
    (width.to_int64() * bpp.to_int64() + 1L) * height.to_int64() <= 64000000L else {
    return Err("png: dimensions exceed the encoder image budget")
  }
  Ok((color, depth, bpp))
}

///|
fn png_enc_header(
  width : Int32,
  height : Int32,
  color : Int32,
  depth : Int32,
) -> Array[Byte] {
  let out = b"\x89PNG\r\n\x1a\n".to_array()
  let header = []
  apng_put_u32(header, width)
  apng_put_u32(header, height)
  header.push(depth.to_byte())
  header.push(color.to_byte())
  header.append([b'\x00', b'\x00', b'\x00'])
  apng_put_chunk(out, b"IHDR", header)
  out
}

///|
fn png_enc_filter(
  pixels : Bytes,
  rowbytes : Int32,
  bpp : Int32,
  height : Int32,
) -> Bytes {
  let result = Array::make((rowbytes + 1) * height, b'\x00')
  let scratch = Array::make(rowbytes, b'\x00')
  for y in 0..<height {
    let row = y * rowbytes
    let dest = y * (rowbytes + 1)
    let mut best = 0x7fffffff
    // None, Sub, Up. Use the smallest sum of absolute signed residuals.
    for filter in 0..<=2 {
      let mut score = 0
      for x in 0..<rowbytes {
        let predictor = if filter == 1 && x >= bpp {
          pixels[row + x - bpp].to_int()
        } else if filter == 2 && y > 0 {
          pixels[row + x - rowbytes].to_int()
        } else {
          0
        }
        let residual = (pixels[row + x].to_int() - predictor) & 255
        scratch[x] = residual.to_byte()
        score += residual.min(256 - residual)
      }
      if score < best {
        best = score
        result[dest] = filter.to_byte()
        for x in 0..<rowbytes {
          result[dest + 1 + x] = scratch[x]
        }
      }
    }
  }
  Bytes::from_array(result)
}

///|
priv struct PngDeflateWriter {
  out : Array[Byte]
  mut bits : Int32
  mut count : Int32
}

///|
fn PngDeflateWriter::put(
  self : PngDeflateWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  self.bits = self.bits | (value << self.count)
  self.count += count
  while self.count >= 8 {
    self.out.push(self.bits.to_byte())
    self.bits = self.bits >> 8
    self.count -= 8
  }
}

///|
fn PngDeflateWriter::code(
  self : PngDeflateWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  let mut reversed = 0
  for i in 0..<count {
    reversed = (reversed << 1) | ((value >> i) & 1)
  }
  self.put(reversed, count)
}

///|
fn PngDeflateWriter::literal(self : PngDeflateWriter, symbol : Int32) -> Unit {
  if symbol < 144 {
    self.code(symbol + 48, 8)
  } else if symbol < 256 {
    self.code(symbol - 144 + 400, 9)
  } else if symbol < 280 {
    self.code(symbol - 256, 7)
  } else {
    self.code(symbol - 280 + 192, 8)
  }
}

///|
fn png_deflate_index(table : FixedArray[Int32], value : Int32) -> Int32 {
  let mut index = table.length() - 1
  while table[index] > value {
    index -= 1
  }
  index
}

///|
fn png_deflate_hash(data : Bytes, i : Int32) -> Int32 {
  ((data[i].to_int() * 251 + data[i + 1].to_int()) * 251 + data[i + 2].to_int()) &
  65535
}

///|
// Fixed Huffman coding with a single previous position per three-byte hash.
fn png_deflate_fixed(data : Bytes) -> Array[Byte] {
  let writer : PngDeflateWriter = {
    out: [b'\x78', b'\x01'],
    bits: 0,
    count: 0,
  }
  writer.put(3, 3) // Final block, fixed Huffman.
  let previous = FixedArray::make(65536, -1)
  let end = data.length()
  let mut i = 0
  while i < end {
    let mut len = 0
    let mut distance = 0
    if i + 2 < end {
      let hash = png_deflate_hash(data, i)
      let start = previous[hash]
      distance = i - start
      if start >= 0 && distance <= 32768 {
        let cap = (end - i).min(258)
        while len < cap && data[start + len] == data[i + len] {
          len += 1
        }
      }
    }
    let step = if len >= 3 {
      let l = png_deflate_index(inflate_length_base, len)
      let d = png_deflate_index(inflate_dist_base, distance)
      writer.literal(257 + l)
      writer.put(len - inflate_length_base[l], inflate_length_extra[l])
      writer.code(d, 5)
      writer.put(distance - inflate_dist_base[d], inflate_dist_extra[d])
      len
    } else {
      writer.literal(data[i].to_int())
      1
    }
    for j in i..<(i + step).min(end - 2) {
      previous[png_deflate_hash(data, j)] = j
    }
    i += step
  }
  writer.literal(256)
  if writer.count > 0 {
    writer.out.push(writer.bits.to_byte())
  }
  writer.out
}

///|
fn png_enc_data(
  pixels : Bytes,
  rowbytes : Int32,
  bpp : Int32,
  height : Int32,
) -> Array[Byte] {
  let filtered = png_enc_filter(pixels, rowbytes, bpp, height)
  let fixed = png_deflate_fixed(filtered)
  let length = filtered.length()
  let stored_size = 2 + length + 5 * ((length + 65534) / 65535)
  let out = if fixed.length() <= stored_size {
    fixed
  } else {
    let stored = [b'\x78', b'\x01']
    for start = 0; start < length; start = start + 65535 {
      let count = (length - start).min(65535)
      stored.push(if start + count == length { b'\x01' } else { b'\x00' })
      stored.push(count.to_byte())
      stored.push((count >> 8).to_byte())
      stored.push((count ^ 255).to_byte())
      stored.push(((count >> 8) ^ 255).to_byte())
      for i in start..<(start + count) {
        stored.push(filtered[i])
      }
    }
    stored
  }
  apng_put_u32(out, inflate_adler32(filtered).reinterpret_as_int())
  out
}

///|
/// Encode packed grayscale, gray-alpha, RGB or RGBA PNG. The corresponding
/// 16-bit formats use big-endian samples. Rows are tightly packed.
pub fn av_png_encode(
  width : Int32,
  height : Int32,
  pixels : Bytes,
  format~ : String = "rgba",
) -> Result[Bytes, String] {
  let (color, depth, bpp) = match png_enc_layout(width, height, format) {
    Ok(layout) => layout
    Err(error) => return Err(error)
  }
  guard pixels.length() == width * height * bpp else {
    return Err("png: incorrect pixel buffer size")
  }
  let out = png_enc_header(width, height, color, depth)
  apng_put_chunk(out, b"IDAT", png_enc_data(pixels, width * bpp, bpp, height))
  apng_put_chunk(out, b"IEND", [])
  Ok(Bytes::from_array(out))
}

///|
/// Encode full-canvas APNG frames. The first frame is also the default PNG
/// image. Each frame replaces the canvas. A loop count of zero repeats forever.
pub fn av_apng_encode(
  width : Int32,
  height : Int32,
  frames : Array[ApngEncodeFrame],
  format~ : String = "rgba",
  loop_count~ : Int32 = 0,
) -> Result[Bytes, String] {
  let (color, depth, bpp) = match png_enc_layout(width, height, format) {
    Ok(layout) => layout
    Err(error) => return Err(error)
  }
  let frame_bytes = width * height * bpp
  guard !frames.is_empty() &&
    frames.length() <= 10000 &&
    frame_bytes.to_int64() * frames.length().to_int64() <= 64000000L &&
    loop_count >= 0 else {
    return Err("apng: invalid frame count, loop count or pixel budget")
  }
  for frame in frames {
    guard frame.pixels.length() == frame_bytes &&
      frame.delay_num >= 0 &&
      frame.delay_num <= 65535 &&
      frame.delay_den >= 0 &&
      frame.delay_den <= 65535 else {
      return Err("apng: invalid frame buffer or delay")
    }
  }
  let out = png_enc_header(width, height, color, depth)
  let control = []
  apng_put_u32(control, frames.length())
  apng_put_u32(control, loop_count)
  apng_put_chunk(out, b"acTL", control)
  let mut sequence = 0
  for index, frame in frames {
    let control = []
    apng_put_u32(control, sequence)
    sequence += 1
    apng_put_u32(control, width)
    apng_put_u32(control, height)
    apng_put_u32(control, 0)
    apng_put_u32(control, 0)
    control.append([
      (frame.delay_num >> 8).to_byte(),
      frame.delay_num.to_byte(),
      (frame.delay_den >> 8).to_byte(),
      frame.delay_den.to_byte(),
      b'\x00',
      b'\x00',
    ])
    apng_put_chunk(out, b"fcTL", control)
    let compressed = png_enc_data(frame.pixels, width * bpp, bpp, height)
    if index == 0 {
      apng_put_chunk(out, b"IDAT", compressed)
    } else {
      let body = []
      apng_put_u32(body, sequence)
      sequence += 1
      body.append(compressed)
      apng_put_chunk(out, b"fdAT", body)
    }
  }
  apng_put_chunk(out, b"IEND", [])
  Ok(Bytes::from_array(out))
}
