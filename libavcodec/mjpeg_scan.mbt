///|
/// Scan decoding and final reconstruction for the JPEG decoder.
///
/// Sequential scans dequantise into per-component coefficient buffers exactly
/// like `decode_block` in `mjpegdec.c`. Progressive scans implement the DC
/// first/refinement and AC first/refinement passes (`decode_dc_progressive`,
/// `decode_block_progressive`, `decode_block_refinement`) with shared EOB runs.
/// All components are IDCT-transformed once, at the end of the image, which is
/// what FFmpeg does for progressive JPEG and produces identical samples for
/// sequential JPEG.

///|
/// `extend`: sign-extend an n-bit magnitude.
fn jpeg_extend(v : Int32, n : Int32) -> Int32 {
  if n == 0 {
    0
  } else if v < 1 << (n - 1) {
    v - (1 << n) + 1
  } else {
    v
  }
}

///|
fn jpeg_huff_get(
  tables : Array[JpegHuffman?],
  index : Int32,
  what : String,
) -> Result[JpegHuffman, String] {
  if index < 0 || index >= tables.length() {
    return Err("mjpeg: invalid \{what} table id")
  }
  match tables[index] {
    Some(h) => Ok(h)
    None => Err("mjpeg: missing \{what} Huffman table")
  }
}

///|
fn jpeg_quant_get(
  quant : Array[Array[Int32]],
  index : Int32,
) -> Result[Array[Int32], String] {
  if index < 0 || index >= quant.length() || quant[index].length() < 64 {
    return Err("mjpeg: missing quant table")
  }
  Ok(quant[index])
}

///|
/// Copy a decoded baseline block into the component's coefficient buffer.
fn jpeg_store_block(
  coeffs : Array[Int32],
  block : Array[Int32],
  block_index : Int32,
) -> Unit {
  let base = block_index * 64
  for i in 0..<64 {
    coeffs[base + i] = block[i]
  }
}

///|
/// Decode one interleaved or non-interleaved sequential scan.
fn mjpeg_decode_scan_sequential(
  bits : JpegEntropy,
  components : Array[JpegComponent],
  scan_components : Array[Int32],
  quant : Array[Array[Int32]],
  dc_tables : Array[JpegHuffman?],
  ac_tables : Array[JpegHuffman?],
  width : Int32,
  height : Int32,
  max_h : Int32,
  max_v : Int32,
  restart_interval : Int32,
) -> Result[Unit, String] {
  if scan_components.length() == 1 {
    let ci = scan_components[0]
    let comp = components[ci]
    let qt = match jpeg_quant_get(quant, comp.tq) {
      Ok(q) => q
      Err(e) => return Err(e)
    }
    let dct = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
      Ok(h) => h
      Err(e) => return Err(e)
    }
    let act = match jpeg_huff_get(ac_tables, comp.ac_table, "AC") {
      Ok(h) => h
      Err(e) => return Err(e)
    }
    let total = comp.blocks_w * comp.blocks_h
    let mut index = 0
    for by in 0..<comp.blocks_h {
      for bx in 0..<comp.blocks_w {
        let block : Array[Int32] = []
        for _ in 0..<64 {
          block.push(0)
        }
        match jpeg_decode_block(bits, block, comp, qt, dct, act) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
        jpeg_store_block(comp.coeffs, block, by * comp.blocks_w + bx)
        index = index + 1
        if restart_interval > 0 &&
          index % restart_interval == 0 &&
          index < total {
          je_restart(bits)
          for c in components {
            c.dc_pred = 4 << 8
          }
        }
      }
    }
    return Ok(())
  }
  let mcu_cols = (width + max_h * 8 - 1) / (max_h * 8)
  let mcu_rows = (height + max_v * 8 - 1) / (max_v * 8)
  let total = mcu_cols * mcu_rows
  let mut mcu_index = 0
  for mcu_y in 0..<mcu_rows {
    for mcu_x in 0..<mcu_cols {
      for ci in scan_components {
        let comp = components[ci]
        let qt = match jpeg_quant_get(quant, comp.tq) {
          Ok(q) => q
          Err(e) => return Err(e)
        }
        let dct = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
          Ok(h) => h
          Err(e) => return Err(e)
        }
        let act = match jpeg_huff_get(ac_tables, comp.ac_table, "AC") {
          Ok(h) => h
          Err(e) => return Err(e)
        }
        for vy in 0..<comp.v {
          for hx in 0..<comp.h {
            let bx = mcu_x * comp.h + hx
            let by = mcu_y * comp.v + vy
            if bx >= comp.blocks_w || by >= comp.blocks_h {
              return Err("mjpeg: MCU block outside component")
            }
            let block : Array[Int32] = []
            for _ in 0..<64 {
              block.push(0)
            }
            match jpeg_decode_block(bits, block, comp, qt, dct, act) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
            jpeg_store_block(comp.coeffs, block, by * comp.blocks_w + bx)
          }
        }
      }
      mcu_index = mcu_index + 1
      if restart_interval > 0 &&
        mcu_index % restart_interval == 0 &&
        mcu_index < total {
        je_restart(bits)
        for c in components {
          c.dc_pred = 4 << 8
        }
      }
    }
  }
  Ok(())
}

