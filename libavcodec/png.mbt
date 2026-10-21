///|
/// MoonBit port of the FFmpeg 9.0.2 PNG decoder slice:
/// `libavcodec/pngdec.c` (signature/IHDR/PLTE/tRNS/IDAT handling, row
/// unfiltering, pass packing) and the native pixel-format selection at
/// `pngdec.c:914`, backed by the in-tree `inflate_zlib`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Output is the same native pixel format FFmpeg selects, so decoded bytes can
/// be compared byte-for-byte with `ffmpeg -f rawvideo -pix_fmt <native>`:
/// gray/16, monob, pal8 (indices + 256-entry RGBA palette), rgb24/48be,
/// rgba/64be, ya8/16be, with tRNS promoted to the alpha formats.
///
/// Out of scope: gamma/ICC/sRGB processing. Chunk CRCs are skipped by
/// `av_png_decode` (matching FFmpeg's default `err_recognition` of zero) and
/// can be enforced with `av_png_decode_ex(data, true)`. Adam7 interlacing and
/// 1/2/4/8/16-bit samples are supported; 2/4-bit grayscale is expanded to 8-bit
/// by bit replication. APNG animation is decoded by `av_apng_decode`.

///|
pub struct PngImage {
  width : Int32
  height : Int32
  bit_depth : Int32
  color_type : Int32
  /// FFmpeg native pixel-format name.
  pix_fmt : String
  /// One row in bytes (native packing for monob/pal8).
  stride : Int32
  pixels : Bytes
  /// RGBA palette for `pal8`, otherwise empty.
  palette : Bytes
}

///|
fn png_u32(data : BytesView, off : Int32) -> Int32 {
  if off + 4 > data.length() {
    0
  } else {
    (data[off].to_int() << 24) |
    (data[off + 1].to_int() << 16) |
    (data[off + 2].to_int() << 8) |
    data[off + 3].to_int()
  }
}

///|
fn png_u16(data : BytesView, off : Int32) -> Int32 {
  if off + 2 > data.length() {
    0
  } else {
    (data[off].to_int() << 8) | data[off + 1].to_int()
  }
}

///|
/// CRC-32 computed over a complete PNG chunk type-and-data range, i.e. the
/// value stored in the chunk's trailing CRC field. FFmpeg uses
/// `~av_crc(AV_CRC_32_IEEE_LE, UINT32_MAX, ...)`.
fn png_crc32(data : Bytes) -> Int32 {
  let table = @libavutil.av_crc_init(true, 32, 0xEDB88320).unwrap()
  @libavutil.av_crc(table, 0xFFFFFFFFU, data).reinterpret_as_int() ^ -1
}

///|
fn png_channels(color_type : Int32) -> Int32 {
  match color_type {
    0 => 1
    2 => 3
    3 => 1
    4 => 2
    6 => 4
    _ => 0
  }
}

///|
/// `png_handle_row` filters 0..4 over raw bytes (bpp is at least 1). */
fn png_unfilter_row(
  filter : Int32,
  cur : Array[Byte],
  prev : Array[Byte],
  bpp : Int32,
  rowbytes : Int32,
) -> Unit {
  for x in 0..<rowbytes {
    let a = if x >= bpp { cur[x - bpp].to_int() } else { 0 }
    let b = prev[x].to_int()
    let c = if x >= bpp { prev[x - bpp].to_int() } else { 0 }
    let predictor = match filter {
      0 => 0
      1 => a
      2 => b
      3 => (a + b) / 2
      4 => {
        let p = a + b - c
        let pa = (p - a).abs()
        let pb = (p - b).abs()
        let pc = (p - c).abs()
        if pa <= pb && pa <= pc {
          a
        } else if pb <= pc {
          b
        } else {
          c
        }
      }
      _ => 0
    }
    cur[x] = ((cur[x].to_int() + predictor) & 0xFF).to_byte()
  }
}

