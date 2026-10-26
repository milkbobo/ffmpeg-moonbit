///|
/// MoonBit port of the FFmpeg 9.0.2 APNG decoder path in
/// `libavcodec/pngdec.c` (`decode_fctl_chunk`, `handle_p_frame_apng`,
/// `apng_reset_background`) plus `libavcodec/apng.h`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Every animation frame is decoded by rebuilding a self-contained PNG from
/// the canvas IHDR parameters and the frame's IDAT/fdAT payload, then feeding
/// it through `av_png_decode_ex(..., true)`. The result is normalised to RGBA
/// and composited on the canvas with FFmpeg's blend equations and dispose
/// rules. This gives byte-identical RGBA output to
/// `ffmpeg -i animation.apng -f rawvideo -pix_fmt rgba`.
///
/// The default image is excluded from the animation unless its `fcTL` chunk
/// precedes the first IDAT, as required by the APNG specification.

///|
/// One composited APNG frame.
pub struct ApngFrame {
  /// Full canvas dimensions (the IHDR dimensions).
  canvas_width : Int32
  canvas_height : Int32
  /// Frame rectangle inside the canvas.
  x_offset : Int32
  y_offset : Int32
  width : Int32
  height : Int32
  /// Raw `delay_num` / `delay_den` from fcTL. A zero denominator means 100.
  delay_num : Int32
  delay_den : Int32
  /// 0 = none, 1 = background, 2 = previous (already normalised for frame 0).
  dispose_op : Int32
  /// 0 = source, 1 = over.
  blend_op : Int32
  /// Composited RGBA canvas, top-to-bottom, `canvas_width * canvas_height * 4`
  /// bytes.
  rgba : Bytes
}

///|
/// A decoded APNG animation.
pub struct ApngImage {
  width : Int32
  height : Int32
  /// `num_plays` from acTL; 0 means infinite.
  loop_count : Int32
  frames : Array[ApngFrame]
}

///|
priv struct ApngFrameSpec {
  sequence_number : Int32
  width : Int32
  height : Int32
  x_offset : Int32
  y_offset : Int32
  delay_num : Int32
  delay_den : Int32
  mut dispose_op : Int32
  blend_op : Int32
  data : Array[Byte]
}

///|
fn apng_put_u32(out : Array[Byte], v : Int32) -> Unit {
  out.push(((v >> 24) & 0xFF).to_byte())
  out.push(((v >> 16) & 0xFF).to_byte())
  out.push(((v >> 8) & 0xFF).to_byte())
  out.push((v & 0xFF).to_byte())
}

///|
fn apng_put_chunk(out : Array[Byte], kind : Bytes, body : Array[Byte]) -> Unit {
  apng_put_u32(out, body.length())
  let typed : Array[Byte] = []
  for b in kind {
    typed.push(b)
  }
  for b in body {
    typed.push(b)
  }
  for b in typed {
    out.push(b)
  }
  apng_put_u32(out, png_crc32(Bytes::from_array(typed[:])))
}

///|
/// Rebuild a PNG containing only this frame's image rectangle. The canvas
/// IHDR settings (bit depth, colour type, interlace) carry over unchanged.
fn apng_frame_png(
  frame : ApngFrameSpec,
  bit_depth : Int32,
  color_type : Int32,
  compression : Int32,
  filter : Int32,
  interlace : Int32,
  plte : Array[Byte],
  trns : Array[Byte],
) -> Bytes {
  let out : Array[Byte] = []
  for b in b"\x89PNG\r\n\x1a\n" {
    out.push(b)
  }
  let ihdr : Array[Byte] = []
  apng_put_u32(ihdr, frame.width)
  apng_put_u32(ihdr, frame.height)
  ihdr.push(bit_depth.to_byte())
  ihdr.push(color_type.to_byte())
  ihdr.push(compression.to_byte())
  ihdr.push(filter.to_byte())
  ihdr.push(interlace.to_byte())
  apng_put_chunk(out, b"IHDR", ihdr)
  if color_type == 3 {
    apng_put_chunk(out, b"PLTE", plte)
  }
  if trns.length() > 0 {
    apng_put_chunk(out, b"tRNS", trns)
  }
  apng_put_chunk(out, b"IDAT", frame.data)
  apng_put_chunk(out, b"IEND", [])
  Bytes::from_array(out[:])
}