///|
/// Progressive DC first pass (`decode_dc_progressive`).
fn jpeg_decode_dc_first(
  bits : JpegEntropy,
  comp : JpegComponent,
  block_index : Int32,
  quant : Array[Int32],
  dc : JpegHuffman,
  al : Int32,
) -> Result[Unit, String] {
  let category = match jpeg_huffman_decode(bits, dc) {
    Ok(c) => c
    Err(e) => return Err(e)
  }
  if category > 11 {
    return Err("mjpeg: invalid DC category")
  }
  let diff = jpeg_extend(je_read(bits, category), category)
  let value = diff * (quant[0] << al) + comp.dc_pred
  comp.dc_pred = value
  comp.coeffs[block_index * 64] = jpeg_i16(value)
  Ok(())
}

///|
/// Progressive DC refinement pass: one correction bit per block.
fn jpeg_decode_dc_refine(
  bits : JpegEntropy,
  comp : JpegComponent,
  block_index : Int32,
  quant : Array[Int32],
  al : Int32,
) -> Result[Unit, String] {
  if je_read(bits, 1) != 0 {
    let base = block_index * 64
    comp.coeffs[base] = jpeg_i16(comp.coeffs[base] + (quant[0] << al))
  }
  Ok(())
}

///|
/// Progressive AC first pass (`decode_block_progressive`).
fn jpeg_decode_ac_first(
  bits : JpegEntropy,
  comp : JpegComponent,
  block_index : Int32,
  quant : Array[Int32],
  ac : JpegHuffman,
  ss : Int32,
  se : Int32,
  al : Int32,
  eobrun : Ref[Int32],
) -> Result[Unit, String] {
  if eobrun.val > 0 {
    eobrun.val = eobrun.val - 1
    return Ok(())
  }
  let base = block_index * 64
  let mut i = ss
  while i <= se {
    let rs = match jpeg_huffman_decode(bits, ac) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let run = rs >> 4
    let size = rs & 0x0F
    if size != 0 {
      i = i + run
      if i > se {
        return Err("mjpeg: progressive AC index out of range")
      }
      let level = jpeg_extend(je_read(bits, size), size)
      comp.coeffs[base + jpeg_zigzag[i]] = jpeg_i16(level * (quant[i] << al))
      i = i + 1
    } else if run == 15 {
      i = i + 15
      if i >= se {
        return Err("mjpeg: progressive ZRL overflow")
      }
      i = i + 1
    } else {
      let mut val = 1 << run
      if run > 0 {
        val = val + je_read(bits, run)
      }
      eobrun.val = val - 1
      break
    }
  }
  if i > comp.last_nnz[block_index] {
    comp.last_nnz[block_index] = i
  }
  Ok(())
}

///|
/// Apply one refinement bit to an already non-zero coefficient.
fn jpeg_refine_coefficient(
  bits : JpegEntropy,
  comp : JpegComponent,
  base : Int32,
  scan_index : Int32,
  quant : Array[Int32],
  al : Int32,
) -> Unit {
  let j = base + jpeg_zigzag[scan_index]
  if je_read(bits, 1) != 0 {
    let delta = quant[scan_index] << al
    comp.coeffs[j] = jpeg_i16(
      comp.coeffs[j] + (if comp.coeffs[j] < 0 { -delta } else { delta }),
    )
  }
}

