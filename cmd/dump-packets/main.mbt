///|
/// `dump-packets` - the second JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/dump-packets -- <media-file> [--stream N] [--limit N]
///
/// Reads the file through the unified playback API and prints one JSON
/// object per packet (ffprobe `-show_packets` style, one per line):
/// `stream_index`, `pts_ms` (the container's own timebase, converted to
/// milliseconds), `size` and `flags` (`K` = keyframe). `--stream N` keeps
/// only stream N's packets; `--limit N` caps the number of emitted lines.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: dump-packets <media-file> [--stream N] [--limit N]")
    println(
      "  prints one JSON packet record per line, ffprobe -show_packets style",
    )
    return
  }
  let mut path = ""
  let mut stream = -1
  let mut limit = -1
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if (a == "--stream" || a == "--limit") && i + 1 < args.length() {
      let v = @string.parse_int(args[i + 1]) catch {
        _ => fail("dump-packets: \{a} expects a number, got \{args[i + 1]}")
      }
      if a == "--stream" {
        stream = v
      } else {
        limit = v
      }
      i = i + 2
    } else if a == "--stream" || a == "--limit" {
      fail("dump-packets: \{a} requires a value")
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      fail("dump-packets: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    fail("dump-packets: no input file")
  }
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data) catch {
    e => fail("dump-packets: \{path}: \{e.message()}")
  }
  // One JSON record per line; the trailing newline the renderer appends
  // plus println's own leaves a final blank line, which JSONL consumers
  // tolerate (core has no newline-free print intrinsic).
  println(mf.dump_packets_json(stream~, limit~))
}
