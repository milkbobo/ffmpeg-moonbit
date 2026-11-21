///|
// Baseline JPEG encoder. It shares the zigzag order and standard Huffman
// tables with the decoder. Each output frame is an independent JPEG.
let jpeg_enc_luma_quant : FixedArray[Int32] = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24,
  40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95,
  98, 112, 100, 103, 99,
]

///|
let jpeg_enc_chroma_quant : FixedArray[Int32] = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99,
  99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99,
]

///|
let jpeg_enc_basis : FixedArray[Double] = FixedArray::makei(64, fn(i) {
  let frequency = i / 8
  let coefficient = if frequency == 0 { 0.3535533905932738 } else { 0.5 }
  coefficient *
  @math.cos(
    ((2 * (i % 8) + 1) * frequency).to_double() * 3.141592653589793 / 16.0,
  )
})

///|
fn jpeg_enc_u16(out : Array[Byte], value : Int32) -> Unit {
  out.push((value >> 8).to_byte())
  out.push(value.to_byte())
}

///|
fn jpeg_enc_segment(
  out : Array[Byte],
  marker : Byte,
  payload : Array[Byte],
) -> Unit {
  out.push(b'\xff')
  out.push(marker)
  jpeg_enc_u16(out, payload.length() + 2)
  out.append(payload)
}

///|
fn jpeg_enc_quant(
  base : FixedArray[Int32],
  quality : Int32,
) -> FixedArray[Int32] {
  let scale = if quality < 50 { 5000 / quality } else { 200 - 2 * quality }
  FixedArray::makei(64, i => ((base[i] * scale + 50) / 100).max(1).min(255))
}

///|
fn jpeg_enc_huffman(
  out : Array[Byte],
  table : JpegHuffman,
  selector : Byte,
) -> FixedArray[(Int32, Int32)] {
  out.push(selector)
  let codes = FixedArray::make(256, (0, 0))
  for width in 1..<=16 {
    let count = table.maxcode[width] - table.mincode[width] + 1
    out.push(count.to_byte())
    for i in 0..<count {
      let symbol = table.vals[table.valptr[width] + i]
      codes[symbol] = (table.mincode[width] + i, width)
    }
  }
  for symbol in table.vals {
    out.push(symbol.to_byte())
  }
  codes
}

///|
fn jpeg_enc_value(
  writer : BitWriter,
  table : FixedArray[(Int32, Int32)],
  run : Int32,
  value : Int32,
) -> Unit {
  let mut category = 0
  let mut magnitude = value.abs()
  while magnitude > 0 {
    category += 1
    magnitude = magnitude >> 1
  }
  let (code, length) = table[(run << 4) | category]
  writer.put(code.reinterpret_as_uint(), length)
  if category > 0 {
    let bits = if value < 0 { value + (1 << category) - 1 } else { value }
    writer.put(bits.reinterpret_as_uint(), category)
  }
}

///|
priv struct JpegEncodePlane {
  data : Bytes
  offset : Int32
  width : Int32
  height : Int32
  sampling : Int32
  rgb_component : Int32?
}

///|
fn JpegEncodePlane::pixel(
  self : JpegEncodePlane,
  x : Int32,
  y : Int32,
) -> Double {
  let i = y.min(self.height - 1) * self.width + x.min(self.width - 1)
  let sample = match self.rgb_component {
    None => self.data[self.offset + i].to_int()
    Some(component) => {
      let r = self.data[i * 3].to_int()
      let g = self.data[i * 3 + 1].to_int()
      let b = self.data[i * 3 + 2].to_int()
      match component {
        0 => (19595 * r + 38470 * g + 7471 * b + 32768) >> 16
        1 => ((-11059 * r - 21709 * g + 32768 * b + 32768) >> 16) + 128
        _ => ((32768 * r - 27439 * g - 5329 * b + 32768) >> 16) + 128
      }
    }
  }
  (sample.max(0).min(255) - 128).to_double()
}

///|
fn jpeg_enc_block(
  plane : JpegEncodePlane,
  x : Int32,
  y : Int32,
  quant : FixedArray[Int32],
  samples : FixedArray[Double],
  row : FixedArray[Double],
  levels : FixedArray[Int32],
) -> Unit {
  for yy in 0..<8 {
    for xx in 0..<8 {
      samples[xx] = plane.pixel(x + xx, y + yy)
    }
    for u in 0..<8 {
      let mut sum = 0.0
      for xx in 0..<8 {
        sum += samples[xx] * jpeg_enc_basis[u * 8 + xx]
      }
      row[yy * 8 + u] = sum
    }
  }
  for v in 0..<8 {
    for u in 0..<8 {
      let mut sum = 0.0
      for yy in 0..<8 {
        sum += row[yy * 8 + u] * jpeg_enc_basis[v * 8 + yy]
      }
      let index = v * 8 + u
      let scaled = sum / quant[index].to_double()
      // Restrict amplitudes to the baseline DC/AC categories.
      levels[index] = (if scaled < 0.0 {
          (scaled - 0.5).to_int()
        } else {
          (scaled + 0.5).to_int()
        })
        .max(-1023)
        .min(1023)
    }
  }
}

///|
fn jpeg_enc_scan_block(
  writer : BitWriter,
  levels : FixedArray[Int32],
  dc : FixedArray[(Int32, Int32)],
  ac : FixedArray[(Int32, Int32)],
  previous : Int32,
) -> Int32 {
  jpeg_enc_value(writer, dc, 0, levels[0] - previous)
  let mut zeros = 0
  for k in 1..<64 {
    let level = levels[jpeg_zigzag[k]]
    if level == 0 {
      zeros += 1
      continue
    }
    while zeros >= 16 {
      jpeg_enc_value(writer, ac, 15, 0)
      zeros -= 16
    }
    jpeg_enc_value(writer, ac, zeros, level)
    zeros = 0
  }
  if zeros != 0 {
    jpeg_enc_value(writer, ac, 0, 0)
  }
  levels[0]
}