///|
/// `ZERO_RUN` from `decode_block_refinement`: skip `run` zero coefficients,
/// refining every non-zero coefficient encountered, and return the index at
/// which the next coefficient must be placed.
fn jpeg_refine_zero_run(
  bits : JpegEntropy,
  comp : JpegComponent,
  base : Int32,
  start : Int32,
  run_count : Int32,
  last : Int32,
  se : Int32,
  quant : Array[Int32],
  al : Int32,
) -> Result[Int32, String] {
  let mut i = start
  let mut run = run_count
  for ;; {
    if i > last {
      i = i + run
      if i > se {
        return Err("mjpeg: progressive refinement index out of range")
      }
      return Ok(i)
    }
    if comp.coeffs[base + jpeg_zigzag[i]] != 0 {
      jpeg_refine_coefficient(bits, comp, base, i, quant, al)
    } else if run == 0 {
      return Ok(i)
    } else {
      run = run - 1
    }
    i = i + 1
  }
}

///|
/// Progressive AC refinement pass (`decode_block_refinement`).
fn jpeg_decode_ac_refine(
  bits : JpegEntropy,
  comp : JpegComponent,
  block_index : Int32,
  quant : Array[Int32],
  ac : JpegHuffman,
  ss : Int32,
  se : Int32,
  al : Int32,
  eobrun : Ref[Int32],
) -> Result[Unit, String] {
  let base = block_index * 64
  let last = if comp.last_nnz[block_index] < se {
    comp.last_nnz[block_index]
  } else {
    se
  }
  let mut i = ss
  if eobrun.val > 0 {
    eobrun.val = eobrun.val - 1
  } else {
    for ;; {
      let code = match jpeg_huffman_decode(bits, ac) {
        Ok(v) => v
        Err(e) => return Err(e)
      }
      let run = code >> 4
      if (code & 0x0F) != 0 {
        let negative = je_read(bits, 1) == 0
        i = match
          jpeg_refine_zero_run(bits, comp, base, i, run, last, se, quant, al) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        let j = base + jpeg_zigzag[i]
        let q = quant[i] << al
        comp.coeffs[j] = jpeg_i16(if negative { -q } else { q })
        if i == se {
          if i > comp.last_nnz[block_index] {
            comp.last_nnz[block_index] = i
          }
          return Ok(())
        }
        i = i + 1
      } else if run == 15 {
        i = match
          jpeg_refine_zero_run(bits, comp, base, i, run, last, se, quant, al) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        i = i + 1
      } else {
        let val = run
        let mut e = 1 << run
        if val > 0 {
          e = e + je_read(bits, val)
        }
        eobrun.val = e - 1
        break
      }
    }
    if i > comp.last_nnz[block_index] {
      comp.last_nnz[block_index] = i
    }
  }
  while i <= last {
    if comp.coeffs[base + jpeg_zigzag[i]] != 0 {
      jpeg_refine_coefficient(bits, comp, base, i, quant, al)
    }
    i = i + 1
  }
  Ok(())
}