///|
/// Copy one unfiltered row into a fresh array. */
fn png_row(rows : Array[Byte], y : Int32, rowbytes : Int32) -> Array[Byte] {
  let row : Array[Byte] = []
  for x in 0..<rowbytes {
    row.push(rows[y * rowbytes + x])
  }
  row
}

///|
/// Adam7 pass geometry: (x_start, y_start, x_step, y_step, width, height). */
fn png_pass_geometry(
  pass : Int32,
  width : Int32,
  height : Int32,
) -> (Int32, Int32, Int32, Int32, Int32, Int32) {
  let (xs, ys, xstep, ystep) = match pass {
    0 => (0, 0, 8, 8)
    1 => (4, 0, 8, 8)
    2 => (0, 4, 4, 8)
    3 => (2, 0, 4, 4)
    4 => (0, 2, 2, 4)
    5 => (1, 0, 2, 2)
    _ => (0, 1, 1, 2)
  }
  let pw = if width > xs { (width - xs + xstep - 1) / xstep } else { 0 }
  let ph = if height > ys { (height - ys + ystep - 1) / ystep } else { 0 }
  (xs, ys, xstep, ystep, pw, ph)
}

///|
/// Write a packed sample (bit depth 1/2/4) into a scanline. */
fn png_set_sample(
  row : Array[Byte],
  base : Int32,
  index : Int32,
  depth : Int32,
  value : Int32,
) -> Unit {
  let bit = index * depth
  let shift = 8 - depth - bit % 8
  let mask = (1 << depth) - 1
  let old = row[base + bit / 8].to_int()
  row[base + bit / 8] = ((old & (0xFF ^ (mask << shift))) |
  ((value & mask) << shift)).to_byte()
}

///|
/// Read a packed sample (bit depth 2/4/8) from a scanline. */
fn png_sample(row : Array[Byte], index : Int32, depth : Int32) -> Int32 {
  if depth == 8 {
    return row[index].to_int()
  }
  let bit = index * depth
  let shift = 8 - depth - bit % 8
  (row[bit / 8].to_int() >> shift) & ((1 << depth) - 1)
}

///|
fn png_expand_sample(v : Int32, depth : Int32) -> Int32 {
  if depth == 8 {
    v
  } else if depth == 4 {
    v * 0x11
  } else if depth == 2 {
    v * 0x55
  } else if depth == 1 {
    if v != 0 {
      255
    } else {
      0
    }
  } else {
    v
  }
}

///|
/// Decode an in-memory PNG, skipping chunk CRC validation. */
pub fn av_png_decode(data : Bytes) -> Result[PngImage, String] {
  av_png_decode_ex(data, false)
}