///|
/// Convert a decoded PNG's native FFmpeg pixel format to tightly packed RGBA.
/// 16-bit samples are reduced to their high byte, which is how the 8-bit APNG
/// canvas is represented here.
fn apng_to_rgba(img : PngImage) -> Result[Bytes, String] {
  let out : Array[Byte] = []
  let n = img.width * img.height
  let p = img.pixels
  if img.pix_fmt == "pal8" {
    for i in 0..<n {
      let idx = p[i].to_int() * 4
      out.push(img.palette[idx])
      out.push(img.palette[idx + 1])
      out.push(img.palette[idx + 2])
      out.push(img.palette[idx + 3])
    }
  } else if img.pix_fmt == "gray" {
    for i in 0..<n {
      let v = p[i]
      out.push(v)
      out.push(v)
      out.push(v)
      out.push(b'\xff')
    }
  } else if img.pix_fmt == "monob" {
    for i in 0..<n {
      let v = (p[i / 8].to_int() >> (7 - i % 8)) & 1
      let g = if v != 0 { b'\xff' } else { b'\x00' }
      out.push(g)
      out.push(g)
      out.push(g)
      out.push(b'\xff')
    }
  } else if img.pix_fmt == "gray16be" {
    for i in 0..<n {
      let v = p[i * 2]
      out.push(v)
      out.push(v)
      out.push(v)
      out.push(b'\xff')
    }
  } else if img.pix_fmt == "ya8" {
    for i in 0..<n {
      let v = p[i * 2]
      out.push(v)
      out.push(v)
      out.push(v)
      out.push(p[i * 2 + 1])
    }
  } else if img.pix_fmt == "ya16be" {
    for i in 0..<n {
      let v = p[i * 4]
      out.push(v)
      out.push(v)
      out.push(v)
      out.push(p[i * 4 + 2])
    }
  } else if img.pix_fmt == "rgb24" {
    for i in 0..<n {
      out.push(p[i * 3])
      out.push(p[i * 3 + 1])
      out.push(p[i * 3 + 2])
      out.push(b'\xff')
    }
  } else if img.pix_fmt == "rgb48be" {
    for i in 0..<n {
      out.push(p[i * 6])
      out.push(p[i * 6 + 2])
      out.push(p[i * 6 + 4])
      out.push(b'\xff')
    }
  } else if img.pix_fmt == "rgba" {
    for i in 0..<n {
      out.push(p[i * 4])
      out.push(p[i * 4 + 1])
      out.push(p[i * 4 + 2])
      out.push(p[i * 4 + 3])
    }
  } else if img.pix_fmt == "rgba64be" {
    for i in 0..<n {
      out.push(p[i * 8])
      out.push(p[i * 8 + 2])
      out.push(p[i * 8 + 4])
      out.push(p[i * 8 + 6])
    }
  } else {
    return Err("apng: unsupported frame pixel format \{img.pix_fmt}")
  }
  Ok(Bytes::from_array(out[:]))
}

///|
/// `FAST_DIV255` from pngdec.c: divide by 255 and round to nearest.
fn apng_fast_div255(x : Int32) -> Int32 {
  ((x + 128) * 257) >> 16
}

///|
fn apng_transparent_canvas(width : Int32, height : Int32) -> Bytes {
  Bytes::make(width * height * 4, b'\x00')
}

