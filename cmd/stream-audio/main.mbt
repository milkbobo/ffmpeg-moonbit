///|
/// `stream-audio` - the sixth JSON CLI command: decode an HLS media/master
/// playlist or a DASH MPD through the adaptive-streaming facade.
///
///   moon run cmd/stream-audio -- <playlist.m3u8|manifest.mpd>
///                                [--dir DIR] [--output out.wav]
///                                [--rate 8000..192000]
///                                [--variant N] [--reloads N]
///
/// Segment resources are read from `--dir` (default: the playlist's own
/// directory) by filename: `media_fetch_path_key` strips any scheme, host,
/// query and fragment from the resolved URI, so a downloaded bundle works
/// offline with no HTTP client. `--reloads` enables live playlist refresh
/// through the same reader, bounded to avoid unbounded polling.
/// Prints the same JSON summary as `decode-audio`, and optionally writes a
/// 16-bit PCM WAV.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: stream-audio <playlist> [--dir DIR] [--output out.wav]")
    println(
      "                              [--rate N] [--variant N] [--reloads N]",
    )
    println("  decodes HLS/DASH segments via StreamingMedia; reads resources")
    println("  by filename from --dir (default: playlist directory)")
    return
  }
  let mut path = ""
  let mut dir = ""
  let mut output = ""
  let mut rate : Int32 = 0
  let mut variant : Int32? = None
  let mut reloads : Int32 = 0
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--dir" && i + 1 < args.length() {
      dir = args[i + 1]
      i = i + 2
    } else if a == "--output" && i + 1 < args.length() {
      output = args[i + 1]
      i = i + 2
    } else if a == "--rate" && i + 1 < args.length() {
      rate = @string.parse_int(args[i + 1]) catch {
        _ => die("stream-audio: --rate expects a number")
      }
      i = i + 2
    } else if a == "--variant" && i + 1 < args.length() {
      variant = Some(
        @string.parse_int(args[i + 1]) catch {
          _ => die("stream-audio: --variant expects a number")
        },
      )
      i = i + 2
    } else if a == "--reloads" && i + 1 < args.length() {
      reloads = @string.parse_int(args[i + 1]) catch {
        _ => die("stream-audio: --reloads expects a number")
      }
      i = i + 2
    } else if a == "--dir" ||
      a == "--output" ||
      a == "--rate" ||
      a == "--variant" ||
      a == "--reloads" {
      die("stream-audio: \{a} requires a value")
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      die("stream-audio: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    die("stream-audio: no playlist")
  }
  if dir == "" {
    dir = parent_dir(path)
  }
  let playlist = @fs.read_file_to_bytes(path)
  let fetch = @avf.media_fetch_from_reader(key => {
    let full = join_path(dir, key)
    try @fs.read_file_to_bytes(full) |> Ok catch {
      _ => Err("cannot read \{full}")
    }
  })
  let session = @avf.StreamingMedia::open(
    playlist,
    fetch,
    base_uri=path,
    variant~,
    playlist_fetch=Some(fetch),
    max_reloads=reloads,
  ) catch {
    e => die("stream-audio: \{path}: \{e.message()}")
  }
  let decoded = session.decode_audio() catch {
    e => die("stream-audio: decode: \{e.message()}")
  }
  let audio = if rate != 0 {
    decoded.resample_to(rate) catch {
      e => die("stream-audio: \{e.message()}")
    }
  } else {
    decoded
  }
  if output != "" {
    let wav = audio.to_wav_s16() catch {
      e => die("stream-audio: wav export: \{e.message()}")
    }
    @fs.write_bytes_to_file(output, wav)
  }
  println(audio.summary_json())
}

///|
/// Print the reason before aborting: on the Wasm backend `fail` aborts with
/// an opaque "unreachable" and no message, so the CLI would otherwise fail
/// silently when a segment resource is missing.
fn[T] die(message : String) -> T raise {
  println(message)
  fail(message)
}

///|
/// Directory part of a path (everything before the last '/' or '\\'), or "."
/// when the path has no separator.
fn parent_dir(path : String) -> String {
  let mut last = -1
  for i = 0; i < path.length(); i = i + 1 {
    let c = path[i].to_int()
    if c == '/'.to_int() || c == '\\'.to_int() {
      last = i
    }
  }
  if last < 0 {
    "."
  } else if last == 0 {
    "/"
  } else {
    path[:last].to_owned()
  }
}

///|
/// Join a directory and a bare filename. A trailing separator is not doubled.
fn join_path(dir : String, name : String) -> String {
  if dir == "" {
    return name
  }
  let last = dir[dir.length() - 1].to_int()
  if last == '/'.to_int() || last == '\\'.to_int() {
    dir + name
  } else {
    dir + "/" + name
  }
}
