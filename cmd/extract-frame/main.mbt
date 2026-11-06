///|
/// `extract-frame` - the fourth JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/extract-frame -- <media-file> [--index N] [--output out.yuv]
///
/// Decodes the first video stream through the unified playback API and
/// writes frame N's planes (planar YUV, `VideoFrame::yuv_bytes`) to
/// `--output` (default `frame.yuv`), printing a JSON summary on stdout:
/// codec, dimensions, bit depth, plane layout and byte count.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: extract-frame <media-file> [--index N] [--output out.yuv]")
    println("  decodes the first video stream, writes frame N as planar YUV")
    return
  }
  let mut path = ""
  let mut index = 0
  let mut output = "frame.yuv"
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if (a == "--index" || a == "--output") && i + 1 < args.length() {
      if a == "--index" {
        index = @string.parse_int(args[i + 1]) catch {
          _ => fail("extract-frame: --index expects a number, got \{args[i + 1]}")
        }
      } else {
        output = args[i + 1]
      }
      i = i + 2
    } else if a == "--index" || a == "--output" {
      fail("extract-frame: \{a} requires a value")
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      fail("extract-frame: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    fail("extract-frame: no input file")
  }
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data) catch {
    e => fail("extract-frame: \{path}: \{e.message()}")
  }
  let mut video = -1
  for i = 0; i < mf.streams().length(); i = i + 1 {
    if video < 0 && mf.streams()[i].media_type == @avf.MediaType::Video {
      video = i
    }
  }
  if video < 0 {
    fail("extract-frame: no video stream in \{path}")
  }
  let dec = @avf.VideoDecoder::open(mf.streams()[video]) catch {
    e => fail("extract-frame: \{path}: \{e.message()}")
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
    None => fail("extract-frame: stream has only \{seen} frame(s)")
  }
  let yuv = frame.yuv_bytes()
  @fs.write_bytes_to_file(output, yuv)
  println(
    "{\n  \"codec_name\": \"\{mf.streams()[video].codec_id}\",\n  \"frame_index\": \{index},\n  \"width\": \{frame.width()},\n  \"height\": \{frame.height()},\n  \"bit_depth\": \{frame.bit_depth()},\n  \"format\": \"planar-yuv\",\n  \"yuv_bytes\": \{yuv.length()}\n}",
  )
}
