///|
/// MoonBit port of the FFmpeg 9.0.2 baseline JPEG/MJPEG decoder slice:
/// `libavcodec/mjpegdec.c` (`ff_mjpeg_decode_sof`, `ff_mjpeg_decode_dqt`,
/// `ff_mjpeg_decode_dht`, `ff_mjpeg_decode_sos`, `decode_block`,
/// `mjpeg_decode_scan`), using the existing Simple-C IDCT
/// (`ff_simple_idct_put_int16_8bit`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: 8-bit sequential DCT (SOF0/SOF1), interleaved and single-component
/// scans, arbitrary 1..4 h/v sampling, DQT (8/16-bit entries), DHT, DRI restart
/// markers and the native `yuvj420p`/`yuvj422p`/`yuvj444p`/`yuvj440p`/`gray`
/// output formats FFmpeg selects. Planes are cropped to the visible size.
///
/// Out of scope: progressive JPEG (SOF2), arithmetic coding, lossless JPEG
/// (SOF3), 12-bit samples, CMYK/YCCK (4 components), Adobe APP14 transforms,
/// and EXIF orientation.

///|
pub struct JpegImage {
  width : Int32
  height : Int32
  pix_fmt : String
  /// Planar samples: Y (or gray), Cb, Cr; each cropped to its visible size.
  planes : Array[Bytes]
  /// Visible width of each plane.
  plane_widths : Array[Int32]
  /// Visible height of each plane.
  plane_heights : Array[Int32]
}

///|
let jpeg_zigzag : FixedArray[Int32] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
  23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62,
  63,
]

///|
fn jpeg_be16(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}

///|
priv struct JpegHuffman {
  mincode : Array[Int32]
  maxcode : Array[Int32]
  valptr : Array[Int32]
  vals : Array[Int32]
}

///|
fn jpeg_huffman_build(
  counts : Array[Int32],
  vals : Array[Int32],
) -> JpegHuffman {
  let mincode : Array[Int32] = []
  let maxcode : Array[Int32] = []
  let valptr : Array[Int32] = []
  for _ in 0..<17 {
    mincode.push(0)
    maxcode.push(-1)
    valptr.push(0)
  }
  let mut code = 0
  let mut k = 0
  for len in 1..<=16 {
    let count = counts[len - 1]
    valptr[len] = k
    mincode[len] = code
    code = code + count
    k = k + count
    maxcode[len] = code - 1
    code = code * 2
  }
  { mincode, maxcode, valptr, vals, }
}

///|
fn jpeg_huffman_decode(
  bits : JpegEntropy,
  h : JpegHuffman,
) -> Result[Int32, String] {
  let mut code = 0
  for len in 1..<=16 {
    let bit = je_read(bits, 1)
    if bits.at_end {
      return Err("mjpeg: truncated Huffman code")
    }
    code = (code << 1) | bit
    if h.maxcode[len] >= 0 && code <= h.maxcode[len] {
      let index = h.valptr[len] + code - h.mincode[len]
      if index < 0 || index >= h.vals.length() {
        return Err("mjpeg: Huffman index out of range")
      }
      return Ok(h.vals[index])
    }
  }
  Err("mjpeg: invalid Huffman code")
}

///|
/// Entropy-coded segment reader with 0xFF00 destuffing and marker detection. */
priv struct JpegEntropy {
  data : Bytes
  mut pos : Int32
  mut buffer : Int32
  mut count : Int32
  mut at_end : Bool
}

///|
fn je_byte(bits : JpegEntropy) -> Int32 {
  if bits.pos >= bits.data.length() {
    bits.at_end = true
    return 0
  }
  let b = bits.data[bits.pos].to_int()
  bits.pos = bits.pos + 1
  if b != 0xFF {
    return b
  }
  while bits.pos < bits.data.length() && bits.data[bits.pos].to_int() == 0xFF {
    bits.pos = bits.pos + 1
  }
  if bits.pos >= bits.data.length() {
    bits.at_end = true
    return 0
  }
  let m = bits.data[bits.pos].to_int()
  if m == 0x00 {
    bits.pos = bits.pos + 1
    return 0xFF
  }
  bits.at_end = true
  return 0
}

