///|
/// `extract-frame` - the fourth JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/extract-frame -- <media-file> [--index N]
///       [--format native|yuv|rgb24|bgr24] [--scale W:H] [--output out.yuv]
///
/// Decodes the first video stream through the unified playback API and
/// writes frame N to `--output` (default extension chosen per format):
/// planar YUV (`VideoFrame::yuv_bytes`) or packed RGB24/BGR24 through the
/// libswscale port (4:2:0 sources; other subsampling keeps the YUV form).
/// A JSON summary on stdout reports codec, dimensions, format and bytes.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: extract-frame <media-file> [--index N] [--output out.yuv]")
    println("  decodes the first video stream, writes frame N as planar YUV")
    return
  }
  let mut path = ""
  let mut index = 0
  let mut format = "native"
  let mut scale : (Int32, Int32)? = None
  let mut output = ""
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--scale" && i + 1 < args.length() {
      let parts : Array[StringView] = args[i + 1].split(":").collect()
      if parts.length() != 2 {
        println("extract-frame: --scale expects W:H (both even, >= 2)")
        return
      }
      let sw_ = @string.parse_int(parts[0].to_owned()) catch {
        _ => {
          println("extract-frame: --scale width must be a number")
          return
        }
      }
      let sh_ = @string.parse_int(parts[1].to_owned()) catch {
        _ => {
          println("extract-frame: --scale height must be a number")
          return
        }
      }
      if sw_ < 2 || sh_ < 2 || sw_ > 16384 || sh_ > 16384 {
        println("extract-frame: --scale expects W:H in 2..=16384")
        return
      }
      scale = Some((sw_, sh_))
      i = i + 2
    } else if (a == "--index" || a == "--output" || a == "--format") &&
      i + 1 < args.length() {
      if a == "--index" {
        index = @string.parse_int(args[i + 1]) catch {
          _ => {
            println(
              "extract-frame: --index expects a number, got \{args[i + 1]}",
            )
            return
          }
        }
      } else if a == "--output" {
        output = args[i + 1]
      } else {
        format = args[i + 1]
        if format != "native" &&
          format != "yuv" &&
          format != "rgb24" &&
          format != "bgr24" {
          fail("extract-frame: --format must be native, yuv, rgb24 or bgr24")
        }
      }
      i = i + 2
    } else if a == "--index" || a == "--output" || a == "--format" {
      println("extract-frame: \{a} requires a value")
      return
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      println("extract-frame: unexpected extra argument \{a}")
      return
    }
  }
  if path == "" {
    println("extract-frame: no input file")
    return
  }
  if format != "native" &&
    format != "yuv" &&
    format != "rgb24" &&
    format != "bgr24" {
    println("extract-frame: --format must be native, yuv, rgb24 or bgr24")
    return
  }
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data) catch {
    e => {
      println("extract-frame: \{path}: \{e.message()}")
      return
    }
  }
  let mut video = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if video < 0 && mf.streams()[i].media_type == @avf.MediaType::Video {
      video = i
    }
  }
  if video < 0 {
    println("extract-frame: no video stream in \{path}")
    return
  }
  let dec = @avf.VideoDecoder::open(mf.streams()[video]) catch {
    e => {
      println("extract-frame: \{path}: \{e.message()}")
      return
    }
  }
  // Feed packets until frame `index` leaves the decoder (the HEVC batch
  // flush at EOF covers the tail frames).
  let mut seen = 0
  let mut got : @avf.VideoFrame? = None
  while true {
    if got is Some(_) {
      break
    }
    let pkt = match mf.next_packet() {
      Some(p) => p
      None => break
    }
    if pkt.stream_index != video {
      continue
    }
    for f in dec.decode(pkt) {
      if seen == index {
        got = Some(f)
        break
      }
      seen = seen + 1
    }
  }
  if got is None {
    for f in dec.finish_video() {
      if seen == index {
        got = Some(f)
        break
      }
      seen = seen + 1
    }
  }
  let frame = match got {
    Some(f) => f
    None => {
      println("extract-frame: stream has only \{seen} frame(s)")
      return
    }
  }
  let mut out_w = 0
  let mut out_h = 0
  let yuv = frame.pixel_bytes()
  let image_format = frame.image_pixel_format()
  let w = frame.width()
  let h = frame.height()
  // Split the compact planar blob into its three planes for the RGB path.
  let split = fn() -> (Bytes, Bytes, Bytes)? {
    let ylen = w * h
    let clen = (w + 1) / 2 * ((h + 1) / 2)
    if yuv.length() < ylen + 2 * clen {
      return None
    }
    Some(
      (
        yuv[0:ylen].to_owned(),
        yuv[ylen:ylen + clen].to_owned(),
        yuv[ylen + clen:ylen + 2 * clen].to_owned(),
      ),
    )
  }
  if scale is None {
    out_w = w
    out_h = h
  }
  let payload = if scale is Some((dw, dh)) {
    out_w = dw
    out_h = dh
    if image_format is Some(fmt) {
      println(
        "extract-frame: --scale needs a planar 4:2:0 frame, got \{fmt}; use --format native",
      )
      return
    }
    if w % 2 != 0 || h % 2 != 0 {
      println("extract-frame: --scale needs an even-sized 4:2:0 frame")
      return
    }
    match split() {
      Some((py, pu, pv)) =>
        if format == "rgb24" || format == "bgr24" {
          let rs = @sws.SwsRgbScaler::new(
            src_w=w,
            src_h=h,
            dst_w=dw,
            dst_h=dh,
            bgr=format == "bgr24",
          ) catch {
            InvalidScaleConfig(m) => {
              println("extract-frame: \{m}")
              return
            }
          }
          rs.scale(py, pu, pv) catch {
            InvalidScaleConfig(m) => {
              println("extract-frame: \{m}")
              return
            }
          }
        } else {
          let ps = @sws.SwsPlanarScaler::new(
            src_w=w,
            src_h=h,
            dst_w=dw,
            dst_h=dh,
          ) catch {
            InvalidScaleConfig(m) => {
              println("extract-frame: \{m}")
              return
            }
          }
          let (dy, du, dv) = ps.scale(py, pu, pv) catch {
            InvalidScaleConfig(m) => {
              println("extract-frame: \{m}")
              return
            }
          }
          let out : Array[Byte] = []
          for plane in [dy, du, dv] {
            for b in plane {
              out.push(b)
            }
          }
          Bytes::from_array(out)
        }
      None => {
        println(
          "extract-frame: frame payload is not 4:2:0 planar; cannot scale",
        )
        return
      }
    }
  } else if format == "native" {
    yuv
  } else if format == "yuv" {
    if image_format is Some(fmt) && !fmt.has_prefix("yuv") {
      println(
        "extract-frame: image format \{fmt} requires --format native or RGB output",
      )
      return
    }
    yuv
  } else if image_format is Some(fmt) {
    if fmt != "rgb24" && fmt != "bgr24" && fmt != "rgba" && fmt != "gray" {
      println(
        "extract-frame: RGB conversion from \{fmt} is unavailable; use --format native",
      )
      return
    }
    let out : Array[Byte] = []
    let step = if fmt == "gray" { 1 } else if fmt == "rgba" { 4 } else { 3 }
    for i in 0..<(w * h) {
      let base = i * step
      let r = yuv[base + (if fmt == "bgr24" { 2 } else { 0 })]
      let g = yuv[base + (if fmt == "gray" { 0 } else { 1 })]
      let b = yuv[base +
        (if fmt == "gray" { 0 } else if fmt == "bgr24" { 0 } else { 2 })]
      if format == "bgr24" {
        out.push(b)
        out.push(g)
        out.push(r)
      } else {
        out.push(r)
        out.push(g)
        out.push(b)
      }
    }
    Bytes::from_array(out)
  } else if w % 2 != 0 || h % 2 != 0 {
    println(
      "extract-frame: rgb output needs an even-sized 4:2:0 frame; use --format yuv",
    )
    return
  } else {
    match split() {
      Some((py, pu, pv)) => {
        let sw = @sws.Yuv2Rgb::mpeg()
        sw.yuv420_to_rgb24(py, pu, pv, w, h, bgr=format == "bgr24")
      }
      None => {
        println(
          "extract-frame: frame payload is not 4:2:0 planar; use --format yuv",
        )
        return
      }
    }
  }
  let fmt = if format == "native" || format == "yuv" {
    image_format.unwrap_or("planar-yuv")
  } else if format == "rgb24" {
    "packed-rgb24"
  } else {
    "packed-bgr24"
  }
  if output == "" {
    output = if format == "native" && image_format is Some(native_fmt) {
      "frame.\{native_fmt}"
    } else if format == "rgb24" {
      "frame.rgb"
    } else if format == "bgr24" {
      "frame.bgr"
    } else {
      "frame.yuv"
    }
  }
  @fs.write_bytes_to_file(output, payload)
  println(
    "{\n  \"codec_name\": \"\{mf.streams()[video].codec_id}\",\n  \"frame_index\": \{index},\n  \"width\": \{out_w},\n  \"height\": \{out_h},\n  \"bit_depth\": \{frame.bit_depth()},\n  \"format\": \"\{fmt}\",\n  \"bytes\": \{payload.length()}\n}",
  )
}