///|
/// Decode an in-memory PNG. When `verify_crc` is true, every chunk CRC is
/// checked before the chunk is parsed. A mismatch is fatal, matching
/// `-err_detect crccheck+explode` rather than FFmpeg's default non-fatal path.
pub fn av_png_decode_ex(
  data : Bytes,
  verify_crc : Bool,
) -> Result[PngImage, String] {
  let signature : Bytes = b"\x89PNG\r\n\x1a\n"
  if data.length() < 8 {
    return Err("png: file too short")
  }
  for i in 0..<8 {
    if data[i] != signature[i] {
      return Err("png: bad signature")
    }
  }
  let mut pos = 8
  let mut width = 0
  let mut height = 0
  let mut bit_depth = 0
  let mut color_type = -1
  let mut interlace = 0
  let mut palette_plte : Array[Byte] = []
  let mut trns : Array[Byte] = []
  let idat : Array[Byte] = []
  let mut saw_ihdr = false
  let mut saw_iend = false
  while pos + 12 <= data.length() {
    let length = png_u32(data, pos)
    let kind = {
      let sb = StringBuilder()
      for i in 0..<4 {
        sb.write_char(data[pos + 4 + i].to_int().unsafe_to_char())
      }
      sb.to_string()
    }
    if length < 0 || pos + 12 + length > data.length() {
      return Err("png: truncated chunk \{kind}")
    }
    if verify_crc {
      let expected = png_u32(data, pos + 8 + length)
      let actual = png_crc32(data[pos + 4:pos + 8 + length].to_owned())
      if expected != actual {
        return Err("png: CRC mismatch in chunk \{kind}")
      }
    }
    let body = pos + 8
    if kind == "IHDR" {
      if length < 13 {
        return Err("png: short IHDR")
      }
      width = png_u32(data, body)
      height = png_u32(data, body + 4)
      bit_depth = data[body + 8].to_int()
      color_type = data[body + 9].to_int()
      let compression = data[body + 10].to_int()
      let filter = data[body + 11].to_int()
      interlace = data[body + 12].to_int()
      if width <= 0 || height <= 0 || width > 65536 || height > 65536 {
        return Err("png: invalid dimensions")
      }
      let depth_ok = bit_depth == 1 ||
        bit_depth == 2 ||
        bit_depth == 4 ||
        bit_depth == 8 ||
        bit_depth == 16
      if !depth_ok {
        return Err("png: invalid bit depth")
      }
      if color_type != 0 &&
        color_type != 2 &&
        color_type != 3 &&
        color_type != 4 &&
        color_type != 6 {
        return Err("png: invalid color type")
      }
      if compression != 0 || filter != 0 {
        return Err("png: unsupported compression/filter method")
      }
      if interlace != 0 && interlace != 1 {
        return Err("png: invalid interlace method")
      }
      saw_ihdr = true
    } else if kind == "PLTE" {
      if length % 3 != 0 || length > 768 {
        return Err("png: invalid PLTE")
      }
      palette_plte = []
      for i in 0..<length {
        palette_plte.push(data[body + i])
      }
    } else if kind == "tRNS" {
      trns = []
      for i in 0..<length {
        trns.push(data[body + i])
      }
    } else if kind == "IDAT" {
      for i in 0..<length {
        idat.push(data[body + i])
      }
    } else if kind == "IEND" {
      saw_iend = true
      break
    }
    pos = pos + 12 + length
  }
  if !saw_ihdr {
    return Err("png: missing IHDR")
  }
  if !saw_iend {
    return Err("png: missing IEND")
  }
  if color_type == 3 && palette_plte.length() == 0 {
    return Err("png: palette PNG without PLTE")
  }
  let channels = png_channels(color_type)
  let bits_per_pixel = channels * bit_depth
  let rowbytes = (width * bits_per_pixel + 7) / 8
  let bpp = if bits_per_pixel >= 8 { bits_per_pixel / 8 } else { 1 }
  let expected = if interlace == 0 {
    (rowbytes + 1) * height
  } else {
    let mut total = 0
    for pass in 0..<7 {
      let (_, _, _, _, pw, ph) = png_pass_geometry(pass, width, height)
      if pw > 0 && ph > 0 {
        total = total + ((pw * bits_per_pixel + 7) / 8 + 1) * ph
      }
    }
    total
  }
  if idat.length() == 0 {
    return Err("png: no IDAT")
  }
  let inflated = match inflate_zlib(Bytes::from_array(idat[:]), expected + 16) {
    Ok(b) => b
    Err(e) => return Err("png: \{e}")
  }
  if inflated.length() < expected {
    return Err("png: not enough image data")
  }
  // Unfilter into contiguous rows (mutable byte array).
  let rows : Array[Byte] = []
  for _ in 0..<(rowbytes * height) {
    rows.push(b'\x00')
  }
  if interlace == 0 {
    let zero_row = Bytes::make(rowbytes, b'\x00')
    for y in 0..<height {
      let src_off = y * (rowbytes + 1)
      let filter = inflated[src_off].to_int()
      if filter < 0 || filter > 4 {
        return Err("png: invalid filter type")
      }
      let cur : Array[Byte] = []
      for x in 0..<rowbytes {
        cur.push(inflated[src_off + 1 + x])
      }
      let prev : Array[Byte] = []
      if y == 0 {
        for x in 0..<rowbytes {
          prev.push(zero_row[x])
        }
      } else {
        let base = (y - 1) * rowbytes
        for x in 0..<rowbytes {
          prev.push(rows[base + x])
        }
      }
      png_unfilter_row(filter, cur, prev, bpp, rowbytes)
      for x in 0..<rowbytes {
        rows[y * rowbytes + x] = cur[x]
      }
    }
  } else {
    let mut off = 0
    for pass in 0..<7 {
      let (xs, ys, xstep, ystep, pw, ph) = png_pass_geometry(
        pass, width, height,
      )
      if pw <= 0 || ph <= 0 {
        continue
      }
      let prb = (pw * bits_per_pixel + 7) / 8
      let prev : Array[Byte] = []
      for _ in 0..<prb {
        prev.push(b'\x00')
      }
      for py in 0..<ph {
        let filter = inflated[off].to_int()
        if filter < 0 || filter > 4 {
          return Err("png: invalid filter type")
        }
        let cur : Array[Byte] = []
        for x in 0..<prb {
          cur.push(inflated[off + 1 + x])
        }
        png_unfilter_row(filter, cur, prev, bpp, prb)
        for px in 0..<pw {
          let x = xs + px * xstep
          let y = ys + py * ystep
          if bit_depth == 8 {
            for c in 0..<channels {
              rows[y * rowbytes + x * channels + c] = cur[px * channels + c]
            }
          } else if bit_depth == 16 {
            for c in 0..<(channels * 2) {
              rows[y * rowbytes + x * channels * 2 + c] = cur[px * channels * 2 +
                c]
            }
          } else {
            png_set_sample(
              rows,
              y * rowbytes,
              x,
              bit_depth,
              png_sample(cur, px, bit_depth),
            )
          }
        }
        for x in 0..<prb {
          prev[x] = cur[x]
        }
        off = off + prb + 1
      }
    }
  }
  // Expand into FFmpeg's native pixel format.
  let rows_b = Bytes::from_array(rows[:])
  let output : Array[Byte] = []
  let mut pix_fmt = ""
  let mut stride = rowbytes
  let has_trns = trns.length() > 0
  let trns_b = Bytes::from_array(trns[:])
  if color_type == 3 {
    pix_fmt = "pal8"
    stride = width
    for y in 0..<height {
      for x in 0..<width {
        output.push(
          png_sample(png_row(rows, y, rowbytes), x, bit_depth).to_byte(),
        )
      }
    }
  } else if color_type == 0 {
    let transparent = if has_trns && trns.length() >= 2 {
      png_u16(trns_b, 0) & ((1 << bit_depth) - 1)
    } else {
      -1
    }
    if has_trns {
      if bit_depth == 16 {
        pix_fmt = "ya16be"
        stride = width * 4
        for y in 0..<height {
          for x in 0..<width {
            let v = png_u16(rows_b, y * rowbytes + x * 2)
            output.push(((v >> 8) & 0xFF).to_byte())
            output.push((v & 0xFF).to_byte())
            let a = if v == transparent { 0 } else { 0xFFFF }
            output.push(((a >> 8) & 0xFF).to_byte())
            output.push((a & 0xFF).to_byte())
          }
        }
      } else {
        pix_fmt = "ya8"
        stride = width * 2
        for y in 0..<height {
          let row = png_row(rows, y, rowbytes)
          for x in 0..<width {
            let v = png_expand_sample(png_sample(row, x, bit_depth), bit_depth)
            let raw = png_sample(row, x, bit_depth)
            output.push(v.to_byte())
            output.push((if raw == transparent { 0 } else { 255 }).to_byte())
          }
        }
      }
    } else if bit_depth == 1 {
      pix_fmt = "monob"
      stride = rowbytes
      for y in 0..<height {
        for x in 0..<rowbytes {
          output.push(rows[y * rowbytes + x])
        }
      }
    } else if bit_depth == 16 {
      pix_fmt = "gray16be"
      stride = width * 2
      for y in 0..<height {
        for x in 0..<(width * 2) {
          output.push(rows[y * rowbytes + x])
        }
      }
    } else {
      pix_fmt = "gray"
      stride = width
      for y in 0..<height {
        let row = png_row(rows, y, rowbytes)
        for x in 0..<width {
          output.push(
            png_expand_sample(png_sample(row, x, bit_depth), bit_depth).to_byte(),
          )
        }
      }
    }
  } else if color_type == 2 {
    if has_trns && trns.length() >= 6 {
      let tr = png_u16(trns_b, 0) & ((1 << bit_depth) - 1)
      let tg = png_u16(trns_b, 2) & ((1 << bit_depth) - 1)
      let tb = png_u16(trns_b, 4) & ((1 << bit_depth) - 1)
      if bit_depth == 16 {
        pix_fmt = "rgba64be"
        stride = width * 8
        for y in 0..<height {
          for x in 0..<width {
            let base = y * rowbytes + x * 6
            let r = png_u16(rows_b, base)
            let g = png_u16(rows_b, base + 2)
            let b = png_u16(rows_b, base + 4)
            output.push(((r >> 8) & 0xFF).to_byte())
            output.push((r & 0xFF).to_byte())
            output.push(((g >> 8) & 0xFF).to_byte())
            output.push((g & 0xFF).to_byte())
            output.push(((b >> 8) & 0xFF).to_byte())
            output.push((b & 0xFF).to_byte())
            let a = if r == tr && g == tg && b == tb { 0 } else { 0xFFFF }
            output.push(((a >> 8) & 0xFF).to_byte())
            output.push((a & 0xFF).to_byte())
          }
        }
      } else {
        pix_fmt = "rgba"
        stride = width * 4
        for y in 0..<height {
          for x in 0..<width {
            let base = y * rowbytes + x * 3
            let r = rows[base].to_int()
            let g = rows[base + 1].to_int()
            let b = rows[base + 2].to_int()
            output.push(r.to_byte())
            output.push(g.to_byte())
            output.push(b.to_byte())
            output.push(
              (if r == tr && g == tg && b == tb { 0 } else { 255 }).to_byte(),
            )
          }
        }
      }
    } else {
      pix_fmt = if bit_depth == 16 { "rgb48be" } else { "rgb24" }
      stride = width * png_channels(color_type) * (bit_depth / 8)
      for y in 0..<height {
        for x in 0..<rowbytes {
          output.push(rows[y * rowbytes + x])
        }
      }
    }
  } else if color_type == 6 {
    pix_fmt = if bit_depth == 16 { "rgba64be" } else { "rgba" }
    stride = width * 4 * (bit_depth / 8)
    for y in 0..<height {
      for x in 0..<rowbytes {
        output.push(rows[y * rowbytes + x])
      }
    }
  } else if color_type == 4 {
    pix_fmt = if bit_depth == 16 { "ya16be" } else { "ya8" }
    stride = width * 2 * (bit_depth / 8)
    for y in 0..<height {
      for x in 0..<rowbytes {
        output.push(rows[y * rowbytes + x])
      }
    }
  } else {
    return Err("png: unsupported color type")
  }
  // Palette: PLTE + optional tRNS, padded to 256 RGBA entries.
  let palette : Array[Byte] = []
  if color_type == 3 {
    let entries = palette_plte.length() / 3
    for i in 0..<256 {
      if i < entries {
        palette.push(palette_plte[i * 3])
        palette.push(palette_plte[i * 3 + 1])
        palette.push(palette_plte[i * 3 + 2])
        palette.push(if i < trns.length() { trns[i] } else { b'\xff' })
      } else {
        palette.push(b'\x00')
        palette.push(b'\x00')
        palette.push(b'\x00')
        palette.push(b'\x00')
      }
    }
  }
  Ok({
    width,
    height,
    bit_depth,
    color_type,
    pix_fmt,
    stride,
    pixels: Bytes::from_array(output[:]),
    palette: Bytes::from_array(palette[:]),
  })
}