///|
/// One progressive scan: DC (interleaved or single-component), or AC
/// (single-component only).
fn mjpeg_decode_scan_progressive(
  bits : JpegEntropy,
  components : Array[JpegComponent],
  scan_components : Array[Int32],
  quant : Array[Array[Int32]],
  dc_tables : Array[JpegHuffman?],
  ac_tables : Array[JpegHuffman?],
  width : Int32,
  height : Int32,
  max_h : Int32,
  max_v : Int32,
  restart_interval : Int32,
  ss : Int32,
  se : Int32,
  ah : Int32,
  al : Int32,
) -> Result[Unit, String] {
  if ss < 0 || se < ss || se > 63 || ah < 0 || al < 0 || ah > 13 || al > 13 {
    return Err("mjpeg: invalid progressive scan parameters")
  }
  if ss == 0 {
    if se != 0 {
      return Err("mjpeg: progressive DC scan must have Se=0")
    }
  } else if scan_components.length() != 1 {
    return Err("mjpeg: progressive AC scan must be non-interleaved")
  }
  let eobrun = Ref(0)
  let mcu_cols = (width + max_h * 8 - 1) / (max_h * 8)
  let mcu_rows = (height + max_v * 8 - 1) / (max_v * 8)
  if scan_components.length() > 1 {
    let total = mcu_cols * mcu_rows
    let mut mcu_index = 0
    for mcu_y in 0..<mcu_rows {
      for mcu_x in 0..<mcu_cols {
        for ci in scan_components {
          let comp = components[ci]
          let qt = match jpeg_quant_get(quant, comp.tq) {
            Ok(q) => q
            Err(e) => return Err(e)
          }
          let dct = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
            Ok(h) => h
            Err(e) => return Err(e)
          }
          for vy in 0..<comp.v {
            for hx in 0..<comp.h {
              let bx = mcu_x * comp.h + hx
              let by = mcu_y * comp.v + vy
              if bx >= comp.blocks_w || by >= comp.blocks_h {
                return Err("mjpeg: MCU block outside component")
              }
              let bi = by * comp.blocks_w + bx
              if ah == 0 {
                match jpeg_decode_dc_first(bits, comp, bi, qt, dct, al) {
                  Ok(_) => ()
                  Err(e) => return Err(e)
                }
              } else {
                match jpeg_decode_dc_refine(bits, comp, bi, qt, al) {
                  Ok(_) => ()
                  Err(e) => return Err(e)
                }
              }
            }
          }
        }
        mcu_index = mcu_index + 1
        if restart_interval > 0 &&
          mcu_index % restart_interval == 0 &&
          mcu_index < total {
          je_restart(bits)
          eobrun.val = 0
          for c in components {
            c.dc_pred = 4 << 8
          }
        }
      }
    }
    return Ok(())
  }
  let ci = scan_components[0]
  let comp = components[ci]
  let qt = match jpeg_quant_get(quant, comp.tq) {
    Ok(q) => q
    Err(e) => return Err(e)
  }
  if ss == 0 {
    let dct = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
      Ok(h) => h
      Err(e) => return Err(e)
    }
    let total = comp.blocks_w * comp.blocks_h
    let mut index = 0
    for by in 0..<comp.blocks_h {
      for bx in 0..<comp.blocks_w {
        let bi = by * comp.blocks_w + bx
        if ah == 0 {
          match jpeg_decode_dc_first(bits, comp, bi, qt, dct, al) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        } else {
          match jpeg_decode_dc_refine(bits, comp, bi, qt, al) {
            Ok(_) => ()
            Err(e) => return Err(e)
          }
        }
        index = index + 1
        if restart_interval > 0 &&
          index % restart_interval == 0 &&
          index < total {
          je_restart(bits)
          eobrun.val = 0
          for c in components {
            c.dc_pred = 4 << 8
          }
        }
      }
    }
    return Ok(())
  }
  let act = match jpeg_huff_get(ac_tables, comp.ac_table, "AC") {
    Ok(h) => h
    Err(e) => return Err(e)
  }
  let total = comp.blocks_w * comp.blocks_h
  let mut index = 0
  for by in 0..<comp.blocks_h {
    for bx in 0..<comp.blocks_w {
      let bi = by * comp.blocks_w + bx
      if ah == 0 {
        match
          jpeg_decode_ac_first(bits, comp, bi, qt, act, ss, se, al, eobrun) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      } else {
        match
          jpeg_decode_ac_refine(bits, comp, bi, qt, act, ss, se, al, eobrun) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      }
      index = index + 1
      if restart_interval > 0 && index % restart_interval == 0 && index < total {
        je_restart(bits)
        eobrun.val = 0
      }
    }
  }
  Ok(())
}