///|
fn je_read(bits : JpegEntropy, n : Int32) -> Int32 {
  while bits.count < n {
    bits.buffer = (bits.buffer << 8) | je_byte(bits)
    bits.count = bits.count + 8
  }
  bits.count = bits.count - n
  (bits.buffer >> bits.count) & ((1 << n) - 1)
}

///|
fn je_align(bits : JpegEntropy) -> Unit {
  bits.buffer = 0
  bits.count = 0
}

///|
fn je_restart(bits : JpegEntropy) -> Unit {
  je_align(bits)
  bits.at_end = false
  if bits.pos + 1 < bits.data.length() && bits.data[bits.pos].to_int() == 0xFF {
    while bits.pos < bits.data.length() && bits.data[bits.pos].to_int() == 0xFF {
      bits.pos = bits.pos + 1
    }
    if bits.pos < bits.data.length() {
      let m = bits.data[bits.pos].to_int()
      if m >= 0xD0 && m <= 0xD7 {
        bits.pos = bits.pos + 1
      }
    }
  }
}

///|
/// `decode_block`: baseline DC + AC with dequantization into natural order. */
fn jpeg_decode_block(
  bits : JpegEntropy,
  block : Array[Int32],
  comp : JpegComponent,
  quant : Array[Int32],
  dc : JpegHuffman,
  ac : JpegHuffman,
) -> Result[Unit, String] {
  for i in 0..<64 {
    block[i] = 0
  }
  let category = match jpeg_huffman_decode(bits, dc) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if category > 11 {
    return Err("mjpeg: invalid DC category")
  }
  let mut diff = je_read(bits, category)
  if category > 0 && diff < 1 << (category - 1) {
    diff = diff - (1 << category) + 1
  }
  let dc = diff * quant[0] + comp.dc_pred
  comp.dc_pred = dc
  block[0] = jpeg_i16(dc)
  let mut k = 1
  while k < 64 {
    let rs = match jpeg_huffman_decode(bits, ac) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let run = rs >> 4
    let size = rs & 0x0F
    if size == 0 {
      if run == 15 {
        k = k + 16
        continue
      }
      break
    }
    k = k + run
    if k >= 64 {
      return Err("mjpeg: AC index out of range")
    }
    let mut level = je_read(bits, size)
    if level < 1 << (size - 1) {
      level = level - (1 << size) + 1
    }
    let natural = jpeg_zigzag[k]
    block[natural] = jpeg_i16(level * quant[k])
    k = k + 1
  }
  Ok(())
}

///|
/// `int16_t` store truncation (the C assigns the products into `int16_t`). */
fn jpeg_i16(v : Int32) -> Int32 {
  v << 16 >> 16
}

///|
/// `idct_put` at an (x, y) block offset: the ported Simple-C IDCT writes at
/// the origin, so transform into a scratch 8x8 and copy into the plane. */
fn mjpeg_idct_put(
  dest : Array[Int32],
  stride : Int32,
  block : Array[Int32],
  x : Int32,
  y : Int32,
) -> Unit {
  let tmp : Array[Int32] = []
  for _ in 0..<64 {
    tmp.push(0)
  }
  ff_simple_idct_put_int16_8bit(tmp, 8, block)
  for r in 0..<8 {
    for c in 0..<8 {
      dest[(y + r) * stride + x + c] = tmp[r * 8 + c]
    }
  }
}

///|
priv struct JpegComponent {
  id : Int32
  h : Int32
  v : Int32
  tq : Int32
  mut dc_table : Int32
  mut ac_table : Int32
  mut dc_pred : Int32
}