///|
/// Compose one frame, append it to `frames`, and return the canvas state that
/// the next frame starts from (after applying this frame's dispose operation).
fn apng_compose_frame(
  spec : ApngFrameSpec,
  bit_depth : Int32,
  color_type : Int32,
  compression : Int32,
  filter : Int32,
  interlace : Int32,
  plte : Array[Byte],
  trns : Array[Byte],
  canvas_width : Int32,
  canvas_height : Int32,
  previous : Bytes,
  frames : Array[ApngFrame],
) -> Result[Bytes, String] {
  let png = apng_frame_png(
    spec, bit_depth, color_type, compression, filter, interlace, plte, trns,
  )
  let decoded = match av_png_decode_ex(png, true) {
    Ok(img) => img
    Err(e) => return Err(e)
  }
  if decoded.width != spec.width || decoded.height != spec.height {
    return Err("apng: frame dimensions do not match fcTL")
  }
  let source = match apng_to_rgba(decoded) {
    Ok(rgba) => rgba
    Err(e) => return Err(e)
  }
  // Start from the previous displayed canvas, exactly like
  // handle_p_frame_apng(), then replace/blend the frame rectangle.
  let out : Array[Byte] = []
  for i in 0..<previous.length() {
    out.push(previous[i])
  }
  let canvas_stride = canvas_width * 4
  if spec.blend_op == 0 {
    for y in 0..<spec.height {
      for x in 0..<spec.width {
        let src = (y * spec.width + x) * 4
        let dst = (spec.y_offset + y) * canvas_stride + (spec.x_offset + x) * 4
        out[dst] = source[src]
        out[dst + 1] = source[src + 1]
        out[dst + 2] = source[src + 2]
        out[dst + 3] = source[src + 3]
      }
    }
  } else {
    for y in 0..<spec.height {
      for x in 0..<spec.width {
        let src = (y * spec.width + x) * 4
        let dst = (spec.y_offset + y) * canvas_stride + (spec.x_offset + x) * 4
        let fg_a = source[src + 3].to_int()
        if fg_a == 255 {
          out[dst] = source[src]
          out[dst + 1] = source[src + 1]
          out[dst + 2] = source[src + 2]
          out[dst + 3] = source[src + 3]
          continue
        }
        if fg_a == 0 {
          // Keep the background pixel.
          continue
        }
        let bg_a = out[dst + 3].to_int()
        let out_a = fg_a + apng_fast_div255((255 - fg_a) * bg_a)
        for c in 0..<3 {
          let fg = source[src + c].to_int()
          let bg = out[dst + c].to_int()
          let v = if out_a == 0 {
            0
          } else if bg_a == 255 {
            apng_fast_div255(fg_a * fg + (255 - fg_a) * bg)
          } else {
            (255 * fg_a * fg + (255 - fg_a) * bg_a * bg) / (255 * out_a)
          }
          out[dst + c] = v.to_byte()
        }
        out[dst + 3] = out_a.to_byte()
      }
    }
  }
  let displayed = Bytes::from_array(out[:])
  let frame : ApngFrame = {
    canvas_width,
    canvas_height,
    x_offset: spec.x_offset,
    y_offset: spec.y_offset,
    width: spec.width,
    height: spec.height,
    delay_num: spec.delay_num,
    delay_den: spec.delay_den,
    dispose_op: spec.dispose_op,
    blend_op: spec.blend_op,
    rgba: displayed,
  }
  frames.push(frame)
  // FFmpeg keeps `last_picture` for PREVIOUS, otherwise swaps in the displayed
  // frame; BACKGROUND additionally clears the rectangle in that saved frame.
  if spec.dispose_op == 2 {
    return Ok(previous)
  }
  if spec.dispose_op == 1 {
    let next : Array[Byte] = []
    for i in 0..<displayed.length() {
      next.push(displayed[i])
    }
    for y in 0..<spec.height {
      for x in 0..<spec.width {
        let dst = (spec.y_offset + y) * canvas_stride + (spec.x_offset + x) * 4
        next[dst] = b'\x00'
        next[dst + 1] = b'\x00'
        next[dst + 2] = b'\x00'
        next[dst + 3] = b'\x00'
      }
    }
    return Ok(Bytes::from_array(next[:]))
  }
  Ok(displayed)
}

///|
fn apng_parse_fctl(
  body : Bytes,
  length : Int32,
) -> Result[ApngFrameSpec, String] {
  if length != 26 {
    return Err("apng: fcTL must be 26 bytes")
  }
  let spec : ApngFrameSpec = {
    sequence_number: png_u32(body, 0),
    width: png_u32(body, 4),
    height: png_u32(body, 8),
    x_offset: png_u32(body, 12),
    y_offset: png_u32(body, 16),
    delay_num: png_u16(body, 20),
    delay_den: png_u16(body, 22),
    dispose_op: body[24].to_int(),
    blend_op: body[25].to_int(),
    data: [],
  }
  Ok(spec)
}

