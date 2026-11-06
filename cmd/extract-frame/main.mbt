///|
/// `extract-frame` - the fourth JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/extract-frame -- <media-file> [--index N]
///       [--format yuv|rgb24|bgr24] [--output out.yuv]
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
  let mut format = "yuv"
  let mut output = ""
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if (a == "--index" || a == "--output" || a == "--format") &&
      i + 1 < args.length() {
      if a == "--index" {
        index = @string.parse_int(args[i + 1]) catch {
          _ => {
            println("extract-frame: --index expects a number, got \{args[i + 1]}")
            return
          }
        }
      } else if a == "--output" {
        output = args[i + 1]
      } else {
        format = args[i + 1]
        if format != "yuv" && format != "rgb24" && format != "bgr24" {
          fail("extract-frame: --format must be yuv, rgb24 or bgr24")
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
  if format != "yuv" && format != "rgb24" && format != "bgr24" {
    println("extract-frame: --format must be yuv, rgb24 or bgr24")
    return
  }
  if output == "" {
    output = if format == "rgb24" {
      "frame.rgb"
    } else if format == "bgr24" {
      "frame.bgr"
    } else {
      "frame.yuv"
    }
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
  let yuv = frame.yuv_bytes()
  let w = frame.width()
  let h = frame.height()
  // Split the compact planar blob into its three planes for the RGB path.
  let split = fn () -> (Bytes, Bytes, Bytes)? {
    let ylen = w * h
    let clen = ((w + 1) / 2) * ((h + 1) / 2)
    if yuv.length() < ylen + 2 * clen {
      return None
    }
    Some((
      yuv[0:ylen].to_owned(),
      yuv[ylen:ylen + clen].to_owned(),
      yuv[ylen + clen:ylen + 2 * clen].to_owned(),
    ))
  }
  let payload = if format == "yuv" {
    yuv
  } else if w % 2 != 0 || h % 2 != 0 {
    println("extract-frame: rgb output needs an even-sized 4:2:0 frame; use --format yuv")
    return
  } else {
    match split() {
      Some((py, pu, pv)) => {
        let sw = @sws.Yuv2Rgb::mpeg()
        sw.yuv420_to_rgb24(py, pu, pv, w, h, bgr=format == "bgr24")
      }
      None => {
        println("extract-frame: frame payload is not 4:2:0 planar; use --format yuv")
        return
      }
    }
  }
  @fs.write_bytes_to_file(output, payload)
  let fmt = if format == "yuv" {
    "planar-yuv"
  } else if format == "rgb24" {
    "packed-rgb24"
  } else {
    "packed-bgr24"
  }
  println(
    "{\n  \"codec_name\": \"\{mf.streams()[video].codec_id}\",\n  \"frame_index\": \{index},\n  \"width\": \{w},\n  \"height\": \{h},\n  \"bit_depth\": \{frame.bit_depth()},\n  \"format\": \"\{fmt}\",\n  \"bytes\": \{payload.length()}\n}",
  )
}