///|
/// Decode an 8-bit baseline JPEG. */
pub fn av_mjpeg_decode(data : Bytes) -> Result[JpegImage, String] {
  if data.length() < 4 || data[0] != b'\xff' || data[1] != b'\xd8' {
    return Err("mjpeg: missing SOI")
  }
  let quant : Array[Array[Int32]] = [[], [], [], []]
  let dc_tables : Array[JpegHuffman?] = [None, None, None, None]
  let ac_tables : Array[JpegHuffman?] = [None, None, None, None]
  let components : Array[JpegComponent] = []
  let mut width = 0
  let mut height = 0
  let mut max_h = 1
  let mut max_v = 1
  let mut restart_interval = 0
  let mut saw_sof = false
  let mut pos = 2
  while pos + 1 < data.length() {
    if data[pos] != b'\xff' {
      return Err("mjpeg: expected marker")
    }
    while pos < data.length() && data[pos] == b'\xff' {
      pos = pos + 1
    }
    if pos >= data.length() {
      break
    }
    let marker = data[pos].to_int()
    pos = pos + 1
    if marker == 0xD9 {
      break
    }
    if marker >= 0xD0 && marker <= 0xD7 {
      continue
    }
    if marker == 0x01 {
      continue
    }
    if pos + 2 > data.length() {
      return Err("mjpeg: truncated segment")
    }
    let seg_len = jpeg_be16(data, pos)
    if seg_len < 2 || pos + seg_len > data.length() {
      return Err("mjpeg: invalid segment length")
    }
    let seg = data[pos + 2:pos + seg_len]
    pos = pos + seg_len
    if marker == 0xDB {
      // DQT
      let mut p = 0
      while p < seg.length() {
        let pq_tq = seg[p].to_int()
        p = p + 1
        let pq = pq_tq >> 4
        let tq = pq_tq & 0x0F
        if tq > 3 {
          return Err("mjpeg: invalid quant table id")
        }
        if pq == 0 && p + 64 > seg.length() {
          return Err("mjpeg: truncated DQT")
        }
        if pq == 1 && p + 128 > seg.length() {
          return Err("mjpeg: truncated DQT")
        }
        let table : Array[Int32] = []
        for _ in 0..<64 {
          if pq == 0 {
            table.push(seg[p].to_int())
            p = p + 1
          } else {
            table.push(jpeg_be16(seg, p))
            p = p + 2
          }
        }
        quant[tq] = table
      }
    } else if marker == 0xC4 {
      // DHT
      let mut p = 0
      while p < seg.length() {
        if p + 17 > seg.length() {
          return Err("mjpeg: truncated DHT")
        }
        let tc_th = seg[p].to_int()
        p = p + 1
        let tc = tc_th >> 4
        let th = tc_th & 0x0F
        if th > 3 || tc > 1 {
          return Err("mjpeg: invalid Huffman table id")
        }
        let counts : Array[Int32] = []
        let mut total = 0
        for i in 0..<16 {
          let c = seg[p + i].to_int()
          counts.push(c)
          total = total + c
        }
        p = p + 16
        if p + total > seg.length() {
          return Err("mjpeg: truncated DHT values")
        }
        let vals : Array[Int32] = []
        for i in 0..<total {
          vals.push(seg[p + i].to_int())
        }
        p = p + total
        let h = jpeg_huffman_build(counts, vals)
        if tc == 0 {
          dc_tables[th] = Some(h)
        } else {
          ac_tables[th] = Some(h)
        }
      }
    } else if marker == 0xC0 || marker == 0xC1 {
      // SOF0/SOF1
      if seg.length() < 6 {
        return Err("mjpeg: short SOF")
      }
      let precision = seg[0].to_int()
      if precision != 8 {
        return Err("PATCHWELCOME: mjpeg sample precision")
      }
      height = jpeg_be16(seg, 1)
      width = jpeg_be16(seg, 3)
      let ncomp = seg[5].to_int()
      if width <= 0 || height <= 0 || ncomp < 1 || ncomp > 4 {
        return Err("mjpeg: invalid frame header")
      }
      if seg.length() < 6 + ncomp * 3 {
        return Err("mjpeg: truncated SOF components")
      }
      for i in 0..<ncomp {
        let base = 6 + i * 3
        let id = seg[base].to_int()
        let hv = seg[base + 1].to_int()
        let h = hv >> 4
        let v = hv & 0x0F
        if h < 1 || h > 4 || v < 1 || v > 4 {
          return Err("mjpeg: invalid sampling factor")
        }
        if h > max_h {
          max_h = h
        }
        if v > max_v {
          max_v = v
        }
        components.push({
          id,
          h,
          v,
          tq: seg[base + 2].to_int(),
          dc_table: 0,
          ac_table: 0,
          dc_pred: 4 << 8,
        })
      }
      saw_sof = true
    } else if marker == 0xDD {
      if seg.length() >= 2 {
        restart_interval = jpeg_be16(seg, 0)
      }
    } else if marker == 0xDA {
      if !saw_sof {
        return Err("mjpeg: SOS before SOF")
      }
      let ns = seg[0].to_int()
      if ns < 1 || ns > components.length() || seg.length() < 1 + ns * 2 + 3 {
        return Err("mjpeg: invalid scan header")
      }
      let scan_components : Array[Int32] = []
      for i in 0..<ns {
        let cid = seg[1 + i * 2].to_int()
        let tables = seg[2 + i * 2].to_int()
        let mut found = -1
        for c in 0..<components.length() {
          if components[c].id == cid {
            found = c
          }
        }
        if found < 0 {
          return Err("mjpeg: unknown scan component")
        }
        components[found].dc_table = tables >> 4
        components[found].ac_table = tables & 0x0F
        scan_components.push(found)
      }
      let ss = seg[1 + ns * 2].to_int()
      if ss != 0 {
        return Err("PATCHWELCOME: progressive JPEG scan")
      }
      // Allocate padded planes.
      let mcu_w = max_h * 8
      let mcu_h = max_v * 8
      let mcu_cols = (width + mcu_w - 1) / mcu_w
      let mcu_rows = (height + mcu_h - 1) / mcu_h
      let strides : Array[Int32] = []
      let plane_h : Array[Int32] = []
      let planes : Array[Array[Int32]] = []
      for comp in components {
        let stride = mcu_cols * comp.h * 8
        let ph = mcu_rows * comp.v * 8
        strides.push(stride)
        plane_h.push(ph)
        let p : Array[Int32] = []
        for _ in 0..<(stride * ph) {
          p.push(0)
        }
        planes.push(p)
      }
      let bits : JpegEntropy = {
        data,
        pos,
        buffer: 0,
        count: 0,
        at_end: false,
      }
      if ns == 1 {
        let ci = scan_components[0]
        let comp = components[ci]
        let qt = if comp.tq >= 0 && comp.tq < 4 { quant[comp.tq] } else { [] }
        if qt.length() < 64 {
          return Err("mjpeg: missing quant table")
        }
        let dct = match dc_tables[comp.dc_table] {
          Some(h) => h
          None => return Err("mjpeg: missing DC Huffman table")
        }
        let act = match ac_tables[comp.ac_table] {
          Some(h) => h
          None => return Err("mjpeg: missing AC Huffman table")
        }
        let cw = (width * comp.h + max_h - 1) / max_h
        let ch = (height * comp.v + max_v - 1) / max_v
        let bw = (cw + 7) / 8
        let bh = (ch + 7) / 8
        let total = bw * bh
        let mut index = 0
        let mut by = 0
        while by < bh && !bits.at_end {
          let mut bx = 0
          while bx < bw && !bits.at_end {
            let block : Array[Int32] = []
            for _ in 0..<64 {
              block.push(0)
            }
            match jpeg_decode_block(bits, block, comp, qt, dct, act) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
            mjpeg_idct_put(planes[ci], strides[ci], block, bx * 8, by * 8)
            index = index + 1
            bx = bx + 1
            if restart_interval > 0 &&
              index % restart_interval == 0 &&
              index < total {
              je_restart(bits)
              comp.dc_pred = 4 << 8
            }
          }
          by = by + 1
        }
      } else {
        let mcu_cols = (width + mcu_w - 1) / mcu_w
        let mcu_rows = (height + mcu_h - 1) / mcu_h
        let total = mcu_cols * mcu_rows
        let mut mcu_index = 0
        let mut mcu_y = 0
        while mcu_y < mcu_rows && !bits.at_end {
          let mut mcu_x = 0
          while mcu_x < mcu_cols && !bits.at_end {
            for ci in scan_components {
              let comp = components[ci]
              let qt = if comp.tq >= 0 && comp.tq < 4 {
                quant[comp.tq]
              } else {
                []
              }
              if qt.length() < 64 {
                return Err("mjpeg: missing quant table")
              }
              let dct = match dc_tables[comp.dc_table] {
                Some(h) => h
                None => return Err("mjpeg: missing DC Huffman table")
              }
              let act = match ac_tables[comp.ac_table] {
                Some(h) => h
                None => return Err("mjpeg: missing AC Huffman table")
              }
              for by in 0..<comp.v {
                for bx in 0..<comp.h {
                  let block : Array[Int32] = []
                  for _ in 0..<64 {
                    block.push(0)
                  }
                  match jpeg_decode_block(bits, block, comp, qt, dct, act) {
                    Ok(_) => ()
                    Err(e) => return Err(e)
                  }
                  mjpeg_idct_put(
                    planes[ci],
                    strides[ci],
                    block,
                    (mcu_x * comp.h + bx) * 8,
                    (mcu_y * comp.v + by) * 8,
                  )
                }
              }
            }
            mcu_index = mcu_index + 1
            mcu_x = mcu_x + 1
            if restart_interval > 0 &&
              mcu_index % restart_interval == 0 &&
              mcu_index < total {
              je_restart(bits)
              for comp in components {
                comp.dc_pred = 4 << 8
              }
            }
          }
          mcu_y = mcu_y + 1
        }
      }
      // Crop padded planes to visible dimensions and choose the pixel format.
      let out_planes : Array[Bytes] = []
      let plane_widths : Array[Int32] = []
      let plane_heights : Array[Int32] = []
      for ci in 0..<components.length() {
        let comp = components[ci]
        let pw = (width * comp.h + max_h - 1) / max_h
        let ph = (height * comp.v + max_v - 1) / max_v
        plane_widths.push(pw)
        plane_heights.push(ph)
        let out : Array[Byte] = []
        for y in 0..<ph {
          for x in 0..<pw {
            out.push(planes[ci][y * strides[ci] + x].to_byte())
          }
        }
        out_planes.push(Bytes::from_array(out[:]))
      }
      let pix_fmt = if components.length() == 1 {
        "gray"
      } else if plane_widths[1] >= width && plane_heights[1] >= height {
        "yuvj444p"
      } else if plane_heights[1] >= height {
        "yuvj422p"
      } else if plane_widths[1] >= width {
        "yuvj440p"
      } else {
        "yuvj420p"
      }
      return Ok({
        width,
        height,
        pix_fmt,
        planes: out_planes,
        plane_widths,
        plane_heights,
      })
    } else if marker == 0xC2 ||
      marker == 0xC3 ||
      marker == 0xC6 ||
      marker == 0xC7 ||
      marker == 0xC9 ||
      marker == 0xCA ||
      marker == 0xCB ||
      marker == 0xCD ||
      marker == 0xCE ||
      marker == 0xCF {
      return Err("PATCHWELCOME: mjpeg JPEG process")
    }
  }
  Err("mjpeg: no scan found")
}