///|
/// Transform all coefficient buffers and produce the cropped planar image.
fn mjpeg_finalize_image(
  components : Array[JpegComponent],
  width : Int32,
  height : Int32,
  max_h : Int32,
  max_v : Int32,
) -> Result[JpegImage, String] {
  let out_planes : Array[Bytes] = []
  let plane_widths : Array[Int32] = []
  let plane_heights : Array[Int32] = []
  for ci in 0..<components.length() {
    let comp = components[ci]
    let stride = comp.blocks_w * 8
    let ph = comp.blocks_h * 8
    let plane : Array[Int32] = []
    for _ in 0..<(stride * ph) {
      plane.push(0)
    }
    for by in 0..<comp.blocks_h {
      for bx in 0..<comp.blocks_w {
        let block : Array[Int32] = []
        let base = (by * comp.blocks_w + bx) * 64
        for i in 0..<64 {
          block.push(comp.coeffs[base + i])
        }
        mjpeg_idct_put(plane, stride, block, bx * 8, by * 8)
      }
    }
    let pw = (width * comp.h + max_h - 1) / max_h
    let phv = (height * comp.v + max_v - 1) / max_v
    plane_widths.push(pw)
    plane_heights.push(phv)
    let out : Array[Byte] = []
    for y in 0..<phv {
      for x in 0..<pw {
        out.push(plane[y * stride + x].to_byte())
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
  Ok({
    width,
    height,
    pix_fmt,
    planes: out_planes,
    plane_widths,
    plane_heights,
  })
}

///|
/// Locate the marker that terminated an entropy-coded segment. `JpegEntropy`
/// consumes the 0xFF of a marker but leaves its second byte in place, so back
/// up over any fill bytes to the marker prefix.
fn jpeg_marker_start(data : Bytes, pos : Int32) -> Int32 {
  let len = data.length()
  let mut p = pos
  if p > len {
    p = len
  }
  while p > 0 && data[p - 1].to_int() == 0xFF {
    p = p - 1
  }
  if p + 1 < len && data[p].to_int() == 0xFF && data[p + 1].to_int() != 0 {
    return p
  }
  // FFmpeg's find_marker scans forward past unread entropy bytes (some
  // encoders pad the scan), treating stuffed 0xFF00 pairs as data.
  while p + 1 < len {
    if data[p].to_int() == 0xFF {
      if data[p + 1].to_int() != 0 {
        return p
      }
      p = p + 2
    } else {
      p = p + 1
    }
  }
  len
}

///|
/// `PREDICT` from `mjpeg.h`: lossless JPEG spatial predictors 0..7. */
fn jpeg_predict(
  topleft : Int32,
  top : Int32,
  left : Int32,
  predictor : Int32,
) -> Int32 {
  match predictor {
    0 => 0
    1 => left
    2 => top
    3 => topleft
    4 => left + top - topleft
    5 => left + ((top - topleft) >> 1)
    6 => top + ((left - topleft) >> 1)
    _ => (left + top) >> 1
  }
}

///|
/// `ljpeg_decode_yuv_scan`: lossless JPEG samples are coded directly in the
/// component planes with a spatial predictor, so no IDCT is involved.  Only
/// the 8-bit planar paths are supported (the 3-component 1x1 "lossless RGB"
/// path is rejected by the parser).
fn mjpeg_decode_scan_lossless(
  bits : JpegEntropy,
  components : Array[JpegComponent],
  scan_components : Array[Int32],
  dc_tables : Array[JpegHuffman?],
  width : Int32,
  height : Int32,
  max_h : Int32,
  max_v : Int32,
  restart_interval : Int32,
  predictor : Int32,
  al : Int32,
) -> Result[Unit, String] {
  let ns = scan_components.length()
  if ns < 1 || ns > 4 {
    return Err("mjpeg: invalid lossless scan component count")
  }
  let interleaved = ns > 1
  let mb_width = if interleaved {
    (width + max_h - 1) / max_h
  } else {
    let first = components[scan_components[0]]
    let hdiv = max_h / first.h
    (width + hdiv - 1) / hdiv
  }
  let mb_height = if interleaved {
    (height + max_v - 1) / max_v
  } else {
    let first = components[scan_components[0]]
    let vdiv = max_v / first.v
    (height + vdiv - 1) / vdiv
  }
  // Per-scan component step and block count, mirroring ff_mjpeg_decode_sos.
  let steps_h : Array[Int32] = Array::make(ns, 1)
  let steps_v : Array[Int32] = Array::make(ns, 1)
  let blocks : Array[Int32] = Array::make(ns, 1)
  for i = 0; i < ns; i = i + 1 {
    let comp = components[scan_components[i]]
    if interleaved {
      steps_h[i] = comp.h
      steps_v[i] = comp.v
      blocks[i] = comp.h * comp.v
    }
  }
  let mask = 0xFF << al
  let mut resync_mb_x = 0
  let mut resync_mb_y = 0
  let mut restart_count = -1
  for mb_y = 0; mb_y < mb_height; mb_y = mb_y + 1 {
    for mb_x = 0; mb_x < mb_width; mb_x = mb_x + 1 {
      let mut restart = false
      if restart_interval != 0 {
        if restart_count <= 0 {
          restart_count = restart_interval
          restart = true
        }
        restart_count = restart_count - 1
      } else if restart_count < 0 {
        restart_count = 0
        restart = true
      }
      if restart {
        je_restart(bits)
        resync_mb_x = mb_x
        resync_mb_y = mb_y
      }
      if (bits.data.length() - bits.pos) * 8 + bits.count < 1 {
        return Err("mjpeg: bitstream end in lossless scan")
      }
      let toprow = mb_y == resync_mb_y ||
        (mb_y == resync_mb_y + 1 && mb_x < resync_mb_x)
      let leftcol = mb_x == 0 || (mb_y == resync_mb_y && mb_x == resync_mb_x)
      for i = 0; i < ns; i = i + 1 {
        let ci = scan_components[i]
        let comp = components[ci]
        let dc = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
          Ok(h) => h
          Err(e) => return Err(e)
        }
        let stride = (width * comp.h + max_h - 1) / max_h
        let plane = comp.samples
        let mut x = 0
        let mut y = 0
        for _j = 0; _j < blocks[i]; _j = _j + 1 {
          let category = match jpeg_huffman_decode(bits, dc) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          if category > 16 {
            return Err("mjpeg: invalid lossless DC category")
          }
          let diff = if category == 0 {
            0
          } else {
            jpeg_extend(je_read(bits, category), category)
          }
          let px = steps_h[i] * mb_x + x
          let py = steps_v[i] * mb_y + y
          if px < width && py < height {
            let pred = if y == 0 && toprow {
              if x == 0 && leftcol {
                1 << 7
              } else {
                plane[py * stride + px - 1]
              }
            } else if x == 0 && leftcol {
              plane[(py - 1) * stride + px]
            } else {
              jpeg_predict(
                plane[(py - 1) * stride + px - 1],
                plane[(py - 1) * stride + px],
                plane[py * stride + px - 1],
                predictor,
              )
            }
            plane[py * stride + px] = ((pred & mask) + (diff << al)) & 0xFF
          }
          x = x + 1
          if x == steps_h[i] {
            x = 0
            y = y + 1
          }
        }
      }
    }
  }
  Ok(())
}

///|
/// Build a planar 8-bit image from the lossless component planes.  The
/// pixel-format choice mirrors `mjpeg_finalize_image`.
fn mjpeg_finalize_lossless(
  components : Array[JpegComponent],
  width : Int32,
  height : Int32,
  max_h : Int32,
  max_v : Int32,
) -> Result[JpegImage, String] {
  let ncomp = components.length()
  if ncomp != 1 && ncomp != 3 {
    return Err("PATCHWELCOME: lossless JPEG component layout")
  }
  let out_planes : Array[Bytes] = []
  let plane_widths : Array[Int32] = []
  let plane_heights : Array[Int32] = []
  for ci = 0; ci < ncomp; ci = ci + 1 {
    let comp = components[ci]
    let pw = (width * comp.h + max_h - 1) / max_h
    let ph = (height * comp.v + max_v - 1) / max_v
    let out : Array[Byte] = []
    for y = 0; y < ph; y = y + 1 {
      for x = 0; x < pw; x = x + 1 {
        out.push(comp.samples[y * pw + x].to_byte())
      }
    }
    out_planes.push(Bytes::from_array(out))
    plane_widths.push(pw)
    plane_heights.push(ph)
  }
  let pix_fmt = if ncomp == 1 {
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
  Ok({
    width,
    height,
    pix_fmt,
    planes: out_planes,
    plane_widths,
    plane_heights,
  })
}

///|
/// `ljpeg_decode_rgb_scan`: 3-component 1x1 lossless RGB. Each component is
/// coded directly at pixel resolution; the first row (and the first pixel of
/// each row or restart interval) forces the left predictor. Samples stay in
/// the component planes until `mjpeg_finalize_rgb` packs them.
fn mjpeg_decode_scan_rgb(
  bits : JpegEntropy,
  components : Array[JpegComponent],
  scan_components : Array[Int32],
  dc_tables : Array[JpegHuffman?],
  width : Int32,
  height : Int32,
  restart_interval : Int32,
  predictor : Int32,
  al : Int32,
  sample_bits : Int32,
) -> Result[Unit, String] {
  let ns = scan_components.length()
  if ns < 1 || ns > 3 {
    return Err("mjpeg: invalid lossless RGB scan component count")
  }
  let mask = ((1 << sample_bits) - 1) << al
  let init = 1 << (sample_bits - 1)
  let top : Array[Int32] = Array::make(ns, init)
  let left : Array[Int32] = Array::make(ns, init)
  let topleft : Array[Int32] = Array::make(ns, init)
  // Previous row's samples for each scan slot (the C's `ljpeg_buffer`).
  let prev : Array[Int32] = []
  for _ in 0..<(ns * width) {
    prev.push(init)
  }
  let mut resync_mb_x = 0
  let mut resync_mb_y = 0
  let mut restart_count = -1
  for mb_y = 0; mb_y < height; mb_y = mb_y + 1 {
    for i = 0; i < ns; i = i + 1 {
      top[i] = prev[i * width]
      left[i] = top[i]
      topleft[i] = top[i]
    }
    for mb_x = 0; mb_x < width; mb_x = mb_x + 1 {
      let mut restart = false
      if restart_interval != 0 {
        if restart_count <= 0 {
          restart_count = restart_interval
          restart = true
        }
        restart_count = restart_count - 1
      } else if restart_count < 0 {
        restart_count = 0
        restart = true
      }
      if restart {
        je_restart(bits)
        resync_mb_x = mb_x
        resync_mb_y = mb_y
        for i = 0; i < ns; i = i + 1 {
          top[i] = init
          left[i] = init
          topleft[i] = init
        }
      }
      if (bits.data.length() - bits.pos) * 8 + bits.count < 1 {
        return Err("mjpeg: bitstream end in lossless RGB scan")
      }
      let modified_predictor = if mb_y == resync_mb_y ||
        (mb_y == resync_mb_y + 1 && mb_x < resync_mb_x) ||
        mb_x == 0 {
        1
      } else {
        predictor
      }
      for i = 0; i < ns; i = i + 1 {
        let ci = scan_components[i]
        let comp = components[ci]
        let dc = match jpeg_huff_get(dc_tables, comp.dc_table, "DC") {
          Ok(h) => h
          Err(e) => return Err(e)
        }
        topleft[i] = top[i]
        top[i] = prev[i * width + mb_x]
        let pred = jpeg_predict(topleft[i], top[i], left[i], modified_predictor)
        let category = match jpeg_huffman_decode(bits, dc) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        if category > 16 {
          return Err("mjpeg: invalid lossless DC category")
        }
        let diff = if category == 0 {
          0
        } else {
          jpeg_extend(je_read(bits, category), category)
        }
        let value = mask & (pred + (diff << al))
        left[i] = value
        prev[i * width + mb_x] = value
        comp.samples[mb_y * width + mb_x] = value
      }
    }
  }
  Ok(())
}

///|
/// Pack lossless RGB samples into FFmpeg's native BGR24 output. With 9-bit
/// samples FFmpeg applies the reversible colour transform used by its
/// `ljpeg` BGR encoder (`s->rct` is set for 9-bit lossless); 8-bit samples
/// are copied directly.
fn mjpeg_finalize_rgb(
  components : Array[JpegComponent],
  width : Int32,
  height : Int32,
  sample_bits : Int32,
) -> Result[JpegImage, String] {
  if components.length() != 3 {
    return Err("mjpeg: lossless RGB needs 3 components")
  }
  let rct = sample_bits == 9
  let out : Array[Byte] = []
  for y = 0; y < height; y = y + 1 {
    for x = 0; x < width; x = x + 1 {
      let i = y * width + x
      let c0 = components[0].samples[i]
      let c1 = components[1].samples[i]
      let c2 = components[2].samples[i]
      if rct {
        let g = c0 - ((c1 + c2 - 0x200) >> 2)
        out.push((c1 + g).to_byte())
        out.push(g.to_byte())
        out.push((c2 + g).to_byte())
      } else {
        out.push(c2.to_byte())
        out.push(c1.to_byte())
        out.push(c0.to_byte())
      }
    }
  }
  Ok({
    width,
    height,
    pix_fmt: "bgr24",
    planes: [Bytes::from_array(out)],
    plane_widths: [width * 3],
    plane_heights: [height],
  })
}
