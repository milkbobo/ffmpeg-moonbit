///|
/// `probe` - the first JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/probe -- <media-file> [<media-file>...]
///
/// For every argument: read the file, open it through the unified playback
/// API (`MediaFile::open` probes the format and builds the stream table) and
/// print the ffprobe-style JSON `probe_json` renders. Errors print on stderr
/// as `probe: <file>: <message>` and set a non-zero exit path (the first
/// failure still processes the remaining arguments, like ffprobe does).
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: probe [--g726-bits 2..5] <media-file> [<media-file>...]")
    println("  prints ffprobe-style JSON (format + streams) for each file")
    return
  }
  let (g726_bits, first_path) = if args[1] == "--g726-bits" {
    if args.length() < 4 {
      fail("probe: --g726-bits requires a value and at least one input file")
    }
    let bits = @string.parse_int(args[2]) catch {
      _ => fail("probe: --g726-bits expects a number")
    }
    (bits, 3)
  } else {
    (4, 1)
  }
  let mut failed = 0
  for path in args[first_path:] {
    match probe_one(path, g726_bits) {
      Ok(json) => {
        println("== \{path}")
        println(json)
      }
      Err(msg) => {
        println("probe: \{path}: \{msg}")
        failed = failed + 1
      }
    }
  }
  if failed > 0 {
    fail("\{failed} file(s) failed to probe")
  }
}

///|
/// Read one file and render its probe JSON; `String` errors keep the
/// human-readable cause (`MediaError::message`).
fn probe_one(path : String, g726_bits : Int32) -> Result[String, String] raise {
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data, filename=path, g726_bits~) catch {
    e => return Err(e.message())
  }
  Ok(mf.probe_json())
}
