///|
/// MoonBit port of the FFmpeg 9.0.2 JPEG/MJPEG decoder slice:
/// `libavcodec/mjpegdec.c` (`ff_mjpeg_decode_sof`, `ff_mjpeg_decode_dqt`,
/// `ff_mjpeg_decode_dht`, `ff_mjpeg_decode_sos`, `decode_block`,
/// `decode_dc_progressive`, `decode_block_progressive`,
/// `decode_block_refinement`, `mjpeg_decode_scan`,
/// `mjpeg_decode_scan_progressive_ac`, `mjpeg_idct_scan_progressive_ac`),
/// using the existing Simple-C IDCT (`ff_simple_idct_put_int16_8bit`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: 8-bit sequential DCT (SOF0/SOF1), progressive DCT (SOF2) and
/// lossless JPEG (SOF3, planar predictors 0..7, point transform, restart
/// intervals; 1-component planar and 3-component 1x1 lossless RGB with
/// 8/9-bit samples, the latter packed as BGR24 with the 9-bit reversible
/// colour transform), interleaved and single-component scans, multi-scan sequential files,
/// progressive DC first/refinement, AC first/refinement and EOB runs, arbitrary
/// 1..4 h/v sampling, DQT (8/16-bit entries), DHT, DRI restart markers, the
/// native `yuvj420p`/`yuvj422p`/`yuvj444p`/`yuvj440p`/`gray` output formats
/// FFmpeg selects, 4-component CMYK/YCCK with the Adobe APP14 transform
/// (transform 0 -> `gbrap`, 2 -> `yuva444p`; the 2x2-Y/full-K layout is
/// chroma-upscaled to 4:4:4 like FFmpeg), and 3-component 1x1 Adobe
/// transform 0 / R,G,B component IDs -> `gbrp`. Planes are cropped to the
/// visible size.
///
/// Out of scope: arithmetic coding, 12-bit samples, other 4-component
/// sampling layouts, subsampled 3-component Adobe transforms, and EXIF
/// orientation.

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
  let mut p = bits.pos
  // The entropy reader may stop either on the marker prefix or on its second
  // byte, depending on whether the prefix was already consumed while filling
  // the bit cache.
  if p < bits.data.length() && bits.data[p].to_int() == 0xFF {
    while p < bits.data.length() && bits.data[p].to_int() == 0xFF {
      p = p + 1
    }
  } else if p > 0 && bits.data[p - 1].to_int() == 0xFF {
    // p already points at RSTn.
  } else {
    return
  }
  if p < bits.data.length() {
    let m = bits.data[p].to_int()
    if m >= 0xD0 && m <= 0xD7 {
      bits.pos = p + 1
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
  /// Uncropped component dimensions in 8x8 blocks.
  mut blocks_w : Int32
  mut blocks_h : Int32
  /// Dequantised coefficients in natural order, row-major blocks of 64.
  coeffs : Array[Int32]
  /// Progressive AC end-of-band position for each block.
  last_nnz : Array[Int32]
  /// Lossless JPEG samples at component resolution (empty otherwise).
  samples : Array[Int32]
}

///|
/// Decode an 8-bit baseline, progressive or lossless JPEG. */
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
  let mut saw_scan = false
  let mut progressive = false
  let mut lossless = false
  let mut rgb_mode = false
  let mut sample_bits = 8
  let mut adobe_transform = -1
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
    } else if marker == 0xEE {
      // Adobe APP14: transform 0 = CMYK, 2 = YCCK.
      if seg.length() >= 12 &&
        seg[0] == b'A' &&
        seg[1] == b'd' &&
        seg[2] == b'o' &&
        seg[3] == b'b' &&
        seg[4] == b'e' {
        adobe_transform = seg[11].to_int()
      }
    } else if marker == 0xC0 ||
      marker == 0xC1 ||
      marker == 0xC2 ||
      marker == 0xC3 {
      // SOF0/SOF1/SOF2/SOF3
      if saw_sof {
        return Err("mjpeg: duplicate SOF")
      }
      if seg.length() < 6 {
        return Err("mjpeg: short SOF")
      }
      let precision = seg[0].to_int()
      lossless = marker == 0xC3
      if precision != 8 && precision != 9 {
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
      progressive = marker == 0xC2
      if lossless && ncomp != 1 && ncomp != 3 {
        return Err("PATCHWELCOME: lossless JPEG component count")
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
          blocks_w: 0,
          blocks_h: 0,
          coeffs: [],
          last_nnz: [],
          samples: [],
        })
      }
      // FFmpeg forces the CMYK transform when the 4 component IDs spell it.
      if ncomp == 4 &&
        components[0].id == 'C' &&
        components[1].id == 'M' &&
        components[2].id == 'Y' &&
        components[3].id == 'K' {
        adobe_transform = 0
      }
      // 9-bit lossless is only produced for 3-component 1x1 RGB, which is
      // stored 16-bit internally then packed to BGR24.
      if precision != 8 && !(lossless && ncomp == 3 && max_h == 1 && max_v == 1) {
        return Err("PATCHWELCOME: mjpeg sample precision")
      }
      rgb_mode = lossless && ncomp == 3 && max_h == 1 && max_v == 1
      sample_bits = precision
      for comp in components {
        let cw = (width * comp.h + max_h - 1) / max_h
        let ch = (height * comp.v + max_v - 1) / max_v
        if lossless {
          for _ in 0..<(cw * ch) {
            comp.samples.push(0)
          }
        } else {
          comp.blocks_w = (cw + 7) / 8
          comp.blocks_h = (ch + 7) / 8
          let nblocks = comp.blocks_w * comp.blocks_h
          for _ in 0..<nblocks {
            comp.last_nnz.push(0)
            for _ in 0..<64 {
              comp.coeffs.push(0)
            }
          }
        }
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
        let dc_id = tables >> 4
        let ac_id = tables & 0x0F
        if dc_id > 3 || ac_id > 3 {
          return Err("mjpeg: invalid scan Huffman table id")
        }
        components[found].dc_table = dc_id
        components[found].ac_table = ac_id
        scan_components.push(found)
      }
      let ss = seg[1 + ns * 2].to_int()
      let se = seg[2 + ns * 2].to_int()
      let ahal = seg[3 + ns * 2].to_int()
      let ah = ahal >> 4
      let al = ahal & 0x0F
      let bits : JpegEntropy = {
        data,
        pos,
        buffer: 0,
        count: 0,
        at_end: false,
      }
      let scan_result = if lossless {
        if se != 0 || ah != 0 {
          return Err("mjpeg: invalid lossless scan parameters")
        }
        if rgb_mode {
          mjpeg_decode_scan_rgb(
            bits, components, scan_components, dc_tables, width, height, restart_interval,
            ss, al, sample_bits,
          )
        } else {
          mjpeg_decode_scan_lossless(
            bits, components, scan_components, dc_tables, width, height, max_h, max_v,
            restart_interval, ss, al,
          )
        }
      } else if progressive {
        mjpeg_decode_scan_progressive(
          bits, components, scan_components, quant, dc_tables, ac_tables, width,
          height, max_h, max_v, restart_interval, ss, se, ah, al,
        )
      } else {
        if ss != 0 || se != 63 || ah != 0 || al != 0 {
          return Err("mjpeg: invalid sequential scan parameters")
        }
        mjpeg_decode_scan_sequential(
          bits, components, scan_components, quant, dc_tables, ac_tables, width,
          height, max_h, max_v, restart_interval,
        )
      }
      match scan_result {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      saw_scan = true
      // Continue at the marker that terminated the entropy segment.
      pos = jpeg_marker_start(data, bits.pos)
      if bits.at_end && pos >= data.length() {
        break
      }
    } else if marker == 0xC5 ||
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
  if !saw_sof {
    return Err("mjpeg: missing SOF")
  }
  if !saw_scan {
    return Err("mjpeg: no scan found")
  }
  if lossless {
    if rgb_mode {
      mjpeg_finalize_rgb(components, width, height, sample_bits)
    } else {
      mjpeg_finalize_lossless(components, width, height, max_h, max_v)
    }
  } else {
    mjpeg_finalize_image(
      components, width, height, max_h, max_v, adobe_transform,
    )
  }
}