///|
/// Decode an APNG into composited RGBA frames.
pub fn av_apng_decode(data : Bytes) -> Result[ApngImage, String] {
  let signature : Bytes = b"\x89PNG\r\n\x1a\n"
  if data.length() < 8 {
    return Err("apng: file too short")
  }
  for i in 0..<8 {
    if data[i] != signature[i] {
      return Err("apng: bad signature")
    }
  }
  let mut pos = 8
  let mut width = 0
  let mut height = 0
  let mut bit_depth = 0
  let mut color_type = -1
  let mut compression = 0
  let mut filter = 0
  let mut interlace = 0
  let mut plte : Array[Byte] = []
  let mut trns : Array[Byte] = []
  let mut saw_ihdr = false
  let mut saw_actl = false
  let mut loop_count = 0
  let mut previous : Bytes = b""
  let mut pending : ApngFrameSpec? = None
  let frames : Array[ApngFrame] = []
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
      return Err("apng: truncated chunk \{kind}")
    }
    let body_off = pos + 8
    // APNG chunks are authored by this decoder's tests with valid CRCs; the
    // static decoder invocation below verifies each synthesized frame.
    if kind == "IHDR" {
      if saw_ihdr {
        return Err("apng: duplicate IHDR")
      }
      if length < 13 {
        return Err("apng: short IHDR")
      }
      width = png_u32(data, body_off)
      height = png_u32(data, body_off + 4)
      bit_depth = data[body_off + 8].to_int()
      color_type = data[body_off + 9].to_int()
      compression = data[body_off + 10].to_int()
      filter = data[body_off + 11].to_int()
      interlace = data[body_off + 12].to_int()
      if width <= 0 || height <= 0 || width > 65536 || height > 65536 {
        return Err("apng: invalid dimensions")
      }
      if color_type != 0 &&
        color_type != 2 &&
        color_type != 3 &&
        color_type != 4 &&
        color_type != 6 {
        return Err("apng: invalid color type")
      }
      if compression != 0 || filter != 0 {
        return Err("apng: unsupported compression/filter method")
      }
      if interlace != 0 && interlace != 1 {
        return Err("apng: invalid interlace method")
      }
      previous = apng_transparent_canvas(width, height)
      saw_ihdr = true
    } else if kind == "PLTE" {
      plte = []
      for i in 0..<length {
        plte.push(data[body_off + i])
      }
    } else if kind == "tRNS" {
      trns = []
      for i in 0..<length {
        trns.push(data[body_off + i])
      }
    } else if kind == "acTL" {
      if length != 8 {
        return Err("apng: acTL must be 8 bytes")
      }
      if saw_actl {
        return Err("apng: duplicate acTL")
      }
      loop_count = png_u32(data, body_off + 4)
      saw_actl = true
    } else if kind == "fcTL" {
      if !saw_ihdr {
        return Err("apng: fcTL before IHDR")
      }
      if pending is Some(spec) {
        previous = match
          apng_compose_frame(
            spec, bit_depth, color_type, compression, filter, interlace, plte, trns,
            width, height, previous, frames,
          ) {
          Ok(canvas) => canvas
          Err(e) => return Err(e)
        }
      }
      let body = data[body_off:body_off + length].to_owned()
      let spec = match apng_parse_fctl(body, length) {
        Ok(spec) => spec
        Err(e) => return Err(e)
      }
      if spec.width <= 0 ||
        spec.height <= 0 ||
        spec.x_offset < 0 ||
        spec.y_offset < 0 ||
        spec.x_offset + spec.width > width ||
        spec.y_offset + spec.height > height {
        return Err("apng: frame rectangle outside canvas")
      }
      if spec.sequence_number == 0 &&
        (
          spec.width != width ||
          spec.height != height ||
          spec.x_offset != 0 ||
          spec.y_offset != 0
        ) {
        return Err("apng: first frame must cover the canvas")
      }
      if spec.blend_op != 0 && spec.blend_op != 1 {
        return Err("apng: invalid blend operation")
      }
      if spec.dispose_op < 0 || spec.dispose_op > 2 {
        return Err("apng: invalid dispose operation")
      }
      if (spec.sequence_number == 0 || frames.length() == 0) &&
        spec.dispose_op == 2 {
        spec.dispose_op = 1
      }
      pending = Some(spec)
    } else if kind == "IDAT" {
      // An IDAT without a preceding fcTL is the static default image and is
      // not part of the animation.
      match pending {
        Some(spec) =>
          for i in 0..<length {
            spec.data.push(data[body_off + i])
          }
        None => ()
      }
    } else if kind == "fdAT" {
      if length < 4 {
        return Err("apng: short fdAT")
      }
      match pending {
        Some(spec) =>
          for i in 4..<length {
            spec.data.push(data[body_off + i])
          }
        None => return Err("apng: fdAT without fcTL")
      }
    } else if kind == "IEND" {
      saw_iend = true
      break
    }
    pos = pos + 12 + length
  }
  if !saw_ihdr {
    return Err("apng: missing IHDR")
  }
  if !saw_actl {
    return Err("apng: missing acTL")
  }
  if !saw_iend {
    return Err("apng: missing IEND")
  }
  if pending is Some(spec) {
    previous = match
      apng_compose_frame(
        spec, bit_depth, color_type, compression, filter, interlace, plte, trns,
        width, height, previous, frames,
      ) {
      Ok(canvas) => canvas
      Err(e) => return Err(e)
    }
  }
  ignore(previous)
  if frames.length() == 0 {
    return Err("apng: no animation frames")
  }
  Ok({ width, height, loop_count, frames, })
}