///|
/// Encode one 8-bit baseline JPEG for use as a still image or MJPEG frame.
/// `gray` and `rgb24` use packed rows. `yuvj420p` and `yuvj444p` use
/// full-range Y, Cb and Cr planes. Odd edges are extended to complete MCUs.
pub fn av_mjpeg_encode(
  width : Int32,
  height : Int32,
  pixels : Bytes,
  format~ : String = "rgb24",
  quality~ : Int32 = 85,
) -> Result[Bytes, String] {
  guard width > 0 &&
    height > 0 &&
    width <= 65535 &&
    height <= 65535 &&
    width.to_int64() * height.to_int64() <= 16000000L &&
    quality >= 1 &&
    quality <= 100 else {
    return Err("mjpeg: invalid dimensions or quality")
  }
  guard format == "gray" ||
    format == "rgb24" ||
    format == "yuvj420p" ||
    format == "yuvj444p" else {
    return Err("mjpeg: unsupported encoder pixel format")
  }
  let gray = format == "gray"
  let sampling = if format == "yuvj420p" { 2 } else { 1 }
  let cw = (width + sampling - 1) / sampling
  let ch = (height + sampling - 1) / sampling
  let luma = width * height
  guard pixels.length() == (if gray { luma } else { luma + 2 * cw * ch }) else {
    return Err("mjpeg: incorrect pixel buffer size")
  }
  let components = if gray { 1 } else { 3 }
  let planes : Array[JpegEncodePlane] = Array::makei(components, fn(i) {
    {
      data: pixels,
      offset: if i == 0 {
        0
      } else {
        luma + (i - 1) * cw * ch
      },
      width: if i == 0 {
        width
      } else {
        cw
      },
      height: if i == 0 {
        height
      } else {
        ch
      },
      sampling: if i == 0 {
        sampling
      } else {
        1
      },
      rgb_component: if format == "rgb24" {
        Some(i)
      } else {
        None
      },
    }
  })
  let out = [b'\xff', b'\xd8']
  jpeg_enc_segment(
    out,
    b'\xe0',
    b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".to_array(),
  )
  let qy = jpeg_enc_quant(jpeg_enc_luma_quant, quality)
  let qc = jpeg_enc_quant(jpeg_enc_chroma_quant, quality)
  let dqt = []
  for table in 0..<(if gray { 1 } else { 2 }) {
    dqt.push(table.to_byte())
    let quant = if table == 0 { qy } else { qc }
    for i in 0..<64 {
      dqt.push(quant[jpeg_zigzag[i]].to_byte())
    }
  }
  jpeg_enc_segment(out, b'\xdb', dqt)
  let sof = [b'\x08']
  jpeg_enc_u16(sof, height)
  jpeg_enc_u16(sof, width)
  sof.push(components.to_byte())
  for i, plane in planes {
    sof.append([
      (i + 1).to_byte(),
      (plane.sampling * 17).to_byte(),
      (if i == 0 { 0 } else { 1 }).to_byte(),
    ])
  }
  jpeg_enc_segment(out, b'\xc0', sof)
  let dht = []
  let dc_y = jpeg_enc_huffman(dht, jpeg_default_huffman(false, false), b'\x00')
  let ac_y = jpeg_enc_huffman(dht, jpeg_default_huffman(true, false), b'\x10')
  let (dc_c, ac_c) = if gray {
    (dc_y, ac_y)
  } else {
    (
      jpeg_enc_huffman(dht, jpeg_default_huffman(false, true), b'\x01'),
      jpeg_enc_huffman(dht, jpeg_default_huffman(true, true), b'\x11'),
    )
  }
  jpeg_enc_segment(out, b'\xc4', dht)
  let sos = [components.to_byte()]
  for i in 0..<components {
    sos.append([(i + 1).to_byte(), if i == 0 { b'\x00' } else { b'\x11' }])
  }
  sos.append([b'\x00', b'\x3f', b'\x00'])
  jpeg_enc_segment(out, b'\xda', sos)
  let writer = BitWriter::new()
  let previous = FixedArray::make(components, 0)
  let samples = FixedArray::make(8, 0.0)
  let row = FixedArray::make(64, 0.0)
  let levels = FixedArray::make(64, 0)
  let mcu_width = 8 * sampling
  for my in 0..<((height + mcu_width - 1) / mcu_width) {
    for mx in 0..<((width + mcu_width - 1) / mcu_width) {
      for i, plane in planes {
        let dc = if i == 0 { dc_y } else { dc_c }
        let ac = if i == 0 { ac_y } else { ac_c }
        for yy in 0..<plane.sampling {
          for xx in 0..<plane.sampling {
            jpeg_enc_block(
              plane,
              (mx * plane.sampling + xx) * 8,
              (my * plane.sampling + yy) * 8,
              if i == 0 {
                qy
              } else {
                qc
              },
              samples,
              row,
              levels,
            )
            previous[i] = jpeg_enc_scan_block(
              writer,
              levels,
              dc,
              ac,
              previous[i],
            )
          }
        }
      }
    }
  }
  while writer.nbits != 0 {
    writer.put_bit(1)
  }
  for byte in writer.buf {
    out.push(byte)
    if byte == b'\xff' {
      out.push(b'\x00')
    }
  }
  out.append([b'\xff', b'\xd9'])
  Ok(Bytes::from_array(out))
}
