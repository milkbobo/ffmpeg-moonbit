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
    println("usage: probe <media-file> [<media-file>...]")
    println("  prints ffprobe-style JSON (format + streams) for each file")
    return
  }
  let mut failed = 0
  for path in args[1:] {
    match probe_one(path) {
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
fn probe_one(path : String) -> Result[String, String] raise {
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data) catch { e => return Err(e.message()) }
  Ok(mf.probe_json())
}
